import CryptoKit
import Foundation

public enum JottaFSStorageError: Error, LocalizedError {
    case applicationGroupUnavailable
    case credentialsDirectoryNotWritable(String)
    case invalidCredentialsDirectory

    public var errorDescription: String? {
        switch self {
        case .applicationGroupUnavailable:
            "Could not access Jottacloud's shared Application Support folder."
        case .credentialsDirectoryNotWritable(let reason):
            "Could not create Jottacloud's shared Application Support folder. Ensure App Group \(JottaFSStorage.applicationGroupIdentifier) is registered and included in the provisioning profiles for both the app and FSKit extension. Details: \(reason)"
        case .invalidCredentialsDirectory:
            "The filesystem resource is not Jottacloud's shared credentials folder."
        }
    }
}

public enum JottaFSStorage {
    public static let applicationGroupIdentifier = "group.no.alrek.jottafs"
    /// Volume name for a mounted location: the name the user chose for it in
    /// the app, or else the location's own name ("Archive", or a backed-up
    /// folder such as "Media"). The system mounts at `/Volumes/<name>` and
    /// picks another path if that one is taken. A name only changes at the
    /// next mount: renaming a mounted volume is not supported
    /// (docs/fskit-internals.md).
    public static func volumeName(device: String, mountpoint: String) -> String {
        if let custom = customVolumeName(device: device, mountpoint: mountpoint) {
            return custom
        }
        return defaultVolumeName(mountpoint: mountpoint)
    }

    /// The location's own name, made usable as a mount point name.
    public static func defaultVolumeName(mountpoint: String) -> String {
        // `/` and `:` cannot appear in a mount point name.
        let cleaned = mountpoint
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return cleaned.isEmpty ? "Jottacloud" : cleaned
    }

    // MARK: Custom volume names (Settings.plist, shared with the extension)

    static let settingsFileName = "Settings.plist"
    static let volumeNamesKey = "VolumeNames"

    static func locationKey(device: String, mountpoint: String) -> String {
        "\(device.lowercased())/\(mountpoint.lowercased())"
    }

    /// The name the user chose for a location, if any.
    public static func customVolumeName(device: String, mountpoint: String) -> String? {
        let names = loadSettings()[volumeNamesKey] as? [String: String]
        return names?[locationKey(device: device, mountpoint: mountpoint)].flatMap(validVolumeName)
    }

    /// Saves (or, with nil, removes) the name the user chose for a location.
    public static func setCustomVolumeName(_ name: String?, device: String, mountpoint: String) throws {
        guard let directory = credentialsDirectoryURL() else {
            throw JottaFSStorageError.applicationGroupUnavailable
        }
        var settings = loadSettings()
        var names = settings[volumeNamesKey] as? [String: String] ?? [:]
        let key = locationKey(device: device, mountpoint: mountpoint)
        if let name {
            guard let valid = validVolumeName(name) else {
                throw POSIXError(.EINVAL)
            }
            names[key] = valid
        } else {
            names.removeValue(forKey: key)
        }
        settings[volumeNamesKey] = names
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try PropertyListSerialization.data(fromPropertyList: settings, format: .xml, options: 0)
        try data.write(to: directory.appendingPathComponent(settingsFileName, isDirectory: false), options: .atomic)
    }

