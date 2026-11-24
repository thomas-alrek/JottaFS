import AppKit
import Darwin
import FSKit
import JottaFSCore
import SwiftUI

private enum AppError: Error, LocalizedError {
    case unableToOpenSettings

    var errorDescription: String? {
        switch self {
        case .unableToOpenSettings:
            "Could not open File System Extensions settings."
        }
    }
}

@main
struct JottaFSApp: App {
    var body: some Scene {
        WindowGroup {
            JottaFSView()
        }
    }
}

private struct JottaFSView: View {
    private let extensionBundleID = "no.alrek.jottafs.extension"

    @Environment(\.scenePhase) private var scenePhase
    @State private var credentialsDirectory: URL?
    @State private var loginToken = ""
    @State private var client: JottacloudClient?
    @State private var mountURL: URL?
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var isBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("JottaFS")
                .font(.title)

            Text("Connect again with your Jottacloud login token. Credentials from the previous app group are not migrated; the token is exchanged once and is not saved.")

            if credentialsDirectory != nil {
                SecureField("Jottacloud personal login token", text: $loginToken)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isBusy || client != nil)

                HStack {
                    Button("Connect to Jottacloud") {
                        Task { await connect() }
                    }
                    .disabled(isBusy || client != nil || loginToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Load Saved Account") {
                        Task { await loadSavedAccount() }
                    }
                    .disabled(isBusy || client != nil || !hasSavedCredentials)
                }

            } else if errorMessage == nil {
                ProgressView("Preparing secure Application Support storage…")
            } else {
                Button("Retry Storage Setup", action: prepareStorage)
                    .disabled(isBusy)
            }

            if client != nil {
                Text("Browse all locations under /<device>/<mountpoint>.")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Open Extension Settings", action: openExtensionSettings)
                    .disabled(isBusy)
                if mountURL != nil {
                    Button("Unmount Jottacloud") {
                        Task { await unmount() }
                    }
                    .disabled(isBusy)
                } else {
                    Button("Mount Jottacloud") {
                        Task { await mountAccount() }
                    }
                    .disabled(isBusy || client == nil)
                }
            }

            if let mountURL {
                Text("Mounted at \(mountURL.path)")
                    .textSelection(.enabled)
                HStack {
                    Button("Show in Finder") {
                        showInFinder(mountURL)
                    }
                }
            }

            if isBusy {
                ProgressView()
            }
            if let statusMessage {
                Text(statusMessage)
                    .foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(24)
        .frame(minWidth: 560, alignment: .leading)
        .onAppear {
            prepareStorage()
            refreshMountState()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                refreshMountState()
            }
        }
    }

    private var hasSavedCredentials: Bool {
        guard let credentialsDirectory else {
            return false
        }
        guard let credentialsURL = try? JottaFSStorage.credentialsFileURL(
            in: credentialsDirectory
        ) else {
            return false
        }
        return FileManager.default.fileExists(atPath: credentialsURL.path)
    }

    private func prepareStorage() {
        guard credentialsDirectory == nil else {
            return
        }
        errorMessage = nil
        do {
            let directory = try JottaFSStorage.prepareCredentialsDirectory()
            let credentialsURL = try JottaFSStorage.credentialsFileURL(in: directory)
            credentialsDirectory = directory
            errorMessage = nil
            if FileManager.default.fileExists(atPath: credentialsURL.path) {
                isBusy = true
                Task { await loadSavedAccount() }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func connect() async {
        guard let credentialsDirectory else {
            return
        }
        let token = loginToken.trimmingCharacters(in: .whitespacesAndNewlines)
        loginToken = ""
        isBusy = true
        errorMessage = nil
        statusMessage = nil
        defer { isBusy = false }

        do {
            let connectedClient = try await JottacloudClient.authenticate(
                loginToken: token,
                persistCredentials: persistenceHandler(for: credentialsDirectory)
            )
            try JottaFSStorage.saveCredentials(
                await connectedClient.currentCredentials(),
                to: credentialsDirectory
            )
            client = connectedClient
            statusMessage = "Account ready. Mount to browse all devices and mountpoints."
        } catch {
            client = nil
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func loadSavedAccount() async {
        guard let credentialsDirectory else {
            return
        }
        isBusy = true
        errorMessage = nil
        statusMessage = nil
        defer { isBusy = false }

        do {
            let credentials = try JottaFSStorage.loadCredentials(
                from: credentialsDirectory
            )
            let savedClient = JottacloudClient(
                credentials: credentials,
                persistCredentials: persistenceHandler(for: credentialsDirectory)
            )
            client = savedClient
            statusMessage = "Saved account ready. Mount to browse all devices and mountpoints."
        } catch {
            client = nil
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func mountAccount() async {
        guard client != nil else {
            errorMessage = "Load or connect a Jottacloud account before mounting."
            return
        }
        isBusy = true
        errorMessage = nil
        statusMessage = nil
        defer { isBusy = false }

        do {
            if let mountedURL = try findJottacloudMount() {
                mountURL = mountedURL
                statusMessage = "Jottacloud is already mounted."
                return
            }
            // A path resource makes the mount local, which Finder needs to
            // list the volume in its sidebar; a generic URL mount is treated
            // as a server volume without a server.
            let resource = FSPathURLResource(
                url: try JottaFSStorage.prepareMountAnchorDirectory(),
                writable: false
            )
            mountURL = try await FSClient.shared.mountSingleVolume(
                resource: resource,
                bundleID: extensionBundleID,
                options: []
            )
            statusMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshMountState() {
        do {
            let mountedURL = try findJottacloudMount()
            mountURL = mountedURL
            if mountedURL != nil {
                statusMessage = "Jottacloud is already mounted."
            } else if statusMessage == "Jottacloud is already mounted." {
                statusMessage = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func openExtensionSettings() {
        guard FSClient.shared.openFileSystemExtensionsSettings() else {
            errorMessage = AppError.unableToOpenSettings.localizedDescription
            return
        }
        errorMessage = nil
    }

    private func showInFinder(_ url: URL) {
        let path = appleScriptString(url.path)
        let source = """
        tell application id "com.apple.finder" to launch
        tell application id "com.apple.finder"
            open POSIX file "\(path)"
            activate
        end tell
        """

        do {
            try runFinderScript(source)
            errorMessage = nil
            statusMessage = "Finder opened the mounted volume."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The FSKit mount is owned by root (fskitd performs it), so `unmount(2)`
    /// fails with EPERM, and DiskArbitration (which tracks it as a network
    /// volume) refuses sandboxed callers with `kDAReturnNotPermitted`.
    /// `FileManager.unmountVolume` also fails under the sandbox (Foundation
    /// error 769). The unsandboxed embedded `JottaFSUnmountService` performs
    /// the DiskArbitration unmount; the mount table decides the outcome.
    @MainActor
    private func unmount() async {
        guard mountURL != nil else {
            return
        }
        isBusy = true
        errorMessage = nil
        statusMessage = nil
        defer { isBusy = false }

        var unmountError: Error?
        do {
            try await requestUnmountFromService()
        } catch {
            unmountError = error
        }

        do {
            if let stillMounted = try findJottacloudMount() {
                self.mountURL = stillMounted
                errorMessage = (unmountError ?? UnmountError.volumeStillMounted)
                    .localizedDescription
                return
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        self.mountURL = nil
        statusMessage = "Volume unmounted."
    }
}

private enum UnmountError: LocalizedError {
    case volumeStillMounted
    case serviceUnavailable
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .volumeStillMounted:
            "Jottacloud is still mounted. Close any windows or terminals using it and try again."
        case .serviceUnavailable:
            "The JottaFS unmount service is unavailable."
        case .failed(let message):
            message
        }
    }
}

/// Asks the embedded unsandboxed XPC service to unmount the JottaFS volume.
private func requestUnmountFromService() async throws {
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

private enum FinderAutomationError: LocalizedError {
    case couldNotCreateScript
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .couldNotCreateScript:
            "Could not create the Finder automation request."
        case .rejected(let reason):
            "Finder automation failed: \(reason)"
        }
    }
}

private func runFinderScript(_ source: String) throws {
    guard let script = NSAppleScript(source: source) else {
        throw FinderAutomationError.couldNotCreateScript
    }

    var errorInfo: NSDictionary?
    _ = script.executeAndReturnError(&errorInfo)
    if let errorInfo {
        let reason = errorInfo[NSAppleScript.errorMessage] as? String
            ?? "Finder rejected the request."
        throw FinderAutomationError.rejected(reason)
    }
}

private func appleScriptString(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

private func findJottacloudMount() throws -> URL? {
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

/// The volume is mounted either from the generic `jottafs://mount` URL or from
/// the mount-anchor directory (shown as a `file://` URL or a plain path).
private func isJottaFSMountSource(_ source: String) -> Bool {
    if source == JottaFSStorage.filesystemResourceURL.absoluteString {
        return true
    }
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

private func persistenceHandler(
    for directory: URL
) -> @Sendable (JottacloudCredentials) async throws -> Void {
    { credentials in
        try JottaFSStorage.saveCredentials(credentials, to: directory)
    }
}
