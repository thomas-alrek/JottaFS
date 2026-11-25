import AppKit
import Foundation
import JottaFSCore

// Mounting support for the app's model: unmounting through JottaFSService. The mount
// table is read with `JottaFSStorage.mountedVolumes()`.

enum UnmountError: LocalizedError {
    case volumeStillMounted
    /// This build cannot unmount (no JottaFSService).
    case ejectInFinder
    case serviceUnavailable
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .ejectInFinder:
            "Eject your Jottacloud disks in Finder first, then try again."
        case .volumeStillMounted:
            "Jottacloud is still in use. Close any files or windows from it and try again."
        case .serviceUnavailable:
            "JottaFS could not disconnect Jottacloud. Try again, or restart your Mac."
        case .failed(let message):
            message
        }
    }
}

/// Asks the embedded unsandboxed XPC service to unmount the JottaFS volume
/// mounted from the anchor `anchorName`.
func requestUnmountFromService(anchorName: String) async throws {
    let connection = NSXPCConnection(serviceName: JottaFSService.serviceName)
    connection.remoteObjectInterface = NSXPCInterface(with: JottaFSServiceProtocol.self)
    connection.resume()
    defer { connection.invalidate() }

    let failure: String? = try await withCheckedThrowingContinuation { continuation in
        let once = ResumeOnce(continuation)
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            once.resume(with: .failure(error))
        } as? JottaFSServiceProtocol
        guard let proxy else {
            once.resume(with: .failure(UnmountError.serviceUnavailable))
            return
        }
        proxy.unmountJottaFSVolume(anchorName: anchorName) { message in
            once.resume(with: .success(message))
        }
        // A hung service must not leave the app on "Unmounting…" forever.
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
            once.resume(with: .failure(UnmountError.serviceUnavailable))
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
