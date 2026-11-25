import Foundation
import JottaFSCore
import OSLog

/// Downloaded file blocks on disk, so reading a file again (or opening it
/// after Finder made a preview) does not download it again. Jottacloud
/// limits downloads to about 5–7 MB/s in total (docs/jottacloud-api-internals.md),
/// so not downloading is the only way to read faster.
///
/// Blocks are keyed by the MD5 of the file's current revision and the block
/// index: a changed file has a new MD5, so a cached block can never be stale,
/// and the same content is shared between files and mounted volumes.
///
/// The cache lives in the app group's `Library/Caches/BlockCache`, so the
/// app can show its size and clear it (Settings), with one folder per
/// mounted location (`BlockCache/<location key>/`). A location's folder is
/// emptied when the location is mounted and deleted when it is unmounted, and
/// the whole cache is emptied after every restart of the Mac (it records the
/// boot time). All locations together hold at most `limit` bytes: the size
/// set in the app's Settings (`JottaFSStorage.blockCacheLimitMB`, 1024 MB by
/// default; 0 turns the cache off). Before a
/// block is added, the oldest blocks (by last use) are deleted until the new
/// one fits. Each mounted volume can run in its own extension process; they
/// share the directory, so the size is measured from the directory itself
/// (at the first write, then again when this process's estimate reaches the
/// limit or is older than `rescanInterval`).
final class BlockCache: @unchecked Sendable {
    private static let rescanInterval: TimeInterval = 30

    /// The size limit in bytes, read from the shared settings at most once
    /// per `rescanInterval`. Call with `lock` held.
    private var limit: UInt64 {
        if Date().timeIntervalSince(limitRead) >= Self.rescanInterval {
            cachedLimit = UInt64(JottaFSStorage.blockCacheLimitMB()) * 1024 * 1024
            limitRead = Date()
        }
        return cachedLimit
    }
    private var cachedLimit: UInt64 = 0
    private var limitRead = Date.distantPast

    /// The whole cache (all locations, and the boot marker).
    private let root: URL?
    /// This location's blocks.
    private let directory: URL?
    private let lock = NSLock()
    /// Bytes in the cache as last measured, plus what this process added.
    private var estimatedSize: UInt64?
    private var lastScan = Date.distantPast
    /// Diagnostics: blocks stored by this process.
    private var storedBlocks = 0
    private let logger = Logger.extension("BlockCache")

