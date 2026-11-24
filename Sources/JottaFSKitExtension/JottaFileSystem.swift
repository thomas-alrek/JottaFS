import ExtensionFoundation
import Foundation
import FSKit
import JottaFSCore
import OSLog

final class JottaFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {
    private static let containerIdentifier = UUID(
        uuidString: "5A49278E-AF1A-4501-97A1-C1910A984A91"
    )!
    private let logger = Logger(
        subsystem: "no.alrek.jottafs.extension",
        category: "Resource"
    )
    private var activeResourceURL: URL?

    /// The only resource this file system mounts: the empty mount-anchor
    /// directory as a path resource (which makes the mount local). Returns its
    /// URL, or nil.
    private static func acceptedResourceURL(_ resource: FSResource) -> URL? {
        if let resource = resource as? FSPathURLResource,
           JottaFSStorage.isMountAnchorDirectory(resource.url) {
            return resource.url
        }
        return nil
    }

    func probeResource(resource: FSResource) async throws -> FSProbeResult {
        guard Self.acceptedResourceURL(resource) != nil,
              let credentialsDirectory = JottaFSStorage.credentialsDirectoryURL(),
              let credentialsURL = try? JottaFSStorage.credentialsFileURL(
                in: credentialsDirectory
              )
        else {
            logger.info("Probe rejected: resource URL or shared storage is unavailable.")
            return .notRecognized
        }
        guard let credentials = try? JottaFSStorage.loadCredentials(from: credentialsDirectory) else {
            logger.info("Probe rejected: shared credentials are not readable.")
            return .notRecognized
        }
        return .usable(
            name: JottaFSStorage.volumeName(device: credentials.device, mountpoint: credentials.mountpoint),
            containerID: FSContainerIdentifier(uuid: Self.containerIdentifier)
        )
    }

    func loadResource(
        resource: FSResource,
        options: FSTaskOptions
    ) async throws -> FSVolume {
        guard let resourceURL = Self.acceptedResourceURL(resource),
              let credentialsDirectory = JottaFSStorage.credentialsDirectoryURL()
        else {
            logger.error("Load rejected: resource URL or shared storage is unavailable.")
            throw POSIXError(.ENOENT)
        }
        do {
            let credentials = try JottaFSStorage.loadCredentials(
                from: credentialsDirectory
            )
            let client = JottacloudClient(
                credentials: credentials,
                persistCredentials: { updated in
                    try JottaFSStorage.saveCredentials(updated, to: credentialsDirectory)
                },
                loadSavedCredentials: {
                    try? JottaFSStorage.loadCredentials(from: credentialsDirectory)
                }
            )
            let account = try await client.listAccount()
            let target = try await mountTarget(credentials: credentials, volumes: account.volumes, client: client)
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

    /// The location chosen in the app (saved with the credentials), matched
    /// case-insensitively like Jottacloud. For a backup location, its
    /// device's service path comes from `DeviceService.List`.
    private func mountTarget(
        credentials: JottacloudCredentials,
        volumes: [JottacloudRemoteVolume],
        client: JottacloudClient
    ) async throws -> MountTarget {
        guard let volume = volumes.first(where: {
            JottaFSNames.sameName($0.device, credentials.device)
                && JottaFSNames.sameName($0.mountpoint, credentials.mountpoint)
        }) else {
            logger.error("The chosen Jottacloud location no longer exists.")
            throw JottacloudError.noRemoteVolumes
        }
        var deviceServicePath: String?
        if volume.device != "Jotta" {
            deviceServicePath = try? await client.listBackupDevices().first { JottaFSNames.sameName($0.name, volume.device) }?.path
            if deviceServicePath == nil {
                logger.error("No service path for the backup device; the Trash is unavailable.")
            }
        }
        return MountTarget(volume: volume, deviceServicePath: deviceServicePath)
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
