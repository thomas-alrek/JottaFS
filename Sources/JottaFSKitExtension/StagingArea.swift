import CryptoKit
import Foundation
import JottaFSCore

/// A file being written: its local copy, size and whether it still needs to
/// be uploaded. `generation` changes on every write so an upload of an older
/// snapshot does not mark newer data clean.
struct StagedFile: Sendable {
    let url: URL
    var size: UInt64
    var dirty: Bool
    var generation: UInt64
    var created: Date
    var modified: Date
}

/// Local copies of files opened for writing, in the extension's Caches
/// container. Jottacloud needs a file's MD5 and size before upload, so writes
/// land here and are uploaded on close or sync (docs/write-support-design.md).
final class StagingArea: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private var files: [UInt64: StagedFile] = [:]
    private var loading: [UInt64: Task<StagedFile, Error>] = [:]
    private var uploading: [UInt64: Task<Void, Error>] = [:]
    /// Which registration `uploading[id]` is (see `serializeUpload`).
    private var uploadTokens: [UInt64: UUID] = [:]
    /// Files whose last upload failed: how many times in a row, and until
    /// when `synchronize` and reclaim leave them alone (close and rename
    /// still upload, as the app waiting for them asked to).
    private var failures: [UInt64: (count: Int, retryAfter: Date)] = [:]
    /// Longest pause after repeated failures.
    static let maximumBackoff: TimeInterval = 15 * 60
    /// The MD5 of each staged file's first `bytes` bytes, kept up to date by
    /// writes that continue exactly where the hashed part ends, so an upload
    /// hashes only the rest (a whole copy written in order needs no extra
    /// pass). Missing when a write or truncation changed the hashed part.
    private var digests: [UInt64: (hasher: Insecure.MD5, bytes: UInt64)] = [:]

    /// `key` names this volume's own folder: each mounted location has one,
    /// and may run in its own extension process.
    init(key: String) throws {
        let caches = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = caches.appendingPathComponent("Staging", isDirectory: true)
        directory = root.appendingPathComponent(key, isDirectory: true)
        // Leftovers belong to a previous extension process for this location
        // whose items no longer exist; their data cannot be matched to a path
        // again. Other locations' folders are never touched.
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Files directly in the root are from versions before 1.1, which had
        // one volume.
        for url in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func file(_ id: UInt64) -> StagedFile? {
        lock.withLock { files[id] }
    }

    var stagedIdentifiers: [UInt64] {
        lock.withLock { Array(files.keys) }
    }

    var dirtyIdentifiers: [UInt64] {
        lock.withLock { files.filter(\.value.dirty).map(\.key) }
    }

    /// Returns the staged file, creating it once with `populate` (which fills
    /// the new local file, for example by downloading the current contents).
    func stage(
        _ id: UInt64,
        populate: @escaping @Sendable (URL) async throws -> Void
    ) async throws -> StagedFile {
        enum Lookup {
            case staged(StagedFile)
            case loading(Task<StagedFile, Error>)
        }
        let lookup: Lookup = lock.withLock {
            if let existing = loading[id] {
                return .loading(existing)
            }
            if let staged = files[id] {
                return .staged(staged)
            }
            let url = directory.appendingPathComponent("\(id)-\(UUID().uuidString)")
            let task = Task {
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                    throw POSIXError(.EIO)
                }
                do {
                    try await populate(url)
                    let now = Date()
                    return StagedFile(
                        url: url,
                        size: try JottaFSStagingFile.size(of: url),
                        dirty: false,
                        generation: 0,
                        created: now,
                        modified: now
                    )
                } catch {
                    try? FileManager.default.removeItem(at: url)
                    throw error
                }
            }
            loading[id] = task
            return .loading(task)
        }
        let task: Task<StagedFile, Error>
        switch lookup {
        case .staged(let staged):
            return staged
        case .loading(let loadingTask):
            task = loadingTask
        }
        do {
            let staged = try await task.value
            return lock.withLock {
                loading.removeValue(forKey: id)
                if let current = files[id] {
                    return current
                }
                files[id] = staged
                // Any contents downloaded by `populate` are hashed at upload.
                digests[id] = (Insecure.MD5(), 0)
                return staged
            }
        } catch {
            _ = lock.withLock { loading.removeValue(forKey: id) }
            throw error
        }
    }

    /// Writes to the staged file and records it: size, dirty, next
    /// generation, and the running MD5. File and records change together
    /// under the lock, so a snapshot always matches its MD5 state. Concurrent
    /// writes can finish in any order, so the size only grows here. Returns
    /// the new size.
    @discardableResult
    /// Reserves disk space for `length` more bytes of a staged file (see
    /// `JottaFSStagingFile.reserve`). Throws `ENOSPC` if the Mac's disk
    /// cannot hold them.
    func reserve(_ length: UInt64, for id: UInt64) throws {
        try lock.withLock {
            guard let staged = files[id] else {
                throw POSIXError(.EBADF)
            }
            try JottaFSStagingFile.reserve(length, for: staged.url)
        }
    }

    func write(_ contents: Data, to id: UInt64, at offset: UInt64) throws -> UInt64 {
        try lock.withLock {
            guard var staged = files[id] else {
                throw POSIXError(.EBADF)
            }
            try JottaFSStagingFile.write(contents, to: staged.url, at: offset)
            if var digest = digests[id] {
                if offset == digest.bytes {
                    digest.hasher.update(data: contents)
                    digest.bytes += UInt64(contents.count)
                    digests[id] = digest
                } else if offset < digest.bytes {
                    digests.removeValue(forKey: id)
                }
                // A write after the hashed part leaves it as it is.
            }
            let end = offset + UInt64(contents.count)
            staged.size = max(staged.size, end)
            staged.dirty = true
            staged.generation &+= 1
            staged.modified = Date()
            files[id] = staged
            return staged.size
        }
    }

    /// Truncates (or extends) the staged file and records it.
    func truncate(_ id: UInt64, to size: UInt64) throws {
        try lock.withLock {
            guard var staged = files[id] else {
                throw POSIXError(.EBADF)
            }
            try JottaFSStagingFile.truncate(staged.url, to: size)
            if let digest = digests[id], digest.bytes > size {
                digests.removeValue(forKey: id)
            }
            staged.size = size
            staged.dirty = true
            staged.generation &+= 1
            staged.modified = Date()
            files[id] = staged
        }
    }

    /// Records a change that sets the size without changing the file (a
    /// created, empty file).
    func markModified(_ id: UInt64, size: UInt64, modified: Date = Date()) {
        lock.withLock {
            guard var staged = files[id] else {
                return
            }
            staged.size = size
            staged.dirty = true
            staged.generation &+= 1
            staged.modified = modified
            files[id] = staged
        }
    }

    func setModified(_ id: UInt64, _ modified: Date) {
        lock.withLock {
            files[id]?.modified = modified
        }
    }

    /// Marks the file clean if nothing changed since `generation` was uploaded.
    func markUploaded(_ id: UInt64, generation: UInt64) {
        lock.withLock {
            if files[id]?.generation == generation {
                files[id]?.dirty = false
            }
        }
    }

    /// Runs `upload` unless an upload of this file is already running, in
    /// which case it waits for that one first.
    ///
    /// The upload task removes its own registration before it completes, so
    /// a waiter never finds a finished upload still registered. (Before
    /// 1.1.3 the caller removed it afterwards; waiters looping on the
    /// finished task, which does not give up the thread, could take every
    /// thread of the pool before that caller ran again: a livelock.)
    func serializeUpload(_ id: UInt64, _ upload: @escaping @Sendable () async throws -> Void) async throws {
        while true {
            // Check for a running upload and register ours in one step.
            let (running, task): (Task<Void, Error>?, Task<Void, Error>?) = lock.withLock {
                if let running = uploading[id] {
                    return (running, nil)
                }
                let token = UUID()
                let task = Task {
                    // Runs before the task completes; takes the lock, so it
                    // also waits until the registration below is done.
                    defer { self.finishUpload(id, token: token) }
                    try await upload()
                }
                uploading[id] = task
                uploadTokens[id] = token
                return (nil, task)
            }
            if let running {
                _ = try? await running.value
                continue
            }
            guard let task else {
                return
            }
            try await task.value
            return
        }
    }

    private func finishUpload(_ id: UInt64, token: UUID) {
        lock.withLock {
            if uploadTokens[id] == token {
                uploading.removeValue(forKey: id)
                uploadTokens.removeValue(forKey: id)
            }
        }
    }

    /// Records a failed upload of the file; the pause before automatic
    /// retries doubles with each failure in a row (30 s, 1 min, 2 min… up
    /// to `maximumBackoff`).
    func uploadFailed(_ id: UInt64, now: Date = Date()) {
        lock.withLock {
            let count = (failures[id]?.count ?? 0) + 1
            let pause = min(30 * pow(2, Double(count - 1)), Self.maximumBackoff)
            failures[id] = (count, now.addingTimeInterval(pause))
        }
    }

    func uploadSucceeded(_ id: UInt64) {
        _ = lock.withLock { failures.removeValue(forKey: id) }
    }

    /// Whether automatic uploads of the file wait because one failed recently.
    func isBackingOff(_ id: UInt64, now: Date = Date()) -> Bool {
        lock.withLock { failures[id].map { $0.retryAfter > now } ?? false }
    }

    func isUploading(_ id: UInt64) -> Bool {
        lock.withLock { uploading[id] != nil }
    }

    /// Stops a running upload of the file (it is being deleted).
    func cancelUpload(_ id: UInt64) {
        lock.withLock { uploading[id] }?.cancel()
    }

    /// Waits until no upload of this file is running (used before deleting
    /// it, so a background upload cannot recreate a just-deleted file).
    func waitForUpload(_ id: UInt64) async {
        // A finished upload is no longer registered (`serializeUpload`), so
        // this loop does not spin.
        while let running = lock.withLock({ uploading[id] }) {
            _ = try? await running.value
        }
    }

    /// Deletes the local copy of a file that is uploaded and unchanged (no
    /// write since, no upload running), so a large copy onto the volume
    /// needs local space for about one file at a time. Returns whether it
    /// was deleted. Later reads come from Jottacloud; a later write stages
    /// the file again.
    @discardableResult
    func discardIfUploaded(_ id: UInt64) -> Bool {
        let url: URL? = lock.withLock {
            guard let staged = files[id], !staged.dirty, uploading[id] == nil, loading[id] == nil else {
                return nil
            }
            files.removeValue(forKey: id)
            digests.removeValue(forKey: id)
            return staged.url
        }
        guard let url else {
            return false
        }
        try? FileManager.default.removeItem(at: url)
        return true
    }

    /// Discards a staged file (after delete, or when a clean item is reclaimed).
    func discard(_ id: UInt64) {
        let url = lock.withLock {
            digests.removeValue(forKey: id)
            failures.removeValue(forKey: id)
            return files.removeValue(forKey: id)?.url
        }
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// A private copy of the staged file to upload, so writes during the
    /// upload do not change the bytes being sent (an APFS clone), and its
    /// MD5. Taken under the lock, so no write is half done; the MD5 hashes
    /// only what the running digest has not.
    func snapshot(_ id: UInt64) throws -> (url: URL, md5: String, hashedWhileWriting: UInt64) {
        let copy = directory.appendingPathComponent("upload-\(UUID().uuidString)")
        let digest = try lock.withLock {
            guard let staged = files[id] else {
                throw POSIXError(.EBADF)
            }
            try FileManager.default.copyItem(at: staged.url, to: copy)
            return digests[id]
        }
        do {
            let size = try JottaFSStagingFile.size(of: copy)
            if let digest, digest.bytes <= size {
                let md5 = try JottaFSStagingFile.md5(of: copy, continuing: digest.hasher, from: digest.bytes)
                return (copy, md5, digest.bytes)
            }
            return (copy, try JottaFSStagingFile.md5(of: copy), 0)
        } catch {
            try? FileManager.default.removeItem(at: copy)
            throw error
        }
    }
}
