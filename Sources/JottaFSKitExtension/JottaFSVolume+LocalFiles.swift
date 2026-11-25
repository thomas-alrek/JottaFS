import FSKit
import Foundation
import JottaFSCore
import OSLog

private let localFilesLogger = Logger.extension("LocalFiles")

/// Finder's own files (`.DS_Store`, `._*`) in folders of the location: kept
/// on this Mac by `LocalFinderFiles`, never uploaded
/// (docs/write-support-design.md, "Finder's own files").
extension JottaFSVolume {
    func createLocalFile(named name: String, at path: String, in parent: JottacloudItem) async throws -> FSCreateItemResult {
        if try await directoryCache.list(path: parent.path, role: parent.role).entries
            .contains(where: { JottaFSNames.sameName($0.entry.name, name) }) {
            throw POSIXError(.EEXIST)
        }
        do {
            try localFiles.create(path)
        } catch {
            throw posixError(error)
        }
        let entry = JottacloudDirectoryEntry(
            entry: RemoteEntry(name: name, kind: .file, size: 0, modified: Date()),
            role: .localFile(path: path)
        )
        let item = try itemStore.child(of: parent, entry: entry)
        await directoryCache.recordPresent(entry, inDirectory: parent.path)
        guard let result = FSCreateItemResult(
            newItem: item,
            newItemName: FSFileName(string: name),
            newItemAttributes: attributes(for: item),
            directoryAttributes: attributes(for: parent),
            freeSpace: nil
        ) else {
            throw POSIXError(.EIO)
        }
        return result
    }

    /// A local file moved to the Trash (the kernel moves a file's `._` file
    /// with it): it joins the Trash's local Finder files, so Put Back can
    /// bring it back.
    func moveLocalFileToTrash(
        _ item: JottacloudItem,
        from source: JottacloudItem,
        name: String,
        in trashFolder: JottacloudItem,
        over overItem: FSItem?
    ) async throws -> FSRenameItemResult {
        guard case .localFile(let path) = item.role, TrashStore.isLocalMetadataName(name),
              let url = localFiles.url(path)
        else {
            throw POSIXError(.EPERM)
        }
        let over = overItem as? JottacloudItem
        if let over, over !== item {
            guard case .trashLocal = over.role else {
                throw POSIXError(.EEXIST)
            }
            itemStore.remove(over)
        }
        let trashURL = trash.localURL(name)
        do {
            try? FileManager.default.removeItem(at: trashURL)
            try FileManager.default.moveItem(at: url, to: trashURL)
        } catch {
            throw posixError(error)
        }
        let oldName = item.entry.name
        let entry = RemoteEntry(name: name, kind: .file, size: item.entry.size, modified: item.entry.modified)
        itemStore.relocate(item, to: trashFolder, name: name, role: .trashLocal(trashURL), entry: entry)
        await trash.localFilesChanged()
        await directoryCache.recordAbsent(name: oldName, inDirectory: source.path)
        await directoryCache.recordPresent(trash.localEntry(name), inDirectory: trashFolder.path)
        return try renameResult(item, name: name, source: source, destination: trashFolder, over: over)
    }

    /// Renames or moves a local file within the location. Its new name must
    /// also be one of Finder's own (an upload would be needed otherwise).
    func renameLocalFile(
        _ item: JottacloudItem,
        from source: JottacloudItem,
        to newName: String,
        in destination: JottacloudItem,
        over overItem: FSItem?
    ) async throws -> FSRenameItemResult {
        guard case .localFile(let path) = item.role,
              LocalFinderFiles.isLocalName(newName),
              let to = destination.childLocation(named: newName),
              let url = localFiles.url(path)
        else {
            throw POSIXError(.EPERM)
        }
        let over = try replaceableLocalFile(overItem, keeping: item)
        do {
            try localFiles.move(url, to: to.path)
        } catch {
            throw posixError(error)
        }
        let oldName = item.entry.name
        let entry = RemoteEntry(name: newName, kind: .file, size: item.entry.size, modified: item.entry.modified)
        itemStore.relocate(item, to: destination, name: newName, role: .localFile(path: to.path), entry: entry)
        await directoryCache.recordAbsent(name: oldName, inDirectory: source.path)
        await directoryCache.recordPresent(JottacloudDirectoryEntry(entry: entry, role: item.role), inDirectory: destination.path)
        return try renameResult(item, name: newName, source: source, destination: destination, over: over)
    }

    /// A regular file renamed to one of Finder's own names (an app that
    /// writes a temporary file and renames it): its contents move to the
    /// local file, and the regular file is deleted (never uploaded if it was
    /// not uploaded yet).
    func turnIntoLocalFile(
        _ item: JottacloudItem,
        at location: (volume: JottacloudRemoteVolume, path: String),
        from source: JottacloudItem,
        to newName: String,
        in destination: JottacloudItem,
        path: String,
        over overItem: FSItem?
    ) async throws -> FSRenameItemResult {
        let over = try replaceableLocalFile(overItem, keeping: item)
        do {
            let staged = try await staging.stage(item.identifier) { [client, size = item.entry.size] url in
                var offset: UInt64 = 0
                while offset < size {
                    let chunk = try await client.readRange(
                        volume: location.volume, path: location.path,
                        offset: offset, length: 1 << 20, fileSize: size
                    )
                    guard !chunk.isEmpty else {
                        throw POSIXError(.EIO)
                    }
                    try JottaFSStagingFile.write(chunk, to: url, at: offset)
                    offset += UInt64(chunk.count)
                }
            }
            try localFiles.copy(staged.url, to: path)
        } catch {
            throw posixError(error)
        }
        try await deletePermanently(item, at: location)
        let oldName = item.entry.name
        let size = localFiles.url(path).flatMap { try? JottaFSStagingFile.size(of: $0) } ?? 0
        let entry = RemoteEntry(name: newName, kind: .file, size: size, modified: Date())
        itemStore.relocate(item, to: destination, name: newName, role: .localFile(path: path), entry: entry)
        await directoryCache.recordAbsent(name: oldName, inDirectory: source.path)
        await directoryCache.recordPresent(JottacloudDirectoryEntry(entry: entry, role: item.role), inDirectory: destination.path)
        localFilesLogger.info("Kept a Finder file on this Mac instead of uploading it.")
        return try renameResult(item, name: newName, source: source, destination: destination, over: over)
    }

    /// A rename target that may be replaced: nothing, the item itself, or
    /// another local file (forgotten here; its file is replaced by the move).
    private func replaceableLocalFile(_ overItem: FSItem?, keeping item: JottacloudItem) throws -> JottacloudItem? {
        guard let over = overItem as? JottacloudItem, over !== item else {
            return nil
        }
        guard case .localFile = over.role else {
            throw POSIXError(.EEXIST)
        }
        itemStore.remove(over)
        return over
    }
}
