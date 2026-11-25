import Foundation
import FSKit
import JottaFSCore
import OSLog

private let trashLogger = Logger.extension("Trash")

/// Finder's Trash on the volume (docs/trash-design.md): `/.Trashes/<uid>`
/// shows the whole Jottacloud trash. Moving an item there trashes it on
/// Jottacloud, moving it out restores it, and removing it deletes it
/// permanently. Only entries trashed from the mounted location are shown.
extension JottaFSVolume {

    // MARK: Finder metadata in the Trash

    func createTrashMetadata(
        named name: String,
        type: FSItem.ItemType,
        in parent: JottacloudItem
    ) async throws -> FSCreateItemResult {
        guard type == .file, TrashStore.isLocalMetadataName(name) else {
            throw POSIXError(.EPERM)
        }
        let url = trash.localURL(name)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw POSIXError(.EEXIST)
        }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw POSIXError(.EIO)
        }
        let entry = trash.localEntry(name)
        let item = try itemStore.child(of: parent, entry: entry)
        await trash.localFilesChanged()
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

    // MARK: Move to Trash

    func moveToTrash(
        _ item: JottacloudItem,
        from source: JottacloudItem,
        name: String,
        in trashFolder: JottacloudItem,
        over overItem: FSItem?
    ) async throws -> FSRenameItemResult {
        guard overItem == nil, !TrashStore.isLocalMetadataName(name) else {
            throw POSIXError(.EEXIST)
        }
        let location = try writableLocation(of: item)
        guard let servicePath = target.servicePath(volume: location.volume, path: location.path) else {
            throw POSIXError(.EPERM)
        }
        let isDirectory = item.entry.kind == .directory
        // The trashed copy must hold the latest data: upload the file, or
        // every unsaved file inside the folder.
        let pending = isDirectory ? stagedDescendants(of: item) : [item]
        do {
            for file in pending {
                try await flush(file)
                await staging.waitForUpload(file.identifier)
            }
        } catch {
            throw posixError(error)
        }
        await readAhead.invalidate(item.identifier)
        let started = Date()
        do {
            try await client.trash(volume: location.volume, path: location.path, isDirectory: isDirectory)
        } catch {
            throw posixError(error)
        }
        for file in pending {
            staging.discard(file.identifier)
        }
        let found = await findTrashed(servicePath, since: started)
        if found == nil {
            trashLogger.error("Trashed an item but could not find it in the trash yet; it gets a name at the next listing.")
        }
        let trashed = found ?? JottacloudPathItem(
            path: servicePath,
            name: item.entry.name,
            isFolder: isDirectory,
            size: item.entry.size,
            modified: item.entry.modified,
            deletedAtMillis: 0
        )
        if let found {
            await trash.add(found, name: name)
        }
        let oldName = item.entry.name
        let entry = RemoteEntry(name: name, kind: item.entry.kind, size: item.entry.size, modified: item.entry.modified)
        itemStore.relocate(item, to: trashFolder, name: name, role: .trashed(trashed, topLevel: true), entry: entry)
        await directoryCache.recordAbsent(name: oldName, inDirectory: source.path)
        await directoryCache.recordPresent(JottacloudDirectoryEntry(entry: entry, role: item.role), inDirectory: trashFolder.path)
        trashLogger.info("Moved an item to the Trash.")
        return try renameResult(item, name: name, source: source, destination: trashFolder, over: nil)
    }

    /// Staged (possibly unsaved) files inside a folder.
    private func stagedDescendants(of folder: JottacloudItem) -> [JottacloudItem] {
        let prefix = folder.path.lowercased() + "/"
        return staging.stagedIdentifiers.compactMap { itemStore.item(identifier: $0) }
            .filter { $0.path.lowercased().hasPrefix(prefix) }
    }

    // MARK: Put Back, rename in the Trash

    func renameFromTrash(
        _ item: JottacloudItem,
        from source: JottacloudItem,
        to newName: String,
        in destination: JottacloudItem,
        over overItem: FSItem?
    ) async throws -> FSRenameItemResult {
        let over = overItem as? JottacloudItem
        switch item.role {
        case .trashLocal(let url):
            if LocalFinderFiles.isLocalName(newName), let to = destination.childLocation(named: newName) {
                // Put Back of a file's `._` file (the kernel moves it with
                // the file): back to the local Finder files.
                if let over, over !== item {
                    guard case .localFile = over.role else {
                        throw POSIXError(.EEXIST)
                    }
                    itemStore.remove(over)
                }
                do {
                    try localFiles.move(url, to: to.path)
                } catch {
                    throw posixError(error)
                }
                let oldName = item.entry.name
                let entry = RemoteEntry(name: newName, kind: .file, size: item.entry.size, modified: item.entry.modified)
                itemStore.relocate(item, to: destination, name: newName, role: .localFile(path: to.path), entry: entry)
                await trash.localFilesChanged()
                await directoryCache.recordAbsent(name: oldName, inDirectory: source.path)
                await directoryCache.recordPresent(JottacloudDirectoryEntry(entry: entry, role: item.role), inDirectory: destination.path)
                return try renameResult(item, name: newName, source: source, destination: destination, over: over)
            }
            guard case .userTrash = destination.role, TrashStore.isLocalMetadataName(newName) else {
                throw POSIXError(.EPERM)
            }
            if let over, over !== item {
                guard case .trashLocal = over.role else {
                    throw POSIXError(.EEXIST)
                }
                itemStore.remove(over)
            }
            let newURL = trash.localURL(newName)
            do {
                if newURL != url {
                    try? FileManager.default.removeItem(at: newURL)
                    try FileManager.default.moveItem(at: url, to: newURL)
                }
            } catch {
                throw posixError(error)
            }
            let oldName = item.entry.name
            let entry = RemoteEntry(name: newName, kind: .file, size: item.entry.size, modified: item.entry.modified)
            itemStore.relocate(item, to: destination, name: newName, role: .trashLocal(newURL), entry: entry)
            await trash.localFilesChanged()
            await directoryCache.recordAbsent(name: oldName, inDirectory: source.path)
            await directoryCache.recordPresent(trash.localEntry(newName), inDirectory: destination.path)
            return try renameResult(item, name: newName, source: source, destination: destination, over: over)

        case .trashed(let trashed, true):
            guard over == nil || over === item else {
                throw POSIXError(.EEXIST)
            }
            let oldName = item.entry.name
            if case .userTrash = destination.role {
                // A new name within the Trash.
                guard !TrashStore.isLocalMetadataName(newName) else {
                    throw POSIXError(.EPERM)
                }
                if trashed.isTrashed {
                    await trash.rename(trashed, to: newName)
                }
                let entry = RemoteEntry(name: newName, kind: item.entry.kind, size: item.entry.size, modified: item.entry.modified)
                itemStore.relocate(item, to: destination, name: newName, role: item.role, entry: entry)
                await directoryCache.recordAbsent(name: oldName, inDirectory: source.path)
                await directoryCache.recordPresent(JottacloudDirectoryEntry(entry: entry, role: item.role), inDirectory: destination.path)
                return try renameResult(item, name: newName, source: source, destination: destination, over: nil)
            }
            return try await putBack(item, trashed: trashed, from: source, to: newName, in: destination)

        default:
            // Items inside a trashed folder cannot be taken out on their own.
            throw POSIXError(.EPERM)
        }
    }

    /// Restores a trash entry. Put Back targets its original location; any
    /// other destination is a restore followed by a move.
    private func putBack(
        _ item: JottacloudItem,
        trashed: JottacloudPathItem,
        from source: JottacloudItem,
        to newName: String,
        in destination: JottacloudItem
    ) async throws -> FSRenameItemResult {
        guard let to = destination.childLocation(named: newName),
              let destinationPath = target.servicePath(volume: to.volume, path: to.path)
        else {
            throw POSIXError(.EPERM)
        }
        let newRole = JottacloudItemRole.remote(to.volume, path: to.path)
        let original = JottacloudClient.requestPath(trashed.path)
        let inPlace = original.lowercased() == JottacloudClient.requestPath(destinationPath).lowercased()
        var originalLocation: String?
        if !inPlace {
            // Restore, then move within the mounted location.
            guard let source = target.location(forServicePath: original),
                  source.volume == to.volume,
                  !source.path.isEmpty
            else {
                throw POSIXError(.EPERM)
            }
            originalLocation = source.path
        }
        do {
            try await client.restore(path: trashed.path)
            if let originalLocation {
                try await client.move(volume: to.volume, from: originalLocation, to: to.path, isDirectory: trashed.isFolder)
            }
        } catch {
            throw posixError(error)
        }
        await trash.forget(trashed)
        let oldName = item.entry.name
        let entry = RemoteEntry(name: newName, kind: item.entry.kind, size: trashed.size, modified: trashed.modified)
        itemStore.relocate(item, to: destination, name: newName, role: newRole, entry: entry)
        await directoryCache.recordAbsent(name: oldName, inDirectory: source.path)
        await directoryCache.recordPresent(JottacloudDirectoryEntry(entry: entry, role: item.role), inDirectory: destination.path)
        trashLogger.info("Restored an item from the Trash\(inPlace ? "" : " and moved it", privacy: .public).")
        return try renameResult(item, name: newName, source: source, destination: destination, over: nil)
    }

    // MARK: Empty Trash

    /// Removing a Trash entry deletes it permanently (a trashed folder with
    /// all of its contents; trashed folders are shown empty).
    func removeFromTrash(_ item: JottacloudItem, from parent: JottacloudItem) async throws -> FSRemoveItemResult {
        switch item.role {
        case .trashLocal(let url):
            do {
                try FileManager.default.removeItem(at: url)
            } catch CocoaError.fileNoSuchFile {
            } catch {
                throw posixError(error)
            }
            await trash.localFilesChanged()
        case .trashed(let trashed, true):
            // An entry whose deletion time is not known yet (just trashed and
            // not found in the trash) could match another trashed copy at the
            // same path; wait for a listing to identify it.
            guard trashed.isTrashed else {
                trashLogger.error("A Trash entry is not identified yet; not deleting it permanently.")
                throw POSIXError(.EBUSY)
            }
            do {
                try await client.deletePermanently(
                    path: trashed.path,
                    expectedDeletedAtMillis: trashed.deletedAtMillis
                )
                trashLogger.info("Deleted a Trash entry permanently.")
            } catch JottacloudError.notInTrash {
                // Emptied or restored elsewhere: nothing to delete here, and
                // a live item is never deleted. It leaves the Trash.
                trashLogger.info("A Trash entry was no longer in the Jottacloud trash; removed it from the Trash.")
            } catch {
                throw posixError(error)
            }
            await trash.forget(trashed)
        default:
            throw POSIXError(.EPERM)
        }
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

    // MARK: Permanent removal (rm)

    /// Deletes the item just trashed at `servicePath` permanently. Failures
    /// are logged; the item then stays in the Jottacloud trash.
    func deleteJustTrashed(servicePath: String, since started: Date) async {
        guard let trashed = await findTrashed(servicePath, since: started) else {
            trashLogger.error("Removed an item, but it was not found in the trash; it stays there.")
            return
        }
        do {
            try await client.deletePermanently(path: trashed.path, expectedDeletedAtMillis: trashed.deletedAtMillis)
            trashLogger.info("Removed an item permanently.")
        } catch {
            trashLogger.error("Permanent delete failed (\(self.describe(error), privacy: .public)); the item stays in the Jottacloud trash.")
        }
    }

    /// The trashed item at `servicePath` trashed at or after `since` (with
    /// some clock tolerance), retried briefly because listings can lag.
    func findTrashed(_ servicePath: String, since started: Date) async -> JottacloudPathItem? {
        // Only a deletion from this operation: a few seconds of clock skew,
        // never an older trashed copy at the same path (which the user may
        // want to keep).
        let earliest = UInt64(max(0, started.timeIntervalSince1970 - 5) * 1000)
        for delay in [0, 250, 500, 1000, 2000] {
            if delay > 0 {
                try? await Task.sleep(for: .milliseconds(delay))
            }
            if let item = try? await client.pathItem(servicePath, includeDeleted: true),
               item.isTrashed, item.deletedAtMillis >= earliest {
                return item
            }
        }
        return nil
    }

    func renameResult(
        _ item: JottacloudItem,
        name: String,
        source: JottacloudItem,
        destination: JottacloudItem,
        over: JottacloudItem?
    ) throws -> FSRenameItemResult {
        guard let result = FSRenameItemResult(
            newName: FSFileName(string: name),
            renamedItemAttributes: attributes(for: item),
            sourceDirectoryAttributes: attributes(for: source),
            destinationDirectoryAttributes: attributes(for: destination),
            overItemAttributes: over.map { attributes(for: $0) },
            freeSpace: nil
        ) else {
            throw POSIXError(.EIO)
        }
        return result
    }
}
