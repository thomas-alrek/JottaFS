import FSKit
import os
import JottaFSCore

/// What a volume mounts: one Jottacloud location (such as `Jotta/Archive`,
/// or one backed-up folder of a computer backup), or a whole device, whose
/// locations are then the folders in the volume's root. Also how its items
/// are addressed in the gRPC file service.
struct MountTarget: Sendable {
    /// The mounted location; for a whole device, `mountpoint` is empty
    /// (`JottacloudRemoteVolume.isWholeDevice`).
    let volume: JottacloudRemoteVolume
    /// For a backup device: its service path (`/backup/<id>`), or nil when
    /// unknown; then trash and permanent deletes are unavailable.
    let deviceServicePath: String?
    /// For a whole `Jotta` device: its locations when it was mounted. They
    /// cannot change (Jottacloud's own locations), and their service paths
    /// (`/archive`, `/photos`…) are the Trash's filter.
    let builtInLocations: [String]
    /// The mount anchor the volume is mounted from (`""` for the legacy
    /// anchor): finds the volume's mount point.
    let anchorName: String

    init(
        volume: JottacloudRemoteVolume,
        deviceServicePath: String?,
        builtInLocations: [String] = [],
        anchorName: String,
        volumeName: String
    ) {
        self.volume = volume
        self.deviceServicePath = deviceServicePath
        self.builtInLocations = builtInLocations
        self.anchorName = anchorName
        self.volumeName = volumeName
    }

    var isWholeDevice: Bool {
        volume.isWholeDevice
    }

    /// Whether locations can be created, renamed and moved to the trash in
    /// the root of a whole-device volume: on backup devices with a known
    /// service path, never on Jottacloud's own device.
    var canChangeLocations: Bool {
        isWholeDevice && !volume.isBuiltIn && deviceServicePath != nil
    }

    /// Names the volume's own folders for local state (staging, the Trash),
    /// so mounted volumes never share them.
    var storageKey: String {
        JottaFSStorage.anchorName(device: volume.device, mountpoint: volume.mountpoint)
    }

    var rootRole: JottacloudItemRole {
        isWholeDevice ? .device(volume.device) : .mountpoint(volume)
    }

    /// The name in Finder: the user's name for the location, or its own
    /// name, numbered if another mounted volume already has it.
    let volumeName: String

    /// The service path of `path` in a location of the mounted volume, or nil.
    func servicePath(volume: JottacloudRemoteVolume, path: String) -> String? {
        guard !volume.isWholeDevice else {
            return nil
        }
        let root: String?
        if volume.isBuiltIn {
            root = JottacloudClient.servicePath(device: volume.device, mountpoint: volume.mountpoint, path: "")
        } else {
            root = deviceServicePath.map { "\($0)/\(volume.mountpoint)" }
        }
        return root.map { path.isEmpty ? $0 : "\($0)/\(path)" }
    }

    /// Lower-cased service path prefixes of the mounted volume; the Trash
    /// lists only entries under them. For a whole backup device this also
    /// covers its trashed locations themselves (`/backup/<id>/<name>`).
    var trashPrefixes: [String] {
        let roots: [String?]
        if !isWholeDevice {
            roots = [servicePath(volume: volume, path: "")]
        } else if volume.isBuiltIn {
            roots = builtInLocations.map { servicePath(volume: volume.location(named: $0), path: "") }
        } else {
            roots = [deviceServicePath]
        }
        return roots.compactMap { $0 }.map { JottacloudClient.requestPath($0).lowercased() + "/" }
    }

    /// The location of a service path inside the mounted volume, or nil.
    /// For a trashed location of a whole device, `path` is empty.
    func location(forServicePath servicePath: String) -> (volume: JottacloudRemoteVolume, path: String)? {
        let request = JottacloudClient.requestPath(servicePath)
        if !isWholeDevice {
            guard let prefix = trashPrefixes.first, request.lowercased().hasPrefix(prefix) else {
                return nil
            }
            return (volume, String(request.dropFirst(prefix.count)))
        }
        if volume.isBuiltIn {
            // `/archive/folder`: the first component is the location.
            for name in builtInLocations {
                guard let root = self.servicePath(volume: volume.location(named: name), path: "") else {
                    continue
                }
                let prefix = JottacloudClient.requestPath(root).lowercased() + "/"
                if request.lowercased().hasPrefix(prefix) {
                    return (volume.location(named: name), String(request.dropFirst(prefix.count)))
                }
            }
            return nil
        }
        // `/backup/<id>/<location>/folder`.
        guard let prefix = trashPrefixes.first, request.lowercased().hasPrefix(prefix) else {
            return nil
        }
        let rest = request.dropFirst(prefix.count)
        let parts = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first, !first.isEmpty else {
            return nil
        }
        return (volume.location(named: String(first)), parts.count > 1 ? String(parts[1]) : "")
    }
}

