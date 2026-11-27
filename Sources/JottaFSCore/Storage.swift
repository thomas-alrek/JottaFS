import CryptoKit
import Foundation
import notify

public enum JottaFSStorageError: Error, LocalizedError {
    case applicationGroupUnavailable
    case credentialsDirectoryNotWritable(String)
    case invalidCredentialsDirectory

    public var errorDescription: String? {
        switch self {
        case .applicationGroupUnavailable:
            String(localized: "Could not access Jottacloud's shared Application Support folder.", bundle: .jottaFSCore)
        case .credentialsDirectoryNotWritable(let reason):
            String(localized: "Could not create Jottacloud's shared Application Support folder. Ensure App Group \(JottaFSStorage.applicationGroupIdentifier) is registered and included in the provisioning profiles for both the app and FSKit extension. Details: \(reason)", bundle: .jottaFSCore)
        case .invalidCredentialsDirectory:
            String(localized: "The filesystem resource is not Jottacloud's shared credentials folder.", bundle: .jottaFSCore)
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
        return defaultVolumeName(device: device, mountpoint: mountpoint)
    }

    /// The name a location gets in Finder when the user has not chosen one:
    /// for the built-in Jottacloud locations, the name in the user's
    /// language that the app saved ("Arkiv" for "Archive"); otherwise the
    /// location's own name.
    public static func defaultVolumeName(device: String, mountpoint: String) -> String {
        if device == JottacloudRemoteVolume.builtInDevice,
           let names = loadSettings()[builtInLocationNamesKey] as? [String: String],
           let name = names[mountpoint.lowercased()].flatMap(validVolumeName) {
            return name
        }
        return defaultVolumeName(mountpoint: mountpoint)
    }

    /// `name`, or "name (2)", "name (3)" … if a mounted volume (of any kind)
    /// already uses it, so two mounted locations with the same name (such as
    /// "Desktop" from two computer backups) can be told apart in Finder. The
    /// result is not saved: the next mount checks again, and a name the user
    /// sets in the app still wins.
    public static func availableVolumeName(_ name: String) -> String {
        let taken = mountedVolumeNames()
        guard taken.contains(name.lowercased()) else {
            return name
        }
        for number in 2...999 {
            let suffix = " (\(number))"
            var base = name
            // A mount point name has at most 255 bytes.
            while base.utf8.count + suffix.utf8.count > 255 {
                base.removeLast()
            }
            let candidate = base + suffix
            if !taken.contains(candidate.lowercased()) {
                return candidate
            }
        }
        return name
    }

    /// Lower-cased names of the volumes mounted under `/Volumes`.
    private static func mountedVolumeNames() -> Set<String> {
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mounts, MNT_NOWAIT)
        guard count > 0, let mounts else {
            return []
        }
        var names: Set<String> = []
        for index in 0..<Int(count) {
            var mount = mounts[index]
            let path = cString(&mount.f_mntonname)
            if path.hasPrefix("/Volumes/") {
                names.insert((path as NSString).lastPathComponent.lowercased())
            }
        }
        return names
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
        try saveSettings(settings, to: directory)
    }

    // MARK: Built-in location names (Settings.plist, shared with the extension)

    static let builtInLocationNamesKey = "BuiltInLocationNames"

    /// Saves the names of the built-in Jottacloud locations in the app's
    /// language, by lower-cased mountpoint ("archive": "Arkiv"). The app
    /// translates them; the extension names the disks with them, so a disk
    /// gets the same name as in the app's list. Writes only when they change.
    public static func setBuiltInLocationNames(_ names: [String: String]) throws {
        guard let directory = credentialsDirectoryURL() else {
            throw JottaFSStorageError.applicationGroupUnavailable
        }
        var settings = loadSettings()
        guard settings[builtInLocationNamesKey] as? [String: String] != names else {
            return
        }
        settings[builtInLocationNamesKey] = names
        try saveSettings(settings, to: directory)
    }

    // MARK: Download cache size (Settings.plist, shared with the extension)

    static let blockCacheLimitKey = "BlockCacheLimitMB"
    /// The default size of the download cache: 1024 MB.
    public static let defaultBlockCacheLimitMB = 1024

    /// The most the extension keeps of downloaded file data on disk, in MB
    /// (1 MB = 1 048 576 bytes); 0 turns the cache off.
    public static func blockCacheLimitMB() -> Int {
        guard let value = loadSettings()[blockCacheLimitKey] as? Int, value >= 0 else {
            return defaultBlockCacheLimitMB
        }
        return value
    }

    public static func setBlockCacheLimitMB(_ megabytes: Int) throws {
        guard let directory = credentialsDirectoryURL() else {
            throw JottaFSStorageError.applicationGroupUnavailable
        }
        var settings = loadSettings()
        settings[blockCacheLimitKey] = max(0, megabytes)
        try saveSettings(settings, to: directory)
    }

