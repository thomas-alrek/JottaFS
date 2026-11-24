import Foundation

/// XPC interface of `JottaFSUnmountService`, the unsandboxed XPC service
/// embedded in the host app, for the two things the sandboxed app cannot do
/// itself: unmounting (DiskArbitration refuses sandboxed callers with
/// `kDAReturnNotPermitted`) and replacing its own bundle with an update.
/// The service takes no unmount path (it finds the JottaFS volume in the
/// mount table itself) and checks every update before installing it.
@objc(JottaFSUnmountServiceProtocol)
protocol JottaFSUnmountServiceProtocol {
    /// Replies with `nil` when the JottaFS volume is unmounted (or was not
    /// mounted), otherwise with a user-facing failure description.
    func unmountJottaFSVolume(reply: @escaping (String?) -> Void)

    /// Installs the update in the downloaded disk image at `diskImagePath`
    /// (in the app's container) over the running app. Replies with `nil` on
    /// success, otherwise with a user-facing reason.
    func installUpdate(diskImagePath: String, reply: @escaping (String?) -> Void)
}

enum JottaFSUnmountService {
    /// Must match the service's `PRODUCT_BUNDLE_IDENTIFIER`.
    static let serviceName = "no.alrek.jottafs.unmount"
}
