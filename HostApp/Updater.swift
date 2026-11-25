import AppKit
import OSLog

/// Checks GitHub for a newer JottaFS release and installs it.
///
/// - At launch and once a day, it reads the latest release of
///   `thomas-alrek/JottaFS`. Network problems, timeouts and unexpected
///   answers are only logged: an update is never urgent.
/// - When the user chooses Update, it downloads the release's DMG into the
///   app's container, asks the unsandboxed helper service to check and
///   install it (`UpdateInstaller`), and relaunches the new version.
/// - Debug builds never check, so development builds are not replaced.
@MainActor
final class Updater: ObservableObject {
    struct Release: Equatable {
        let version: String
        let diskImageURL: URL
        let pageURL: URL?
    }

    enum State: Equatable {
        case idle
        case available(Release)
        case downloading(Release, progress: Double)
        case installing(Release)
        case failed(Release, reason: String)
    }

    @Published private(set) var state: State = .idle

    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/thomas-alrek/JottaFS/releases/latest")!
    private static let checkInterval: TimeInterval = 24 * 60 * 60
    private var checkTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?

    private var installedVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Starts checking (at once, then daily).
    func start() {
        #if DEBUG
        updateLogger.info("Update checks are off in Debug builds.")
        #else
        guard checkTask == nil else {
            return
        }
        // Installing needs JottaFSService, which a fully sandboxed build
        // does not have: no checks then (updates come another way).
        guard JottaFSService.isAvailable else {
            updateLogger.info("Update checks are off: this build has no JottaFSService.")
            return
        }
        checkTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: .seconds(Self.checkInterval))
            }
        }
        #endif
    }

    /// Hides the offer until the next check.
    func dismiss() {
        downloadTask?.cancel()
        state = .idle
    }

    // MARK: Check

    private func check() async {
        switch state {
        case .downloading, .installing:
            return
        default:
            break
        }
        do {
            guard let release = try await latestRelease() else {
                return
            }
            if UpdateVersion.isVersion(release.version, newerThan: installedVersion) {
                updateLogger.info("JottaFS \(release.version, privacy: .public) is available.")
                // Keep an offer the user is already looking at.
                if state == .idle {
                    state = .available(release)
                }
            }
        } catch {
            // Not urgent: try again at the next check.
            updateLogger.info("Update check failed (\((error as NSError).code, privacy: .public)).")
        }
    }

    private func latestRelease() async throws -> Release? {
        var request = URLRequest(url: Self.latestReleaseURL, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("JottaFS/\(installedVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String,
              let assets = object["assets"] as? [[String: Any]]
        else {
            return nil
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let asset = assets.first {
            guard let name = $0["name"] as? String else { return false }
            return name.hasPrefix("JottaFS-") && name.hasSuffix(".dmg")
        }
        guard let address = asset?["browser_download_url"] as? String,
              let url = URL(string: address), Self.isTrustedDownload(url)
        else {
            return nil
        }
        return Release(
            version: version,
            diskImageURL: url,
            pageURL: (object["html_url"] as? String).flatMap(URL.init(string:))
        )
    }

    /// Only GitHub's own HTTPS hosts.
    private static func isTrustedDownload(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else {
            return false
        }
        return host == "github.com" || host.hasSuffix(".githubusercontent.com")
    }

    // MARK: Install

    /// Downloads, installs (through the helper service) and relaunches.
    func install() {
        let release: Release
        switch state {
        case .available(let offered), .failed(let offered, _):
            release = offered
        default:
            return
        }
        state = .downloading(release, progress: 0)
        downloadTask = Task { [weak self] in
            await self?.download(release)
        }
    }

    private func download(_ release: Release) async {
        do {
            let file = try await downloadDiskImage(release)
            guard !Task.isCancelled else {
                return
            }
            state = .installing(release)
            if let failure = try await requestInstall(diskImage: file) {
                state = .failed(release, reason: failure)
                return
            }
            relaunch()
        } catch {
            guard !Task.isCancelled else {
                return
            }
            updateLogger.error("Update download failed (\((error as NSError).code, privacy: .public)).")
            state = .failed(release, reason: "The update couldn’t be downloaded. Check your internet connection and try again.")
        }
    }

    private func downloadDiskImage(_ release: Release) async throws -> URL {
        let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Updates", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let reporter = DownloadProgress { [weak self] fraction in
            Task { @MainActor in
                if case .downloading(let current, _) = self?.state, current == release {
                    self?.state = .downloading(release, progress: fraction)
                }
            }
        }
        let (temporary, response) = try await URLSession.shared.download(
            for: URLRequest(url: release.diskImageURL, timeoutInterval: 60),
            delegate: reporter
        )
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let destination = folder.appendingPathComponent("JottaFS-\(release.version).dmg")
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    private func requestInstall(diskImage: URL) async throws -> String? {
        let connection = NSXPCConnection(serviceName: JottaFSService.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: JottaFSServiceProtocol.self)
        connection.resume()
        defer { connection.invalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            let once = ReplyOnce(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.resume(.failure(error))
            } as? JottaFSServiceProtocol
            guard let proxy else {
                once.resume(.success("The installer couldn’t be started."))
                return
            }
            proxy.installUpdate(diskImagePath: diskImage.path) { failure in
                once.resume(.success(failure))
            }
        }
    }

    /// Opens the newly installed app and quits this one.
    private func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            if let error {
                updateLogger.error("Relaunch failed (\((error as NSError).code, privacy: .public)).")
            }
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }
}

/// Dotted version comparison (1.0.10 is newer than 1.0.9).
enum UpdateVersion {
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
}

/// Reports download progress (0…1).
private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let report: @Sendable (Double) -> Void

    init(report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else {
            return
        }
        report(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

/// XPC may call either the reply or the error handler; resume exactly once.
private final class ReplyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Error>?

    init(_ continuation: CheckedContinuation<String?, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<String?, Error>) {
        let pending = lock.withLock { () -> CheckedContinuation<String?, Error>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(with: result)
    }
}

private let updateLogger = Logger(subsystem: "no.alrek.jottafs", category: "Update")
