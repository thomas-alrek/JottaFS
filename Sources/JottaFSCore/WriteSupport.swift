import CryptoKit
import Foundation

public enum JottaFSNameError: Error, Equatable {
    case invalid
}

public enum JottaFSNames {
    /// Jottacloud names are case-insensitive. Compare exactly otherwise, so
    /// look-alike characters never match.
    public static func sameName(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .literal]) == .orderedSame
    }

    /// Characters Jottacloud cannot store (rclone encodes these instead).
    private static let forbidden = CharacterSet(charactersIn: "\"*:<>?|%/\\")

    /// Validates a name for a new or renamed item. Invalid names are rejected
    /// rather than silently re-encoded.
    public static func validate(_ name: String) throws {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              name.utf8.count <= 255,  // a byte limit, like the volume's maximum name length
              name.unicodeScalars.allSatisfy({
                  !forbidden.contains($0) && !CharacterSet.controlCharacters.contains($0)
              })
        else {
            throw JottaFSNameError.invalid
        }
        // `.DS_Store` and AppleDouble (`._*`) files are allowed and uploaded
        // like any other file: refusing them made Finder abort folder copies
        // (error -8062).
    }
}

/// Local file operations for staged writes.
public enum JottaFSStagingFile {
    /// Writes `data` at `offset`, extending the file as needed. Returns the
    /// new file size.
    @discardableResult
    public static func write(_ data: Data, to url: URL, at offset: UInt64) throws -> UInt64 {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: data)
        return try handle.seekToEnd()
    }

    /// Reads up to `length` bytes at `offset` (short at end of file).
    public static func read(from url: URL, at offset: UInt64, length: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: length) ?? Data()
    }

    /// Reserves `length` bytes of disk space after the end of the file
    /// (`F_PREALLOCATE`, all or nothing, kept after this call closes the
    /// file), so writing that much more cannot run out of space. Throws
    /// `POSIXError(.ENOSPC)` if the disk cannot hold it.
    public static func reserve(_ length: UInt64, for url: URL) throws {
        guard length > 0 else {
            return
        }
        let descriptor = open(url.path, O_WRONLY)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        // F_ALLOCATEALL (0x4) | F_ALLOCATEPERSIST (0x8).
        var store = fstore_t(
            fst_flags: 0x4 | 0x8,
            fst_posmode: F_PEOFPOSMODE,
            fst_offset: 0,
            fst_length: off_t(clamping: length),
            fst_bytesalloc: 0
        )
        guard fcntl(descriptor, F_PREALLOCATE, &store) != -1 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Whether `error` means that the Mac's disk is full.
    public static func isOutOfSpace(_ error: Error) -> Bool {
        if (error as? CocoaError)?.code == .fileWriteOutOfSpace {
            return true
        }
        if let posix = error as? POSIXError, posix.code == .ENOSPC {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOSPC)
    }

    public static func truncate(_ url: URL, to size: UInt64) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: size)
    }

    public static func size(of url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// Lowercase hex MD5 of a file, computed in chunks. With `hasher` (the
    /// MD5 state of the file's first `offset` bytes), only the rest is read.
    public static func md5(of url: URL, continuing hasher: Insecure.MD5 = Insecure.MD5(), from offset: UInt64 = 0) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = hasher
        try handle.seek(toOffset: offset)
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// `POST https://api.jottacloud.com/files/v1/allocate` request body.
struct AllocateRequest: Encodable, Equatable {
    let bytes: UInt64
    let md5: String
    let path: String
    let created: String
    let modified: String

    init(
        device: String,
        mountpoint: String,
        path: String,
        bytes: UInt64,
        md5: String,
        created: Date,
        modified: Date
    ) {
        self.bytes = bytes
        self.md5 = md5
        self.path = "/jfs/\(device)/\(mountpoint)/\(path)"
        self.created = Self.timestamp(created)
        self.modified = Self.timestamp(modified)
    }

    /// RFC 3339 without fractional seconds, as Jottacloud expects.
    static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601)
    }
}

struct AllocateResponse: Decodable, Equatable {
    let state: String?
    let uploadURL: String?
    let resumePosition: UInt64?

    enum CodingKeys: String, CodingKey {
        case state
        case uploadURL = "upload_url"
        case resumePosition = "resume_pos"
    }
}

/// A file's current revision as reported by a JFS metadata request.
struct RemoteFileRevision: Equatable {
    let entry: RemoteEntry
    let md5: String?
}
