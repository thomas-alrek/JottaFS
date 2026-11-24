import Darwin
import Foundation
import Security

// JottaFSProgressAgent: publishes upload progress for files on the mounted
// JottaCloud volume on behalf of the FSKit extension, because Finder ignores
// progress updates published from inside the extension process (updates from
// other processes, sandboxed or not, work). It is itself sandboxed, as
// SMAppService requires for agents of a sandboxed app.
// launchd starts it on demand through its Mach service
// (Contents/Library/LaunchAgents/no.alrek.jottafs.progress.plist). It only
// accepts the JottaFS extension signed by this agent's own team, and only
// publishes progress for paths on the volume; it never touches files.

private let extensionIdentifier = "no.alrek.jottafs.extension"
private let fileSystemType = "jottacloud" // the extension's FSShortName
// Keep in sync with `JottaFSStorage.mountAnchorsDirectoryURL()` (the agent
// deliberately does not link JottaFSCore).
private let mountAnchorsSuffix = "/group.no.alrek.jottafs/JottaCloudMount"

/// Mount point of the JottaFS volume mounted from the anchor `anchorName`
/// (`""`: the legacy anchor, the anchors directory itself), found in the
/// mount table. Volumes are named after their location, so the path is not
/// fixed.
private func jottaCloudMountPoint(anchorName: String) -> URL? {
    guard anchorName.isEmpty || (anchorName.count == 32 && anchorName.allSatisfy({ $0.isHexDigit && !$0.isUppercase })) else {
        return nil
    }
    let expectedSuffix = anchorName.isEmpty ? mountAnchorsSuffix : "\(mountAnchorsSuffix)/\(anchorName)"
    var mounts: UnsafeMutablePointer<statfs>?
    let count = getmntinfo(&mounts, MNT_NOWAIT)
    guard count > 0, let mounts else {
        return nil
    }
    for index in 0..<Int(count) {
        var mount = mounts[index]
        let type = withUnsafeBytes(of: &mount.f_fstypename) {
            String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
        }
        let source = withUnsafeBytes(of: &mount.f_mntfromname) {
            String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
        }
        var sourcePath = source.hasPrefix("file://") ? (URL(string: source)?.path ?? "") : source
        while sourcePath.hasSuffix("/") {
            sourcePath.removeLast()
        }
        guard type == fileSystemType, sourcePath.hasSuffix(expectedSuffix) else {
            continue
        }
        let path = withUnsafeBytes(of: &mount.f_mntonname) {
            String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    return nil
}

/// Published progress objects by upload identifier. All access happens on
/// the main queue, whose run loop relays updates to Finder.
@MainActor
private final class ProgressRegistry {
    static let shared = ProgressRegistry()
    private var uploads: [String: Progress] = [:]

    func begin(identifier: String, anchorName: String, path: String, totalBytes: Int64) {
        end(identifier: identifier)
        guard let components = JottaFSProgressService.safeComponents(of: path) else {
            return
        }
        // No volume in the mount table: nothing to show progress on.
        guard let mountPoint = jottaCloudMountPoint(anchorName: anchorName) else {
            return
        }
        // String-built with an explicit isDirectory: inferring it would lstat
        // the path on the JottaCloud volume while its extension may be busy.
        let fileURL = URL(
            fileURLWithPath: ([mountPoint.path] + components).joined(separator: "/"),
            isDirectory: false
        )
        let progress = Progress(totalUnitCount: max(totalBytes, 1))
        progress.kind = .file
        progress.fileOperationKind = .uploading
        progress.fileURL = fileURL
        progress.isCancellable = false
        progress.isPausable = false
        progress.publish()
        uploads[identifier] = progress
    }

    func update(identifier: String, bytesSent: Int64) {
        guard let progress = uploads[identifier] else {
            return
        }
        progress.completedUnitCount = min(max(bytesSent, 0), progress.totalUnitCount)
    }

    func end(identifier: String) {
        guard let progress = uploads.removeValue(forKey: identifier) else {
            return
        }
        progress.completedUnitCount = progress.totalUnitCount
        progress.unpublish()
    }

    /// Ends every upload of a connection that went away.
    func endAll(_ identifiers: Set<String>) {
        identifiers.forEach { end(identifier: $0) }
    }
}

/// One connection from the extension; remembers its uploads so they are
/// cleaned up if the extension exits mid-upload.
private final class ProgressService: NSObject, JottaFSProgressServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var identifiers: Set<String> = []

    func beginUpload(identifier: String, anchorName: String, path: String, totalBytes: Int64) {
        lock.withLock { _ = identifiers.insert(identifier) }
        DispatchQueue.main.async {
            ProgressRegistry.shared.begin(identifier: identifier, anchorName: anchorName, path: path, totalBytes: totalBytes)
        }
    }

    func updateUpload(identifier: String, bytesSent: Int64) {
        DispatchQueue.main.async {
            ProgressRegistry.shared.update(identifier: identifier, bytesSent: bytesSent)
        }
    }

    func endUpload(identifier: String) {
        lock.withLock { _ = identifiers.remove(identifier) }
        DispatchQueue.main.async {
            ProgressRegistry.shared.end(identifier: identifier)
        }
    }

    func connectionEnded() {
        let pending = lock.withLock { identifiers }
        DispatchQueue.main.async {
            ProgressRegistry.shared.endAll(pending)
        }
    }
}

/// Accept only the JottaFS extension signed by this agent's own team.
private func clientRequirement() -> String {
    var code: SecCode?
    var staticCode: SecStaticCode?
    var information: CFDictionary?
    if SecCodeCopySelf([], &code) == errSecSuccess,
       let code,
       SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
       let staticCode,
       SecCodeCopySigningInformation(
           staticCode,
           SecCSFlags(rawValue: kSecCSSigningInformation),
           &information
       ) == errSecSuccess,
       let team = (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
       !team.isEmpty {
        return #"identifier "\#(extensionIdentifier)" and anchor apple generic and certificate leaf[subject.OU] = "\#(team)""#
    }
    #if DEBUG
    // Ad-hoc development builds have no team.
    return #"identifier "\#(extensionIdentifier)""#
    #else
    // The agent is a Mach service in the user session: never accept an
    // ad-hoc signed client in a release build.
    return #"identifier "\#(extensionIdentifier)" and anchor apple generic"#
    #endif
}

private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let requirement = clientRequirement()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(requirement)
        let service = ProgressService()
        connection.exportedInterface = NSXPCInterface(with: JottaFSProgressServiceProtocol.self)
        connection.exportedObject = service
        connection.invalidationHandler = { service.connectionEnded() }
        connection.interruptionHandler = { service.connectionEnded() }
        connection.resume()
        return true
    }
}

private let delegate = ListenerDelegate()
private let listener = NSXPCListener(machServiceName: JottaFSProgressService.machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
