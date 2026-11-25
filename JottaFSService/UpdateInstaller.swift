import Foundation
import Security

/// Installs a downloaded JottaFS update. The app is sandboxed and cannot
/// replace its own bundle, so this unsandboxed service does it, with checks
/// that do not trust the caller:
///
/// - the disk image must be a regular `.dmg` file in the app's own
///   container;
/// - the disk image, and the app inside it, must be signed with Developer ID
///   by the same team as this service, with the app's bundle identifier;
/// - the new version must be newer than the installed one;
/// - the app installed is the one that contains this service (its location
///   is never taken from the request).
///
/// The new app is copied next to the old one and swapped in atomically.
enum UpdateInstaller {
    private static let appIdentifier = "no.alrek.jottafs"
    private static let appName = "JottaFS.app"

    enum Failure: Error {
        case message(String)
    }

    /// Returns nil on success, or a short reason to show to the user.
    static func install(diskImagePath: String) -> String? {
        do {
            try performInstall(diskImagePath: diskImagePath)
            return nil
        } catch Failure.message(let message) {
            return message
        } catch {
            return "The update couldn’t be installed (\((error as NSError).code))."
        }
    }

    private static func performInstall(diskImagePath: String) throws {
        guard let team = ownTeamIdentifier() else {
            throw Failure.message("Updates can only be installed in a signed release build.")
        }
        let installed = try installedAppURL()
        let diskImage = try validatedDiskImage(diskImagePath)
        defer { try? FileManager.default.removeItem(at: diskImage) }

        // The disk image: if it is signed, by our team (releases signed with
        // Xcode's cloud-managed certificate leave it unsigned). The app
        // inside is what must be ours, and is always checked below.
        try checkSignature(
            of: diskImage,
            requirement: #"anchor apple generic and certificate leaf[subject.OU] = "\#(team)""#,
            allowUnsigned: true
        )

        let mountPoint = FileManager.default.temporaryDirectory
            .appendingPathComponent("JottaFS-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mountPoint.path, diskImage.path])
        defer {
            _ = try? run("/usr/bin/hdiutil", ["detach", "-force", mountPoint.path])
            try? FileManager.default.removeItem(at: mountPoint)
        }

        let newApp = mountPoint.appendingPathComponent(appName, isDirectory: true)
        let values = try? newApp.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else {
            throw Failure.message("The update doesn’t contain JottaFS.")
        }
        let appRequirement = #"anchor apple generic and identifier "\#(appIdentifier)" and certificate leaf[subject.OU] = "\#(team)""#
        try checkSignature(of: newApp, requirement: appRequirement)
        guard let newVersion = version(of: newApp), let oldVersion = version(of: installed),
              isVersion(newVersion, newerThan: oldVersion)
        else {
            throw Failure.message("The update isn’t newer than the installed version.")
        }

        // Copy next to the installed app (same volume), drop the download
        // quarantine (the signature was checked above), check again, swap.
        let staging = installed.deletingLastPathComponent()
            .appendingPathComponent(".JottaFS-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(appName, isDirectory: true)
        try run("/usr/bin/ditto", [newApp.path, staged.path])
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        try checkSignature(of: staged, requirement: appRequirement)
        do {
            _ = try FileManager.default.replaceItemAt(installed, withItemAt: staged)
        } catch {
            throw Failure.message("JottaFS couldn’t be replaced. Check that you can change it in the Applications folder.")
        }
    }

    // MARK: Checks

    /// The app bundle containing this service
    /// (JottaFS.app/Contents/XPCServices/<service>.xpc).
    private static func installedAppURL() throws -> URL {
        let app = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard Bundle(url: app)?.bundleIdentifier == appIdentifier else {
            throw Failure.message("JottaFS couldn’t find its own app to update.")
        }
        return app
    }

    /// A regular `.dmg` file in the app's sandbox container.
    private static func validatedDiskImage(_ path: String) throws -> URL {
        let container = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Containers/\(appIdentifier)/Data", isDirectory: true)
            .resolvingSymlinksInPath().path + "/"
        let url = URL(fileURLWithPath: path)
        let resolved = url.resolvingSymlinksInPath()
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard resolved.path.hasPrefix(container),
              resolved.pathExtension.lowercased() == "dmg",
              values?.isRegularFile == true, values?.isSymbolicLink != true
        else {
            throw Failure.message("The downloaded update isn’t valid.")
        }
        return resolved
    }

    private static func checkSignature(of url: URL, requirement text: String, allowUnsigned: Bool = false) throws {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement
        else {
            throw Failure.message("The update’s signature couldn’t be checked.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(code, flags, requirement)
        if status == errSecSuccess || (allowUnsigned && status == errSecCSUnsigned) {
            return
        }
        throw Failure.message("The update isn’t signed by the JottaFS developer.")
    }

    private static func ownTeamIdentifier() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let team = (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty
        else {
            return nil
        }
        return team
    }

    private static func version(of app: URL) -> String? {
        Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// Numeric comparison of dotted versions (1.0.10 is newer than 1.0.9).
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y {
                return x > y
            }
        }
        return false
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.message("The update couldn’t be installed (\(URL(fileURLWithPath: tool).lastPathComponent) failed).")
        }
        return process.terminationStatus
    }
}
