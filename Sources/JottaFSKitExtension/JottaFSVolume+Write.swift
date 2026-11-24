import Foundation
import FSKit
import JottaFSCore
import OSLog

private let writeLogger = Logger.extension("Write")

/// Write support (docs/write-support-design.md): everything inside the mounted
/// location can be created, written, renamed and deleted.
extension JottaFSVolume: FSVolume.OpenCloseHandler {

    // MARK: Permissions

    /// The remote location of an existing item that may be modified: any
    /// item inside the mounted location (not the volume root itself, the
    /// volume icon or the Trash).
    func writableLocation(of item: JottacloudItem) throws -> (volume: JottacloudRemoteVolume, path: String) {
        guard let location = item.remoteLocation else {
            throw POSIXError(.EPERM)
        }
        return location
    }

    /// Whether the item gets write permission bits.
    func grantsWritePermission(_ item: JottacloudItem) -> Bool {
        switch item.role {
        case .mountpoint, .remote:
            return true
        case .userTrash, .trashed, .trashLocal:
            // The Trash can be emptied and its items put back (the kernel
            // needs write permission on a folder to remove its entries);
            // writes to trashed files are refused by the handlers.
            return true
        default:
            return false
        }
    }

    /// Names the volume root provides itself (the Trash and the volume icon).
    func isReservedRootName(_ name: String) -> Bool {
        JottaFSNames.sameName(name, DirectoryCache.trashesName)
            || JottaFSNames.sameName(name, Self.volumeIconName)
    }

