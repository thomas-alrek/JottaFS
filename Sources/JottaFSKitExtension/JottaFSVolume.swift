import Darwin
import CryptoKit
import Foundation
import FSKit
import JottaFSCore

final class JottaFSVolume: FSVolume, FSVolume.Handler, FSVolume.ReadWriteHandler {
    private static let volumeIconName = "@JottaVolume.icns"
    private let client: JottacloudClient
    private let itemStore = ItemStore()
    private let directoryCache: DirectoryCache
    private let statistics: FSStatFSResult
    private let capabilities: FSVolume.SupportedCapabilities
    private let volumeIconData: Data

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
        accountIdentifier: String
    ) throws {
        self.volumeIconData = try Self.loadVolumeIcon()
        self.client = client
        self.directoryCache = DirectoryCache(client: client, volumes: remoteVolumes)
        self.statistics = FSStatFSResult(fileSystemTypeName: "jottacloud")
        self.capabilities = FSVolume.SupportedCapabilities()
        self.capabilities.doesNotSupportVolumeSizes = true
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
        self.statistics.blockSize = 4_096
        self.statistics.ioSize = 4_096
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
        let entries = try entries(in: snapshot, for: directory)
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
        if case .volumeIcon = item.role {
            attributes.flags = UInt32(UF_HIDDEN)
        }
        attributes.linkCount = item.entry.kind == .directory ? 2 : 1
        attributes.uid = UInt32(getuid())
        attributes.gid = UInt32(getgid())
        attributes.size = item.entry.size
        attributes.allocSize = item.entry.size
        if let modified = item.entry.modified {
            attributes.modifyTime = timespec(
                tv_sec: Int(modified.timeIntervalSince1970),
                tv_nsec: 0
            )
        }
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
