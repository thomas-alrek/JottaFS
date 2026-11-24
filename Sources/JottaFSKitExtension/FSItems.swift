import FSKit
import os
import JottaFSCore

/// The mounted Jottacloud location (such as `Jotta/Archive`, or one
/// backed-up folder of a computer backup) and how its items are addressed in
/// the gRPC file service.
struct MountTarget: Sendable {
    let volume: JottacloudRemoteVolume
    /// For a backup location: its device's service path (`/backup/<id>`), or
    /// nil when unknown; then trash and permanent deletes are unavailable.
    let deviceServicePath: String?
    /// The mount anchor the volume is mounted from (`""` for the legacy
    /// anchor): finds the volume's mount point.
    let anchorName: String

    /// Names the volume's own folders for local state (staging, the Trash),
    /// so mounted locations never share them.
    var storageKey: String {
        JottaFSStorage.anchorName(device: volume.device, mountpoint: volume.mountpoint)
    }

    var rootRole: JottacloudItemRole {
        .mountpoint(volume)
    }

    /// The name in Finder: the user's name for the location, or its own
    /// name, numbered if another mounted volume already has it.
    let volumeName: String

    /// The service path of `path` in the mounted location, or nil.
    func servicePath(volume: JottacloudRemoteVolume, path: String) -> String? {
        let root: String?
        if volume.isBuiltIn {
            root = JottacloudClient.servicePath(device: volume.device, mountpoint: volume.mountpoint, path: "")
        } else {
            root = deviceServicePath.map { "\($0)/\(volume.mountpoint)" }
        }
        return root.map { path.isEmpty ? $0 : "\($0)/\(path)" }
    }

    /// Lower-cased service path prefix of the mounted location; the Trash
    /// lists only entries under it.
    var trashPrefix: String? {
        servicePath(volume: volume, path: "").map { JottacloudClient.requestPath($0).lowercased() + "/" }
    }

    /// The location of a service path inside the mounted location, or nil.
    func location(forServicePath servicePath: String) -> (volume: JottacloudRemoteVolume, path: String)? {
        let request = JottacloudClient.requestPath(servicePath)
        guard let prefix = trashPrefix, request.lowercased().hasPrefix(prefix) else {
            return nil
        }
        return (volume, String(request.dropFirst(prefix.count)))
    }
}

enum JottacloudItemRole: Sendable {
    /// The volume root: the mounted Jottacloud location.
    case mountpoint(JottacloudRemoteVolume)
    case remote(JottacloudRemoteVolume, path: String)
    case volumeIcon
    /// `/.Trashes` (virtual).
    case trashes
    /// `/.Trashes/<uid>`: the Jottacloud trash, as Finder's Trash.
    case userTrash
    /// An item in the Jottacloud trash: a top-level trash entry, or an item
    /// inside a trashed folder.
    case trashed(JottacloudPathItem, topLevel: Bool)
    /// Finder metadata (`.DS_Store`, `._*`) in the Trash, kept locally.
    case trashLocal(URL)
}

struct JottacloudDirectoryEntry: Sendable {
    let entry: RemoteEntry
    let role: JottacloudItemRole
}

final class JottacloudItem: FSItem {
    let identifier: UInt64

    /// The item's mutable state. FSKit calls the volume concurrently and
    /// renames, moves to the Trash and writes change these fields, so every
    /// access goes through a lock (a plain `String` or enum assignment is not
    /// atomic and can crash a concurrent reader).
    private struct State {
        var parentIdentifier: UInt64
        var path: String
        var role: JottacloudItemRole
        var entry: RemoteEntry
    }

    private let state: OSAllocatedUnfairLock<State>

    var parentIdentifier: UInt64 {
        get { state.withLock { $0.parentIdentifier } }
        set { state.withLock { $0.parentIdentifier = newValue } }
    }

    var path: String {
        get { state.withLock { $0.path } }
        set { state.withLock { $0.path = newValue } }
    }

    var role: JottacloudItemRole {
        get { state.withLock { $0.role } }
        set { state.withLock { $0.role = newValue } }
    }

    var entry: RemoteEntry {
        get { state.withLock { $0.entry } }
        set { state.withLock { $0.entry = newValue } }
    }

    init(
        identifier: UInt64,
        parentIdentifier: UInt64,
        path: String,
        role: JottacloudItemRole,
        entry: RemoteEntry
    ) {
        self.identifier = identifier
        self.state = OSAllocatedUnfairLock(initialState: State(
            parentIdentifier: parentIdentifier,
            path: path,
            role: role,
            entry: entry
        ))
        super.init()
    }

    /// Remote location for items inside the mounted location (not for the
    /// volume root itself, the volume icon or the Trash).
    var remoteLocation: (volume: JottacloudRemoteVolume, path: String)? {
        if case .remote(let volume, let path) = role {
            return (volume, path)
        }
        return nil
    }

    /// Remote location of a direct child named `name`, if this item is a
    /// mountpoint or a remote folder.
    func childLocation(named name: String) -> (volume: JottacloudRemoteVolume, path: String)? {
        switch role {
        case .mountpoint(let volume):
            return (volume, name)
        case .remote(let volume, let path):
            return (volume, path.isEmpty ? name : "\(path)/\(name)")
        default:
            return nil
        }
    }
}

/// Items by volume path. Keys are case-folded because Jottacloud (and the
/// volume) is case-insensitive.
final class ItemStore {
    private let lock = NSLock()
    private let rootRole: JottacloudItemRole

    init(rootRole: JottacloudItemRole) {
        self.rootRole = rootRole
    }
    private var nextIdentifier: UInt64 = 3
    private var itemsByPath: [String: JottacloudItem] = [:]
    private var itemsByIdentifier: [UInt64: JottacloudItem] = [:]

