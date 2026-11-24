import Darwin
import CryptoKit
import Foundation
import FSKit
import JottaFSCore

final class JottaFSVolume: FSVolume, FSVolume.Handler, FSVolume.ReadWriteHandler {
    /// macOS only uses a custom volume icon named `.VolumeIcon.icns` at the
    /// root, and only when the root's FinderInfo has `kHasCustomIcon` set
    /// (served by the `FSVolume.XattrHandler` extension below).
    static let volumeIconName = ".VolumeIcon.icns"
    let client: JottacloudClient
    /// The mounted Jottacloud location.
    let target: MountTarget
    let itemStore: ItemStore
    let volumeName: String
    let directoryCache: DirectoryCache
    let staging: StagingArea
    let trash: TrashStore
    /// Larger, prefetched reads while a file is read sequentially.
    let readAhead = ReadAhead()
    private let statistics: FSStatFSResult
    private let capabilities: FSVolume.SupportedCapabilities
    private let volumeIconData: Data
    /// Timestamp for items without a remote modification time.
    private let mountTime = timespec(tv_sec: time(nil), tv_nsec: 0)

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        capabilities
    }

    var volumeStatistics: FSStatFSResult {
        statistics
    }

    /// Read-write: everything inside the mounted location can be changed.
    var requestedMountOptions: FSVolume.MountOptions {
        []
    }

    var enableOpenUnlinkEmulation: Bool {
        false
    }

    var maximumLinkCount: Int {
        1
    }

    var maximumNameLength: Int {
        255
    }

    var restrictsOwnershipChanges: Bool {
        true
    }

    var truncatesLongNames: Bool {
        false
    }

    init(
        client: JottacloudClient,
        target: MountTarget,
        storage: JottacloudStorage,
        accountIdentifier: String
    ) throws {
        self.volumeIconData = try Self.loadVolumeIcon()
        self.client = client
        self.target = target
        self.itemStore = ItemStore(rootRole: target.rootRole)
        self.volumeName = target.volumeName
        self.staging = try StagingArea()
        self.trash = try TrashStore(client: client, locationPrefix: target.trashPrefix)
        self.directoryCache = DirectoryCache(client: client, trash: trash)
        self.statistics = FSStatFSResult(fileSystemTypeName: "jottacloud")
        self.capabilities = FSVolume.SupportedCapabilities()
        // Finder omits volumes that report no size (statfs f_blocks == 0).
        self.capabilities.doesNotSupportVolumeSizes = false
        self.capabilities.doesNotSupportSettingFilePermissions = true
        self.capabilities.supportsFastStatFS = true
        self.capabilities.supportsHiddenFiles = true
        // Jottacloud names are case-insensitive.
        self.capabilities.caseFormat = .insensitiveCasePreserving
        let identifier = FSVolume.Identifier(
            // One identifier per account and location, so Finder and
            // Spotlight never mix up two locations.
            uuid: Self.stableVolumeIdentifier(for: "\(accountIdentifier)/\(target.volume.id)")
        )
        super.init(
            volumeID: identifier,
            volumeName: FSFileName(string: volumeName)
        )
        let blockSize: UInt64 = 4_096
        let sizes = storage.volumeSizes(blockSize: blockSize)
        self.statistics.blockSize = Int(blockSize)
        self.statistics.ioSize = Int(blockSize)
        self.statistics.totalBytes = sizes.total
        self.statistics.usedBytes = sizes.used
        self.statistics.freeBytes = sizes.free
        self.statistics.availableBytes = sizes.free
        self.statistics.totalBlocks = (sizes.total + blockSize - 1) / blockSize
        self.statistics.usedBlocks = (sizes.used + blockSize - 1) / blockSize
        self.statistics.freeBlocks = sizes.free / blockSize
        self.statistics.availableBlocks = sizes.free / blockSize
    }

    func activateVolume(options: FSTaskOptions) async throws -> FSActivateResult {
        guard let result = FSActivateResult(rootItem: itemStore.rootItem()) else {
            throw POSIXError(.EIO)
        }
        let trash = trash
        Task { await trash.start() }
        return result
    }

    func deactivateVolume(options: FSDeactivateOptions) async throws {
        try? await flushAll()
        await trash.stop()
        await readAhead.removeAll()
        await directoryCache.clear()
    }

    func mount(options: FSTaskOptions) async throws {}

    /// Finishes pending and running uploads before the volume goes away, so
    /// an unmount (from the app, Finder or System Settings) cannot cut off
    /// an upload that a writer is still waiting for in close(2).
    func unmount() async {
        try? await flushAll()
    }

    /// Uploads dirty files. Failures are logged (by `flushAll`) and not
    /// returned: macOS syncs before unmounting, and an upload that keeps
    /// failing must not make the volume impossible to unmount.
    func synchronize(flags: FSSyncFlags) async throws {
        try? await flushAll()
    }

    func lookupItem(
        named name: FSFileName,
        in directory: FSItem,
        context: FSContext
    ) async throws -> FSLookupItemResult {
        guard let parent = directory as? JottacloudItem,
              parent.entry.kind == .directory,
              let name = name.string
        else {
            throw POSIXError(.ENOENT)
        }
        let snapshot = try await directoryCache.list(
            path: parent.path,
            role: parent.role
        )
        // Case-insensitive like Jottacloud; prefer an exact match. The root
        // also resolves the virtual volume icon, so it uses the full list.
        let found: JottacloudDirectoryEntry?
        if isVolumeRoot(parent) {
            let entries = try entries(in: snapshot, for: parent)
            found = entries.first(where: { $0.entry.name == name })
                ?? entries.first(where: { JottaFSNames.sameName($0.entry.name, name) })
        } else {
            found = snapshot.entry(named: name)
        }
        guard let entry = found else {
            throw POSIXError(.ENOENT)
        }
        let item = try itemStore.child(of: parent, entry: entry)
        guard let result = FSLookupItemResult(
            foundItem: item,
            itemName: FSFileName(string: entry.entry.name),
            itemAttributes: attributes(for: item)
        ) else {
            throw POSIXError(.EIO)
        }
        return result
    }

    func reclaimItem(_ item: FSItem) async throws {
        guard let item = item as? JottacloudItem else {
            throw POSIXError(.EINVAL)
        }
        if let staged = staging.file(item.identifier) {
            if staged.dirty {
                // Last chance to upload before the item is forgotten.
                try? await flush(item)
            }
            if staging.file(item.identifier)?.dirty == false {
                staging.discard(item.identifier)
            }
        }
        await readAhead.invalidate(item.identifier)
        itemStore.reclaim(item)
    }

    func createItem(
        named name: FSFileName,
        type: FSItem.ItemType,
        in directory: FSItem,
        attributes: FSItem.SetAttributesRequest,
        context: FSContext
    ) async throws -> FSCreateItemResult {
        try await create(named: name, type: type, in: directory)
    }

    func createSymbolicLink(
        named name: FSFileName,
        in directory: FSItem,
        attributes: FSItem.SetAttributesRequest,
        linkContents: FSFileName,
        context: FSContext
    ) async throws -> FSCreateSymlinkResult {
        throw POSIXError(.ENOTSUP)
    }

    func createLink(
        to item: FSItem,
        named name: FSFileName,
        in directory: FSItem,
        context: FSContext
    ) async throws -> FSCreateLinkResult {
        throw POSIXError(.ENOTSUP)
    }

    func renameItem(
        _ item: FSItem,
        inDirectory sourceDirectory: FSItem,
        named sourceName: FSFileName,
        to destinationName: FSFileName,
        inDirectory destinationDirectory: FSItem,
        overItem: FSItem?,
        context: FSContext
    ) async throws -> FSRenameItemResult {
        try await rename(
            item,
            from: sourceDirectory,
            to: destinationName,
            in: destinationDirectory,
            over: overItem
        )
    }

    func removeItem(
        _ item: FSItem,
        named name: FSFileName,
        from directory: FSItem,
        context: FSContext
    ) async throws -> FSRemoveItemResult {
        try await remove(item, from: directory)
    }

    func attributes(
        _ desiredAttributes: FSItem.GetAttributesRequest,
        of item: FSItem,
        context: FSContext
    ) async throws -> FSGetAttributesResult {
        guard let item = item as? JottacloudItem,
              let result = FSGetAttributesResult(attributes: attributes(for: item))
        else {
            throw POSIXError(.EINVAL)
        }
        return result
    }

    func setAttributes(
        _ newAttributes: FSItem.SetAttributesRequest,
        on item: FSItem,
        context: FSContext
    ) async throws -> FSSetAttributesResult {
        try await applyAttributes(newAttributes, on: item)
    }

    func enumerateDirectory(
        _ directory: FSItem,
        startingAt cookie: FSDirectoryCookie,
        verifier: FSDirectoryVerifier,
        attributes requestedAttributes: FSItem.GetAttributesRequest?,
        packer: FSDirectoryEntryPacker,
        context: FSContext
    ) async throws -> FSEnumerateDirectoryResult {
        guard let directory = directory as? JottacloudItem,
              directory.entry.kind == .directory
        else {
            throw POSIXError(.ENOTDIR)
        }
        let snapshot = try await directoryCache.list(
            path: directory.path,
            role: directory.role
        )
        // The volume icon is resolvable by name (lookupItem), which is how
        // Finder loads it, but is never listed, so `ls -a` does not show it.
        let entries = try entries(in: snapshot, for: directory).filter {
            if case .volumeIcon = $0.role {
                return false
            }
            return true
        }
        var records: [(name: String, item: JottacloudItem)] = []
        if requestedAttributes == nil {
            records.append((".", directory))
            if let parent = itemStore.item(identifier: directory.parentIdentifier) {
                records.append(("..", parent))
            }
        }
        for entry in entries {
            records.append(
                (entry.entry.name, try itemStore.child(of: directory, entry: entry))
            )
        }

        // A later page of a listing that changed since the first page:
        // indexes no longer match, so FSKit must start over.
        let start = Int(cookie.rawValue)
        guard start == 0 || verifier.rawValue == snapshot.verifier,
              start <= records.count
        else {
            throw FSError(.invalidDirectoryCookie)
        }
        for index in start..<records.count {
            let record = records[index]
            let recordAttributes = requestedAttributes == nil
                ? nil
                : attributes(for: record.item)
            let packed = packer.packEntry(
                name: FSFileName(string: record.name),
                itemType: itemType(record.item.entry.kind),
                itemID: FSItem.Identifier(record.item.identifier),
                nextCookie: FSDirectoryCookie(UInt64(index + 1)),
                attributes: recordAttributes
            )
            if !packed {
                break
            }
        }
        guard let result = FSEnumerateDirectoryResult(verifier: snapshot.verifier) else {
            throw POSIXError(.EIO)
        }
        return result
    }

    func readSymbolicLink(
        _ item: FSItem,
        context: FSContext
    ) async throws -> FSReadSymlinkResult {
        throw POSIXError(.EINVAL)
    }

    func read(
        from item: FSItem,
        at offset: off_t,
        length: Int,
        into buffer: FSMutableFileDataBuffer
    ) async throws -> FSReadFileResult {
        guard let item = item as? JottacloudItem,
              item.entry.kind == .file,
              offset >= 0,
              length >= 0
        else {
            throw POSIXError(.EINVAL)
        }
        let data: Data
        if let staged = try stagedData(of: item, at: offset, length: length) {
            data = staged
        } else {
        switch item.role {
        case .remote(let volume, let remotePath):
            let client = client
            let fileSize = item.entry.size
            data = try await readAhead.read(
                item.identifier,
                offset: UInt64(offset),
                length: length,
                fileSize: fileSize
            ) { blockOffset, blockLength in
                try await client.readRange(
                    volume: volume,
                    path: remotePath,
                    offset: blockOffset,
                    length: blockLength,
                    fileSize: fileSize,
                    maximumLength: max(blockLength, JottacloudClient.maxReadSize)
                )
            }
        case .trashLocal(let url):
            data = try JottaFSStagingFile.read(from: url, at: UInt64(offset), length: length)
        case .trashed:
            // Reading trashed files is not supported yet.
            throw POSIXError(.EACCES)
        case .volumeIcon:
            guard let startOffset = Int(exactly: offset) else {
                throw POSIXError(.EINVAL)
            }
            let start = min(startOffset, volumeIconData.count)
            let end = start + min(length, volumeIconData.count - start)
            data = volumeIconData.subdata(in: start..<end)
        default:
            throw POSIXError(.EINVAL)
        }
        }
        let bytesRead = buffer.withUnsafeMutableBytes { destination in
            data.copyBytes(to: destination)
        }
        guard let result = FSReadFileResult(
            bytesRead: bytesRead,
            itemAttributes: attributes(for: item)
        ) else {
            throw POSIXError(.EIO)
        }
        return result
    }

    func write(
        contents: Data,
        to item: FSItem,
        at offset: off_t
    ) async throws -> FSWriteFileResult {
        try await writeData(contents, to: item, at: offset)
    }

    func attributes(for item: JottacloudItem) -> FSItem.Attributes {
        let attributes = FSItem.Attributes()
        attributes.fileID = FSItem.Identifier(item.identifier)
        attributes.parentID = FSItem.Identifier(item.parentIdentifier)
        attributes.type = itemType(item.entry.kind)
        // Write bits only where writes are allowed, so the kernel rejects
        // other writes before they reach the extension.
        let writable = grantsWritePermission(item)
        switch (item.entry.kind, writable) {
        case (.directory, true): attributes.mode = 0o755
        case (.directory, false): attributes.mode = 0o555
        case (.file, true): attributes.mode = 0o644
        case (.file, false): attributes.mode = 0o444
        }
        switch item.role {
        case .trashes:
            // Like a real volume's `.Trashes`: d-wx-wx-wt.
            attributes.mode = 0o1333
            attributes.flags = UInt32(UF_HIDDEN)
        case .userTrash:
            attributes.mode = 0o700
        default:
            break
        }
        if case .volumeIcon = item.role {
            attributes.flags = UInt32(UF_HIDDEN)
        }
        if isVolumeRoot(item) {
            // Root exposes only com.apple.FinderInfo (custom-icon flag).
            attributes.supportsLimitedXAttrs = true
        }
        attributes.linkCount = item.entry.kind == .directory ? 2 : 1
        attributes.uid = UInt32(getuid())
        attributes.gid = UInt32(getgid())
        let size: UInt64
        if case .trashLocal(let url) = item.role {
            size = UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        } else {
            size = stagedSize(of: item) ?? item.entry.size
        }
        attributes.size = size
        attributes.allocSize = size
        // Every time attribute must be valid: getattrlist(2) fails with EINVAL
        // for any requested time FSKit cannot supply, and Finder hides a
        // volume whose root it cannot stat that way. Jottacloud listings only
        // carry a modification time, and virtual items (the volume root,
        // volume icon and Trash folders) carry none, so fall back to mount
        // time.
        let time = item.entry.modified.map {
            timespec(tv_sec: Int($0.timeIntervalSince1970), tv_nsec: 0)
        } ?? mountTime
        attributes.modifyTime = time
        attributes.changeTime = time
        attributes.accessTime = time
        attributes.birthTime = time
        attributes.addedTime = time
        // Finder's "Date Added" in the Trash is when the item was trashed.
        if case .trashed(let trashed, true) = item.role, trashed.deletedAtMillis > 0 {
            attributes.addedTime = timespec(tv_sec: Int(trashed.deletedAtMillis / 1000), tv_nsec: 0)
        }
        attributes.backupTime = timespec(tv_sec: 0, tv_nsec: 0)
        return attributes
    }

    private func entries(
        in snapshot: DirectorySnapshot,
        for directory: JottacloudItem
    ) throws -> [JottacloudDirectoryEntry] {
        guard isVolumeRoot(directory) else {
            return snapshot.entries
        }
        // The virtual icon wins over a remote file with the same name (one
        // could exist if another client created it); throwing here would
        // break every lookup and listing of the root.
        let iconEntry = RemoteEntry(
            name: Self.volumeIconName,
            kind: .file,
            size: UInt64(volumeIconData.count),
            modified: nil
        )
        return snapshot.entries.filter { !JottaFSNames.sameName($0.entry.name, Self.volumeIconName) } + [
            JottacloudDirectoryEntry(entry: iconEntry, role: .volumeIcon)
        ]
    }

    func isVolumeRoot(_ item: JottacloudItem) -> Bool {
        item.identifier == FSItem.Identifier.rootDirectory.rawValue
    }

    private static func loadVolumeIcon() throws -> Data {
        guard let url = Bundle.main.url(
            forResource: "JottaVolume",
            withExtension: "icns"
        ) else {
            throw JottaFSVolumeError.missingIcon
        }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    private static func stableVolumeIdentifier(for accountIdentifier: String) -> UUID {
        var bytes = Array(
            SHA256.hash(
                data: Data("no.alrek.jottafs:\(accountIdentifier)".utf8)
            ).prefix(16)
        )
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private func itemType(_ kind: RemoteEntry.Kind) -> FSItem.ItemType {
        switch kind {
        case .file:
            .file
        case .directory:
            .directory
        }
    }

    private enum JottaFSVolumeError: LocalizedError {
        case missingIcon

        var errorDescription: String? {
            "The Jottacloud volume icon is missing from the file system extension."
        }
    }
}

/// "Limited" extended-attribute support: the volume has no general xattrs and
/// only exposes the root's FinderInfo so Finder uses `.VolumeIcon.icns`.
extension JottaFSVolume: FSVolume.XattrHandler {
    private static let finderInfoName = "com.apple.FinderInfo"

    /// 32-byte FinderInfo for a folder; Finder flags are the big-endian
    /// UInt16 at offset 8, and `kHasCustomIcon` is 0x0400.
    static let rootFinderInfo: Data = {
        var bytes = [UInt8](repeating: 0, count: 32)
        bytes[8] = 0x04
        return Data(bytes)
    }()

    private func isRoot(_ item: FSItem) -> Bool {
        guard let item = item as? JottacloudItem else {
            return false
        }
        return isVolumeRoot(item)
    }

    func supportedXattrNames(for item: FSItem) -> [FSFileName] {
        isRoot(item) ? [FSFileName(string: Self.finderInfoName)] : []
    }

    func xattr(
        named name: FSFileName,
        of item: FSItem,
        context: FSContext
    ) async throws -> FSGetXattrResult {
        guard isRoot(item),
              name.string == Self.finderInfoName,
              let result = FSGetXattrResult(xattrValue: Self.rootFinderInfo)
        else {
            throw POSIXError(.ENOATTR)
        }
        return result
    }

    func setXattr(
        named name: FSFileName,
        to value: Data?,
        on item: FSItem,
        policy: FSVolume.SetXattrPolicy,
        context: FSContext
    ) async throws -> FSSetXattrResult {
        throw POSIXError(.ENOTSUP)
    }

    func xattrs(of item: FSItem, context: FSContext) async throws -> FSListXattrsResult {
        guard let result = FSListXattrsResult(xattrNames: supportedXattrNames(for: item)) else {
            throw POSIXError(.EIO)
        }
        return result
    }
}
