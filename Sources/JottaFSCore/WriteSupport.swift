import CryptoKit
import Foundation

/// The only place the volume may modify. Every mutation is checked against
/// this scope before any network request; see docs/write-support-design.md.
public enum JottaFSWriteScope {
    public static let device = "Jotta"
    public static let mountpoint = "Archive"
    /// Folder directly under `Jotta/Archive`. It did not exist before write
    /// support, so everything in it was created through JottaFS.
    public static let folder = "JottaFS-Test"

    /// Whether `path` (relative to the mountpoint) is the scope folder itself.
    public static func isScopeRoot(device: String, mountpoint: String, path: String) -> Bool {
        guard isScopeMountpoint(device: device, mountpoint: mountpoint),
              let components = components(of: path)
        else {
            return false
        }
        return components.count == 1 && sameName(components[0], folder)
    }

    /// Whether `path` (relative to the mountpoint) lies strictly inside the
    /// scope folder. The scope folder itself is not "inside".
    public static func contains(device: String, mountpoint: String, path: String) -> Bool {
        guard isScopeMountpoint(device: device, mountpoint: mountpoint),
              let components = components(of: path),
              components.count >= 2
        else {
            return false
        }
        return sameName(components[0], folder)
    }

    /// Whether the given device/mountpoint is the one holding the scope.
    public static func isScopeMountpoint(device: String, mountpoint: String) -> Bool {
        sameName(device, Self.device) && sameName(mountpoint, Self.mountpoint)
    }

    /// Splits a mountpoint-relative path, rejecting empty, `.` and `..`
    /// components so a path can never escape by traversal.
    static func components(of path: String) -> [String]? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            return nil
        }
        return parts
    }

    /// Jottacloud names are case-insensitive. Compare exactly otherwise, so
    /// look-alike characters never match.
    public static func sameName(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .literal]) == .orderedSame
    }
}

public enum JottaFSNameError: Error, Equatable {
    case invalid
}

public enum JottaFSNames {
    /// Characters Jottacloud cannot store (rclone encodes these instead).
    private static let forbidden = CharacterSet(charactersIn: "\"*:<>?|%/\\")

    /// Validates a name for a new or renamed item. Invalid names are rejected
    /// rather than silently re-encoded.
    public static func validate(_ name: String) throws {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              name.count <= 255,
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

    public static func truncate(_ url: URL, to size: UInt64) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: size)
    }

    public static func size(of url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// Lowercase hex MD5 of a file, computed in chunks.
    public static func md5(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Insecure.MD5()
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
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
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