    /// The cache of one mounted location (`key`: `MountTarget.storageKey`).
    /// Starts empty: blocks left from an earlier mount (for example after the
    /// extension stopped without unmounting) are deleted.
    init(key: String) {
        guard let root = JottaFSStorage.blockCacheDirectoryURL() else {
            self.root = nil
            self.directory = nil
            return
        }
        let directory = root.appendingPathComponent(key, isDirectory: true)
        // Test builds of 1.0.2 kept the cache in the extension's temporary
        // directory.
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("BlockCache", isDirectory: true))
        do {
            Self.removeIfFromAnEarlierBoot(root)
            try Self.prepare(root: root)
            // Blocks directly in the root are from versions up to 1.0.5,
            // which had one folder for all locations.
            for url in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
            where url.lastPathComponent != Self.bootMarkerName
                && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                try? FileManager.default.removeItem(at: url)
            }
            try? FileManager.default.removeItem(at: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            self.root = root
            self.directory = directory
        } catch {
            self.root = nil
            self.directory = nil
        }
    }

    /// Deletes this location's blocks (when it is unmounted).
    func removeAll() {
        guard let directory else {
            return
        }
        lock.withLock {
            try? FileManager.default.removeItem(at: directory)
            estimatedSize = nil
        }
    }

    /// Gives disk space back for files being uploaded, which need it more:
    /// deletes the least recently used blocks of any location until `bytes`
    /// are freed or the cache is empty. Returns the bytes freed.
    @discardableResult
    func release(_ bytes: UInt64) -> UInt64 {
        guard let root else {
            return 0
        }
        return lock.withLock {
            var freed: UInt64 = 0
            var removed = 0
            for entry in Self.entries(in: root) where freed < bytes {
                // Gone already (another process) is fine.
                try? FileManager.default.removeItem(at: entry.url)
                freed += entry.size
                removed += 1
            }
            estimatedSize = nil
            if removed > 0 {
                logger.notice("Removed \(removed, privacy: .public) blocks from the cache to make room for an upload.")
            }
            return freed
        }
    }

    /// The cached blocks of all locations, least recently used first.
    private static func entries(in root: URL) -> [(url: URL, size: UInt64, used: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys)?.allObjects as? [URL]) ?? []
        return files
            .compactMap { url -> (url: URL, size: UInt64, used: Date)? in
                guard url.lastPathComponent != bootMarkerName,
                      let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true
                else {
                    return nil
                }
                return (url, UInt64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.used < $1.used }
    }

    /// Creates the root and its boot marker.
    private static func prepare(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let marker = root.appendingPathComponent(bootMarkerName)
        if !FileManager.default.fileExists(atPath: marker.path) {
            try Data(bootTime.utf8).write(to: marker)
        }
    }

    // MARK: Restarts

    private static let bootMarkerName = ".boot"

    /// The system boot time (`kern.boottime`), as text.
    private static var bootTime: String {
        var time = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &time, &size, nil, 0) == 0 else {
            return "unknown"
        }
        return "\(time.tv_sec).\(time.tv_usec)"
    }

    /// Deletes a cache left from before the last restart. Another process of
    /// this boot may already have checked (and written the marker); then the
    /// cache is kept.
    private static func removeIfFromAnEarlierBoot(_ root: URL) {
        let marker = root.appendingPathComponent(bootMarkerName)
        guard FileManager.default.fileExists(atPath: root.path) else {
            return
        }
        let recorded = (try? String(contentsOf: marker, encoding: .utf8)) ?? ""
        if recorded != bootTime {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// A cached block of exactly `length` bytes, or nil.
    func block(md5: String, index: UInt64, length: Int) -> Data? {
        guard let url = url(md5: md5, index: index),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count == length
        else {
            return nil
        }
        // Mark it as recently used.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return data
    }

    /// Stores a downloaded block, deleting the oldest blocks first so it fits.
    func store(_ data: Data, md5: String, index: UInt64) {
        guard let root, let directory, let url = url(md5: md5, index: index), !data.isEmpty else {
            return
        }
        lock.withLock {
            let limit = limit
            guard UInt64(data.count) <= limit else {
                // Off (or smaller than one block): empty it once.
                if estimatedSize != 0 {
                    makeRoom(for: 0, in: root, limit: 0)
                }
                return
            }
            makeRoom(for: UInt64(data.count), in: root, limit: limit)
            // The app may have cleared the cache (deleting the root).
            if !FileManager.default.fileExists(atPath: directory.path) {
                try? Self.prepare(root: root)
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                estimatedSize = nil
            }
            // Written to a temporary name and renamed, so a reader (in this or
            // another process) never sees a partial block.
            let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
            do {
                try data.write(to: temporary)
                guard rename(temporary.path, url.path) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                estimatedSize = (estimatedSize ?? 0) + UInt64(data.count)
                storedBlocks += 1
                if storedBlocks == 1 || storedBlocks % 64 == 0 {
                    logger.debug("Cached \(self.storedBlocks, privacy: .public) blocks so far (about \((self.estimatedSize ?? 0) >> 20, privacy: .public) MB in the cache).")
                }
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                logger.error("A block could not be cached.")
            }
        }
    }

    // MARK: Helpers

    /// `<md5>-<index>`; nil unless `md5` is 32 hexadecimal characters.
    private func url(md5: String, index: UInt64) -> URL? {
        guard let directory, md5.count == 32, md5.allSatisfy(\.isHexDigit) else {
            return nil
        }
        return directory.appendingPathComponent("\(md5.lowercased())-\(index)", isDirectory: false)
    }

    /// Deletes the least recently used blocks of any location until
    /// `needed` more bytes fit under the limit. Call with `lock` held.
    private func makeRoom(for needed: UInt64, in root: URL, limit: UInt64) {
        if let estimatedSize, estimatedSize + needed <= limit,
           Date().timeIntervalSince(lastScan) < Self.rescanInterval {
            return
        }
        let entries = Self.entries(in: root)
        var total = entries.reduce(0) { $0 + $1.size }
        var removed = 0
        for entry in entries where total + needed > limit {
            // Gone already (another process) is fine.
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
            removed += 1
        }
        if removed > 0 {
            logger.info("Removed \(removed, privacy: .public) old blocks from the cache.")
        }
        estimatedSize = total
        lastScan = Date()
    }
}
