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
    /// Largest file the volume will stage; larger writes fail with EFBIG.
    /// 2 GiB.
    static let maximumSize: UInt64 = 2 * 1024 * 1024 * 1024

    private let directory: URL
    private let lock = NSLock()
    private var files: [UInt64: StagedFile] = [:]
    private var loading: [UInt64: Task<StagedFile, Error>] = [:]
    private var uploading: [UInt64: Task<Void, Error>] = [:]

    init() throws {
        let caches = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        directory = caches.appendingPathComponent("Staging", isDirectory: true)
        // Leftovers belong to a previous extension process whose items no
        // longer exist; their data cannot be matched to a path again.
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
                return staged
            }
        } catch {
            _ = lock.withLock { loading.removeValue(forKey: id) }
            throw error
        }
    }

    /// Records a modification: new size, dirty, next generation.
    /// Records a write that ended at `endOffset`. Concurrent writes can
    /// finish in any order, so the size only grows here (truncation uses
    /// `markModified(_:size:)`).
    func markWritten(_ id: UInt64, endingAt endOffset: UInt64) {
        lock.withLock {
            guard var staged = files[id] else {
                return
            }
            staged.size = max(staged.size, endOffset)
            staged.dirty = true
            staged.generation &+= 1
            staged.modified = Date()
            files[id] = staged
        }
    }

    /// Records a change that sets the size (create, truncate).
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
    func serializeUpload(_ id: UInt64, _ upload: @escaping @Sendable () async throws -> Void) async throws {
        while true {
            // Check for a running upload and register ours in one step.
            let (running, task): (Task<Void, Error>?, Task<Void, Error>?) = lock.withLock {
                if let running = uploading[id] {
                    return (running, nil)
                }
                let task = Task { try await upload() }
                uploading[id] = task
                return (nil, task)
            }
            if let running {
                _ = try? await running.value
                continue
            }
            guard let task else {
                return
            }
            defer {
                lock.withLock {
                    if uploading[id] == task {
                        uploading.removeValue(forKey: id)
                    }
                }
            }
            try await task.value
            return
        }
    }

    /// Waits until no upload of this file is running (used before deleting
    /// it, so a background upload cannot recreate a just-deleted file).
    func waitForUpload(_ id: UInt64) async {
        while let running = lock.withLock({ uploading[id] }) {
            _ = try? await running.value
        }
    }

    /// Discards a staged file (after delete, or when a clean item is reclaimed).
    func discard(_ id: UInt64) {
        let url = lock.withLock { files.removeValue(forKey: id)?.url }
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// A private copy of the staged file to upload, so writes during the
    /// upload do not change the bytes being sent.
    func snapshot(_ staged: StagedFile) throws -> URL {
        let copy = directory.appendingPathComponent("upload-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: staged.url, to: copy)
        return copy
    }
}