    private lazy var root = JottacloudItem(
        identifier: FSItem.Identifier.rootDirectory.rawValue,
        parentIdentifier: FSItem.Identifier.rootDirectory.rawValue,
        path: "",
        role: rootRole,
        entry: RemoteEntry(
            name: "",
            kind: .directory,
            size: 0,
            modified: nil
        )
    )

    private static func key(_ path: String) -> String {
        path.lowercased()
    }

    private static func childPath(_ parent: JottacloudItem, _ name: String) -> String {
        parent.path.isEmpty ? name : "\(parent.path)/\(name)"
    }

    func rootItem() -> JottacloudItem {
        lock.withLock {
            root
        }
    }

    func item(identifier: UInt64) -> JottacloudItem? {
        lock.withLock {
            if identifier == root.identifier {
                return root
            }
            return itemsByIdentifier[identifier]
        }
    }

    func child(
        of parent: JottacloudItem,
        entry: JottacloudDirectoryEntry
    ) throws -> JottacloudItem {
        try lock.withLock {
            let path = Self.childPath(parent, entry.entry.name)
            if let item = itemsByPath[Self.key(path)] {
                item.entry = entry.entry
                item.role = entry.role
                return item
            }
            guard nextIdentifier < UInt64.max else {
                throw POSIXError(.EOVERFLOW)
            }
            let item = JottacloudItem(
                identifier: nextIdentifier,
                parentIdentifier: parent.identifier,
                path: path,
                role: entry.role,
                entry: entry.entry
            )
            nextIdentifier += 1
            itemsByPath[Self.key(path)] = item
            itemsByIdentifier[item.identifier] = item
            return item
        }
    }

    /// Moves an item to `name` in `newParent` with a new role (into or out of
    /// the Trash), forgetting its cached descendants.
    func relocate(
        _ item: JottacloudItem,
        to newParent: JottacloudItem,
        name: String,
        role: JottacloudItemRole,
        entry: RemoteEntry
    ) {
        lock.withLock {
            let prefix = Self.key(item.path) + "/"
            for (key, descendant) in itemsByPath where key.hasPrefix(prefix) {
                itemsByPath.removeValue(forKey: key)
                itemsByIdentifier.removeValue(forKey: descendant.identifier)
            }
            let newPath = Self.childPath(newParent, name)
            if let displaced = itemsByPath[Self.key(newPath)], displaced !== item {
                itemsByIdentifier.removeValue(forKey: displaced.identifier)
            }
            itemsByPath.removeValue(forKey: Self.key(item.path))
            item.path = newPath
            item.parentIdentifier = newParent.identifier
            item.role = role
            item.entry = entry
            itemsByPath[Self.key(newPath)] = item
        }
    }

    /// Forgets a removed item (and, for a folder, its cached descendants).
    func remove(_ item: JottacloudItem) {
        lock.withLock {
            let prefix = Self.key(item.path) + "/"
            for (key, descendant) in itemsByPath where key.hasPrefix(prefix) {
                itemsByPath.removeValue(forKey: key)
                itemsByIdentifier.removeValue(forKey: descendant.identifier)
            }
            itemsByPath.removeValue(forKey: Self.key(item.path))
            itemsByIdentifier.removeValue(forKey: item.identifier)
        }
    }

    /// Moves an item (and its cached descendants) to `name` in `newParent`,
    /// which must be in the same device/mountpoint.
    func move(
        _ item: JottacloudItem,
        to newParent: JottacloudItem,
        name: String
    ) throws {
        try lock.withLock {
            guard let location = newParent.childLocation(named: name) else {
                throw POSIXError(.EINVAL)
            }
            let oldPath = item.path
            let oldRemotePath = item.remoteLocation?.path
            let newPath = Self.childPath(newParent, name)
            if let displaced = itemsByPath[Self.key(newPath)], displaced !== item {
                itemsByIdentifier.removeValue(forKey: displaced.identifier)
            }

            itemsByPath.removeValue(forKey: Self.key(oldPath))
            item.path = newPath
            item.parentIdentifier = newParent.identifier
            item.role = .remote(location.volume, path: location.path)
            // Same content: keep the MD5 (and so the cached blocks).
            item.entry = RemoteEntry(
                name: name,
                kind: item.entry.kind,
                size: item.entry.size,
                modified: item.entry.modified,
                md5: item.entry.md5
            )
            itemsByPath[Self.key(newPath)] = item

            let prefix = Self.key(oldPath) + "/"
            for (key, descendant) in itemsByPath where key.hasPrefix(prefix) {
                itemsByPath.removeValue(forKey: key)
                let suffix = String(descendant.path.dropFirst(oldPath.count))
                descendant.path = newPath + suffix
                if let oldRemotePath, let remote = descendant.remoteLocation {
                    let remoteSuffix = String(remote.path.dropFirst(oldRemotePath.count))
                    descendant.role = .remote(remote.volume, path: location.path + remoteSuffix)
                }
                itemsByPath[Self.key(descendant.path)] = descendant
            }
        }
    }

    func reclaim(_ item: JottacloudItem) {
        lock.withLock {
            _ = item.tryReclaim {
                if item.identifier != FSItem.Identifier.rootDirectory.rawValue,
                   self.itemsByIdentifier[item.identifier] === item {
                    self.itemsByIdentifier.removeValue(forKey: item.identifier)
                    if self.itemsByPath[Self.key(item.path)] === item {
                        self.itemsByPath.removeValue(forKey: Self.key(item.path))
                    }
                }
            }
        }
    }
}
