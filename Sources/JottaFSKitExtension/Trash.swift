import Darwin
import Foundation
import JottaFSCore
import OSLog

private let trashLogger = Logger.extension("Trash")

/// State behind the virtual Trash (docs/trash-design.md).
///
/// The Jottacloud trash can hold many thousands of entries and is listed at
/// about 500 entries per request, so it is loaded in the background and
/// Finder is always answered from memory: a file system call must never
/// wait for the whole trash (Finder looks up the Trash while moving items
/// into it). Also kept here:
///
/// - stable names for trash entries, because Finder's Put Back information
///   refers to items by their name in the Trash;
/// - Finder's own metadata files in the Trash (`.DS_Store`, `._*`), kept in
///   the extension's container and never uploaded.
actor TrashStore {
    /// Name of the per-user folder in `/.Trashes`.
    nonisolated let userFolderName = String(getuid())
    nonisolated let localDirectory: URL
    static let maximumEntries = 20_000
    private static let pageSize: UInt64 = 500
    /// A full reload (which also notices entries emptied or restored
    /// elsewhere) at most this often, and a check of the newest page.
    private static let fullRefreshInterval: TimeInterval = 30 * 60
    private static let quickRefreshInterval: TimeInterval = 30
    private static let tombstoneLifetime: TimeInterval = 10 * 60

    private let client: JottacloudClient
    /// Lower-cased service path prefix of what is mounted (for example
    /// `/archive/` or `/backup/<id>/`); nil when unknown, and the Trash then
    /// stays empty.
    private let locationPrefixes: [String]
    private let namesURL: URL
    /// Trash entry key (`path` + deletion time) to its name in the Trash.
    private var names: [String: String]
    private var usedNames: Set<String> = []
    private var items: [String: JottacloudPathItem] = [:]
    /// Entries removed here, so a listing fetched before the removal does
    /// not bring them back.
    private var tombstones: [String: Date] = [:]
    private var generation: UInt64 = 1
    private var cachedSnapshot: DirectorySnapshot?
    private var refreshTask: Task<Void, Never>?
    private var lastFullLoad: Date?
    private var lastQuickLoad: Date?

    /// `key` names this volume's own folder (see `MountTarget.storageKey`).
    init(client: JottacloudClient, locationPrefixes: [String], key: String) throws {
        self.client = client
        self.locationPrefixes = locationPrefixes
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appending(path: "Trash", directoryHint: .isDirectory)
        .appending(path: key, directoryHint: .isDirectory)
        localDirectory = support.appending(path: "Local", directoryHint: .isDirectory)
        namesURL = support.appending(path: "Names.plist", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: namesURL),
           let stored = try? PropertyListDecoder().decode([String: String].self, from: data) {
            names = stored
        } else {
            names = [:]
        }
        usedNames = Set(names.values.map { $0.lowercased() })
    }

    static func key(_ item: JottacloudPathItem) -> String {
        "\(item.path.lowercased())\n\(item.deletedAtMillis)"
    }

    /// Finder metadata names that may be created in the Trash.
    nonisolated static func isLocalMetadataName(_ name: String) -> Bool {
        name == ".DS_Store" || (name.hasPrefix("._") && name.count > 2)
    }

    nonisolated func localURL(_ name: String) -> URL {
        localDirectory.appending(path: name, directoryHint: .notDirectory)
    }

    // MARK: Listing

    /// The Trash as loaded so far. Never waits for the network; starts a
    /// background refresh when one is due.
    func snapshot() -> DirectorySnapshot {
        refreshIfDue()
        if let cachedSnapshot {
            return cachedSnapshot
        }
        var entries = items.values
            .sorted { $0.deletedAtMillis > $1.deletedAtMillis }
            .map { item in
                JottacloudDirectoryEntry(
                    entry: RemoteEntry(
                        name: names[Self.key(item)] ?? item.name,
                        kind: item.isFolder ? .directory : .file,
                        size: item.isFolder ? 0 : item.size,
                        modified: item.modified
                    ),
                    role: .trashed(item, topLevel: true)
                )
            }
        for name in localNames() {
            entries.append(localEntry(name))
        }
        let snapshot = DirectorySnapshot(entries: entries, verifier: generation)
        cachedSnapshot = snapshot
        return snapshot
    }

    /// Starts loading the trash (at mount, so it is ready when Finder looks).
    func start() {
        refreshIfDue()
    }

    private func refreshIfDue() {
        guard refreshTask == nil else {
            return
        }
        let now = Date()
        if lastFullLoad.map({ now.timeIntervalSince($0) >= Self.fullRefreshInterval }) ?? true {
            refreshTask = Task { await self.load(full: true) }
        } else if lastQuickLoad.map({ now.timeIntervalSince($0) >= Self.quickRefreshInterval }) ?? true {
            refreshTask = Task { await self.load(full: false) }
        }
    }

    /// Loads the trash page by page (newest first), publishing each page.
    /// A complete full load also drops entries that are no longer there.
    private func load(full: Bool) async {
        let started = Date()
        var seen = Set<String>()
        var cursor: String?
        var complete = false
        var failed = false
        var newestPageOldest: UInt64?
        repeat {
            do {
                let page = try await client.trashPage(cursor: cursor, limit: full ? Self.pageSize : 100)
                if newestPageOldest == nil, page.cursor != nil {
                    newestPageOldest = page.items.map(\.deletedAtMillis).min()
                }
                merge(page.items, seen: &seen)
                cursor = page.cursor
                complete = cursor == nil
            } catch {
                trashLogger.error("Loading the trash failed (\((error as NSError).code, privacy: .public)).")
                failed = true
                break
            }
        } while full && cursor != nil && seen.count < Self.maximumEntries
        var needsFullLoad = false
        if complete, !failed {
            // The whole trash was seen (a full load, or a quick check of a
            // trash that fits on one page): drop everything else.
            prune(keeping: seen, loadStarted: started)
        } else if !full, !failed, let oldest = newestPageOldest {
            // A quick check sees the newest entries. If one we show from
            // that time range is missing, entries were emptied or restored
            // elsewhere: reload everything now instead of in 30 minutes.
            needsFullLoad = items.contains { $0.value.deletedAtMillis >= oldest && !seen.contains($0.key) && tombstones[$0.key] == nil }
        }
        if full, !failed {
            lastFullLoad = Date()
            save()
            trashLogger.info("Loaded \(seen.count, privacy: .public) trash entries\(complete ? "" : " (limit reached)", privacy: .public).")
        }
        if !failed {
            lastQuickLoad = Date()
        } else if lastFullLoad == nil {
            // Retry the first load on a later access, not in a loop.
            lastFullLoad = Date().addingTimeInterval(60 - Self.fullRefreshInterval)
            lastQuickLoad = Date()
        }
        refreshTask = nil
        if needsFullLoad {
            trashLogger.info("Trash entries changed elsewhere; reloading the trash.")
            refreshTask = Task { await self.load(full: true) }
        }
    }

    /// Drops entries not in `seen`, except ones added here while the load
    /// ran (trashed within a minute before it started, or later).
    private func prune(keeping seen: Set<String>, loadStarted started: Date) {
        let cutoff = UInt64(started.timeIntervalSince1970 * 1000) - 60_000
        let removed = items.filter { !seen.contains($0.key) && $0.value.deletedAtMillis < cutoff }
        guard !removed.isEmpty else {
            return
        }
        for key in removed.keys {
            items.removeValue(forKey: key)
        }
        names = names.filter { items[$0.key] != nil }
        usedNames = Set(names.values.map { $0.lowercased() })
        save()
        changed()
        trashLogger.info("\(removed.count, privacy: .public) trash entries are gone from Jottacloud.")
    }

    private func merge(_ page: [JottacloudPathItem], seen: inout Set<String>) {
        let now = Date()
        tombstones = tombstones.filter { $0.value > now }
        var updated = false
        let localTaken = Set(localNames().map { $0.lowercased() })
        for item in page where item.isTrashed && belongsToLocation(item) {
            let key = Self.key(item)
            seen.insert(key)
            guard tombstones[key] == nil else {
                continue
            }
            if items[key] != item {
                items[key] = item
                updated = true
            }
            if names[key] == nil {
                let name = Self.uniqueName(item.name, taken: usedNames.union(localTaken))
                names[key] = name
                usedNames.insert(name.lowercased())
                updated = true
            }
        }
        if updated {
            changed()
        }
    }

    private func belongsToLocation(_ item: JottacloudPathItem) -> Bool {
        let path = JottacloudClient.requestPath(item.path).lowercased()
        return locationPrefixes.contains { path.hasPrefix($0) }
    }

    // MARK: Changes made through the volume

    /// Adds an item Finder moved into the Trash, under the name Finder chose.
    func add(_ item: JottacloudPathItem, name: String) {
        let key = Self.key(item)
        tombstones.removeValue(forKey: key)
        // Finder chose a name not shown in the Trash; an entry not loaded
        // yet may hold it, and gets another name.
        if let other = names.first(where: { $0.key != key && $0.value.lowercased() == name.lowercased() })?.key {
            names.removeValue(forKey: other)
            usedNames = Set(names.values.map { $0.lowercased() })
            usedNames.insert(name.lowercased())
            if let otherItem = items[other] {
                names[other] = Self.uniqueName(otherItem.name, taken: usedNames)
                usedNames.insert(names[other]!.lowercased())
            }
        }
        items[key] = item
        names[key] = name
        usedNames = Set(names.values.map { $0.lowercased() })
        save()
        changed()
    }

    /// Renames an entry within the Trash.
    func rename(_ item: JottacloudPathItem, to name: String) {
        names[Self.key(item)] = name
        usedNames = Set(names.values.map { $0.lowercased() })
        save()
        changed()
    }

    /// Forgets an entry deleted permanently or restored.
    func forget(_ item: JottacloudPathItem) {
        let key = Self.key(item)
        tombstones[key] = Date().addingTimeInterval(Self.tombstoneLifetime)
        items.removeValue(forKey: key)
        if names.removeValue(forKey: key) != nil {
            usedNames = Set(names.values.map { $0.lowercased() })
            save()
        }
        changed()
    }

    /// Stops background loading (the volume is going away).
    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// A local metadata file was created, renamed or removed.
    func localFilesChanged() {
        changed()
    }

    private func changed() {
        generation += 1
        cachedSnapshot = nil
    }

    // MARK: Local metadata files

    private func localNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: localDirectory.path)) ?? [])
            .filter(Self.isLocalMetadataName)
    }

    nonisolated func localEntry(_ name: String) -> JottacloudDirectoryEntry {
        let url = localURL(name)
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return JottacloudDirectoryEntry(
            entry: RemoteEntry(
                name: name,
                kind: .file,
                size: UInt64(values?.fileSize ?? 0),
                modified: values?.contentModificationDate
            ),
            role: .trashLocal(url)
        )
    }

    private func save() {
        do {
            let data = try PropertyListEncoder().encode(names)
            try data.write(to: namesURL, options: .atomic)
        } catch {
            trashLogger.error("Could not save Trash names (\((error as NSError).code, privacy: .public)).")
        }
    }

    /// `name`, or `base 2.ext`, `base 3.ext`… if taken (case-insensitive).
    static func uniqueName(_ name: String, taken: Set<String>) -> String {
        guard taken.contains(name.lowercased()) else {
            return name
        }
        let ns = name as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        let hasExtension = !ext.isEmpty && !stem.isEmpty
        let base = hasExtension ? stem : name
        let suffix = hasExtension ? "." + ext : ""
        var number = 2
        while true {
            let candidate = "\(base) \(number)\(suffix)"
            if !taken.contains(candidate.lowercased()) {
                return candidate
            }
            number += 1
        }
    }
}