    private func validateNewName(_ name: FSFileName) throws -> String {
        guard let string = name.string else {
            throw POSIXError(.EINVAL)
        }
        do {
            try JottaFSNames.validate(string)
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

    func posixError(_ error: Error) -> Error {
        if error is POSIXError {
            return error
        }
        writeLogger.error("Write request failed (\(self.describe(error), privacy: .public)).")
        if case JottacloudError.grpcStatus(let status) = error {
            switch status {
            case 5: return POSIXError(.ENOENT)
            case 6: return POSIXError(.EEXIST)
            case 7, 16: return POSIXError(.EACCES)
            default: return POSIXError(.EIO)
            }
        }
        if case JottacloudError.notInTrash = error {
            return POSIXError(.EPERM)
        }
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
        return snapshot.entries.first { JottaFSNames.sameName($0.entry.name, name) }
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
        if case .userTrash = parent.role {
            return try await createTrashMetadata(named: newName, type: type, in: parent)
        }
        guard let location = parent.childLocation(named: newName),
              !(isVolumeRoot(parent) && isReservedRootName(newName))
        else {
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
        writeLogger.info("Created a \(kind == .directory ? "folder" : "file", privacy: .public).")

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
        if case .trashLocal(let url) = item.role {
            do {
                _ = try JottaFSStagingFile.write(contents, to: url, at: UInt64(offset))
            } catch {
                throw posixError(error)
            }
            guard let result = FSWriteFileResult(bytesWritten: contents.count, itemAttributes: attributes(for: item), freeSpace: nil) else {
                throw POSIXError(.EIO)
            }
            return result
        }
        _ = try writableLocation(of: item)
        let end = UInt64(offset) + UInt64(contents.count)
        guard end <= StagingArea.maximumSize else {
            throw POSIXError(.EFBIG)
        }
        do {
            _ = try await stage(item, keepContents: true)
            await readAhead.invalidate(item.identifier)
            let size = try staging.write(contents, to: item.identifier, at: UInt64(offset))
            updateEntry(item, size: size, modified: Date())
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
        switch item.role {
        case .trashLocal(let url):
            if request.isValid(.size) {
                do {
                    try JottaFSStagingFile.truncate(url, to: request.size)
                } catch {
                    throw posixError(error)
                }
                request.consumedAttributes.insert(.size)
            }
        case .userTrash, .trashed:
            // Trashed items cannot change; accept metadata-only requests
            // (Finder sets times and flags while moving items) without effect.
            guard !request.isValid(.size) else {
                throw POSIXError(.EPERM)
            }
        default:
            break
        }
        if case .remote = item.role {} else {
            for attribute: FSItem.Attribute in [.mode, .uid, .gid, .flags, .accessTime, .modifyTime, .changeTime, .birthTime, .backupTime, .addedTime]
                where request.isValid(attribute) {
                request.consumedAttributes.insert(attribute)
            }
            guard let result = FSSetAttributesResult(attributes: attributes(for: item), freeSpace: nil) else {
                throw POSIXError(.EIO)
            }
            return result
        }
        if item.entry.kind == .file, request.isValid(.size) {
            _ = try writableLocation(of: item)
            let newSize = request.size
            guard newSize <= StagingArea.maximumSize else {
                throw POSIXError(.EFBIG)
            }
            do {
                await readAhead.invalidate(item.identifier)
                _ = try await stage(item, keepContents: newSize > 0)
                try staging.truncate(item.identifier, to: newSize)
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
        // Path as seen through the mount, for Finder's upload progress. Built
        // as a string with an explicit isDirectory: URL path APIs that infer
        // directory-ness lstat the path, which re-enters this very volume and
        // deadlocks the extension (seen during a sync of a folder copy).
        let volumePath = item.path
        let anchorName = target.anchorName
        let mountPath = JottaFSStorage.mountPoint(anchorName: anchorName)?.path ?? "/Volumes/\(volumeName)"
        let mountedURL = URL(
            fileURLWithPath: "\(mountPath)/\(item.path)",
            isDirectory: false
        )
        let uploaded = UploadFlag()
        try await staging.serializeUpload(id) {
            guard let staged = staging.file(id), staged.dirty else {
                return
            }
            let clock = PhaseClock()
            let (snapshot, md5, hashedWhileWriting) = try staging.snapshot(id)
            defer { try? FileManager.default.removeItem(at: snapshot) }
            let size = try JottaFSStagingFile.size(of: snapshot)
            clock.mark("snapshot of \(size) bytes and md5 (\(size - min(size, hashedWhileWriting)) bytes hashed now)")
            let progress = UploadProgress(anchorName: anchorName, volumePath: volumePath, fileURL: mountedURL, totalBytes: size)
            defer {
                progress.finish()
                writeLogger.info("Upload progress: \(progress.summary, privacy: .public)")
            }
            do {
                _ = try await client.upload(
                    volume: location.volume,
                    path: location.path,
                    from: snapshot,
                    size: size,
                    md5: md5,
                    created: staged.created,
                    modified: staged.modified,
                    progress: { sent in progress.update(bytesSent: sent) },
                    phase: { name in clock.mark(name) }
                )
            } catch {
                writeLogger.error("Upload phases before the failure: \(clock.summary, privacy: .public)")
                throw error
            }
            staging.markUploaded(id, generation: staged.generation)
            uploaded.set()
            writeLogger.info("Upload phases: \(clock.summary, privacy: .public)")
        }
        guard uploaded.isSet else {
            return
        }
        // The remote file changed.
        await readAhead.invalidate(item.identifier)
        writeLogger.info("Uploaded a file.")
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
        if case .trashLocal = item.role {
            return
        }
        _ = try writableLocation(of: item)
    }

    /// Uploads when the last writer closes and only returns once the file is
    /// on Jottacloud, so close(2) — and Finder's copy and its "done" sound —
    /// complete only when the upload has. Jottacloud needs the whole file's
    /// MD5 before an upload can start, so the upload cannot overlap the
    /// writes (see docs/jottacloud-api-internals.md). A failed upload is
    /// returned as an error from close (Finder reports the copy as failed);
    /// the data stays staged and is retried on the next close or sync.
    func closeItem(_ item: FSItem, modes: FSVolume.OpenModes, context: FSContext) async throws {
        // `modes` are the modes still open: when none are left, the
        // read-ahead blocks are no longer needed.
        if modes.isEmpty, let item = item as? JottacloudItem {
            await readAhead.invalidate(item.identifier)
        }
        guard !modes.contains(.write),
              let item = item as? JottacloudItem,
              staging.file(item.identifier)?.dirty == true
        else {
            return
        }
        do {
            try await flush(item)
        } catch {
            writeLogger.error("Upload on close failed (\(self.describe(error), privacy: .public)); the file stays staged for retry.")
            throw posixError(error)
        }
    }

    // MARK: Remove

    func remove(_ fsItem: FSItem, from directory: FSItem) async throws -> FSRemoveItemResult {
        guard let item = fsItem as? JottacloudItem, let parent = directory as? JottacloudItem else {
            throw POSIXError(.EINVAL)
        }
        switch item.role {
        case .trashed, .trashLocal:
            return try await removeFromTrash(item, from: parent)
        default:
            break
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
        try await deletePermanently(item, at: location)
        await directoryCache.recordAbsent(name: item.entry.name, inDirectory: parent.path)
        let itemAttributes = attributes(for: item)
        itemStore.remove(item)
        guard let result = FSRemoveItemResult(
            itemAttributes: itemAttributes,
            directoryAttributes: attributes(for: parent),
            freeSpace: nil
        ) else {
            throw POSIXError(.EIO)
        }
        return result
    }

    /// Deletes a live item permanently, like unlink(2) on a local disk: it is
    /// trashed, then that trashed item is deleted permanently. Pending and
    /// running uploads of the file are stopped first, so they cannot create
    /// it again.
    private func deletePermanently(_ item: JottacloudItem, at location: (volume: JottacloudRemoteVolume, path: String)) async throws {
        await readAhead.invalidate(item.identifier)
        let isDirectory = item.entry.kind == .directory
        if !isDirectory {
            // An upload that has not started finds nothing to send; wait for
            // one that is running.
            staging.discard(item.identifier)
            await staging.waitForUpload(item.identifier)
        }
        let started = Date()
        do {
            try await client.trash(volume: location.volume, path: location.path, isDirectory: isDirectory)
        } catch JottacloudError.httpStatus(404) {
            // Created locally and never uploaded; nothing to delete remotely.
            staging.discard(item.identifier)
            return
        } catch {
            throw posixError(error)
        }
        staging.discard(item.identifier)
        if let servicePath = target.servicePath(volume: location.volume, path: location.path) {
            await deleteJustTrashed(servicePath: servicePath, since: started)
        } else {
            writeLogger.error("Removed an item to the Jottacloud trash (no permanent delete here).")
        }
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
        if case .userTrash = destination.role {
            switch item.role {
            case .remote:
                return try await moveToTrash(item, from: source, name: newName, in: destination, over: overItem)
            default:
                throw POSIXError(.EPERM)
            }
        }
        switch item.role {
        case .trashed, .trashLocal:
            return try await renameFromTrash(item, from: source, to: newName, in: destination, over: overItem)
        default:
            break
        }
        let from = try writableLocation(of: item)
        guard let to = destination.childLocation(named: newName),
              !(isVolumeRoot(destination) && isReservedRootName(newName))
        else {
            throw POSIXError(.EPERM)
        }
        guard to.volume == from.volume else {
            throw POSIXError(.EXDEV)
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
            // Replaced like on a local disk (apps that save by renaming a new
            // file over the old one would otherwise fill the Trash).
            try await deletePermanently(over, at: overLocation)
            overAttributes = attributes(for: over)
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
        writeLogger.info("Renamed an item.")

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

/// Shows upload progress on the file's icon in Finder. Finder ignores progress
/// updates published from inside the extension's sandbox (only the publish
/// and unpublish arrive), so updates go to `JottaFSProgressAgent`, which
/// publishes them unsandboxed. If the agent is unavailable, the extension
/// publishes locally, which still shows a bar that completes at the end.
final class UploadProgress: @unchecked Sendable {
    private let identifier = UUID().uuidString
    private let fileURL: URL
    private let total: Int64
    private let lock = NSLock()
    private var remote: JottaFSProgressServiceProtocol?
    private var local: Progress?
    private var lastSent = Date.distantPast
    private var updates = 0
    private var lastBytes: Int64 = 0
    private var finished = false

    init(anchorName: String, volumePath: String, fileURL: URL, totalBytes: UInt64) {
        self.fileURL = fileURL
        total = max(Int64(clamping: totalBytes), 1)
        let proxy = ProgressAgentClient.shared.proxy { [weak self] in self?.fallBackToLocal() }
        lock.withLock { remote = proxy }
        proxy?.beginUpload(identifier: identifier, anchorName: anchorName, path: volumePath, totalBytes: total)
        if proxy == nil {
            fallBackToLocal()
        }
    }

    func update(bytesSent: Int64) {
        let value = min(max(bytesSent, 0), total)
        let target: (JottaFSProgressServiceProtocol?, Progress?)? = lock.withLock {
            updates += 1
            lastBytes = value
            // At most ten updates per second.
            guard Date().timeIntervalSince(lastSent) >= 0.1 || value == total else {
                return nil
            }
            lastSent = Date()
            return (remote, local)
        }
        guard let target else {
            return
        }
        target.0?.updateUpload(identifier: identifier, bytesSent: value)
        target.1?.completedUnitCount = value
    }

    func finish() {
        let target: (JottaFSProgressServiceProtocol?, Progress?) = lock.withLock {
            finished = true
            return (remote, local)
        }
        target.0?.endUpload(identifier: identifier)
        if let local = target.1 {
            local.completedUnitCount = total
            local.unpublish()
        }
    }

    private func fallBackToLocal() {
        lock.withLock {
            guard local == nil, !finished else {
                return
            }
            remote = nil
            let progress = Progress(totalUnitCount: total)
            progress.kind = .file
            progress.fileOperationKind = .uploading
            progress.fileURL = fileURL
            progress.isCancellable = false
            progress.isPausable = false
            progress.completedUnitCount = lastBytes
            progress.publish()
            local = progress
        }
    }

    /// Diagnostic: how many byte updates arrived and where they went.
    var summary: String {
        lock.withLock {
            let route = local == nil ? "agent" : "local fallback"
            return "\(updates) updates via \(route), last \(lastBytes) of \(total) bytes"
        }
    }
}

/// Connection to `JottaFSProgressAgent` (launchd starts it on demand).
final class ProgressAgentClient: @unchecked Sendable {
    static let shared = ProgressAgentClient()
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    /// A proxy whose failures call `onError`; nil if no connection exists.
    func proxy(onError: @escaping @Sendable () -> Void) -> JottaFSProgressServiceProtocol? {
        let connection = lock.withLock { () -> NSXPCConnection in
            if let existing = self.connection {
                return existing
            }
            let created = NSXPCConnection(machServiceName: JottaFSProgressService.machServiceName, options: [])
            created.remoteObjectInterface = NSXPCInterface(with: JottaFSProgressServiceProtocol.self)
            created.invalidationHandler = { [weak self] in
                self?.lock.withLock { self?.connection = nil }
            }
            created.resume()
            self.connection = created
            return created
        }
        return connection.remoteObjectProxyWithErrorHandler { error in
            writeLogger.error("Progress agent unavailable (\((error as NSError).code, privacy: .public)); publishing locally.")
            onError()
        } as? JottaFSProgressServiceProtocol
    }
}

/// Diagnostic timing of upload phases (durations only, no names or paths).
final class PhaseClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date()
    private var phases: [String] = []

    func mark(_ name: String) {
        lock.withLock {
            let now = Date()
            phases.append(String(format: "%@ %.2fs", name, now.timeIntervalSince(last)))
            last = now
        }
    }

    var summary: String {
        lock.withLock { phases.joined(separator: "; ") }
    }
}

final class UploadFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.withLock { value = true }
    }

    var isSet: Bool {
        lock.withLock { value }
    }
}
