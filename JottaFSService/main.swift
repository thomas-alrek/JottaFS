import DiskArbitration
import Foundation
import Security

// Keep in sync with `JottaFSStorage.mountAnchorsDirectoryURL()` and the
// extension's `FSShortName`. The service deliberately does not link
// JottaFSCore.
private let mountAnchorsSuffix = "/group.no.alrek.jottafs/JottaCloudMount"
private let fileSystemType = "jottacloud"

/// A JottaFS anchor name: 32 lower-case hexadecimal characters, or `""` for
/// the legacy anchor.
private func isValidAnchorName(_ name: String) -> Bool {
    name.isEmpty || (name.count == 32 && name.allSatisfy { $0.isHexDigit && !$0.isUppercase })
}

/// The volume is mounted from the anchor `anchorName` in the app group
/// (reported as a `file://` URL or a plain path).
private func isMountSource(_ source: String, ofAnchor anchorName: String) -> Bool {
    let path = source.hasPrefix("file://") ? (URL(string: source)?.path ?? "") : source
    var trimmed = path
    while trimmed.hasSuffix("/") {
        trimmed.removeLast()
    }
    return trimmed.hasSuffix(anchorName.isEmpty ? mountAnchorsSuffix : "\(mountAnchorsSuffix)/\(anchorName)")
}
private let hostAppIdentifier = "no.alrek.jottafs"

private let busyMessage = String(localized: "Jottacloud is in use. Close any windows or terminals using it and try again.")
private let diskArbitrationQueue = DispatchQueue(label: "no.alrek.jottafs.service.diskarbitration")

final class JottaFSServiceHandler: NSObject, JottaFSServiceProtocol {
    func installUpdate(diskImagePath: String, reply: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            reply(UpdateInstaller.install(diskImagePath: diskImagePath))
        }
    }

    func unmountJottaFSVolume(anchorName: String, reply: @escaping (String?) -> Void) {
        guard isValidAnchorName(anchorName) else {
            reply(String(localized: "Jottacloud could not be unmounted."))
            return
        }
        let mountPoint: URL?
        do {
            mountPoint = try jottaFSMountPoint(anchorName: anchorName)
        } catch {
            reply(String(localized: "Could not read the list of mounted volumes."))
            return
        }
        guard let mountPoint else {
            reply(nil)
            return
        }
        unmount(mountPoint, reply: reply)
    }
}

private struct MountTableUnavailable: Error {}

/// Finds the mount point of an anchor's JottaFS volume; never acts on a
/// caller-supplied path.
private func jottaFSMountPoint(anchorName: String) throws -> URL? {
    var mounts: UnsafeMutablePointer<statfs>?
    let count = getmntinfo(&mounts, MNT_NOWAIT)
    guard count > 0, let mounts else {
        throw MountTableUnavailable()
    }
    for index in 0..<Int(count) {
        var mount = mounts[index]
        guard isMountSource(cString(&mount.f_mntfromname), ofAnchor: anchorName),
              cString(&mount.f_fstypename) == fileSystemType
        else {
            continue
        }
        return URL(fileURLWithPath: cString(&mount.f_mntonname), isDirectory: true)
    }
    return nil
}

private func cString<Value>(_ value: inout Value) -> String {
    withUnsafePointer(to: &value) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<Value>.size) {
            String(cString: $0)
        }
    }
}

private final class PendingUnmount {
    let session: DASession
    let reply: (String?) -> Void

    init(session: DASession, reply: @escaping (String?) -> Void) {
        self.session = session
        self.reply = reply
    }
}

/// fskitd mounts the volume as root, so `unmount(2)` from this user process
/// fails with EPERM. DiskArbitration tracks it as a network volume without a
/// BSD device and unmounts it for an unsandboxed caller.
private func unmount(_ mountPoint: URL, reply: @escaping (String?) -> Void) {
    guard let session = DASessionCreate(kCFAllocatorDefault) else {
        reply(String(localized: "DiskArbitration is unavailable."))
        return
    }
    guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, mountPoint as CFURL) else {
        reply("macOS did not recognize the Jottacloud volume.")
        return
    }
    DASessionSetDispatchQueue(session, diskArbitrationQueue)
    let context = Unmanaged.passRetained(PendingUnmount(session: session, reply: reply)).toOpaque()
    DADiskUnmount(
        disk,
        DADiskUnmountOptions(kDADiskUnmountOptionDefault),
        { _, dissenter, context in
            let pending = Unmanaged<PendingUnmount>.fromOpaque(context!).takeRetainedValue()
            let session = pending.session
            diskArbitrationQueue.async {
                DASessionSetDispatchQueue(session, nil)
            }
            guard let dissenter else {
                pending.reply(nil)
                return
            }
            let status = DADissenterGetStatus(dissenter)
            if status == DAReturn(kDAReturnBusy) {
                pending.reply(busyMessage)
                return
            }
            let reason = (DADissenterGetStatusString(dissenter) as String?)
                ?? String(format: "0x%08x", UInt32(bitPattern: status))
            pending.reply(String(localized: "Jottacloud could not be unmounted (\(reason))."))
        },
        context
    )
}

/// Accept only the JottaFS host app signed by this service's own team.
private func hostAppRequirement() -> String {
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
        return #"identifier "\#(hostAppIdentifier)" and anchor apple generic and certificate leaf[subject.OU] = "\#(team)""#
    }
    #if DEBUG
    // Unsigned/ad-hoc development builds have no team; launchd still limits an
    // embedded XPC service to its containing app.
    return #"identifier "\#(hostAppIdentifier)""#
    #else
    return #"identifier "\#(hostAppIdentifier)" and anchor apple generic"#
    #endif
}

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        // Per-connection rather than `NSXPCListener.setConnectionCodeSigningRequirement`,
        // which crashes (EXC_BAD_ACCESS) on the `NSXPCListener.service()` listener.
        connection.setCodeSigningRequirement(clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: JottaFSServiceProtocol.self)
        connection.exportedObject = JottaFSServiceHandler()
        connection.resume()
        return true
    }
}

private let clientRequirement = hostAppRequirement()
private let delegate = ServiceDelegate()
private let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
