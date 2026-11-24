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
    public static let filesystemResourceURL = URL(string: "jottafs://mount")!
    /// Volume name reported to FSKit; the system mounts at `/Volumes/<name>`.
    public static let volumeName = "JottaCloud"
    /// File system type (the extension's `FSShortName`).
    public static let fileSystemType = "jottacloud"

    /// Empty directory used as the `FSPathURLResource` the volume is mounted
    /// from. A path resource makes the mount local (like Xcode's DeviceFS),
    /// which a generic `jottafs://` resource does not, and Finder lists only
    /// local or NetFS-backed volumes in its sidebar. It holds no data and is
    /// deliberately not the credentials directory.
    public static func mountAnchorDirectoryURL() -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: applicationGroupIdentifier
        )?
        .appendingPathComponent("JottaCloudMount", isDirectory: true)
        .standardizedFileURL
    }

    public static func prepareMountAnchorDirectory() throws -> URL {
        guard let directory = mountAnchorDirectoryURL() else {
            throw JottaFSStorageError.applicationGroupUnavailable
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    public static func isMountAnchorDirectory(_ url: URL) -> Bool {
        guard let expected = mountAnchorDirectoryURL() else {
            return false
        }
        return url.isFileURL
            && url.standardizedFileURL.resolvingSymlinksInPath().path
                == expected.resolvingSymlinksInPath().path
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

    public static func loadCredentials(from directory: URL) throws -> JottacloudCredentials {
        let url = try credentialsFileURL(in: directory)
        return try PropertyListDecoder().decode(
            JottacloudCredentials.self,
            from: Data(contentsOf: url)
        )
    }

    public static func saveCredentials(
        _ credentials: JottacloudCredentials,
        to directory: URL
    ) throws {
        let url = try credentialsFileURL(in: directory)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(credentials).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    public static func encodeCredentials(_ credentials: JottacloudCredentials) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(credentials)
    }
}
