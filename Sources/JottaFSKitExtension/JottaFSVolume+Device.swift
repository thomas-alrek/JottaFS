import Foundation
import FSKit
import JottaFSCore
import OSLog

private let deviceLogger = Logger.extension("Device")

/// The root of a whole-device volume (docs/device-volume-design.md): its
/// folders are the device's locations. Creating a folder creates a location,
/// renaming one renames the location, Move to Trash moves the location (with
/// its files) to the Jottacloud trash and Put Back restores it. Files cannot
/// be created there, only Finder's own files (kept on this Mac). Jottacloud's
/// own device has fixed locations: everything inside them can change, the
/// root cannot.
extension JottaFSVolume {

    /// The mounted backup device, for the gRPC calls on its locations; nil
    /// when its locations cannot be changed here.
    private var mountedBackupDevice: JottacloudBackupDevice? {
        guard target.canChangeLocations, let path = target.deviceServicePath else {
            return nil
        }
        return JottacloudBackupDevice(id: "", name: target.volume.device, path: path)
    }

    /// Whether `item` is a location folder in the root of a whole-device
    /// volume.
    func isLocationFolder(_ item: JottacloudItem) -> Bool {
        guard target.isWholeDevice, item.parentIdentifier == FSItem.Identifier.rootDirectory.rawValue,
              case .mountpoint = item.role
        else {
            return false
        }
        return true
    }

    // MARK: Create

    func createInDeviceRoot(
        named name: String,
        type: FSItem.ItemType,
        in root: JottacloudItem
    ) async throws -> FSCreateItemResult {
        guard !isReservedRootName(name) else {
            throw POSIXError(.EPERM)
        }
        if type == .file, LocalFinderFiles.isLocalName(name) {
            return try await createLocalFile(named: name, at: name, in: root)
        }
        // Only folders (locations) in the root: a file there would have no
        // location to be stored in.
        guard type == .directory else {
            deviceLogger.info("Refused a file in the root of a device volume.")
            throw POSIXError(.EPERM)
        }
        guard let device = mountedBackupDevice else {
            throw POSIXError(.EPERM)
        }
        if try await directoryCache.list(path: root.path, role: root.role).entry(named: name) != nil {
            throw POSIXError(.EEXIST)
        }
        do {
            try await client.createMountpoint(device: device.name, named: name)
        } catch {
            throw posixError(error)
        }
        let entry = JottacloudDirectoryEntry(
            entry: RemoteEntry(name: name, kind: .directory, size: 0, modified: Date()),
            role: .mountpoint(target.volume.location(named: name))
        )
        let item = try itemStore.child(of: root, entry: entry)
        await directoryCache.recordPresent(entry, inDirectory: root.path)
        deviceLogger.info("Created a location.")
        guard let result = FSCreateItemResult(
            newItem: item,
            newItemName: FSFileName(string: name),
            newItemAttributes: attributes(for: item),
            directoryAttributes: attributes(for: root),
            freeSpace: nil
        ) else {
            throw POSIXError(.EIO)
        }
        return result
    }

    // MARK: Remove (rmdir)

    /// Removes an empty location permanently, like rmdir on a local disk:
    /// it is moved to the trash, then that trashed location is deleted.
    func removeLocation(_ item: JottacloudItem, from root: JottacloudItem) async throws -> FSRemoveItemResult {
        guard let device = mountedBackupDevice, case .mountpoint(let location) = item.role else {
            throw POSIXError(.EPERM)
        }
        await directoryCache.invalidate(path: item.path)
        guard try await directoryCache.list(path: item.path, role: item.role).entries.isEmpty else {
            throw POSIXError(.ENOTEMPTY)
        }
        let started = Date()
        do {
            try await client.removeMountpoint(location.mountpoint, of: device)
        } catch {
            throw posixError(error)
        }
        await deleteJustTrashed(servicePath: device.path + "/" + location.mountpoint, since: started)
        localFiles.removeFolder(item.path)
        await directoryCache.recordAbsent(name: item.entry.name, inDirectory: root.path)
        let itemAttributes = attributes(for: item)
        itemStore.remove(item)
        guard let result = FSRemoveItemResult(
            itemAttributes: itemAttributes,
            directoryAttributes: attributes(for: root),
            freeSpace: nil
        ) else {
            throw POSIXError(.EIO)
        }
        return result
    }

    // MARK: Rename and Move to Trash