    /// A name usable for a volume (`/Volumes/<name>`), trimmed, or nil: not
    /// empty, not `.`/`..`, no `/`, `:` or control characters, and at most
    /// 255 bytes of UTF-8.
    public static func validVolumeName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..",
              !trimmed.contains("/"), !trimmed.contains(":"),
              trimmed.utf8.count <= 255,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            return nil
        }
        return trimmed
    }

    private static func loadSettings() -> [String: Any] {
        guard let directory = credentialsDirectoryURL(),
              let data = try? Data(contentsOf: directory.appendingPathComponent(settingsFileName, isDirectory: false)),
              let settings = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            return [:]
        }
        return settings
    }

    /// File system type (the extension's `FSShortName`).
    public static let fileSystemType = "jottacloud"

    // MARK: Mount anchors

    /// Each location is mounted from its own empty directory, its *mount
    /// anchor*, `<app group>/JottaCloudMount/<anchor name>`, used as the
    /// `FSPathURLResource`. A path resource makes the mount local (like
    /// Xcode's DeviceFS), which a generic URL resource does not, and Finder
    /// lists only local or NetFS-backed volumes in its sidebar. One anchor
    /// per location lets several locations be mounted at the same time. The
    /// anchor holds only `Location.plist`, which names its location; it is
    /// deliberately not the credentials directory.
    ///
    /// Versions before 1.1 mounted from `JottaCloudMount` itself (the
    /// *legacy anchor*), with the location saved in the credentials. Such a
    /// mount can still be found and unmounted after an update.
    public static func mountAnchorsDirectoryURL() -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: applicationGroupIdentifier
        )?
        .appendingPathComponent("JottaCloudMount", isDirectory: true)
        .standardizedFileURL
    }

    static let anchorLocationFileName = "Location.plist"

    /// The anchor name of a location: 32 hexadecimal characters derived from
    /// its device and mountpoint (case-insensitive, like Jottacloud).
    public static func anchorName(device: String, mountpoint: String) -> String {
        let digest = SHA256.hash(data: Data(locationKey(device: device, mountpoint: mountpoint).utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// True for a valid anchor name (and the empty name of the legacy anchor).
    public static func isValidAnchorName(_ name: String) -> Bool {
        name.isEmpty || (name.count == 32 && name.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    /// The anchor of a location, created if needed, with its
    /// `Location.plist`.
    public static func prepareMountAnchor(device: String, mountpoint: String) throws -> URL {
        guard let anchors = mountAnchorsDirectoryURL() else {
            throw JottaFSStorageError.applicationGroupUnavailable
        }
        let anchor = anchors.appendingPathComponent(anchorName(device: device, mountpoint: mountpoint), isDirectory: true)
        try FileManager.default.createDirectory(at: anchor, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["Device": device, "Mountpoint": mountpoint],
            format: .xml,
            options: 0
        )
        try data.write(to: anchor.appendingPathComponent(anchorLocationFileName, isDirectory: false), options: .atomic)
        return anchor
    }

    /// The anchor name of `url` if it is a mount anchor: `""` for the legacy
    /// anchor, else the directory's name. Nil for any other URL.
    public static func anchorName(ofAnchor url: URL) -> String? {
        guard url.isFileURL, let anchors = mountAnchorsDirectoryURL() else {
            return nil
        }
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let root = anchors.resolvingSymlinksInPath().path
        if path == root {
            return ""
        }
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        guard parent == root, !name.isEmpty, isValidAnchorName(name) else {
            return nil
        }
        return name
    }

    /// The location an anchor was made for, from its `Location.plist`. Nil
    /// for the legacy anchor (its location is the one in the credentials)
    /// and for an anchor without a readable, matching file.
    public static func location(ofAnchor url: URL) -> (device: String, mountpoint: String)? {
        guard let name = anchorName(ofAnchor: url), !name.isEmpty,
              let data = try? Data(contentsOf: url.appendingPathComponent(anchorLocationFileName, isDirectory: false)),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
              let device = plist["Device"], let mountpoint = plist["Mountpoint"],
              anchorName(device: device, mountpoint: mountpoint) == name
        else {
            return nil
        }
        return (device, mountpoint)
    }

    /// A mounted JottaFS volume.
    public struct MountedVolume: Sendable, Equatable {
        /// The anchor it is mounted from (`""` for the legacy anchor).
        public let anchorName: String
        public let anchorURL: URL
        public let mountPoint: URL

        public init(anchorName: String, anchorURL: URL, mountPoint: URL) {
            self.anchorName = anchorName
            self.anchorURL = anchorURL
            self.mountPoint = mountPoint
        }
    }

    /// The JottaFS volumes in the mount table (cached values only, so it is
    /// safe to call from the extension itself). Nil if the mount table
    /// can't be read.
    public static func mountedVolumes() -> [MountedVolume]? {
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mounts, MNT_NOWAIT)
        guard count > 0, let mounts else {
            return nil
        }
        var volumes: [MountedVolume] = []
        for index in 0..<Int(count) {
            var mount = mounts[index]
            guard cString(&mount.f_fstypename) == fileSystemType else {
                continue
            }
            let source = cString(&mount.f_mntfromname)
            let sourceURL = source.hasPrefix("file://")
                ? URL(string: source)
                : URL(fileURLWithPath: source, isDirectory: true)
            guard let sourceURL, let name = anchorName(ofAnchor: sourceURL) else {
                continue
            }
            volumes.append(MountedVolume(
                anchorName: name,
                anchorURL: sourceURL,
                mountPoint: URL(fileURLWithPath: cString(&mount.f_mntonname), isDirectory: true)
            ))
        }
        return volumes
    }

    /// Where the volume of an anchor is mounted, if it is.
    public static func mountPoint(anchorName name: String) -> URL? {
        mountedVolumes()?.first { $0.anchorName == name }?.mountPoint
    }

    private static func cString<Value>(_ value: inout Value) -> String {
        withUnsafePointer(to: &value) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<Value>.size) {
                String(cString: $0)
            }
        }
    }

    public static func prepareCredentialsDirectory() throws -> URL {
        guard let directory = credentialsDirectoryURL() else {
            throw JottaFSStorageError.applicationGroupUnavailable
        }
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        } catch {
            throw JottaFSStorageError.credentialsDirectoryNotWritable(
                error.localizedDescription
            )
        }
        return directory
    }

    public static func credentialsDirectoryURL() -> URL? {
        guard let groupContainer = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: applicationGroupIdentifier
        ) else {
            return nil
        }
        return groupContainer
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("JottaFS", isDirectory: true)
            .standardizedFileURL
    }

    public static func isCredentialsDirectory(_ url: URL) -> Bool {
        guard let expectedURL = credentialsDirectoryURL() else {
            return false
        }
        return url.isFileURL && url.standardizedFileURL == expectedURL
    }

    public static func credentialsFileURL(in directory: URL) throws -> URL {
        guard isCredentialsDirectory(directory) else {
            throw JottaFSStorageError.invalidCredentialsDirectory
        }
        return directory.appendingPathComponent("credentials.plist")
    }

    /// Removes the saved credentials (signing out).
    public static func deleteCredentials(from directory: URL) throws {
        let url = try credentialsFileURL(in: directory)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public static func loadCredentials(from directory: URL) throws -> JottacloudCredentials {
        let url = try credentialsFileURL(in: directory)
        return try PropertyListDecoder().decode(
            JottacloudCredentials.self,
            from: Data(contentsOf: url)
        )
    }

    /// Replaces the saved credentials (used when signing in). Other changes
    /// go through `updateCredentials`, which keeps concurrent writers from
    /// undoing each other.
    public static func saveCredentials(
        _ credentials: JottacloudCredentials,
        to directory: URL
    ) throws {
        try withCredentialsLock(in: directory) {
            try writeCredentials(credentials, to: directory)
        }
    }

    /// Changes some fields of the saved credentials: read, change and write
    /// under an exclusive lock that the app and the file system extension
    /// share. Each writer changes only its own fields (tokens, location or
    /// profile), so a token rotated by one process is never written back
    /// stale by the other.
    @discardableResult
    public static func updateCredentials(
        in directory: URL,
        _ change: (inout JottacloudCredentials) throws -> Void
    ) throws -> JottacloudCredentials {
        try withCredentialsLock(in: directory) {
            var credentials = try loadCredentials(from: directory)
            try change(&credentials)
            try writeCredentials(credentials, to: directory)
            return credentials
        }
    }

    /// Saves rotated tokens only.
    public static func saveTokens(of credentials: JottacloudCredentials, to directory: URL) throws {
        try updateCredentials(in: directory) { saved in
            saved.accessToken = credentials.accessToken
            saved.refreshToken = credentials.refreshToken
            saved.expiresAt = credentials.expiresAt
        }
    }

    /// An `flock` on `credentials.lock` next to the credentials file.
    private static func withCredentialsLock<T>(in directory: URL, _ body: () throws -> T) throws -> T {
        _ = try credentialsFileURL(in: directory)
        let lockPath = directory.appendingPathComponent("credentials.lock", isDirectory: false).path
        let descriptor = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    /// Writes the file atomically with mode 0600 from the start (a temporary
    /// file created 0600, then renamed over the old one).
    private static func writeCredentials(_ credentials: JottacloudCredentials, to directory: URL) throws {
        let url = try credentialsFileURL(in: directory)
        let data = try encodeCredentials(credentials)
        let temporary = directory.appendingPathComponent(".credentials-\(UUID().uuidString).tmp", isDirectory: false)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard rename(temporary.path, url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    static func encodeCredentials(_ credentials: JottacloudCredentials) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(credentials)
    }
}