    /// The download cache: `<app group>/Library/Caches/BlockCache`, with one
    /// folder per mounted location, shared by the extension (which fills it)
    /// and the app (which shows its size and can clear it).
    public static func blockCacheDirectoryURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: applicationGroupIdentifier)?
            .appendingPathComponent("Library/Caches/BlockCache", isDirectory: true)
            .standardizedFileURL
    }

    /// Bytes of downloaded data in the cache (all locations' folders).
    public static func blockCacheSize() -> UInt64 {
        guard let directory = blockCacheDirectoryURL(),
              let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])?.allObjects as? [URL]
        else {
            return 0
        }
        return files.reduce(0) { total, url in
            // Only data blocks (`<md5>-<index>`); not the boot marker, files
            // being written (`.<uuid>.tmp`) or Finder's `.DS_Store`.
            guard !url.lastPathComponent.hasPrefix("."),
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true
            else {
                return total
            }
            return total + UInt64(values.fileSize ?? 0)
        }
    }

    /// Deletes all cached downloads (files that are being read are downloaded
    /// again as needed).
    public static func clearBlockCache() throws {
        guard let directory = blockCacheDirectoryURL() else {
            throw JottaFSStorageError.applicationGroupUnavailable
        }
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return
        }
        try FileManager.default.removeItem(at: directory)
    }

    private static func saveSettings(_ settings: [String: Any], to directory: URL) throws {
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

    // MARK: Serving extensions

    /// Which file system extension serves a mounted location. The extension
    /// records itself when it loads a mount anchor and removes the record
    /// when it unloads it; the app compares the record with its own
    /// extension. A disk that stays mounted across an update keeps the
    /// extension process that mounted it, so it runs the old version until
    /// it is mounted again (found 2026-11-27).
    public struct ServingExtension: Codable, Equatable, Sendable {
        /// The extension bundle's path.
        public let path: String
        /// Its `CFBundleShortVersionString`.
        public let version: String

        public init(path: String, version: String) {
            self.path = path
            self.version = version
        }
    }

    /// `<app group>/ServingExtensions`, one property list per anchor.
    public static func servingExtensionsDirectoryURL() -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: applicationGroupIdentifier
        )?
        .appendingPathComponent("ServingExtensions", isDirectory: true)
        .standardizedFileURL
    }

    private static func servingExtensionURL(anchorName: String, in directory: URL?) -> URL? {
        guard isValidAnchorName(anchorName) else {
            return nil
        }
        return directory?.appendingPathComponent((anchorName.isEmpty ? "legacy" : anchorName) + ".plist", isDirectory: false)
    }

    /// Records the extension serving the anchor `anchorName` (the extension
    /// itself, when it loads the anchor).
    public static func recordServingExtension(
        _ record: ServingExtension,
        anchorName: String,
        directory: URL? = servingExtensionsDirectoryURL()
    ) throws {
        guard let directory, let url = servingExtensionURL(anchorName: anchorName, in: directory) else {
            throw JottaFSStorageError.applicationGroupUnavailable
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try PropertyListEncoder().encode(record)
        try data.write(to: url, options: .atomic)
    }

    /// The extension recorded for `anchorName`; nil if none recorded one
    /// (an extension older than 1.4.2, or not mounted).
    public static func servingExtension(
        anchorName: String,
        directory: URL? = servingExtensionsDirectoryURL()
    ) -> ServingExtension? {
        guard let url = servingExtensionURL(anchorName: anchorName, in: directory),
              let data = try? Data(contentsOf: url)
        else {
            return nil
        }
        return try? PropertyListDecoder().decode(ServingExtension.self, from: data)
    }

    /// Removes the record (the extension, when it unloads the anchor).
    public static func removeServingExtension(
        anchorName: String,
        directory: URL? = servingExtensionsDirectoryURL()
    ) {
        if let url = servingExtensionURL(anchorName: anchorName, in: directory) {
            try? FileManager.default.removeItem(at: url)
        }
    }

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

    /// Removes the saved credentials (signing out), and the mark that the
    /// sign-in has ended.
    public static func deleteCredentials(from directory: URL) throws {
        let url = try credentialsFileURL(in: directory)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        clearSessionEnded(in: directory)
    }

    // MARK: Ended sign-in (shared by the app and the extensions)

    static let sessionEndedFileName = "SessionEnded"
    /// Darwin notification posted when a process finds that the sign-in has
    /// ended; the app signs out and asks the user to sign in again.
    public static let sessionEndedNotification = "no.alrek.jottafs.session-ended"

    /// Marks the sign-in as ended (Jottacloud refused the refresh token)
    /// and tells the app. Any process can find this first: the app, the
    /// file system extension or the Finder extension.
    public static func markSessionEnded() {
        guard let directory = credentialsDirectoryURL() else {
            return
        }
        FileManager.default.createFile(
            atPath: directory.appendingPathComponent(sessionEndedFileName).path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        )
        notify_post(sessionEndedNotification)
    }

    /// Whether a process found that the sign-in has ended.
    public static func sessionHasEnded(in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(sessionEndedFileName).path)
    }

    static func clearSessionEnded(in directory: URL) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(sessionEndedFileName))
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
        // A new sign-in.
        clearSessionEnded(in: directory)
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
