import CryptoKit
import ExtensionFoundation
import Foundation
import FSKit
import JottaFSCore
import OSLog

final class JottaFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {
    /// The container of a legacy mount (versions before 1.1 had one).
    private static let legacyContainerIdentifier = UUID(
        uuidString: "5A49278E-AF1A-4501-97A1-C1910A984A91"
    )!
    private let logger = Logger.extension("Resource")
    private var activeResourceURL: URL?

    /// A resource this file system mounts: a location's mount anchor (an
    /// empty directory as a path resource, which makes the mount local).
    private static func acceptedResourceURL(_ resource: FSResource) -> URL? {
        if let resource = resource as? FSPathURLResource,
           JottaFSStorage.anchorName(ofAnchor: resource.url) != nil {
            return resource.url
        }
        return nil
    }

    /// The location an anchor mounts: from its `Location.plist`, or for the
    /// legacy anchor, the location saved in the credentials.
    private static func location(
        ofAnchor url: URL,
        credentials: JottacloudCredentials
    ) -> (device: String, mountpoint: String)? {
        if JottaFSStorage.anchorName(ofAnchor: url) == "" {
            return (credentials.device, credentials.mountpoint)
        }
        return JottaFSStorage.location(ofAnchor: url)
    }

    /// One container per location, so FSKit keeps several mounted locations
    /// apart.
    private static func containerIdentifier(anchorName: String) -> FSContainerIdentifier {
        guard !anchorName.isEmpty else {
            return FSContainerIdentifier(uuid: legacyContainerIdentifier)
        }
        var bytes = Array(SHA256.hash(data: Data("no.alrek.jottafs.container:\(anchorName)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return FSContainerIdentifier(uuid: UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )))
    }

    func probeResource(resource: FSResource) async throws -> FSProbeResult {
        guard let resourceURL = Self.acceptedResourceURL(resource),
              let anchorName = JottaFSStorage.anchorName(ofAnchor: resourceURL),
              let credentialsDirectory = JottaFSStorage.credentialsDirectoryURL()
        else {
            logger.info("Probe rejected: resource URL or shared storage is unavailable.")
            return .notRecognized
        }
        guard let credentials = try? JottaFSStorage.loadCredentials(from: credentialsDirectory) else {
            logger.info("Probe rejected: shared credentials are not readable.")
            return .notRecognized
        }
        guard let location = Self.location(ofAnchor: resourceURL, credentials: credentials) else {
            logger.info("Probe rejected: the mount anchor names no location.")
            return .notRecognized
        }
        return .usable(
            name: JottaFSStorage.availableVolumeName(
                JottaFSStorage.volumeName(device: location.device, mountpoint: location.mountpoint)
            ),
            containerID: Self.containerIdentifier(anchorName: anchorName)
        )
    }

    func loadResource(
        resource: FSResource,
        options: FSTaskOptions
    ) async throws -> FSVolume {
        guard let resourceURL = Self.acceptedResourceURL(resource),
              let anchorName = JottaFSStorage.anchorName(ofAnchor: resourceURL),
              let credentialsDirectory = JottaFSStorage.credentialsDirectoryURL()
        else {
            logger.error("Load rejected: resource URL or shared storage is unavailable.")
            throw POSIXError(.ENOENT)
        }
        do {
            let credentials = try JottaFSStorage.loadCredentials(
                from: credentialsDirectory
            )
            guard let location = Self.location(ofAnchor: resourceURL, credentials: credentials) else {
                logger.error("Load rejected: the mount anchor names no location.")
                throw JottacloudError.locationNotFound
            }
            let client = JottacloudClient(
                credentials: credentials,
                persistCredentials: { updated in
                    try JottaFSStorage.saveTokens(of: updated, to: credentialsDirectory)
                },
                loadSavedCredentials: {
                    try? JottaFSStorage.loadCredentials(from: credentialsDirectory)
                },
                // The app signs out and asks the user to sign in again.
                sessionEnded: { JottaFSStorage.markSessionEnded() }
            )
            let account = try await client.listAccount()
            let target = try await mountTarget(
                device: location.device,
                mountpoint: location.mountpoint,
                anchorName: anchorName,
                volumes: account.volumes,
                client: client
            )
            if account.storage.usage == nil {
                logger.info("Account usage unavailable; reporting a minimal volume size.")
            }
            let volume = try JottaFSVolume(
                client: client,
                target: target,
                storage: account.storage,
                accountIdentifier: credentials.username
            )
            activeResourceURL = resourceURL
            containerStatus = .ready
            return volume
        } catch {
            let nsError = error as NSError
            logger.error(
                "Volume setup failed with \(nsError.domain, privacy: .public) code \(nsError.code, privacy: .public)."
            )
            throw error
        }
    }

    /// The location the anchor names, matched case-insensitively like
    /// Jottacloud. For a backup location, its device's service path comes
    /// from `DeviceService.List`.
    private func mountTarget(
        device: String,
        mountpoint: String,
        anchorName: String,
        volumes: [JottacloudRemoteVolume],
        client: JottacloudClient
    ) async throws -> MountTarget {
        guard let volume = volumes.first(where: {
            JottaFSNames.sameName($0.device, device)
                && JottaFSNames.sameName($0.mountpoint, mountpoint)
        }) else {
            logger.error("The chosen Jottacloud location no longer exists.")
            throw JottacloudError.locationNotFound
        }
        var deviceServicePath: String?
        if !volume.isBuiltIn {
            deviceServicePath = try? await client.listBackupDevices().first { JottaFSNames.sameName($0.name, volume.device) }?.path
            if deviceServicePath == nil {
                logger.error("No service path for the backup device; the Trash is unavailable.")
            }
        }
        return MountTarget(
            volume: volume,
            deviceServicePath: deviceServicePath,
            anchorName: anchorName,
            volumeName: JottaFSStorage.availableVolumeName(
                JottaFSStorage.volumeName(device: volume.device, mountpoint: volume.mountpoint)
            )
        )
    }

    func unloadResource(
        resource: FSResource,
        options: FSTaskOptions
    ) async throws {
        guard let resourceURL = Self.acceptedResourceURL(resource),
              resourceURL == activeResourceURL
        else {
            throw POSIXError(.EINVAL)
        }
        activeResourceURL = nil
    }
}

@main
struct JottaFSKitModule: UnaryFileSystemExtension {
    var fileSystem: JottaFileSystem {
        JottaFileSystem()
    }
}

extension Logger {
    /// A logger for the file system extension (subsystem
    /// `no.alrek.jottafs.extension`).
    static func `extension`(_ category: String) -> Logger {
        Logger(subsystem: "no.alrek.jottafs.extension", category: category)
    }
}
