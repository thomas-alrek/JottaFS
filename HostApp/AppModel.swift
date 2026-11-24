import AppKit
import AuthenticationServices
import OSLog
import FSKit
import JottaFSCore
import ServiceManagement
import SwiftUI

/// The app's state and actions: signing in (browser or personal login
/// token), choosing the Jottacloud location to show in Finder, mounting,
/// disconnecting and opening at login. Views only read this and call it.
@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case starting
        case signedOut
        case waitingForBrowser
        case finishingSignIn
        case signedIn
    }

    enum Activity: Equatable {
        case mounting
        case unmounting
    }

    static let extensionBundleID = "no.alrek.jottafs.extension"
    private static let mountAtLoginKey = "MountAtLogin"

    @Published private(set) var phase: Phase = .starting
    @Published private(set) var username = ""
    @Published private(set) var accountName: String?
    @Published private(set) var accountEmail: String?
    @Published private(set) var locations: [JottacloudRemoteVolume] = []
    @Published private(set) var isLoadingLocations = false
    @Published var selectedLocationID: String?
    @Published private(set) var mountURL: URL?
    @Published private(set) var mountedLocationID: String?
    /// What the app is doing right now (shown in the main button).
    @Published private(set) var activity: Activity?
    /// The error to show in an alert.
    @Published var alert: AppAlert?
    /// nil while unknown.
    @Published private(set) var extensionEnabled: Bool?
    @Published private(set) var progressAgentNeedsApproval = false
    @Published private(set) var mountAtLogin = false
    @Published private(set) var loginItemNeedsApproval = false

    /// Set by the app delegate when macOS opened the app at login.
    var launchedAtLogin = false
    /// Creates and shows the window (it does not exist after a launch at
    /// login); set by the app delegate.
    var showWindow: (() -> Void)?

    private var credentialsDirectory: URL?
    private var client: JottacloudClient?
    private var callbackServer: LoopbackCallbackServer?
    private var signInTask: Task<Void, Never>?
    private var authSession: ASWebAuthenticationSession?
    private var extensionWatch: Task<Void, Never>?
    /// The user went to System Settings from the app's notice; bring the
    /// app back once the extension is turned on.
    private var openedExtensionSettings = false
    private var volumeObservers: [NSObjectProtocol] = []

    var selectedLocation: JottacloudRemoteVolume? {
        locations.first { $0.id == selectedLocationID }
    }

    var mountedLocation: JottacloudRemoteVolume? {
        locations.first { $0.id == mountedLocationID }
    }

    var isBusy: Bool {
        activity != nil
    }

    // MARK: Start

    func start() async {
        guard phase == .starting else {
            return
        }
        mountAtLogin = UserDefaults.standard.bool(forKey: Self.mountAtLoginKey)
        observeVolumeChanges()
        do {
            credentialsDirectory = try JottaFSStorage.prepareCredentialsDirectory()
        } catch {
            phase = .signedOut
            alert = AppAlert(title: "JottaFS couldn’t prepare its storage.", message: "Reinstall the app and try again.")
            return
        }
        await refreshSystemState()
        guard let saved = loadSavedCredentials() else {
            phase = .signedOut
            if launchedAtLogin {
                NSApp.terminate(nil)
            }
            return
        }
        useClient(makeClient(saved), credentials: saved)
        if launchedAtLogin {
            await mountAtLoginLaunch()
            return
        }
        await loadLocations()
    }

    /// Called when the app becomes active (the user may have changed System
    /// Settings or ejected the volume in Finder).
    func refreshSystemState() async {
        refreshMountState()
        refreshLoginItemStatus()
        registerProgressAgent()
        await refreshExtensionState()
    }

    /// Reads whether JottaFS is turned on in System Settings. While it is
    /// off, keeps checking every two seconds (FSKit sends no notification),
    /// so the app updates as soon as the user turns it on.
    private func refreshExtensionState() async {
        guard let extensions = try? await FSClient.shared.installedExtensions else {
            return
        }
        let enabled = extensions.first { $0.bundleIdentifier == Self.extensionBundleID }?.isEnabled ?? false
        let wasDisabled = extensionEnabled == false
        extensionEnabled = enabled
        if enabled {
            extensionWatch?.cancel()
            extensionWatch = nil
            if wasDisabled, openedExtensionSettings {
                openedExtensionSettings = false
                Self.bringWindowToFront()
            }
        } else if extensionWatch == nil {
            // Check again in two seconds (each check schedules the next one
            // while the extension stays off).
            extensionWatch = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else {
                    return
                }
                self.extensionWatch = nil
                await self.refreshExtensionState()
            }
        }
    }

    // MARK: Sign in with the browser

    func signInWithBrowser() {
        alert = nil
        stopSignIn()
        signInTask = Task { await runBrowserSignIn() }
    }

    func cancelSignIn() {
        stopSignIn()
        phase = .signedOut
    }

    /// Ends the current sign-in attempt completely: its task, its browser
    /// session and its callback server.
    private func stopSignIn() {
        signInTask?.cancel()
        signInTask = nil
        authSession?.cancel()
        authSession = nil
        callbackServer?.stop()
        callbackServer = nil
    }

    /// Opens the sign-in page in a web authentication session: a browser
    /// tab or window the system manages for the app (in the default browser
    /// when it supports it). Jottacloud redirects to the local callback
    /// server, which redirects on to `jottafs://signed-in`; the browser then
    /// completes the session, closes the tab and returns to JottaFS. (A page
    /// cannot close its own tab, and Safari keeps the tab open when the app
    /// cancels the session.) Returns false if no session could start.
    private func startAuthenticationSession(_ url: URL, server: LoopbackCallbackServer) -> ASWebAuthenticationSession? {
        let reference = SessionReference()
        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: LoopbackCallbackServer.sessionCallbackScheme
        ) { [weak self, weak server] callbackURL, error in
            // Completed (the tab closed) or closed by the user: stop waiting
            // (ignored if the code already arrived) and come to the front.
            signInLogger.info("Sign-in session ended (completed: \(callbackURL != nil, privacy: .public), error: \((error as NSError?)?.code ?? 0, privacy: .public)).")
            server?.stop()
            Task { @MainActor in
                guard let self, self.authSession === reference.session else {
                    return
                }
                self.authSession = nil
                Self.bringWindowToFront()
            }
        }
        reference.session = session
        session.presentationContextProvider = AuthenticationPresenter.shared
        // Reuse an existing jottacloud.com login in the browser.
        session.prefersEphemeralWebBrowserSession = false
        guard session.start() else {
            return nil
        }
        authSession = session
        return session
    }

    private func runBrowserSignIn() async {
        let server = LoopbackCallbackServer()
        callbackServer = server
        var session: ASWebAuthenticationSession?
        defer {
            server.stop()
            if callbackServer === server {
                callbackServer = nil
            }
        }
        do {
            let redirectURI = try await server.start()
            let login = try await JottacloudClient.beginBrowserLogin(redirectURI: redirectURI)
            try Task.checkCancellation()
            phase = .waitingForBrowser
            // Expect this sign-in's state; redirect to the session only if a
            // web authentication session runs (else the browser shows a page).
            server.expect(state: login.state, redirectsToSession: true)
            session = startAuthenticationSession(login.authorizationURL, server: server)
            if session == nil {
                server.expect(state: login.state, redirectsToSession: false)
                NSWorkspace.shared.open(login.authorizationURL)
            }
            let query = try await server.waitForCallback()
            try Task.checkCancellation()
            // The browser now follows the redirect to `jottafs://` and ends
            // the session itself; cancel it only if that has not happened
            // after a few seconds.
            if let session {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(5))
                    if let self, self.authSession === session {
                        session.cancel()
                        self.authSession = nil
                    }
                }
            }
            Self.bringWindowToFront()
            phase = .finishingSignIn
            let directory = try storageDirectory()
            let signedIn = try await JottacloudClient.completeBrowserLogin(
                login,
                callbackQuery: query,
                persistCredentials: Self.persistence(directory)
            )
            try Task.checkCancellation()
            try await finishSignIn(signedIn)
        } catch {
            // A newer attempt (Start Over) or Cancel owns the shared state.
            guard !Task.isCancelled else {
                return
            }
            if let session, authSession === session {
                session.cancel()
                authSession = nil
            }
            phase = .signedOut
            // Closing the sign-in window is not an error.
            if case LoopbackCallbackServer.ServerError.cancelled = error {
                alert = nil
            } else {
                alert = signInAlert(for: error, usedToken: false)
            }
        }
    }

    /// Brings the app's window to the front after sign-in.
    /// macOS 14+ activates cooperatively, and the browser does not hand
    /// activation back after sign-in, so `NSApp.activate()` alone is ignored.
    /// Fall back to the older forcing call and, if still not frontmost, ask
    /// Launch Services to open the app again (like clicking it in the Dock).
    static func bringWindowToFront() {
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
        }
        guard !NSApp.isActive else {
            return
        }
        NSApp.activate()
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !NSApp.isActive else {
                signInLogger.info("JottaFS is frontmost.")
                return
            }
            signInLogger.info("Activation was declined; reopening JottaFS through Launch Services.")
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
                if let error {
                    signInLogger.error("Reopening failed (\((error as NSError).code, privacy: .public)).")
                }
            }
        }
    }

    // MARK: Sign in with a personal login token

    func signIn(withToken token: String) async {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            return
        }
        alert = nil
        phase = .finishingSignIn
        do {
            let directory = try storageDirectory()
            let signedIn = try await JottacloudClient.authenticate(
                loginToken: token,
                persistCredentials: Self.persistence(directory)
            )
            try await finishSignIn(signedIn)
        } catch {
            phase = .signedOut
            alert = signInAlert(for: error, usedToken: true)
        }
    }

    private func finishSignIn(_ signedIn: JottacloudClient) async throws {
        let directory = try storageDirectory()
        let credentials = await signedIn.currentCredentials()
        try JottaFSStorage.saveCredentials(credentials, to: directory)
        // Use a client that also reads tokens the extension saves.
        useClient(makeClient(credentials), credentials: credentials)
        await loadLocations()
    }

    private func useClient(_ client: JottacloudClient, credentials: JottacloudCredentials) {
        self.client = client
        username = credentials.username
        accountName = credentials.accountName
        accountEmail = credentials.accountEmail
        selectedLocationID = JottacloudRemoteVolume(device: credentials.device, mountpoint: credentials.mountpoint).id
        if mountURL != nil {
            mountedLocationID = selectedLocationID
        }
        phase = .signedIn
    }

    // MARK: Sign out

    /// Unmounts the volume first (it uses these credentials); sign-out stops
    /// if it cannot be unmounted.
    func signOut() async {
        alert = nil
        refreshMountState()
        if mountURL != nil {
            await disconnect()
            guard mountURL == nil else {
                alert = AppAlert(
                    title: "JottaFS couldn’t sign out because Jottacloud is still mounted.",
                    message: alert?.message ?? UnmountError.volumeStillMounted.localizedDescription
                )
                return
            }
        }
        if let credentialsDirectory {
            do {
                try JottaFSStorage.deleteCredentials(from: credentialsDirectory)
            } catch {
                alert = AppAlert(title: "JottaFS couldn’t sign out.", message: error.localizedDescription)
                return
            }
        }
        if mountAtLogin {
            setMountAtLogin(false)
        }
        client = nil
        username = ""
        accountName = nil
        accountEmail = nil
        locations = []
        selectedLocationID = nil
        mountedLocationID = nil
        phase = .signedOut
    }

    // MARK: Locations

    func loadLocations() async {
        guard let client else {
            return
        }
        isLoadingLocations = true
        defer { isLoadingLocations = false }
        await refreshAccountProfile(client)
        do {
            let account = try await client.listAccount()
            // Signed out (or in again) meanwhile: these results are stale.
            guard self.client === client else {
                return
            }
            locations = account.volumes
            loadCustomNames()
            if selectedLocation == nil {
                selectedLocationID = (account.volumes.first { $0.isBuiltIn && $0.mountpoint == "Archive" }
                    ?? account.volumes.first)?.id
            }
            alert = nil
        } catch {
            guard self.client === client else {
                return
            }
            alert = errorAlert(error, title: "JottaFS couldn’t load your Jottacloud locations.")
        }
    }

    /// Updates the name and email shown for the account (saved with the
    /// credentials, so they also show offline).
    private func refreshAccountProfile(_ client: JottacloudClient) async {
        guard let profile = try? await client.fetchAccountProfile(), self.client === client else {
            return
        }
        accountName = profile.name
        accountEmail = profile.email
        if let directory = credentialsDirectory {
            _ = try? JottaFSStorage.updateCredentials(in: directory) { saved in
                saved.accountName = profile.name
                saved.accountEmail = profile.email
            }
        }
    }

    /// The account as shown to the user: name, else email, else the
    /// internal username.
    var accountTitle: String {
        accountName ?? accountEmail ?? username
    }

    /// Shown under the name when both are known.
    var accountSubtitle: String? {
        accountName != nil ? accountEmail : nil
    }

    // MARK: Finder

    /// Mounts the selected location and opens it in Finder (the Mount
    /// button and a double-click in the list).
    func mountSelected() async {
        guard let location = selectedLocation else {
            return
        }
        alert = nil
        if let mountURL, mountedLocationID == location.id {
            showInFinder(mountURL)
            return
        }
        if await mount(location) {
            if let mountURL {
                showInFinder(mountURL)
            }
        }
    }

    /// Mounts `location`, disconnecting another mounted location first.
    private func mount(_ location: JottacloudRemoteVolume) async -> Bool {
        guard extensionEnabled != false else {
            alert = Self.extensionOffAlert
            return false
        }
        if mountURL != nil {
            await disconnect()
            guard mountURL == nil else {
                return false
            }
        }
        activity = .mounting
        defer { activity = nil }
        do {
            try await saveLocation(location)
            let resource = FSPathURLResource(url: try JottaFSStorage.prepareMountAnchorDirectory(), writable: true)
            mountURL = try await FSClient.shared.mountSingleVolume(
                resource: resource,
                bundleID: Self.extensionBundleID,
                options: []
            )
            mountedLocationID = location.id
            return true
        } catch {
            await refreshSystemState()
            if mountURL != nil {
                mountedLocationID = location.id
                return true
            }
            alert = extensionEnabled == false
                ? Self.extensionOffAlert
                : errorAlert(error, title: "JottaFS couldn’t mount the location.")
            return false
        }
    }

    /// Unmounts the volume (Finder's Eject does the same).
    func disconnect() async {
        guard mountURL != nil else {
            return
        }
        activity = .unmounting
        defer { activity = nil }
        var failure: Error?
        do {
            try await requestUnmountFromService()
        } catch {
            failure = error
        }
        refreshMountState()
        if mountURL != nil {
            alert = AppAlert(
                title: "JottaFS couldn’t unmount the location.",
                message: (failure ?? UnmountError.volumeStillMounted).localizedDescription
            )
        } else {
            mountedLocationID = nil
        }
    }

    /// Opens a Finder window on the mounted volume. This only asks Finder to
    /// show the folder, so the sandboxed app needs no access to it.
    private func showInFinder(_ url: URL) {
        if !NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// Follows mounts and unmounts made outside the app (Finder's Eject,
    /// `umount`, a mount at login), so the app always shows the real state.
    private func observeVolumeChanges() {
        guard volumeObservers.isEmpty else {
            return
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            volumeObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.activity == nil else {
                        // The app's own mount/unmount updates the state itself.
                        return
                    }
                    self.refreshMountState()
                }
            })
        }
    }

    private func refreshMountState() {
        let mounted = try? findJottacloudMount()
        mountURL = mounted
        if mounted == nil {
            mountedLocationID = nil
        } else if mountedLocationID == nil, let saved = loadSavedCredentials() {
            // Mounted earlier (or at login): the saved location is mounted.
            mountedLocationID = JottacloudRemoteVolume(device: saved.device, mountpoint: saved.mountpoint).id
        }
    }

    // MARK: Open at login

    func setMountAtLogin(_ enabled: Bool) {
        alert = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            mountAtLogin = enabled
            UserDefaults.standard.set(enabled, forKey: Self.mountAtLoginKey)
        } catch {
            alert = AppAlert(
                title: enabled ? "JottaFS couldn’t turn on mounting at login." : "JottaFS couldn’t turn off mounting at login.",
                message: "Check Login Items in System Settings."
            )
        }
        refreshLoginItemStatus()
    }

    private func refreshLoginItemStatus() {
        let status = SMAppService.mainApp.status
        loginItemNeedsApproval = mountAtLogin && status == .requiresApproval
        if mountAtLogin, status == .notRegistered || status == .notFound {
            // Removed in System Settings: follow the system.
            mountAtLogin = false
            UserDefaults.standard.set(false, forKey: Self.mountAtLoginKey)
        }
    }

    /// Opened by macOS at login: mount the saved location without showing
    /// the window, then quit. The window stays open only to report a problem.
    private func mountAtLoginLaunch() async {
        // There is no window and no Dock icon (see the app delegate).
        guard mountAtLogin else {
            NSApp.terminate(nil)
            return
        }
        if mountURL == nil, let saved = loadSavedCredentials() {
            let location = JottacloudRemoteVolume(device: saved.device, mountpoint: saved.mountpoint)
            locations = [location]
            loadCustomNames()
            guard await mount(location) else {
                // Show the problem as a normal app, with Dock icon and menu.
                launchedAtLogin = false
                showWindow?()
                await loadLocations()
                return
            }
        }
        NSApp.terminate(nil)
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func openExtensionSettings() {
        openedExtensionSettings = FSClient.shared.openFileSystemExtensionsSettings()
    }

    // MARK: Upload progress agent

    /// Registers JottaFSProgressAgent, which shows upload progress on file
    /// icons in Finder (the sandboxed extension cannot).
    private func registerProgressAgent() {
        let agent = SMAppService.agent(plistName: JottaFSProgressService.launchAgentPlistName)
        if agent.status != .enabled {
            try? agent.register()
        }
        progressAgentNeedsApproval = agent.status == .requiresApproval
    }

    // MARK: Names

    /// The location's name in Finder (a custom name, if set).
    func displayName(of location: JottacloudRemoteVolume) -> String {
        customName(of: location) ?? location.mountpoint
    }

    /// Names the user chose for locations in Finder, by location id (read
    /// once per listing, not for every row on every update).
    @Published private(set) var customNames: [String: String] = [:]

    /// The name the user chose for a location in Finder, if any.
    func customName(of location: JottacloudRemoteVolume) -> String? {
        customNames[location.id]
    }

    private func loadCustomNames() {
        customNames = Dictionary(uniqueKeysWithValues: locations.compactMap { location in
            JottaFSStorage.customVolumeName(device: location.device, mountpoint: location.mountpoint)
                .map { (location.id, $0) }
        })
    }

    /// Saves the name a location gets in Finder; nil or empty restores the
    /// location's own name. Used at the next mount.
    func setCustomName(_ name: String?, for location: JottacloudRemoteVolume) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let value = trimmed.isEmpty || trimmed == JottaFSStorage.defaultVolumeName(mountpoint: location.mountpoint)
            ? nil : trimmed
        do {
            try JottaFSStorage.setCustomVolumeName(value, device: location.device, mountpoint: location.mountpoint)
            customNames[location.id] = value
        } catch {
            alert = AppAlert(title: "JottaFS couldn’t save the name.", message: error.localizedDescription)
        }
    }

    // MARK: Storage

    private func storageDirectory() throws -> URL {
        if let credentialsDirectory {
            return credentialsDirectory
        }
        let directory = try JottaFSStorage.prepareCredentialsDirectory()
        credentialsDirectory = directory
        return directory
    }

    private func loadSavedCredentials() -> JottacloudCredentials? {
        guard let credentialsDirectory else {
            return nil
        }
        return try? JottaFSStorage.loadCredentials(from: credentialsDirectory)
    }

    private func makeClient(_ credentials: JottacloudCredentials) -> JottacloudClient {
        let directory = credentialsDirectory
        return JottacloudClient(
            credentials: credentials,
            persistCredentials: Self.persistence(directory),
            loadSavedCredentials: {
                directory.flatMap { try? JottaFSStorage.loadCredentials(from: $0) }
            }
        )
    }

    /// Saves the chosen location with the credentials; the extension mounts
    /// it. Only changed while nothing is mounted.
    private func saveLocation(_ location: JottacloudRemoteVolume) async throws {
        let directory = try storageDirectory()
        try JottaFSStorage.updateCredentials(in: directory) { saved in
            saved.device = location.device
            saved.mountpoint = location.mountpoint
        }
        await client?.setLocation(device: location.device, mountpoint: location.mountpoint)
    }

    /// Saves rotated tokens only (never other fields, which the extension
    /// or the app may have changed meanwhile).
    private static func persistence(_ directory: URL?) -> @Sendable (JottacloudCredentials) async throws -> Void {
        { credentials in
            guard let directory else {
                return
            }
            try JottaFSStorage.saveTokens(of: credentials, to: directory)
        }
    }

    // MARK: Messages

    private static let extensionOffAlert = AppAlert(
        title: "Turn on JottaFS in System Settings.",
        message: "Open System Settings → General → Login Items & Extensions → File System Extensions, and turn on JottaFS."
    )

    private func signInAlert(for error: Error, usedToken: Bool) -> AppAlert {
        let title = "JottaFS couldn’t sign you in."
        if let error = error as? JottacloudError {
            switch error {
            case .invalidLoginToken:
                return AppAlert(title: title, message: "That doesn’t look like a personal login token. Copy the whole token from Jottacloud and paste it again.")
            case .httpStatus(400), .httpStatus(401):
                return AppAlert(title: title, message: usedToken
                    ? "This token has already been used or has expired. Create a new token in Jottacloud and try again."
                    : "Jottacloud didn’t accept the sign-in. Please try again.")
            case .browserLoginStateMismatch:
                return AppAlert(title: title, message: "The sign-in didn’t match this window. Please try again.")
            case .browserLoginFailed:
                return AppAlert(title: title, message: "Sign-in didn’t finish in the browser. Please try again.")
            default:
                break
            }
        }
        return errorAlert(error, title: title)
    }

    /// An alert for `error` with a full-sentence title (no sentence
    /// fragments, so each title can be translated as a whole).
    private func errorAlert(_ error: Error, title: String) -> AppAlert {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .timedOut, .dnsLookupFailed:
                return AppAlert(title: "JottaFS can’t reach Jottacloud.", message: "Check your internet connection and try again.")
            default:
                break
            }
        }
        if case JottacloudError.locationNotFound = error {
            return AppAlert(title: "This location isn’t available any more.", message: "Choose another location.")
        }
        if case JottacloudError.tokenRefreshDisabled = error {
            return AppAlert(title: "Your sign-in has expired.", message: "Sign out and sign in again.")
        }
        return AppAlert(title: title, message: error.localizedDescription)
    }
}

/// Presents web authentication sessions over the JottaFS window.
final class AuthenticationPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = AuthenticationPresenter()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApp.keyWindow ?? NSApp.windows.first { $0.canBecomeMain } ?? ASPresentationAnchor()
        }
    }
}

private let signInLogger = Logger(subsystem: "no.alrek.jottafs", category: "SignIn")

/// Lets a session's completion handler recognise its own session.
private final class SessionReference: @unchecked Sendable {
    weak var session: ASWebAuthenticationSession?
}

/// An error shown to the user in an alert.
struct AppAlert: Equatable {
    let title: String
    let message: String?
}
