import Foundation

/// XPC interface of `JottaFSService`, the unsandboxed XPC service
/// embedded in the host app, for the two things the sandboxed app cannot do
/// itself: unmounting (DiskArbitration refuses sandboxed callers with
/// `kDAReturnNotPermitted`) and replacing its own bundle with an update.
/// The service takes no unmount path (it finds the JottaFS volume of a
/// mount anchor in the mount table itself) and checks every update before
/// installing it.
@objc(JottaFSServiceProtocol)
protocol JottaFSServiceProtocol {
    /// Unmounts the JottaFS volume mounted from the anchor `anchorName` (see
    /// `JottaFSStorage.anchorName`; `""` is the legacy anchor). Replies with
    /// `nil` when it is unmounted (or was not mounted), otherwise with a
    /// user-facing failure description.
    func unmountJottaFSVolume(anchorName: String, reply: @escaping (String?) -> Void)

    /// Installs the update in the downloaded disk image at `diskImagePath`
    /// (in the app's container) over the running app. Replies with `nil` on
    /// success, otherwise with a user-facing reason.
    func installUpdate(diskImagePath: String, reply: @escaping (String?) -> Void)
}

enum JottaFSService {
    /// Must match the service's `PRODUCT_BUNDLE_IDENTIFIER`.
    static let serviceName = "no.alrek.jottafs.service"

    /// Whether the service is part of this app. A fully sandboxed build
    /// (build setting `JOTTAFS_SANDBOXED=YES`) leaves it out; then the app
    /// does not update itself and cannot unmount (the user ejects in Finder).
    static var isAvailable: Bool {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/XPCServices/JottaFSService.xpc", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path)
    }
}
