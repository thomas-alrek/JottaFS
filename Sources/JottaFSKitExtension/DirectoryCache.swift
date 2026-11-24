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
    private let volumes: [JottacloudRemoteVolume]
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
    private var overlays: [String: [String: Overlay]] = [:]

    init(client: JottacloudClient, volumes: [JottacloudRemoteVolume]) {
        self.client = client
        var seenVolumeIDs = Set<String>()
        self.volumes = volumes.filter { seenVolumeIDs.insert($0.id).inserted }
    }

    func list(
        path: String,
        role: JottacloudItemRole
    ) async throws -> DirectorySnapshot {
        applyOverlay(to: try await fetch(path: path, role: role), path: path)
    }

    /// Records a created, uploaded or moved-in item in `directoryPath`.
    func recordPresent(_ entry: JottacloudDirectoryEntry, inDirectory directoryPath: String) {
        record(name: entry.entry.name, entry: entry, inDirectory: directoryPath)
    }

    /// Records a removed or moved-out item in `directoryPath`.
    func recordAbsent(name: String, inDirectory directoryPath: String) {
        record(name: name, entry: nil, inDirectory: directoryPath)
    }

    /// Drops the cached listing so the next request fetches it again.
    func invalidate(path: String) {
        cache.removeValue(forKey: path)
    }

    private func record(name: String, entry: JottacloudDirectoryEntry?, inDirectory directoryPath: String) {
        overlays[directoryPath.lowercased(), default: [:]][name.lowercased()] = Overlay(
            entry: entry,
            expires: Date().addingTimeInterval(overlayLifetime)
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
        entries += overlay.values.compactMap(\.entry)
        return DirectorySnapshot(entries: entries, verifier: snapshot.verifier)
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
            case .root:
                var seenDevices = Set<String>()
                entries = volumes.compactMap { volume in
                    guard seenDevices.insert(volume.device).inserted else {
                        return nil
                    }
                    return JottacloudDirectoryEntry(
                        entry: RemoteEntry(
                            name: volume.device,
                            kind: .directory,
                            size: 0,
                            modified: nil
                        ),
                        role: .device(volume.device)
                    )
                }
            case .device(let device):
                var seenMountpoints = Set<String>()
                entries = volumes.compactMap { volume in
                    guard volume.device == device,
                          seenMountpoints.insert(volume.mountpoint).inserted
                    else {
                        return nil
                    }
                    return JottacloudDirectoryEntry(
                        entry: RemoteEntry(
                            name: volume.mountpoint,
                            kind: .directory,
                            size: 0,
                            modified: nil
                        ),
                        role: .mountpoint(volume)
                    )
                }
            case .mountpoint(let volume):
                let remoteEntries = try await client.listDirectory(
                    volume: volume,
                    path: ""
                )
                entries = remoteEntries.map {
                    JottacloudDirectoryEntry(
                        entry: $0,
                        role: .remote(volume, path: $0.name)
                    )
                }
            case .remote(let volume, let remotePath):
                let remoteEntries = try await client.listDirectory(
                    volume: volume,
                    path: remotePath
                )
                entries = remoteEntries.map { entry in
                    let path = remotePath.isEmpty
                        ? entry.name
                        : "\(remotePath)/\(entry.name)"
                    return JottacloudDirectoryEntry(
                        entry: entry,
                        role: .remote(volume, path: path)
                    )
                }
            case .volumeIcon:
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

    func clear() {
        cache.removeAll()
        refreshing.removeAll()
        requests.values.forEach { $0.cancel() }
        requests.removeAll()
    }
}
