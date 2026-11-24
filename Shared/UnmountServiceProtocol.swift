import Foundation

/// XPC interface of `JottaFSUnmountService`, the unsandboxed XPC service
/// embedded in the host app. DiskArbitration refuses unmount requests from
/// sandboxed callers (`kDAReturnNotPermitted`), so the sandboxed app delegates
/// this one operation. The service takes no path: it only ever unmounts the
/// JottaFS volume it finds in the mount table itself.
@objc(JottaFSUnmountServiceProtocol)
protocol JottaFSUnmountServiceProtocol {
    /// Replies with `nil` when the JottaFS volume is unmounted (or was not
    /// mounted), otherwise with a user-facing failure description.
    func unmountJottaFSVolume(reply: @escaping (String?) -> Void)
}

enum JottaFSUnmountService {
    /// Must match the service's `PRODUCT_BUNDLE_IDENTIFIER`.
    static let serviceName = "no.alrek.jottafs.unmount"
}
