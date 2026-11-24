import Foundation
import FSKit
import JottaFSCore
import OSLog

private let writeLogger = Logger(subsystem: "no.alrek.jottafs.extension", category: "Write")

/// Write support (docs/write-support-design.md). Every mutation is confined to
/// `JottaFSWriteScope` and checked before any network request; everything
/// else stays read-only.
extension JottaFSVolume: FSVolume.OpenCloseHandler {

    // MARK: Scope

    /// The remote location of an existing item that may be modified: strictly
    /// inside the write scope (never the scope folder itself).
    func writableLocation(of item: JottacloudItem) throws -> (volume: JottacloudRemoteVolume, path: String) {
        guard let location = item.remoteLocation,
              JottaFSWriteScope.contains(
                  device: location.volume.device,
                  mountpoint: location.volume.mountpoint,
                  path: location.path
              )
        else {
            throw POSIXError(.EPERM)
        }
        return location
    }

    /// Whether the item gets write permission bits: the scope folder, its
    /// contents, and its parent mountpoint (so the scope folder can be made).
    func grantsWritePermission(_ item: JottacloudItem) -> Bool {
        switch item.role {
        case .mountpoint(let volume):
            return JottaFSWriteScope.isScopeMountpoint(device: volume.device, mountpoint: volume.mountpoint)
        case .remote(let volume, let path):
            return JottaFSWriteScope.isScopeRoot(device: volume.device, mountpoint: volume.mountpoint, path: path)
                || JottaFSWriteScope.contains(device: volume.device, mountpoint: volume.mountpoint, path: path)
        default:
            return false
        }
    }

    private func validateNewName(_ name: FSFileName) throws -> String {
        guard let string = name.string else {
            throw POSIXError(.EINVAL)
        }
        do {
            try JottaFSNames.validate(string)
        } catch JottaFSNameError.macMetadata {
            throw POSIXError(.EPERM)
        } catch {
            throw POSIXError(.EINVAL)
        }
        return string
    }

