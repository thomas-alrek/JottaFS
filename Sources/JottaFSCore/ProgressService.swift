import Foundation

/// XPC interface of `JottaFSProgressAgent`, an unsandboxed launch agent that
/// publishes upload progress for files on the mounted volume.
///
/// Finder shows a published `NSProgress` as a progress bar on a file's icon.
/// Progress published by the sandboxed FSKit extension appears but never
/// advances (verified 2026-11-24: identical updates from an unsandboxed
/// process do advance), so the extension forwards its progress here.
///
/// This file is compiled into both `JottaFSCore` (used by the extension) and
/// the agent target, so both sides share one definition.
@objc(JottaFSProgressServiceProtocol)
public protocol JottaFSProgressServiceProtocol {
    /// Starts showing upload progress for `path`, relative to the volume root
    /// (for example `Jotta/Archive/JottaFS-Test/a.bin`).
    func beginUpload(identifier: String, path: String, totalBytes: Int64)
    func updateUpload(identifier: String, bytesSent: Int64)
    func endUpload(identifier: String)
}

public enum JottaFSProgressService {
    /// launchd Mach service name; must match the agent's launchd plist and
    /// the extension's `mach-lookup` sandbox exception.
    public static let machServiceName = "no.alrek.jottafs.progress"
    /// The launchd plist in `Contents/Library/LaunchAgents` of the app.
    public static let launchAgentPlistName = "no.alrek.jottafs.progress.plist"

    /// Splits a volume-relative path, rejecting anything that could leave the
    /// volume (absolute paths, empty, `.` or `..` components).
    public static func safeComponents(of path: String) -> [String]? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") })
        else {
            return nil
        }
        return parts
    }
}
