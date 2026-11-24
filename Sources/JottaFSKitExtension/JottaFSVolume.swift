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
    private let client: JottacloudClient
    private let itemStore = ItemStore()
    private let directoryCache: DirectoryCache
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

    var requestedMountOptions: FSVolume.MountOptions {
        .readOnly
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
        remoteVolumes: [JottacloudRemoteVolume],
        storage: JottacloudStorage,
        accountIdentifier: String
    ) throws {
        self.volumeIconData = try Self.loadVolumeIcon()
        self.client = client
        self.directoryCache = DirectoryCache(client: client, volumes: remoteVolumes)
        self.statistics = FSStatFSResult(fileSystemTypeName: "jottacloud")
        self.capabilities = FSVolume.SupportedCapabilities()
        // Finder omits volumes that report no size (statfs f_blocks == 0).
        self.capabilities.doesNotSupportVolumeSizes = false
        self.capabilities.doesNotSupportSettingFilePermissions = true
        self.capabilities.supportsFastStatFS = true
        self.capabilities.supportsHiddenFiles = true
        self.capabilities.caseFormat = .sensitive
        let identifier = FSVolume.Identifier(
            uuid: Self.stableVolumeIdentifier(for: accountIdentifier)
        )
        super.init(
            volumeID: identifier,
            volumeName: FSFileName(string: JottaFSStorage.volumeName)
        )
        let blockSize: UInt64 = 4_096
        let sizes = storage.volumeSizes(blockSize: blockSize)
        // Matches FSSubType of the extension's FSPersonalities entry, which is
        // where the volume's format name ("Jottacloud") may be looked up.
        self.statistics.fileSystemSubType = 0
        self.statistics.blockSize = Int(blockSize)
        self.statistics.ioSize = Int(blockSize)
        self.statistics.totalBytes = sizes.total
        self.statistics.usedBytes = sizes.used
        self.statistics.freeBytes = sizes.free
        // Read-only: nothing is available to this volume's callers.
        self.statistics.availableBytes = 0
        self.statistics.totalBlocks = (sizes.total + blockSize - 1) / blockSize
        self.statistics.usedBlocks = (sizes.used + blockSize - 1) / blockSize
        self.statistics.freeBlocks = sizes.free / blockSize
        self.statistics.availableBlocks = 0
    }

    func activateVolume(options: FSTaskOptions) async throws -> FSActivateResult {
        guard let result = FSActivateResult(rootItem: itemStore.rootItem()) else {
            throw POSIXError(.EIO)
        }
        return result
    }

    func deactivateVolume(options: FSDeactivateOptions) async throws {
        await directoryCache.clear()
    }

    func mount(options: FSTaskOptions) async throws {}

    func unmount() async {}

    func synchronize(flags: FSSyncFlags) async throws {}

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
        let entries = try entries(in: snapshot, for: parent)
        guard let entry = entries.first(where: { $0.entry.name == name }) else {
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
        itemStore.reclaim(item)
    }

    func createItem(
        named name: FSFileName,
        type: FSItem.ItemType,
        in directory: FSItem,
        attributes: FSItem.SetAttributesRequest,
        context: FSContext
    ) async throws -> FSCreateItemResult {
        throw POSIXError(.EROFS)
    }

    func createSymbolicLink(
        named name: FSFileName,
        in directory: FSItem,
        attributes: FSItem.SetAttributesRequest,
        linkContents: FSFileName,
        context: FSContext
    ) async throws -> FSCreateSymlinkResult {
        throw POSIXError(.EROFS)
    }

    func createLink(
        to item: FSItem,
        named name: FSFileName,
        in directory: FSItem,
        context: FSContext
    ) async throws -> FSCreateLinkResult {
        throw POSIXError(.EROFS)
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
        throw POSIXError(.EROFS)
    }

    func removeItem(
        _ item: FSItem,
        named name: FSFileName,
        from directory: FSItem,
        context: FSContext
    ) async throws -> FSRemoveItemResult {
        throw POSIXError(.EROFS)
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
        throw POSIXError(.EROFS)
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

        let start = Int(cookie.rawValue)
        guard start <= records.count else {
            throw POSIXError(.EINVAL)
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
        switch item.role {
        case .remote(let volume, let remotePath):
            data = try await client.readRange(
                volume: volume,
                path: remotePath,
                offset: UInt64(offset),
                length: length,
                fileSize: item.entry.size
            )
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
        throw POSIXError(.EROFS)
    }

    private func attributes(for item: JottacloudItem) -> FSItem.Attributes {
        let attributes = FSItem.Attributes()
        attributes.fileID = FSItem.Identifier(item.identifier)
        attributes.parentID = FSItem.Identifier(item.parentIdentifier)
        attributes.type = itemType(item.entry.kind)
        attributes.mode = item.entry.kind == .directory ? 0o555 : 0o444
        switch item.role {
        case .volumeIcon:
            attributes.flags = UInt32(UF_HIDDEN)
        case .root:
            // Root exposes only com.apple.FinderInfo (custom-icon flag).
            attributes.supportsLimitedXAttrs = true
        default:
            break
        }
        attributes.linkCount = item.entry.kind == .directory ? 2 : 1
        attributes.uid = UInt32(getuid())
        attributes.gid = UInt32(getgid())
        attributes.size = item.entry.size
        attributes.allocSize = item.entry.size
        // Every time attribute must be valid: getattrlist(2) fails with EINVAL
        // for any requested time FSKit cannot supply, and Finder hides a
        // volume whose root it cannot stat that way. Jottacloud listings only
        // carry a modification time, and virtual items (root, devices,
        // mountpoints, volume icon) carry none, so fall back to mount time.
        let time = item.entry.modified.map {
            timespec(tv_sec: Int($0.timeIntervalSince1970), tv_nsec: 0)
        } ?? mountTime
        attributes.modifyTime = time
        attributes.changeTime = time
        attributes.accessTime = time
        attributes.birthTime = time
        attributes.addedTime = time
        attributes.backupTime = timespec(tv_sec: 0, tv_nsec: 0)
        return attributes
    }

    private func entries(
        in snapshot: DirectorySnapshot,
        for directory: JottacloudItem
    ) throws -> [JottacloudDirectoryEntry] {
        guard case .root = directory.role else {
            return snapshot.entries
        }
        guard !snapshot.entries.contains(where: {
            $0.entry.name == Self.volumeIconName
        }) else {
            throw POSIXError(.EEXIST)
        }
        let iconEntry = RemoteEntry(
            name: Self.volumeIconName,
            kind: .file,
            size: UInt64(volumeIconData.count),
            modified: nil
        )
        return snapshot.entries + [
            JottacloudDirectoryEntry(entry: iconEntry, role: .volumeIcon)
        ]
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
        guard let item = item as? JottacloudItem, case .root = item.role else {
            return false
        }
        return true
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
        throw POSIXError(.EROFS)
    }

    func xattrs(of item: FSItem, context: FSContext) async throws -> FSListXattrsResult {
        guard let result = FSListXattrsResult(xattrNames: supportedXattrNames(for: item)) else {
            throw POSIXError(.EIO)
        }
        return result
    }
}
