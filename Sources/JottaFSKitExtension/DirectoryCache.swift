import Foundation
import JottaFSCore

struct DirectorySnapshot: Sendable {
    let entries: [JottacloudDirectoryEntry]
    let verifier: UInt64
}

actor DirectoryCache {
    private struct Cached {
        let snapshot: DirectorySnapshot
        let loadedAt: Date
    }

    private let client: JottacloudClient
    private let volumes: [JottacloudRemoteVolume]
    private let lifetime: TimeInterval = 5
    private let maximumDirectories = 128
    private let maximumEntries = 2_048
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
        if let cached = cache[path], Date().timeIntervalSince(cached.loadedAt) < lifetime {
            return cached.snapshot
        }
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
        requests.values.forEach { $0.cancel() }
        requests.removeAll()
    }
}
