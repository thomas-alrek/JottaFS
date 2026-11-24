import Foundation

/// Sequential read-ahead for remote files.
///
/// Each FSKit read used to be one HTTPS range request of at most 1 MiB, one
/// after another, so a copy spent most of its time waiting for the first
/// byte of each request (about 70–100 ms). A single Jottacloud download also
/// runs at only about 4–5 MB/s, independent of its size.
///
/// Once 2 MiB of a file have been read in order, the file is read in blocks
/// of 8 MiB at fixed positions, with up to four blocks downloading at the
/// same time ahead of the reader. Random reads, and readers that only look at
/// the start of a file (thumbnails, previews), still go straight to
/// Jottacloud.
///
/// Memory is bounded: the blocks around the reader (at most six per file)
/// and `memoryLimit` in total; least recently used files are dropped first.
/// Callers invalidate a file when its contents may change (writes, uploads,
/// deletes) and when it is closed.
actor ReadAhead {
    /// Reads `length` bytes at `offset` from Jottacloud.
    typealias Fetch = @Sendable (_ offset: UInt64, _ length: Int) async throws -> Data

    static let blockSize = 8 * 1024 * 1024
    /// Blocks downloading at the same time ahead of the reader.
    static let parallelBlocks = 4
    static let memoryLimit = 128 * 1024 * 1024
    /// Bytes read in order before reading ahead.
    private static let sequentialThreshold: UInt64 = 2 * 1024 * 1024
    /// Reads this close to the expected position still count as sequential
    /// (FSKit can deliver concurrent reads slightly out of order).
    private static let sequentialSlack: UInt64 = 8 * 1024 * 1024

    private struct File {
        /// Downloads (running or done) by block index.
        var blocks: [UInt64: Task<Data, Error>] = [:]
        var nextOffset: UInt64 = 0
        /// Bytes read in order so far.
        var sequentialBytes: UInt64 = 0
        var lastUse = Date()
        /// Unique per cache entry, so results of requests started before an
        /// invalidation are dropped.
        let generation: Int
    }

    private var files: [UInt64: File] = [:]
    private var nextGeneration = 0

    func read(
        _ id: UInt64,
        offset: UInt64,
        length: Int,
        fileSize: UInt64,
        fetch: @escaping Fetch
    ) async throws -> Data {
        guard length > 0, offset < fileSize else {
            return Data()
        }
        let end = min(offset + UInt64(length), fileSize)
        var file = files[id] ?? newFile()
        let sequential = offset + Self.sequentialSlack >= file.nextOffset
            && offset <= file.nextOffset + Self.sequentialSlack
        if sequential {
            file.sequentialBytes += end - offset
            file.nextOffset = max(file.nextOffset, end)
        } else {
            file.blocks.values.forEach { $0.cancel() }
            file.blocks = [:]
            file.sequentialBytes = end - offset
            file.nextOffset = end
        }
        file.lastUse = Date()
        files[id] = file
        guard file.sequentialBytes > Self.sequentialThreshold else {
            return try await fetch(offset, Int(end - offset))
        }

        // Start the blocks this read needs and the ones ahead of it, then
        // drop blocks the reader has passed.
        let block = UInt64(Self.blockSize)
        let first = offset / block
        let last = (end - 1) / block
        let lastBlock = (fileSize - 1) / block
        let ahead = min(last + UInt64(Self.parallelBlocks), lastBlock)
        var tasks: [UInt64: Task<Data, Error>] = [:]
        for index in first...ahead {
            tasks[index] = task(for: index, of: id, fileSize: fileSize, fetch: fetch)
        }
        trim(id, keepingFrom: first > 0 ? first - 1 : 0)
        enforceMemoryLimit(keeping: id)

        var result = Data()
        result.reserveCapacity(Int(end - offset))
        for index in first...last {
            let blockStart = index * block
            let data: Data
            do {
                data = try await tasks[index]!.value
            } catch {
                // Cancelled (invalidated) or failed: read this part directly.
                discard(index, of: id)
                let from = max(offset, blockStart)
                let to = min(end, blockStart + block)
                result.append(try await fetch(from, Int(to - from)))
                continue
            }
            let from = Int(max(offset, blockStart) - blockStart)
            let to = Int(min(end, blockStart + UInt64(data.count)) - blockStart)
            guard from < to else {
                break
            }
            result.append(data[data.startIndex + from ..< data.startIndex + to])
        }
        return result
    }

    /// Drops cached data for a file (its contents may have changed, or it
    /// was closed).
    func invalidate(_ id: UInt64) {
        files[id]?.blocks.values.forEach { $0.cancel() }
        files.removeValue(forKey: id)
    }

    func removeAll() {
        files.values.forEach { file in file.blocks.values.forEach { $0.cancel() } }
        files.removeAll()
    }

    // MARK: Helpers

    private func newFile() -> File {
        nextGeneration += 1
        return File(generation: nextGeneration)
    }

    /// The download of one block, started if needed.
    private func task(for index: UInt64, of id: UInt64, fileSize: UInt64, fetch: @escaping Fetch) -> Task<Data, Error> {
        if let existing = files[id]?.blocks[index] {
            return existing
        }
        let offset = index * UInt64(Self.blockSize)
        let length = Int(min(UInt64(Self.blockSize), fileSize - offset))
        let task = Task { try await fetch(offset, length) }
        files[id]?.blocks[index] = task
        return task
    }

    private func discard(_ index: UInt64, of id: UInt64) {
        files[id]?.blocks.removeValue(forKey: index)
    }

    /// Keeps the block before the reader (reads can arrive slightly out of
    /// order) and everything after it.
    private func trim(_ id: UInt64, keepingFrom index: UInt64) {
        guard var file = files[id] else {
            return
        }
        for (key, task) in file.blocks where key < index {
            task.cancel()
            file.blocks.removeValue(forKey: key)
        }
        files[id] = file
    }

    private func enforceMemoryLimit(keeping id: UInt64) {
        func bytes(_ file: File) -> Int { file.blocks.count * Self.blockSize }
        var total = files.values.reduce(0) { $0 + bytes($1) }
        while total > Self.memoryLimit,
              let oldest = files.filter({ $0.key != id }).min(by: { $0.value.lastUse < $1.value.lastUse }) {
            total -= bytes(oldest.value)
            invalidate(oldest.key)
        }
    }
}
