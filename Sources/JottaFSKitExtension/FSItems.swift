import FSKit
import JottaFSCore

enum JottacloudItemRole: Sendable {
    case root
    case device(String)
    case mountpoint(JottacloudRemoteVolume)
    case remote(JottacloudRemoteVolume, path: String)
    case volumeIcon
}

struct JottacloudDirectoryEntry: Sendable {
    let entry: RemoteEntry
    let role: JottacloudItemRole
}

final class JottacloudItem: FSItem {
    let identifier: UInt64
    // Mutable only through ItemStore (under its lock) when an item is renamed.
    var parentIdentifier: UInt64
    var path: String
    var role: JottacloudItemRole
    var entry: RemoteEntry

    init(
        identifier: UInt64,
        parentIdentifier: UInt64,
        path: String,
        role: JottacloudItemRole,
        entry: RemoteEntry
    ) {
        self.identifier = identifier
        self.parentIdentifier = parentIdentifier
        self.path = path
        self.role = role
        self.entry = entry
        super.init()
    }

    /// Remote location for items inside a mountpoint (not for the root,
    /// devices, mountpoints themselves or the volume icon).
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
    private var nextIdentifier: UInt64 = 3
    private var itemsByPath: [String: JottacloudItem] = [:]
    private var itemsByIdentifier: [UInt64: JottacloudItem] = [:]

    private lazy var root = JottacloudItem(
        identifier: FSItem.Identifier.rootDirectory.rawValue,
        parentIdentifier: FSItem.Identifier.rootDirectory.rawValue,
        path: "",
        role: .root,
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
            item.entry = RemoteEntry(
                name: name,
                kind: item.entry.kind,
                size: item.entry.size,
                modified: item.entry.modified
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
