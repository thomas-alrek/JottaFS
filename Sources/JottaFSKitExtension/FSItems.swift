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
    let parentIdentifier: UInt64
    let path: String
    let role: JottacloudItemRole
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
}

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
            let path = parent.path.isEmpty
                ? entry.entry.name
                : "\(parent.path)/\(entry.entry.name)"
            if let item = itemsByPath[path] {
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
            itemsByPath[path] = item
            itemsByIdentifier[item.identifier] = item
            return item
        }
    }

    func reclaim(_ item: JottacloudItem) {
        lock.withLock {
            _ = item.tryReclaim {
                if item.identifier != FSItem.Identifier.rootDirectory.rawValue {
                    self.itemsByIdentifier.removeValue(forKey: item.identifier)
                    self.itemsByPath.removeValue(forKey: item.path)
                }
            }
        }
    }
}
