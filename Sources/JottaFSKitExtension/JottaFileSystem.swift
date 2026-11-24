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

    /// The resources this file system mounts: the original generic
    /// `jottafs://mount` URL, or the empty mount-anchor directory as a path
    /// resource (which makes the mount local). Returns its URL, or nil.
    private static func acceptedResourceURL(_ resource: FSResource) -> URL? {
        if let resource = resource as? FSGenericURLResource,
           resource.url == JottaFSStorage.filesystemResourceURL {
            return resource.url
        }
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
        guard FileManager.default.isReadableFile(atPath: credentialsURL.path) else {
            logger.info("Probe rejected: shared credentials are not readable.")
            return .notRecognized
        }
        return .usable(
            name: JottaFSStorage.volumeName,
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
            let client = JottacloudClient(credentials: credentials) { updated in
                try JottaFSStorage.saveCredentials(
                    updated,
                    to: credentialsDirectory
                )
            }
            let account = try await client.listAccount()
            guard !account.volumes.isEmpty else {
                throw JottacloudError.noRemoteVolumes
            }
            if account.storage.usage == nil {
                logger.info("Account usage unavailable; reporting a minimal volume size.")
            }
            let volume = try JottaFSVolume(
                client: client,
                remoteVolumes: account.volumes,
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