    /// A log-safe description: error type, HTTP status or Jottacloud error
    /// text; never tokens, URLs or file names.
    func describe(_ error: Error) -> String {
        if let error = error as? JottacloudError {
            if case .httpStatus(let status) = error {
                return "HTTP \(status)"
            }
            return error.localizedDescription
        }
        if let error = error as? POSIXError {
            return "POSIX \(error.code.rawValue)"
        }
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code)"
    }

    private func posixError(_ error: Error) -> Error {
        if error is POSIXError {
            return error
        }
        writeLogger.error("Write request failed (\(self.describe(error), privacy: .public)).")
        if case JottacloudError.httpStatus(let status) = error {
            switch status {
            case 404: return POSIXError(.ENOENT)
            case 409: return POSIXError(.EEXIST)
            case 401, 403: return POSIXError(.EACCES)
            case 507: return POSIXError(.ENOSPC)
            default: break
            }
        }
        if (error as? CocoaError)?.code == .fileWriteOutOfSpace {
            return POSIXError(.ENOSPC)
        }
        return POSIXError(.EIO)
    }

    private func directoryEntry(
        name: String,
        kind: RemoteEntry.Kind,
        size: UInt64,
        modified: Date?,
        volume: JottacloudRemoteVolume,
        path: String
    ) -> JottacloudDirectoryEntry {
        JottacloudDirectoryEntry(
            entry: RemoteEntry(name: name, kind: kind, size: size, modified: modified),
            role: .remote(volume, path: path)
        )
    }

    private func existingChild(named name: String, in parent: JottacloudItem) async throws -> JottacloudDirectoryEntry? {
        let snapshot = try await directoryCache.list(path: parent.path, role: parent.role)
        return snapshot.entries.first { JottaFSWriteScope.sameName($0.entry.name, name) }
    }

    // MARK: Create

    func create(
        named name: FSFileName,
        type: FSItem.ItemType,
        in directory: FSItem
    ) async throws -> FSCreateItemResult {
        guard let parent = directory as? JottacloudItem, parent.entry.kind == .directory else {
            throw POSIXError(.ENOTDIR)
        }
        let newName = try validateNewName(name)
        guard let location = parent.childLocation(named: newName) else {
            throw POSIXError(.EPERM)
        }
        let device = location.volume.device
        let mountpoint = location.volume.mountpoint
        let inside = JottaFSWriteScope.contains(device: device, mountpoint: mountpoint, path: location.path)
        let isScopeFolder = type == .directory
            && JottaFSWriteScope.isScopeRoot(device: device, mountpoint: mountpoint, path: location.path)
        guard inside || isScopeFolder else {
            throw POSIXError(.EPERM)
        }
        guard type == .file || type == .directory else {
            throw POSIXError(.ENOTSUP)
        }
        if try await existingChild(named: newName, in: parent) != nil {
            throw POSIXError(.EEXIST)
        }

        let now = Date()
        let kind: RemoteEntry.Kind = type == .directory ? .directory : .file
        let entry = directoryEntry(
            name: newName, kind: kind, size: 0, modified: now,
            volume: location.volume, path: location.path
        )
        do {
            if kind == .directory {
                try await client.createFolder(volume: location.volume, path: location.path)
            }
        } catch {
            throw posixError(error)
        }
        let item = try itemStore.child(of: parent, entry: entry)
        if kind == .file {
            // Upload happens on close (or sync); until then the file is local.
            _ = try await staging.stage(item.identifier) { _ in }
            staging.markModified(item.identifier, size: 0, modified: now)
        }
        await directoryCache.recordPresent(entry, inDirectory: parent.path)
        writeLogger.info("Created \(kind == .directory ? "folder" : "file", privacy: .public) in write scope.")

        guard let result = FSCreateItemResult(
            newItem: item,
            newItemName: FSFileName(string: newName),
            newItemAttributes: attributes(for: item),
            directoryAttributes: attributes(for: parent),
            freeSpace: nil
        ) else {
            throw POSIXError(.EIO)
        }
        return result
    }

    // MARK: Read/write

    /// Stages an existing in-scope file, downloading its current contents
    /// unless `keepContents` is false (for example when truncating to zero).
    private func stage(_ item: JottacloudItem, keepContents: Bool) async throws -> StagedFile {
        let location = try writableLocation(of: item)
        let size = item.entry.size
        guard size <= StagingArea.maximumSize else {
            throw POSIXError(.EFBIG)
        }
        let client = client
        return try await staging.stage(item.identifier) { url in
            guard keepContents, size > 0 else {
                return
            }
            var offset: UInt64 = 0
            while offset < size {
                let chunk = try await client.readRange(
                    volume: location.volume,
                    path: location.path,
                    offset: offset,
                    length: 1 << 20,
                    fileSize: size
                )
                guard !chunk.isEmpty else {
                    throw POSIXError(.EIO)
                }
                try JottaFSStagingFile.write(chunk, to: url, at: offset)
                offset += UInt64(chunk.count)
            }
        }
    }

    func writeData(_ contents: Data, to fsItem: FSItem, at offset: off_t) async throws -> FSWriteFileResult {
        guard let item = fsItem as? JottacloudItem, item.entry.kind == .file, offset >= 0 else {
            throw POSIXError(.EINVAL)
        }
        _ = try writableLocation(of: item)
        let end = UInt64(offset) + UInt64(contents.count)
        guard end <= StagingArea.maximumSize else {
            throw POSIXError(.EFBIG)
        }
        do {
            let staged = try await stage(item, keepContents: true)
            let fileSize = try JottaFSStagingFile.write(contents, to: staged.url, at: UInt64(offset))
            staging.markModified(item.identifier, size: fileSize)
            updateEntry(item, size: fileSize, modified: Date())
        } catch {
            throw posixError(error)
        }
        guard let result = FSWriteFileResult(
            bytesWritten: contents.count,
            itemAttributes: attributes(for: item),
            freeSpace: nil
        ) else {
            throw POSIXError(.EIO)
        }
        return result
    }

    /// Reads from the staged copy if the file is being written.
    func stagedData(of item: JottacloudItem, at offset: off_t, length: Int) throws -> Data? {
        guard let staged = staging.file(item.identifier) else {
            return nil
        }
        return try JottaFSStagingFile.read(from: staged.url, at: UInt64(offset), length: length)
    }

    func stagedSize(of item: JottacloudItem) -> UInt64? {
        staging.file(item.identifier)?.size
    }

    private func updateEntry(_ item: JottacloudItem, size: UInt64, modified: Date?) {
        item.entry = RemoteEntry(
            name: item.entry.name,
            kind: item.entry.kind,
            size: size,
            modified: modified ?? item.entry.modified
        )
    }

    // MARK: Attributes

    func applyAttributes(
        _ request: FSItem.SetAttributesRequest,
        on fsItem: FSItem
    ) async throws -> FSSetAttributesResult {
        guard let item = fsItem as? JottacloudItem else {
            throw POSIXError(.EINVAL)
        }
        guard grantsWritePermission(item) else {
            throw POSIXError(.EPERM)
        }
        if item.entry.kind == .file, request.isValid(.size) {
            _ = try writableLocation(of: item)
            let newSize = request.size
            guard newSize <= StagingArea.maximumSize else {
                throw POSIXError(.EFBIG)
            }
            do {
                let staged = try await stage(item, keepContents: newSize > 0)
                try JottaFSStagingFile.truncate(staged.url, to: newSize)
                staging.markModified(item.identifier, size: newSize)
                updateEntry(item, size: newSize, modified: Date())
            } catch {
                throw posixError(error)
            }
            request.consumedAttributes.insert(.size)
        }
        if request.isValid(.modifyTime) {
            let time = request.modifyTime
            let date = Date(timeIntervalSince1970: TimeInterval(time.tv_sec))
            // Applied with the next upload of this file (no metadata-only
            // update in the first version).
            staging.setModified(item.identifier, date)
            if staging.file(item.identifier) != nil {
                updateEntry(item, size: item.entry.size, modified: date)
            }
            request.consumedAttributes.insert(.modifyTime)
        }
        // Jottacloud has no permissions, ownership, flags or other times;
        // accept and ignore them inside the scope so copies succeed.
        for attribute: FSItem.Attribute in [.mode, .uid, .gid, .flags, .accessTime, .changeTime, .birthTime, .backupTime, .addedTime]
            where request.isValid(attribute) {
            request.consumedAttributes.insert(attribute)
        }
        guard let result = FSSetAttributesResult(attributes: attributes(for: item), freeSpace: nil) else {
            throw POSIXError(.EIO)
        }
        return result
    }

    // MARK: Upload

    /// Uploads a dirty staged file and verifies it on Jottacloud.
    func flush(_ item: JottacloudItem) async throws {
        guard staging.file(item.identifier)?.dirty == true else {
            return
        }
        let location = try writableLocation(of: item)
        let id = item.identifier
        let staging = staging
        let client = client
        try await staging.serializeUpload(id) {
            guard let staged = staging.file(id), staged.dirty else {
                return
            }
            let snapshot = try staging.snapshot(staged)
            defer { try? FileManager.default.removeItem(at: snapshot) }
            let size = try JottaFSStagingFile.size(of: snapshot)
            let md5 = try JottaFSStagingFile.md5(of: snapshot)
            _ = try await client.upload(
                volume: location.volume,
                path: location.path,
                from: snapshot,
                size: size,
                md5: md5,
                created: staged.created,
                modified: staged.modified
            )
            staging.markUploaded(id, generation: staged.generation)
        }
        writeLogger.info("Uploaded a file in write scope.")
        if let parent = itemStore.item(identifier: item.parentIdentifier) {
            await directoryCache.recordPresent(
                JottacloudDirectoryEntry(entry: item.entry, role: item.role),
                inDirectory: parent.path
            )
        }
    }

    /// Uploads every dirty file; used by sync and on deactivation.
    func flushAll() async throws {
        var firstError: Error?
        for id in staging.dirtyIdentifiers {
            guard let item = itemStore.item(identifier: id) else {
                continue
            }
            do {
                try await flush(item)
            } catch {
                writeLogger.error("Upload failed (\(self.describe(error), privacy: .public)); the file stays staged for retry.")
                firstError = firstError ?? error
            }
        }
        if let firstError {
            throw posixError(firstError)
        }
    }

    // MARK: Open/close

    func openItem(_ item: FSItem, modes: FSVolume.OpenModes, context: FSContext) async throws {
        guard modes.contains(.write) else {
            return
        }
        guard let item = item as? JottacloudItem, item.entry.kind == .file else {
            throw POSIXError(.EISDIR)
        }
        _ = try writableLocation(of: item)
    }

    func closeItem(_ item: FSItem, modes: FSVolume.OpenModes, context: FSContext) async throws {
        guard !modes.contains(.write), let item = item as? JottacloudItem else {
            return
        }
        do {
            try await flush(item)
        } catch {
            // close(2) results are ignored by most apps; keep the data staged
            // and retry on the next close or sync (see the design document).
            writeLogger.error("Upload on close failed (\(self.describe(error), privacy: .public)); the file stays staged for retry.")
        }
    }

    // MARK: Remove

    func remove(_ fsItem: FSItem, from directory: FSItem) async throws -> FSRemoveItemResult {
        guard let item = fsItem as? JottacloudItem, let parent = directory as? JottacloudItem else {
            throw POSIXError(.EINVAL)
        }
        let location = try writableLocation(of: item)
        let isDirectory = item.entry.kind == .directory
        if isDirectory {
            await directoryCache.invalidate(path: item.path)
            let contents = try await directoryCache.list(path: item.path, role: item.role)
            guard contents.entries.isEmpty else {
                throw POSIXError(.ENOTEMPTY)
            }
        }
        do {
            try await client.trash(volume: location.volume, path: location.path, isDirectory: isDirectory)
        } catch JottacloudError.httpStatus(404) {
            // Created locally and never uploaded; nothing to trash remotely.
        } catch {
            throw posixError(error)
        }
        staging.discard(item.identifier)
        await directoryCache.recordAbsent(name: item.entry.name, inDirectory: parent.path)
        let itemAttributes = attributes(for: item)
        itemStore.remove(item)
        writeLogger.info("Moved an item in write scope to the Jottacloud trash.")
        guard let result = FSRemoveItemResult(
            itemAttributes: itemAttributes,
            directoryAttributes: attributes(for: parent),
            freeSpace: nil
        ) else {
            throw POSIXError(.EIO)
        }
        return result
    }

    // MARK: Rename

    func rename(
        _ fsItem: FSItem,
        from sourceDirectory: FSItem,
        to destinationName: FSFileName,
        in destinationDirectory: FSItem,
        over overItem: FSItem?
    ) async throws -> FSRenameItemResult {
        guard let item = fsItem as? JottacloudItem,
              let source = sourceDirectory as? JottacloudItem,
              let destination = destinationDirectory as? JottacloudItem
        else {
            throw POSIXError(.EINVAL)
        }
        let newName = try validateNewName(destinationName)
        let from = try writableLocation(of: item)
        guard let to = destination.childLocation(named: newName),
              to.volume == from.volume,
              JottaFSWriteScope.contains(device: to.volume.device, mountpoint: to.volume.mountpoint, path: to.path)
        else {
            throw POSIXError(.EPERM)
        }
        let isDirectory = item.entry.kind == .directory

        // The remote copy must hold the latest data before it is moved.
        if !isDirectory {
            do {
                try await flush(item)
            } catch {
                throw posixError(error)
            }
        }

        var overAttributes: FSItem.Attributes?
        if let over = overItem as? JottacloudItem, over !== item {
            let overLocation = try writableLocation(of: over)
            if over.entry.kind == .directory {
                await directoryCache.invalidate(path: over.path)
                let contents = try await directoryCache.list(path: over.path, role: over.role)
                guard contents.entries.isEmpty else {
                    throw POSIXError(.ENOTEMPTY)
                }
            }
            do {
                try await client.trash(
                    volume: overLocation.volume,
                    path: overLocation.path,
                    isDirectory: over.entry.kind == .directory
                )
            } catch JottacloudError.httpStatus(404) {
            } catch {
                throw posixError(error)
            }
            overAttributes = attributes(for: over)
            staging.discard(over.identifier)
            itemStore.remove(over)
        }

        do {
            try await client.move(volume: from.volume, from: from.path, to: to.path, isDirectory: isDirectory)
        } catch {
            throw posixError(error)
        }
        let oldName = item.entry.name
        try itemStore.move(item, to: destination, name: newName)
        await directoryCache.recordAbsent(name: oldName, inDirectory: source.path)
        await directoryCache.recordPresent(
            JottacloudDirectoryEntry(entry: item.entry, role: item.role),
            inDirectory: destination.path
        )
        if isDirectory {
            await directoryCache.invalidate(path: item.path)
        }
        writeLogger.info("Renamed an item in write scope.")

        guard let result = FSRenameItemResult(
            newName: FSFileName(string: newName),
            renamedItemAttributes: attributes(for: item),
            sourceDirectoryAttributes: attributes(for: source),
            destinationDirectoryAttributes: attributes(for: destination),
            overItemAttributes: overAttributes,
            freeSpace: nil
        ) else {
            throw POSIXError(.EIO)
        }
        return result
    }
}
