import Foundation
import JottaFSCore

struct DirectorySnapshot: Sendable {
    let entries: [JottacloudDirectoryEntry]
    let verifier: UInt64
    /// Name indexes so a lookup in a folder with thousands of entries is one
    /// dictionary access instead of a scan (Finder looks up every entry).
    private let exactIndex: [String: Int]
    private let foldedIndex: [String: Int]

    init(entries: [JottacloudDirectoryEntry], verifier: UInt64) {
        self.entries = entries
        self.verifier = verifier
        var exact: [String: Int] = [:]
        var folded: [String: Int] = [:]
        exact.reserveCapacity(entries.count)
        folded.reserveCapacity(entries.count)
        for (index, entry) in entries.enumerated() {
            exact[entry.entry.name] = exact[entry.entry.name] ?? index
            folded[entry.entry.name.lowercased()] = folded[entry.entry.name.lowercased()] ?? index
        }
        exactIndex = exact
        foldedIndex = folded
    }

    /// Exact match first, then case-insensitive (Jottacloud is case-insensitive).
    func entry(named name: String) -> JottacloudDirectoryEntry? {
        if let index = exactIndex[name] ?? foldedIndex[name.lowercased()] {
            return entries[index]
        }
        return nil
    }
}

actor DirectoryCache {
    private struct Cached {
        let snapshot: DirectorySnapshot
        let loadedAt: Date
    }

    private let client: JottacloudClient
    private let trash: TrashStore
    /// Name of the virtual trash folder at the volume root.
    static let trashesName = ".Trashes"
    static let trashesEntry = JottacloudDirectoryEntry(
        entry: RemoteEntry(name: trashesName, kind: .directory, size: 0, modified: nil),
        role: .trashes
    )
    /// Name of the virtual `fseventsd` folder at the volume root.
    static let fseventsName = ".fseventsd"
    static let fseventsEntry = JottacloudDirectoryEntry(
        entry: RemoteEntry(name: fseventsName, kind: .directory, size: 0, modified: nil),
        role: .fseventsDirectory
    )
    /// A listing younger than this is served without contacting Jottacloud.
    private let freshLifetime: TimeInterval = 15
    /// An older listing up to this age is still served immediately while one
    /// background request refreshes it (stale-while-revalidate). Finder and
    /// Quick Look ask for the same folders many times per second; refetching
    /// each time made large folders very slow.
    private let staleLifetime: TimeInterval = 300
    private let maximumDirectories = 512
    /// Folders with more entries are not cached (memory bound).
    private let maximumEntries = 20_000
    private var refreshing: Set<String> = []
    private var nextVerifier: UInt64 = 0
    private var cache: [String: Cached] = [:]
    private var requests: [String: Task<DirectorySnapshot, Error>] = [:]

    /// Local changes applied on top of fetched listings for a short while,
    /// because Jottacloud's listings can lag behind uploads, moves and
    /// deletes. Keyed by case-folded directory path, then case-folded name;
    /// a nil entry means "removed".
    private struct Overlay {
        let entry: JottacloudDirectoryEntry?
        let expires: Date
    }
    private let overlayLifetime: TimeInterval = 60
    private let pendingLifetime: TimeInterval = 30 * 60
    private var overlays: [String: [String: Overlay]] = [:]

    private let localFiles: LocalFinderFiles

    init(client: JottacloudClient, trash: TrashStore, localFiles: LocalFinderFiles) {
        self.localFiles = localFiles
        self.client = client
        self.trash = trash
    }

    func list(
        path: String,
        role: JottacloudItemRole
    ) async throws -> DirectorySnapshot {
        // The Trash is served from memory and loads in the background.
        if case .userTrash = role {
            return applyOverlay(to: await trash.snapshot(), path: path)
        }
        return applyOverlay(to: try await fetch(path: path, role: role), path: path)
    }

    /// The folder's local Finder files, after removing those whose items
    /// are no longer in the folder's (complete) Jottacloud listing.
    private nonisolated func localEntries(inFolder folder: String, remote: [RemoteEntry]) -> [JottacloudDirectoryEntry] {
        localFiles.prune(
            folder: folder,
            keeping: Set(remote.filter { !LocalFinderFiles.isLocalName($0.name) }.map { $0.name.lowercased() })
        )
        return localFiles.entries(inFolder: folder)
    }

    /// Records a created, uploaded or moved-in item in `directoryPath`.
    /// `untilReplaced` keeps it until the next record for the name, for up
    /// to `pendingLifetime` (a file created here, which Jottacloud cannot
    /// list until its upload is done; that can take longer than
    /// `overlayLifetime`).
    func recordPresent(_ entry: JottacloudDirectoryEntry, inDirectory directoryPath: String, untilReplaced: Bool = false) {
        record(name: entry.entry.name, entry: entry, inDirectory: directoryPath, untilReplaced: untilReplaced)
    }

    /// Records a removed or moved-out item in `directoryPath`.
    func recordAbsent(name: String, inDirectory directoryPath: String) {
        record(name: name, entry: nil, inDirectory: directoryPath)
    }

    /// Drops the cached listing so the next request fetches it again.
    func invalidate(path: String) {
        cache.removeValue(forKey: path)
    }

    private func record(name: String, entry: JottacloudDirectoryEntry?, inDirectory directoryPath: String, untilReplaced: Bool = false) {
        overlays[directoryPath.lowercased(), default: [:]][name.lowercased()] = Overlay(
            entry: entry,
            expires: Date().addingTimeInterval(untilReplaced ? pendingLifetime : overlayLifetime)
        )
        // New verifier on the next listing, so FSKit re-enumerates.
        cache.removeValue(forKey: directoryPath)
    }

    private func applyOverlay(to snapshot: DirectorySnapshot, path: String) -> DirectorySnapshot {
        let key = path.lowercased()
        guard var overlay = overlays[key] else {
            return snapshot
        }
        let now = Date()
        overlay = overlay.filter { $0.value.expires > now }
        overlays[key] = overlay.isEmpty ? nil : overlay
        guard !overlay.isEmpty else {
            return snapshot
        }
        var entries = snapshot.entries.filter { overlay[$0.entry.name.lowercased()] == nil }
        // A stable order (paged enumeration relies on it).
        entries += overlay.values.compactMap(\.entry).sorted { $0.entry.name < $1.entry.name }
        // A different verifier for every overlay state, so FSKit notices
        // when local changes appear or expire.
        var hasher = Hasher()
        hasher.combine(snapshot.verifier)
        for (name, change) in overlay.sorted(by: { $0.key < $1.key }) {
            hasher.combine(name)
            hasher.combine(change.entry == nil)
            hasher.combine(change.expires)
        }
        let verifier = UInt64(bitPattern: Int64(hasher.finalize())) | 1
        return DirectorySnapshot(entries: entries, verifier: verifier)
    }

    private func fetch(
        path: String,
        role: JottacloudItemRole
    ) async throws -> DirectorySnapshot {
        if let cached = cache[path] {
            let age = Date().timeIntervalSince(cached.loadedAt)
            if age < freshLifetime {
                return cached.snapshot
            }
            if age < staleLifetime {
                if requests[path] == nil, refreshing.insert(path).inserted {
                    Task {
                        _ = try? await self.load(path: path, role: role)
                        self.finishRefresh(path)
                    }
                }
                return cached.snapshot
            }
        }
        return try await load(path: path, role: role)
    }

    private func finishRefresh(_ path: String) {
        refreshing.remove(path)
    }

    /// Fetches a listing (sharing an in-flight request) and caches it.
    private func load(
        path: String,
        role: JottacloudItemRole
    ) async throws -> DirectorySnapshot {
        if let request = requests[path] {
            return try await request.value
        }

        guard nextVerifier < UInt64.max else {
            throw POSIXError(.EOVERFLOW)
        }
        nextVerifier += 1
        let verifier = nextVerifier
        let request = Task {
            let entries: [JottacloudDirectoryEntry]
            switch role {
            case .device(let device):
                // A whole-device volume: its locations are the root's
                // folders, next to the virtual Trash and `.fseventsd`.
                let folders = Self.locationFolders(
                    try await client.listMountpoints(device: device),
                    device: device
                )
                let remote = folders.map { RemoteEntry(name: $0.name, kind: .directory, size: 0, modified: nil) }
                entries = [Self.trashesEntry, Self.fseventsEntry] + folders.map {
                    JottacloudDirectoryEntry(
                        entry: RemoteEntry(name: $0.name, kind: .directory, size: 0, modified: nil),
                        role: .mountpoint(JottacloudRemoteVolume(device: device, mountpoint: $0.mountpoint))
                    )
                } + localEntries(inFolder: path, remote: remote)
            case .mountpoint(let volume):
                let remoteEntries = try await client.listDirectory(
                    volume: volume,
                    path: ""
                )
                        // As the volume root, it also holds the virtual Trash and
                // the virtual `.fseventsd` (not as a folder in a
                // whole-device root).
                entries = (path.isEmpty ? [Self.trashesEntry, Self.fseventsEntry] : []) + remoteEntries.compactMap {
                    // A remote item named like one of them stays hidden (a
                    // `.fseventsd` uploaded by versions before 1.1.2), and so
                    // do Finder's own files: the local ones are shown.
                    guard !JottaFSNames.sameName($0.name, Self.trashesName),
                          !JottaFSNames.sameName($0.name, Self.fseventsName),
                          !LocalFinderFiles.isLocalName($0.name)
                    else {
                        return nil
                    }
                    return JottacloudDirectoryEntry(
                        entry: $0,
                        role: .remote(volume, path: $0.name)
                    )
                } + localEntries(inFolder: path, remote: remoteEntries)
            case .remote(let volume, let remotePath):
                let remoteEntries = try await client.listDirectory(
                    volume: volume,
                    path: remotePath
                )
                entries = remoteEntries.compactMap { entry in
                    guard !LocalFinderFiles.isLocalName(entry.name) else {
                        return nil
                    }
                    let path = remotePath.isEmpty
                        ? entry.name
                        : "\(remotePath)/\(entry.name)"
                    return JottacloudDirectoryEntry(
                        entry: entry,
                        role: .remote(volume, path: path)
                    )
                } + localEntries(inFolder: path, remote: remoteEntries)
            case .trashes:
                entries = [JottacloudDirectoryEntry(
                    entry: RemoteEntry(name: trash.userFolderName, kind: .directory, size: 0, modified: nil),
                    role: .userTrash
                )]
            case .userTrash:
                entries = await trash.snapshot().entries
            case .trashed:
                // Trashed folders are shown empty: listing each one would
                // cost a request while Finder waits, and their files cannot
                // be read yet. Deleting one deletes all of its contents.
                entries = []
            case .fseventsDirectory:
                entries = [JottacloudDirectoryEntry(
                    entry: RemoteEntry(name: "no_log", kind: .file, size: 0, modified: nil),
                    role: .fseventsNoLog
                )]
            case .volumeIcon, .timeMachineMarker, .fseventsNoLog, .trashLocal, .localFile:
                throw POSIXError(.ENOTDIR)
            }
            return DirectorySnapshot(entries: entries, verifier: verifier)
        }
        requests[path] = request
        do {
            let snapshot = try await request.value
            requests.removeValue(forKey: path)
            if snapshot.entries.count <= maximumEntries {
                if cache.count >= maximumDirectories, cache[path] == nil,
                   let oldest = cache.min(by: { $0.value.loadedAt < $1.value.loadedAt })?.key {
                    cache.removeValue(forKey: oldest)
                }
                cache[path] = Cached(snapshot: snapshot, loadedAt: Date())
            } else {
                cache.removeValue(forKey: path)
            }
            return snapshot
        } catch {
            requests.removeValue(forKey: path)
            throw error
        }
    }

    /// The folders of a whole-device root: one per location, named after
    /// it. Jottacloud's own locations get the names the app saved in the
    /// user's language ("Arkiv" for "Archive", like their disk names); a
    /// location keeps its own name if the translated name would be taken.
    /// Names that the root needs itself, or that are Finder's own files,
    /// are left out.
    static func locationFolders(
        _ mountpoints: [String],
        device: String,
        translatedName: (String) -> String? = { mountpoint in
            let name = JottaFSStorage.defaultVolumeName(device: JottacloudRemoteVolume.builtInDevice, mountpoint: mountpoint)
            return name == JottaFSStorage.defaultVolumeName(mountpoint: mountpoint) ? nil : name
        }
    ) -> [(name: String, mountpoint: String)] {
        let usable = mountpoints.filter {
            !JottaFSNames.sameName($0, trashesName)
                && !JottaFSNames.sameName($0, fseventsName)
                && !LocalFinderFiles.isLocalName($0)
        }
        guard device == JottacloudRemoteVolume.builtInDevice else {
            return usable.map { ($0, $0) }
        }
        let translated = usable.map { mountpoint in
            translatedName(mountpoint).flatMap { (try? JottaFSNames.validate($0)) != nil ? $0 : nil } ?? mountpoint
        }
        return zip(usable, translated).map { mountpoint, name in
            let clashes = zip(usable, translated).contains { other, otherName in
                other != mountpoint && (JottaFSNames.sameName(otherName, name) || JottaFSNames.sameName(other, name))
            }
            return (clashes ? mountpoint : name, mountpoint)
        }
    }

    func clear() {
        cache.removeAll()
        refreshing.removeAll()
        requests.values.forEach { $0.cancel() }
        requests.removeAll()
    }
}