enum JottacloudItemRole: Sendable {
    /// The root of a whole-device volume: the device, whose locations are
    /// its folders.
    case device(String)
    /// A mounted Jottacloud location: the volume root, or a folder in the
    /// root of a whole-device volume.
    case mountpoint(JottacloudRemoteVolume)
    case remote(JottacloudRemoteVolume, path: String)
    case volumeIcon
    /// `/.com.apple.timemachine.donotpresent` (virtual, empty): keeps the
    /// disk out of Time Machine's list of backup disks.
    case timeMachineMarker
    /// `/.fseventsd` (virtual, read-only), holding only `no_log`, so
    /// `fseventsd` keeps no event log on the disk (it would otherwise create
    /// this folder and upload its log files to Jottacloud).
    case fseventsDirectory
    /// `/.fseventsd/no_log` (virtual, empty).
    case fseventsNoLog
    /// `/.Trashes` (virtual).
    case trashes
    /// `/.Trashes/<uid>`: the Jottacloud trash, as Finder's Trash.
    case userTrash
    /// An item in the Jottacloud trash: a top-level trash entry, or an item
    /// inside a trashed folder.
    case trashed(JottacloudPathItem, topLevel: Bool)
    /// Finder metadata (`.DS_Store`, `._*`) in the Trash, kept locally.
    case trashLocal(URL)
    /// Finder's own files (`.DS_Store`, `._*`) anywhere else on the volume,
    /// kept on this Mac (`LocalFinderFiles`); `path` is the item's path in
    /// the volume (for a mounted location, the same as a remote item's path
    /// in it).
    case localFile(path: String)
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

    /// The remote folder this item is: a location (path `""`) or a folder
    /// in one; nil for anything else.
    var remoteBase: (volume: JottacloudRemoteVolume, path: String)? {
        switch role {
        case .mountpoint(let volume):
            return (volume, "")
        case .remote(let volume, let path):
            return (volume, path)
        default:
            return nil
        }
    }

    /// The volume path of a direct child named `name` that is one of
    /// Finder's own files (kept on this Mac), if this item is a folder that
    /// can hold them: the root, a location or a remote folder.
    func localChildPath(named name: String) -> String? {
        switch role {
        case .device, .mountpoint, .remote:
            return path.isEmpty ? name : "\(path)/\(name)"
        default:
            return nil
        }
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

    /// Whether a file has a local copy (being written, or written and not
    /// yet uploaded or discarded). Its size and date then come from that
    /// copy, never from a listing: listings and overlays can be older than
    /// the writes (a listing during an upload once reset a just-copied file
    /// to the size recorded at its creation, 0 bytes; 1.1.2).
    private let isStaged: @Sendable (UInt64) -> Bool

    init(rootRole: JottacloudItemRole, isStaged: @escaping @Sendable (UInt64) -> Bool = { _ in false }) {
        self.rootRole = rootRole
        self.isStaged = isStaged
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

    /// A file's entry after an upload: the size, MD5 and (when Jottacloud
    /// reports one) date that the upload verified, under the item's name.
    static func uploadedEntry(_ current: RemoteEntry, verified: RemoteEntry, modified: Date) -> RemoteEntry {
        RemoteEntry(
            name: current.name,
            kind: .file,
            size: verified.size,
            modified: verified.modified ?? modified,
            md5: verified.md5
        )
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
                if item.entry.kind == .file, entry.entry.kind == .file, isStaged(item.identifier) {
                    // Keep the written size and date (see `isStaged`).
                } else {
                    item.entry = entry.entry
                }
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

    /// Moves an item (and its cached descendants) to `name` in `newParent`
    /// in the same device: within its location, into another location, or
    /// (with `role`, a location folder in a whole-device root) renaming a
    /// location.
    func move(
        _ item: JottacloudItem,
        to newParent: JottacloudItem,
        name: String,
        role newRole: JottacloudItemRole? = nil
    ) throws {
        try lock.withLock {
            let role: JottacloudItemRole
            if let newRole {
                role = newRole
            } else if let location = newParent.childLocation(named: name) {
                role = .remote(location.volume, path: location.path)
            } else {
                throw POSIXError(.EINVAL)
            }
            let oldPath = item.path
            let oldBase = item.remoteBase
            let newPath = Self.childPath(newParent, name)
            if let displaced = itemsByPath[Self.key(newPath)], displaced !== item {
                itemsByIdentifier.removeValue(forKey: displaced.identifier)
            }

            itemsByPath.removeValue(forKey: Self.key(oldPath))
            item.path = newPath
            item.parentIdentifier = newParent.identifier
            item.role = role
            // Same content: keep the MD5 (and so the cached blocks).
            item.entry = RemoteEntry(
                name: name,
                kind: item.entry.kind,
                size: item.entry.size,
                modified: item.entry.modified,
                md5: item.entry.md5
            )
            itemsByPath[Self.key(newPath)] = item
            let newBase = item.remoteBase

            let prefix = Self.key(oldPath) + "/"
            for (key, descendant) in itemsByPath where key.hasPrefix(prefix) {
                itemsByPath.removeValue(forKey: key)
                let suffix = String(descendant.path.dropFirst(oldPath.count))
                descendant.path = newPath + suffix
                if let oldBase, let newBase, let remote = descendant.remoteLocation {
                    descendant.role = .remote(
                        newBase.volume,
                        path: Self.rebase(remote.path, from: oldBase.path, to: newBase.path)
                    )
                } else if case .localFile = descendant.role {
                    // A local Finder file inside the moved folder: its path
                    // is its path in the volume.
                    descendant.role = .localFile(path: descendant.path)
                }
                itemsByPath[Self.key(descendant.path)] = descendant
            }
        }
    }

    /// `path` (inside the folder at `oldBase`) moved under `newBase`; an
    /// empty base is a location's root.
    static func rebase(_ path: String, from oldBase: String, to newBase: String) -> String {
        let relative = oldBase.isEmpty ? path : String(path.dropFirst(oldBase.count + 1))
        return newBase.isEmpty ? relative : (relative.isEmpty ? newBase : "\(newBase)/\(relative)")
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