    /// A location folder renamed in the root (renames the location) or
    /// moved to the Trash (moves the location to the Jottacloud trash). A
    /// location cannot become a folder inside another location.
    func renameLocationFolder(
        _ item: JottacloudItem,
        from root: JottacloudItem,
        to newName: String,
        in destination: JottacloudItem,
        over overItem: FSItem?
    ) async throws -> FSRenameItemResult {
        guard let device = mountedBackupDevice, case .mountpoint(let location) = item.role else {
            throw POSIXError(.EPERM)
        }
        if case .userTrash = destination.role {
            return try await moveLocationToTrash(item, location: location, device: device, from: root, name: newName, in: destination, over: overItem)
        }
        guard isVolumeRoot(destination), !isReservedRootName(newName), !LocalFinderFiles.isLocalName(newName) else {
            throw POSIXError(.EPERM)
        }
        if let over = overItem as? JottacloudItem, over !== item {
            throw POSIXError(.EEXIST)
        }
        let oldPath = item.path
        if newName != location.mountpoint {
            // Upload pending writes first: their uploads name the old location.
            try await flushStagedFiles(in: item)
            do {
                try await client.renameMountpoint(location.mountpoint, to: newName, of: device)
            } catch {
                throw posixError(error)
            }
        }
        let oldName = item.entry.name
        try itemStore.move(item, to: root, name: newName, role: .mountpoint(target.volume.location(named: newName)))
        localFiles.moveFolder(from: oldPath, to: item.path)
        await directoryCache.recordAbsent(name: oldName, inDirectory: root.path)
        await directoryCache.recordPresent(JottacloudDirectoryEntry(entry: item.entry, role: item.role), inDirectory: root.path)
        await directoryCache.invalidate(path: oldPath)
        await directoryCache.invalidate(path: item.path)
        deviceLogger.info("Renamed a location.")
        return try renameResult(item, name: newName, source: root, destination: root, over: nil)
    }

    private func moveLocationToTrash(
        _ item: JottacloudItem,
        location: JottacloudRemoteVolume,
        device: JottacloudBackupDevice,
        from root: JottacloudItem,
        name: String,
        in trashFolder: JottacloudItem,
        over overItem: FSItem?
    ) async throws -> FSRenameItemResult {
        guard overItem == nil, !TrashStore.isLocalMetadataName(name) else {
            throw POSIXError(.EEXIST)
        }
        // The trashed location must hold the latest data.
        try await flushStagedFiles(in: item)
        let servicePath = device.path + "/" + location.mountpoint
        let started = Date()
        do {
            try await client.removeMountpoint(location.mountpoint, of: device)
        } catch {
            throw posixError(error)
        }
        let found = await findTrashed(servicePath, since: started)
        if found == nil {
            deviceLogger.error("Trashed a location but could not find it in the trash yet; it gets a name at the next listing.")
        }
        let trashed = found ?? JottacloudPathItem(
            path: servicePath,
            name: location.mountpoint,
            isFolder: true,
            size: 0,
            modified: item.entry.modified,
            deletedAtMillis: 0
        )
        if let found {
            await trash.add(found, name: name)
        }
        let oldName = item.entry.name
        let entry = RemoteEntry(name: name, kind: .directory, size: 0, modified: item.entry.modified)
        itemStore.relocate(item, to: trashFolder, name: name, role: .trashed(trashed, topLevel: true), entry: entry)
        await directoryCache.recordAbsent(name: oldName, inDirectory: root.path)
        await directoryCache.recordPresent(JottacloudDirectoryEntry(entry: entry, role: item.role), inDirectory: trashFolder.path)
        deviceLogger.info("Moved a location to the Trash.")
        return try renameResult(item, name: name, source: root, destination: trashFolder, over: nil)
    }

    /// Uploads every staged (possibly unsaved) file inside `folder`.
    func flushStagedFiles(in folder: JottacloudItem) async throws {
        do {
            for file in stagedDescendants(of: folder) {
                try await flush(file)
                await staging.waitForUpload(file.identifier)
            }
        } catch {
            throw posixError(error)
        }
        for file in stagedDescendants(of: folder) {
            staging.discard(file.identifier)
        }
    }

    // MARK: Put Back

    /// Restores a trashed location of the mounted device: Put Back to the
    /// root under its own name.
    func restoreLocation(
        _ item: JottacloudItem,
        trashed: JottacloudPathItem,
        from source: JottacloudItem,
        to newName: String,
        in root: JottacloudItem
    ) async throws -> FSRenameItemResult {
        guard target.canChangeLocations,
              let original = target.location(forServicePath: trashed.path),
              original.path.isEmpty,
              JottaFSNames.sameName(original.volume.mountpoint, newName)
        else {
            throw POSIXError(.EPERM)
        }
        do {
            try await client.restore(path: trashed.path)
        } catch {
            throw posixError(error)
        }
        await trash.forget(trashed)
        let oldName = item.entry.name
        let entry = RemoteEntry(name: newName, kind: .directory, size: 0, modified: trashed.modified)
        itemStore.relocate(item, to: root, name: newName, role: .mountpoint(original.volume), entry: entry)
        await directoryCache.recordAbsent(name: oldName, inDirectory: source.path)
        await directoryCache.recordPresent(JottacloudDirectoryEntry(entry: entry, role: item.role), inDirectory: root.path)
        deviceLogger.info("Restored a location from the Trash.")
        return try renameResult(item, name: newName, source: source, destination: root, over: nil)
    }
}
