import AppKit
import Darwin
import Foundation
import JottaFSCore

// Mounting support shared by the app's model: the unmount service and the
// mount table.

enum UnmountError: LocalizedError {
    case volumeStillMounted
    case serviceUnavailable
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .volumeStillMounted:
            "Jottacloud is still in use. Close any files or windows from it and try again."
        case .serviceUnavailable:
            "JottaFS could not disconnect Jottacloud. Try again, or restart your Mac."
        case .failed(let message):
            message
        }
    }
}

/// Asks the embedded unsandboxed XPC service to unmount the JottaFS volume.
func requestUnmountFromService() async throws {
    let connection = NSXPCConnection(serviceName: JottaFSUnmountService.serviceName)
    connection.remoteObjectInterface = NSXPCInterface(with: JottaFSUnmountServiceProtocol.self)
    connection.resume()
    defer { connection.invalidate() }

    let failure: String? = try await withCheckedThrowingContinuation { continuation in
        let once = ResumeOnce(continuation)
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            once.resume(with: .failure(error))
        } as? JottaFSUnmountServiceProtocol
        guard let proxy else {
            once.resume(with: .failure(UnmountError.serviceUnavailable))
            return
        }
        proxy.unmountJottaFSVolume { message in
            once.resume(with: .success(message))
        }
    }
    if let failure {
        throw UnmountError.failed(failure)
    }
}

/// XPC may call either the reply or the error handler; resume exactly once.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Error>?

    init(_ continuation: CheckedContinuation<String?, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<String?, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

func findJottacloudMount() throws -> URL? {
    var mounts: UnsafeMutablePointer<statfs>?
    let count = getmntinfo(&mounts, MNT_NOWAIT)
    guard count > 0, let mounts else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    for index in 0..<Int(count) {
        var mount = mounts[index]
        guard stringFromCStringTuple(&mount.f_fstypename) == JottaFSStorage.fileSystemType,
              isJottaFSMountSource(stringFromCStringTuple(&mount.f_mntfromname))
        else {
            continue
        }
        return URL(
            fileURLWithPath: stringFromCStringTuple(&mount.f_mntonname),
            isDirectory: true
        )
    }
    return nil
}

/// The volume is mounted from the mount-anchor directory, reported as a
/// `file://` URL or a plain path.
private func isJottaFSMountSource(_ source: String) -> Bool {
    let path = source.hasPrefix("file://")
        ? URL(string: source)?.path
        : source
    guard let path else {
        return false
    }
    return JottaFSStorage.isMountAnchorDirectory(URL(fileURLWithPath: path, isDirectory: true))
}

private func stringFromCStringTuple<Value>(_ value: inout Value) -> String {
    withUnsafePointer(to: &value) { pointer in
        pointer.withMemoryRebound(
            to: CChar.self,
            capacity: MemoryLayout<Value>.size
        ) {
            String(cString: $0)
        }
    }
}
