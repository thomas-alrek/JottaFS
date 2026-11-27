import AppKit
import AuthenticationServices
import FinderSync
import OSLog
import FSKit
import JottaFSCore
import Network
import notify
import ServiceManagement
import SwiftUI
import SystemConfiguration

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
        case mounting(locationID: String)
        /// nil: every mounted location (signing out).
        case unmounting(locationID: String?)
        /// Creating or removing a backup device or a location.
        case changingLocations

        /// True if this is work on the location `id` (shown in its button).
        func concerns(_ id: String?) -> Bool {
            switch self {
            case .mounting(let locationID): locationID == id
            case .unmounting(let locationID): locationID == nil || locationID == id
            case .changingLocations: false
            }
        }
    }

    static let extensionBundleID = "no.alrek.jottafs.extension"
    /// Before 1.1: one setting for the one location.
    private static let legacyMountAtLoginKey = "MountAtLogin"
    /// The locations to mount at login, chosen per location. A list of
    /// `["Device": …, "Mountpoint": …]`.
    private static let loginLocationsKey = "MountAtLoginLocations"
    private static let offeredFinderExtensionKey = "OfferedFinderExtension"

    @Published private(set) var phase: Phase = .starting
    @Published private(set) var username = ""
    @Published private(set) var accountName: String?
    @Published private(set) var accountEmail: String?
    @Published private(set) var locations: [JottacloudRemoteVolume] = []
    @Published private(set) var isLoadingLocations = false
    /// The locations could not be loaded because there is no network yet;
    /// they load by themselves when it is up (no error is shown meanwhile).
    @Published private(set) var isWaitingForNetwork = false
    @Published var selectedLocationID: String?
    /// The mounted locations, by location id.
    @Published private(set) var mounts: [String: JottaFSStorage.MountedVolume] = [:]
    /// What the app is doing right now (shown in the main button).
    @Published private(set) var activity: Activity?
    /// The error to show in an alert.
    @Published var alert: AppAlert?
    /// nil while unknown.
    @Published private(set) var extensionEnabled: Bool?
    @Published private(set) var progressAgentNeedsApproval = false
    /// The locations to mount at login, in the order they were turned on.
    @Published private(set) var loginLocations: [JottacloudRemoteVolume] = []
    @Published private(set) var loginItemNeedsApproval = false
    /// Asks once whether to turn on the Finder extension (share links).
    @Published var offersFinderExtension = false

    /// Set by the app delegate when macOS opened the app at login.
    var launchedAtLogin = false
    /// Set by the app delegate when the refresh agent opened the app to
    /// keep the sign-in alive (no window; it quits when done).
    var launchedToRefresh = false
    /// Creates and shows the window (it does not exist after a launch at
    /// login); set by the app delegate.
    var showWindow: (() -> Void)?
    /// Work for the hidden refresh launch before it quits (the update
    /// check; set by the app delegate).
    var backgroundWork: (() async -> Void)?

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

    func isMounted(_ location: JottacloudRemoteVolume) -> Bool {
        mounts[location.id] != nil
    }

    var selectedIsMounted: Bool {
        selectedLocationID.map { mounts[$0] != nil } ?? false
    }

    /// The work in progress on the selected location, if any.
    var selectedActivity: Activity? {
        activity.flatMap { $0.concerns(selectedLocationID) ? $0 : nil }
    }

    var isBusy: Bool {
        activity != nil
    }

    // MARK: Start

    func start() async {
        guard phase == .starting else {
            return
        }
        #if DEBUG
        // Debug builds only: start at the sign-in screen without touching
        // the saved sign-in (for the README screenshots).
        if CommandLine.arguments.contains("--preview-signed-out") {
            phase = .signedOut
            return
        }
        #endif
        observeVolumeChanges()
        do {
            credentialsDirectory = try JottaFSStorage.prepareCredentialsDirectory()
            // The extension names the built-in locations' disks with these
            // (in the user's language, like the list).
            try? JottaFSStorage.setBuiltInLocationNames(Self.builtInLocationNames)
        } catch {
            phase = .signedOut
            alert = AppAlert(title: String(localized: "JottaFS couldn’t prepare its storage."), message: String(localized: "Reinstall the app and try again."))
            return
        }
        await refreshSystemState()
        let saved = loadSavedCredentials()
        loadLoginLocations(migrating: saved)
        migrateLoginItem()
        guard let saved else {
            phase = .signedOut
            if launchedAtLogin {
                NSApp.terminate(nil)
            }
            return
        }
        useClient(makeClient(saved), credentials: saved)
        observeSessionEnd()
        if let credentialsDirectory, JottaFSStorage.sessionHasEnded(in: credentialsDirectory) {
            await handleSessionEnded()
            return
        }
        if launchedToRefresh {
            await refreshSessionLaunch()
            return
        }
        loginLogger.notice("Launched \(self.launchedAtLogin ? "at login (--mount-at-login)" : "normally", privacy: .public), \(Int(ProcessInfo.processInfo.systemUptime), privacy: .public) s after start-up.")
        if launchedAtLogin {
            await mountAtLoginLaunch()
            return
        }
        await loadLocations()
    }

    /// Called when the app becomes active (the user may have changed System
    /// Settings or ejected the volume in Finder).
    func refreshSystemState() async {
        if let credentialsDirectory, JottaFSStorage.sessionHasEnded(in: credentialsDirectory) {
            await handleSessionEnded()
            return
        }
        refreshMountState()
        refreshLoginItemStatus()
        registerProgressAgent()
        await refreshExtensionState()
    }

    /// Reads whether JottaFS is turned on in System Settings, and keeps
    /// checking (FSKit sends no notification): every two seconds while it is
    /// off, so the app updates as soon as the user turns it on, and every
    /// five seconds while it is on, so the window shows how to turn it on
    /// again if the user turns it off.
    private func refreshExtensionState() async {
        extensionWatch?.cancel()
        extensionWatch = nil
        if let extensions = try? await FSClient.shared.installedExtensions {
            let enabled = extensions.first { $0.bundleIdentifier == Self.extensionBundleID }?.isEnabled ?? false
            let wasDisabled = extensionEnabled == false
            let wasEnabled = extensionEnabled == true
            extensionEnabled = enabled
            offerFinderExtensionIfNeeded()
            if enabled, wasDisabled, openedExtensionSettings {
                openedExtensionSettings = false
                Self.bringWindowToFront()
            } else if !enabled, wasEnabled {
                // Turning it off unmounts the disks.
                refreshMountState()
            }
        }
        let interval: Duration = extensionEnabled == true ? .seconds(5) : .seconds(2)
        extensionWatch = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard let self, !Task.isCancelled else {
                return
            }
            // Not cancelled by the call below (it would cancel this task).
            self.extensionWatch = nil
            await self.refreshExtensionState()
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
        phase = .signedIn
        // Keeps the sign-in alive while JottaFS is not in use.
        if Self.refreshAgent.status != .enabled {
            try? Self.refreshAgent.register()
        }
        registerSession(client)
    }

    /// Names this sign-in on jottacloud.com (Security → signed-in devices):
    /// the Mac's name and "JottaFS", instead of "Jottacloud CLI". Done at
    /// each launch, so the name and version stay current; failures only
    /// leave the old name.
    private func registerSession(_ client: JottacloudClient) {
        let deviceName = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? Host.current().localizedName ?? "Mac"
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let deviceID = Self.sessionDeviceID
        Task {
            do {
                try await client.registerSession(deviceName: deviceName, appVersion: appVersion, deviceID: deviceID)
            } catch {
                signInLogger.notice("Naming the sign-in failed (\(Self.describe(error), privacy: .public)).")
            }
        }
    }

    /// A random identifier for this Mac's JottaFS, kept across sign-ins.
    private static var sessionDeviceID: String {
        let key = "SessionDeviceID"
        if let id = UserDefaults.standard.string(forKey: key) {
            return id
        }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    // MARK: Ended sign-in

    /// The launch agent that opens JottaFS twice a day (hidden) to refresh
    /// the sign-in, so Jottacloud's offline session never passes its idle
    /// limit while no disk is mounted (docs/jottacloud-api-internals.md).
    private static let refreshAgent = SMAppService.agent(plistName: "no.alrek.jottafs.refresh.plist")
    static let refreshSessionArgument = "--refresh-session"
    private var sessionEndObserver: Int32 = NOTIFY_TOKEN_INVALID
    private var handlingSessionEnd = false

    /// Listens for the notification that a process (the app, the file
    /// system extension or the Finder extension) found the sign-in ended.
    private func observeSessionEnd() {
        guard sessionEndObserver == NOTIFY_TOKEN_INVALID else {
            return
        }
        notify_register_dispatch(JottaFSStorage.sessionEndedNotification, &sessionEndObserver, .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else {
                    return
                }
                Task { await self.handleSessionEnded() }
            }
        }
    }

    /// A refresh launch: refreshes the tokens and quits. If the sign-in has
    /// ended, signs out and shows the window with the reason.
    private func refreshSessionLaunch() async {
        do {
            try await client?.refreshSession()
            loginLogger.notice("Refreshed the sign-in.")
        } catch JottacloudError.sessionEnded {
            await handleSessionEnded()
            return
        } catch {
            // Usually no network: the next run tries again.
            loginLogger.notice("Refreshing the sign-in failed (\(Self.describe(error), privacy: .public)); trying again later.")
        }
        if launchedToRefresh {
            await backgroundWork?()
        }
        // The user may have opened the window during the update check.
        if launchedToRefresh {
            NSApp.terminate(nil)
        } else {
            // The user opened the window meanwhile.
            await loadLocations()
        }
    }

    /// Jottacloud no longer accepts the sign-in: unmounts every location
    /// (they cannot work any more), signs out and asks the user to sign in
    /// again. The locations chosen for mount at login are kept for the next
    /// sign-in.
    func handleSessionEnded() async {
        guard let credentialsDirectory, JottaFSStorage.sessionHasEnded(in: credentialsDirectory),
              client != nil, !handlingSessionEnd
        else {
            return
        }
        handlingSessionEnd = true
        defer { handlingSessionEnd = false }
        signInLogger.notice("The Jottacloud sign-in has ended; signing out.")
        refreshMountState()
        let failure = await unmountAll()
        try? JottaFSStorage.deleteCredentials(from: credentialsDirectory)
        try? await Self.refreshAgent.unregister()
        forgetAccount()
        alert = AppAlert(
            title: String(localized: "Your Jottacloud sign-in has ended."),
            message: failure == nil
                ? String(localized: "Sign in again to use your Jottacloud disks. Your files stay in Jottacloud.")
                : String(localized: "Sign in again to use your Jottacloud disks. Eject the Jottacloud disks that are still in Finder. Your files stay in Jottacloud.")
        )
        if launchedAtLogin || launchedToRefresh {
            launchedAtLogin = false
            launchedToRefresh = false
            showWindow?()
        }
        Self.bringWindowToFront()
    }

    /// Clears the signed-in state (after the credentials are deleted).
    private func forgetAccount() {
        client = nil
        username = ""
        accountName = nil
        accountEmail = nil
        locations = []
        selectedLocationID = nil
        phase = .signedOut
    }

    // MARK: Sign out

    /// Unmounts every mounted location first (they use these credentials);
    /// sign-out stops if one cannot be unmounted.
    func signOut() async {
        alert = nil
        refreshMountState()
        if let failure = await unmountAll() {
            alert = AppAlert(
                title: String(localized: "JottaFS couldn’t sign out because Jottacloud is still mounted."),
                message: failure.localizedDescription
            )
            return
        }
        // End the sign-in on Jottacloud too, so it leaves the account's list
        // of signed-in devices and its tokens stop working. Offline, it only
        // ends here (the server ends unused sign-ins by itself).
        do {
            try await client?.logout()
        } catch {
            signInLogger.notice("Signing out on Jottacloud failed (\(Self.describe(error), privacy: .public)); signing out here only.")
        }
        if let credentialsDirectory {
            do {
                try JottaFSStorage.deleteCredentials(from: credentialsDirectory)
            } catch {
                alert = AppAlert(title: String(localized: "JottaFS couldn’t sign out."), message: error.localizedDescription)
                return
            }
        }
        if !loginLocations.isEmpty {
            saveLoginLocations([])
        }
        try? await Self.refreshAgent.unregister()
        forgetAccount()
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
            locationsLoadFailed = false
            isWaitingForNetwork = false
            loadCustomNames()
            offerFinderExtensionIfNeeded()
            // Start on a mounted location if there is one.
            if let mounted = account.volumes.first(where: isMounted), !selectedIsMounted {
                selectedLocationID = mounted.id
            } else if selectedLocation == nil {
                selectedLocationID = (account.volumes.first { $0.isBuiltIn && $0.mountpoint == "Archive" }
                    ?? account.volumes.first)?.id
            }
            alert = nil
        } catch {
            guard self.client === client else {
                return
            }
            locationsLoadFailed = true
            if Self.isNetworkError(error) {
                // Usually the network is not up yet (just after start-up):
                // wait for it instead of showing an error.
                isWaitingForNetwork = true
                reloadLocationsWhenOnline()
            } else {
                alert = errorAlert(error, title: String(localized: "JottaFS couldn’t load your Jottacloud locations."))
            }
        }
    }

    private var locationsReload: Task<Void, Never>?
    private var locationsLoadFailed = false

    /// Loads the locations again once the network is back (for up to 10
    /// minutes), so the list does not stay on "couldn't be loaded" after the
    /// Mac comes online.
    private func reloadLocationsWhenOnline() {
        guard locationsReload == nil else {
            return
        }
        locationsReload = Task { [weak self] in
            defer {
                self?.locationsReload = nil
                // Gave up: show the list's normal "couldn't be loaded" state.
                if self?.locationsLoadFailed == true {
                    self?.isWaitingForNetwork = false
                }
            }
            let deadline = Date().addingTimeInterval(600)
            while Date() < deadline, !Task.isCancelled {
                guard await Self.waitForNetwork(until: deadline) else {
                    return
                }
                // DNS and routes can lag a moment behind the network path.
                try? await Task.sleep(for: .seconds(3))
                guard let self, self.phase == .signedIn, self.locationsLoadFailed else {
                    return
                }
                await self.loadLocations()
                if !self.locationsLoadFailed {
                    return
                }
                try? await Task.sleep(for: .seconds(10))
            }
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
    /// button and a double-click in the list). A mounted location only
    /// opens in Finder.
    func mountSelected() async {
        guard let location = selectedLocation, !isBusy else {
            return
        }
        alert = nil
        if let mounted = mounts[location.id] {
            showInFinder(mounted.mountPoint)
            return
        }
        if await mount(location), let mounted = mounts[location.id] {
            showInFinder(mounted.mountPoint)
        }
    }

    /// Mounts `location` from its own mount anchor; other mounted locations
    /// stay mounted.
    private func mount(_ location: JottacloudRemoteVolume) async -> Bool {
        lastMountError = nil
        guard extensionEnabled != false else {
            alert = Self.extensionOffAlert
            return false
        }
        if mounts[location.id] != nil {
            return true
        }
        activity = .mounting(locationID: location.id)
        defer { activity = nil }
        do {
            let anchor = try JottaFSStorage.prepareMountAnchor(device: location.device, mountpoint: location.mountpoint)
            let resource = FSPathURLResource(url: anchor, writable: true)
            let mountPoint = try await FSClient.shared.mountSingleVolume(
                resource: resource,
                bundleID: Self.extensionBundleID,
                options: []
            )
            refreshMountState()
            if mounts[location.id] == nil {
                // Not in the (cached) mount table yet.
                mounts[location.id] = JottaFSStorage.MountedVolume(
                    anchorName: JottaFSStorage.anchorName(device: location.device, mountpoint: location.mountpoint),
                    anchorURL: anchor,
                    mountPoint: mountPoint
                )
            }
        } catch {
            lastMountError = error
            await refreshSystemState()
            if mounts[location.id] == nil {
                alert = extensionEnabled == false
                    ? Self.extensionOffAlert
                    : errorAlert(error, title: String(localized: "JottaFS couldn’t mount the location."))
                return false
            }
        }
        return true
    }

    /// The error of the last failed mount, if any.
    private var lastMountError: Error?

    /// True for errors that can go away once the network is up (no
    /// connection yet, DNS not ready, a timeout).
    private static func isNetworkError(_ error: Error?) -> Bool {
        guard let error = error as NSError?, error.domain == NSURLErrorDomain else {
            return false
        }
        let codes: [URLError.Code] = [
            .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
            .timedOut, .dnsLookupFailed, .dataNotAllowed, .secureConnectionFailed,
        ]
        return codes.contains(URLError.Code(rawValue: error.code))
    }

    /// Waits until the Mac has a usable network path, or until `deadline`.
    /// Returns whether the network is up.
    private static func waitForNetwork(until deadline: Date) async -> Bool {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "no.alrek.jottafs.network")
        let ready = AsyncStream<Bool> { continuation in
            monitor.pathUpdateHandler = { path in
                if path.status == .satisfied {
                    continuation.yield(true)
                    continuation.finish()
                }
            }
            monitor.start(queue: queue)
            let seconds = max(0, deadline.timeIntervalSinceNow)
            queue.asyncAfter(deadline: .now() + seconds) {
                continuation.yield(false)
                continuation.finish()
            }
        }
        defer { monitor.cancel() }
        for await isUp in ready {
            return isUp
        }
        return false
    }

    /// Unmounts the selected location (Finder's Eject does the same).
    /// Whether the app can unmount: only through JottaFSService, which a
    /// fully sandboxed build does not have (then the user ejects in Finder).
    var canUnmount: Bool {
        JottaFSService.isAvailable
    }

    func unmountSelected() async {
        guard canUnmount, let location = selectedLocation, let mounted = mounts[location.id], !isBusy else {
            return
        }
        alert = nil
        activity = .unmounting(locationID: location.id)
        defer { activity = nil }
        var failure: Error?
        do {
            try await requestUnmountFromService(anchorName: mounted.anchorName)
        } catch {
            failure = error
        }
        refreshMountState()
        if mounts[location.id] != nil {
            alert = AppAlert(
                title: String(localized: "JottaFS couldn’t unmount the location."),
                message: (failure ?? UnmountError.volumeStillMounted).localizedDescription
            )
        }
    }

    /// Unmounts every JottaFS volume (also any whose location is no longer
    /// listed). Returns the first failure, or nil when none is mounted.
    private func unmountAll() async -> Error? {
        guard let volumes = JottaFSStorage.mountedVolumes(), !volumes.isEmpty else {
            return nil
        }
        guard canUnmount else {
            return UnmountError.ejectInFinder
        }
        activity = .unmounting(locationID: nil)
        defer { activity = nil }
        var failure: Error?
        for volume in volumes {
            do {
                try await requestUnmountFromService(anchorName: volume.anchorName)
            } catch {
                failure = failure ?? error
            }
        }
        refreshMountState()
        guard JottaFSStorage.mountedVolumes()?.isEmpty != false else {
            return failure ?? UnmountError.volumeStillMounted
        }
        return nil
    }

    // MARK: Backup devices and locations

    /// The backup devices in the list (not Jottacloud's own device), in list
    /// order.
    var backupDeviceNames: [String] {
        var seen = Set<String>()
        return locations.filter { !$0.isBuiltIn }.map(\.device).filter { seen.insert($0.lowercased()).inserted }
    }

    func locations(on device: String) -> [JottacloudRemoteVolume] {
        locations.filter { $0.device.caseInsensitiveCompare(device) == .orderedSame }
    }

    func mountedLocations(on device: String) -> [JottacloudRemoteVolume] {
        locations(on: device).filter(isMounted)
    }

    /// Creates a backup device with its first location (a device without a
    /// location does not show in Jottacloud's listing) and selects it.
    func createBackupDevice(named rawName: String, firstLocation rawLocation: String) async throws {
        guard let client, !isBusy else {
            return
        }
        let name = try Self.validLocationName(rawName)
        let location = try Self.validLocationName(rawLocation)
        let existing = Set(((try? await client.listBackupDevices()) ?? []).map { $0.name.lowercased() })
            .union(locations.map { $0.device.lowercased() })
            .union([JottacloudRemoteVolume.builtInDevice.lowercased()])
        guard !existing.contains(name.lowercased()) else {
            throw LocationChangeError.nameInUse(name)
        }
        alert = nil
        activity = .changingLocations
        defer { activity = nil }
        try await client.createDevice(named: name)
        try await client.createMountpoint(device: name, named: location)
        await loadLocations()
        selectedLocationID = JottacloudRemoteVolume(device: name, mountpoint: location).id
    }

    /// Creates a location on a backup device and selects it.
    func createLocation(named rawName: String, on device: String) async throws {
        guard let client, !isBusy else {
            return
        }
        guard device != JottacloudRemoteVolume.builtInDevice else {
            throw LocationChangeError.builtInDevice
        }
        let name = try Self.validLocationName(rawName)
        guard !locations(on: device).contains(where: { $0.mountpoint.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw LocationChangeError.nameInUse(name)
        }
        alert = nil
        activity = .changingLocations
        defer { activity = nil }
        try await client.createMountpoint(device: device, named: name)
        await loadLocations()
        selectedLocationID = JottacloudRemoteVolume(device: device, mountpoint: name).id
    }

    /// Moves a location of a backup device, with its files, to the Jottacloud
    /// trash; unmounted first (nothing is removed if that fails).
    func moveLocationToTrash(_ location: JottacloudRemoteVolume) async throws {
        guard let client, !isBusy else {
            return
        }
        guard !location.isBuiltIn else {
            throw LocationChangeError.builtInDevice
        }
        alert = nil
        activity = .changingLocations
        defer { activity = nil }
        let device = try await backupDevice(named: location.device, client: client)
        try await LocationRemoval.run(
            unmounting: isMounted(location) ? [location] : [],
            unmount: unmount,
            remove: { try await client.removeMountpoint(location.mountpoint, of: device) }
        )
        forget(location)
        await loadLocations()
    }

    /// Deletes a backup device with all its locations and files, for good;
    /// its mounted locations are unmounted first (nothing is deleted if one
    /// of them can't be unmounted).
    func deleteBackupDevice(_ name: String) async throws {
        guard let client, !isBusy else {
            return
        }
        guard name != JottacloudRemoteVolume.builtInDevice else {
            throw LocationChangeError.builtInDevice
        }
        alert = nil
        activity = .changingLocations
        defer { activity = nil }
        let device = try await backupDevice(named: name, client: client)
        let affected = locations(on: name)
        try await LocationRemoval.run(
            unmounting: affected.filter(isMounted),
            unmount: unmount,
            remove: { try await client.deleteDevice(device) }
        )
        affected.forEach(forget)
        await loadLocations()
    }

    private func backupDevice(named name: String, client: JottacloudClient) async throws -> JottacloudBackupDevice {
        guard let device = try await client.listBackupDevices().first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw LocationChangeError.deviceNotFound(name)
        }
        return device
    }

    /// Unmounts one location; throws (naming it) if it stays mounted.
    private func unmount(_ location: JottacloudRemoteVolume) async throws {
        guard let mounted = mounts[location.id] else {
            return
        }
        guard canUnmount else {
            throw LocationChangeError.ejectFirst(finderName(of: location))
        }
        var failure: Error?
        do {
            try await requestUnmountFromService(anchorName: mounted.anchorName)
        } catch {
            failure = error
        }
        refreshMountState()
        if mounts[location.id] != nil {
            throw LocationChangeError.couldNotUnmount(finderName(of: location), (failure ?? UnmountError.volumeStillMounted).localizedDescription)
        }
    }

    /// Drops a removed location's own settings: mount at login and the name
    /// in Finder.
    private func forget(_ location: JottacloudRemoteVolume) {
        if mountsAtLogin(location) {
            setMountAtLogin(false, for: location)
        }
        if customName(of: location) != nil {
            setCustomName(nil, for: location)
        }
    }

    /// A trimmed name Jottacloud can store (JottaFSNames rules), or an error.
    static func validLocationName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, (try? JottaFSNames.validate(name)) != nil else {
            throw LocationChangeError.invalidName
        }
        return name
    }

    enum LocationChangeError: LocalizedError {
        case invalidName
        case nameInUse(String)
        case builtInDevice
        case deviceNotFound(String)
        case ejectFirst(String)
        case couldNotUnmount(String, String)

        var errorDescription: String? {
            switch self {
            case .invalidName:
                String(localized: "This name can’t be used in Jottacloud. Avoid the characters \" * : < > ? | % \\ /.")
            case .nameInUse(let name):
                String(localized: "“\(name)” already exists.")
            case .builtInDevice:
                String(localized: "New locations can only be added to backup devices.")
            case .deviceNotFound(let name):
                String(localized: "The backup device “\(name)” wasn’t found. Try again in a moment.")
            case .ejectFirst(let name):
                String(localized: "Eject “\(name)” in Finder first, then try again.")
            case .couldNotUnmount(let name, let reason):
                String(localized: "“\(name)” couldn’t be unmounted, so nothing was removed. \(reason)")
            }
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

    /// Reads the mounted locations from the mount table: each anchor names
    /// its location; a legacy mount (before 1.1) is the location saved in
    /// the credentials.
    private func refreshMountState() {
        guard let volumes = JottaFSStorage.mountedVolumes() else {
            return
        }
        var result: [String: JottaFSStorage.MountedVolume] = [:]
        for volume in volumes {
            let location: (device: String, mountpoint: String)?
            if volume.anchorName.isEmpty {
                location = loadSavedCredentials().map { ($0.device, $0.mountpoint) }
            } else {
                location = JottaFSStorage.location(ofAnchor: volume.anchorURL)
            }
            if let location {
                result[JottacloudRemoteVolume(device: location.device, mountpoint: location.mountpoint).id] = volume
            }
        }
        if result != mounts {
            mounts = result
        }
    }

    // MARK: Open at login

    func mountsAtLogin(_ location: JottacloudRemoteVolume) -> Bool {
        loginLocations.contains { $0.id == location.id }
    }

    /// Turns mounting at login on or off for `location`. JottaFS is a login
    /// item while at least one location has it on.
    func setMountAtLogin(_ enabled: Bool, for location: JottacloudRemoteVolume) {
        alert = nil
        var list = loginLocations.filter { $0.id != location.id }
        if enabled {
            list.append(location)
        }
        saveLoginLocations(list)
        if alert != nil, enabled {
            // Could not register: leave it off.
            saveLoginLocations(loginLocations.filter { $0.id != location.id }, registering: false)
        }
    }

    /// Saves the list and registers (or unregisters) the login item to
    /// match.
    private func saveLoginLocations(_ list: [JottacloudRemoteVolume], registering: Bool = true) {
        let wasOn = !loginLocations.isEmpty
        loginLocations = list
        UserDefaults.standard.set(
            list.map { ["Device": $0.device, "Mountpoint": $0.mountpoint] },
            forKey: Self.loginLocationsKey
        )
        guard registering, wasOn != !list.isEmpty else {
            refreshLoginItemStatus()
            return
        }
        do {
            if list.isEmpty {
                try Self.loginAgent.unregister()
            } else {
                try Self.loginAgent.register()
            }
        } catch {
            alert = AppAlert(
                title: list.isEmpty ? String(localized: "JottaFS couldn’t turn off mounting at login.") : String(localized: "JottaFS couldn’t turn on mounting at login."),
                message: String(localized: "Check Login Items in System Settings.")
            )
        }
        refreshLoginItemStatus()
    }

    /// The launch agent that starts the app at login with `--mount-at-login`
    /// (HostApp/no.alrek.jottafs.login.plist). The argument tells the app
    /// for certain that it was started at login.
    private static let loginAgent = SMAppService.agent(plistName: "no.alrek.jottafs.login.plist")
    static let mountAtLoginArgument = "--mount-at-login"

    /// Versions up to 1.0.4 registered the app itself as the login item
    /// (SMAppService.mainApp), which cannot say how the app was started.
    /// Move to the launch agent.
    private func migrateLoginItem() {
        guard SMAppService.mainApp.status == .enabled else {
            return
        }
        try? SMAppService.mainApp.unregister()
        if !loginLocations.isEmpty {
            try? Self.loginAgent.register()
        }
        loginLogger.notice("Moved mount at login from the app login item to the launch agent.")
    }

    private func refreshLoginItemStatus() {
        let status = Self.loginAgent.status
        loginItemNeedsApproval = !loginLocations.isEmpty && status == .requiresApproval
        if !loginLocations.isEmpty, status == .notRegistered || status == .notFound {
            // Removed in System Settings: follow the system.
            loginLocations = []
            UserDefaults.standard.set([[String: String]](), forKey: Self.loginLocationsKey)
        }
    }

    /// Opened by macOS at login: mount the locations chosen for it without
    /// showing the window, then quit. The window stays open only to report
    /// a problem.
    private func mountAtLoginLaunch() async {
        // There is no window and no Dock icon (see the app delegate).
        let wanted = loginLocations
        guard !wanted.isEmpty else {
            NSApp.terminate(nil)
            return
        }
        // launchd also runs the agent when it is registered (turning on
        // mount at login in the open app). Then JottaFS is already open and
        // handles mounting itself; do nothing.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard others.isEmpty else {
            loginLogger.notice("JottaFS is already open; the login launch does nothing.")
            NSApp.terminate(nil)
            return
        }
        locations = wanted
        loadCustomNames()
        let mounted = await mountLoginLocations(wanted)
        guard launchedAtLogin else {
            // The user opened the window meanwhile: stay open, with the
            // full list.
            await loadLocations()
            return
        }
        guard mounted else {
            // Show the problem as a normal app, with Dock icon and menu.
            launchedAtLogin = false
            showWindow?()
            await loadLocations()
            return
        }
        NSApp.terminate(nil)
    }

    /// Mounts the locations chosen for login, retrying what can still work
    /// for up to `loginWait`. Returns false if a mount failed for good (the
    /// alert describes it).
    private func mountLoginLocations(_ wanted: [JottacloudRemoteVolume]) async -> Bool {
        // Right after login, several things may not be ready yet: Wi-Fi
        // (and DNS), FSKit's list of enabled extensions (JottaFS can look
        // turned off for a moment) and FSKit itself. Keep trying for up to
        // `loginWait`; show the window only when a mount still fails then,
        // or fails in a way that waiting cannot fix.
        let deadline = Date().addingTimeInterval(Self.loginWait)
        if await !Self.waitForNetwork(until: deadline) {
            loginLogger.notice("No network at login yet; trying to mount anyway.")
        }
        var pending = wanted.filter { !isMounted($0) }
        var failed = false
        var pause: Duration = .seconds(2)
        var attempt = 0
        while !pending.isEmpty {
            attempt += 1
            if extensionEnabled != true {
                await refreshExtensionState()
            }
            var retry: [JottacloudRemoteVolume] = []
            for location in pending where !isMounted(location) {
                guard await !mount(location) else {
                    continue
                }
                let error = lastMountError
                loginLogger.notice("Mount at login, attempt \(attempt, privacy: .public): failed (\(Self.describe(error), privacy: .public); JottaFS enabled: \(String(describing: self.extensionEnabled), privacy: .public)).")
                if !Self.isPermanentMountError(error), Date() < deadline {
                    retry.append(location)
                } else {
                    failed = true
                }
            }
            pending = retry
            guard !pending.isEmpty else {
                break
            }
            alert = nil
            try? await Task.sleep(for: pause)
            pause = min(pause * 2, .seconds(20))
            _ = await Self.waitForNetwork(until: deadline)
        }
        return !failed
    }

    /// How long a launch at login keeps trying before it shows a failed mount.
    private static let loginWait: TimeInterval = 180

    /// Errors that waiting cannot fix: the location is gone, or the sign-in
    /// is no longer valid. Everything else is retried at login.
    private static func isPermanentMountError(_ error: Error?) -> Bool {
        switch error {
        case JottacloudError.locationNotFound?, JottacloudError.tokenRefreshDisabled?, JottacloudError.invalidLoginToken?:
            return true
        default:
            return false
        }
    }

    /// Domain and code of an error, for the log (no user data).
    private static func describe(_ error: Error?) -> String {
        guard let error else {
            return "no error; not mounted"
        }
        let nsError = error as NSError
        var text = "\(nsError.domain) \(nsError.code)"
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " / \(underlying.domain) \(underlying.code)"
        }
        return text
    }

    /// Reads the locations to mount at login. Before 1.1 there was one
    /// switch, for the location saved in the credentials.
    private func loadLoginLocations(migrating saved: JottacloudCredentials?) {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.loginLocationsKey) == nil {
            let legacy = defaults.bool(forKey: Self.legacyMountAtLoginKey)
            defaults.set(
                legacy ? saved.map { [["Device": $0.device, "Mountpoint": $0.mountpoint]] } ?? [] : [],
                forKey: Self.loginLocationsKey
            )
            defaults.removeObject(forKey: Self.legacyMountAtLoginKey)
        }
        let stored = defaults.array(forKey: Self.loginLocationsKey) as? [[String: String]] ?? []
        loginLocations = stored.compactMap { entry in
            guard let device = entry["Device"], let mountpoint = entry["Mountpoint"] else {
                return nil
            }
            return JottacloudRemoteVolume(device: device, mountpoint: mountpoint)
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Once, when JottaFS works (signed in, file system extension on, window
    /// shown): offer to turn on the Finder extension, unless it is on.
    private func offerFinderExtensionIfNeeded() {
        guard extensionEnabled == true, phase == .signedIn, !launchedAtLogin,
              !UserDefaults.standard.bool(forKey: Self.offeredFinderExtensionKey),
              !FIFinderSyncController.isExtensionEnabled
        else {
            return
        }
        UserDefaults.standard.set(true, forKey: Self.offeredFinderExtensionKey)
        offersFinderExtension = true
    }

    /// The Finder extensions page of System Settings.
    func openFinderExtensionSettings() {
        FIFinderSyncController.showExtensionManagementInterface()
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

    /// The location's name in the user's language: "Arkiv" for Jottacloud's
    /// built-in "Archive" in Norwegian. Backed-up folders keep their names.
    static func ownName(of location: JottacloudRemoteVolume) -> String {
        guard location.isBuiltIn else {
            return location.mountpoint
        }
        return builtInLocationNames[location.mountpoint.lowercased()] ?? location.mountpoint
    }

    /// The translated names of Jottacloud's built-in locations, by
    /// lower-cased mountpoint. Saved for the extension, which names the
    /// disks with them (`JottaFSStorage.setBuiltInLocationNames`).
    static let builtInLocationNames: [String: String] = [
        "archive": String(localized: "Archive", comment: "Jottacloud's built-in location for files stored only in Jottacloud"),
        "sync": String(localized: "Sync", comment: "Jottacloud's built-in location for files synced with the user's devices"),
        "shared": String(localized: "Shared", comment: "Jottacloud's built-in location for folders shared with others"),
        "photos": String(localized: "Photos", comment: "Jottacloud's built-in location for photos and videos"),
    ]

    /// The name a location gets in Finder when the user has not chosen one.
    static func defaultName(of location: JottacloudRemoteVolume) -> String {
        JottaFSStorage.defaultVolumeName(mountpoint: ownName(of: location))
    }

    /// The location's name in Finder (a custom name, if set).
    func displayName(of location: JottacloudRemoteVolume) -> String {
        customName(of: location) ?? Self.defaultName(of: location)
    }

    /// The name the location has in Finder: while mounted, its volume's
    /// actual name (numbered, such as "Desktop (2)", if another volume had
    /// the name), else the name it gets at the next mount.
    func finderName(of location: JottacloudRemoteVolume) -> String {
        mounts[location.id]?.mountPoint.lastPathComponent ?? displayName(of: location)
    }

    /// `finderName(of:)`, or nil when it is the location's own name.
    func finderNameIfDifferent(of location: JottacloudRemoteVolume) -> String? {
        let name = finderName(of: location)
        return name == Self.defaultName(of: location) ? nil : name
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
        let value = trimmed.isEmpty || trimmed == Self.defaultName(of: location)
            ? nil : trimmed
        do {
            try JottaFSStorage.setCustomVolumeName(value, device: location.device, mountpoint: location.mountpoint)
            customNames[location.id] = value
        } catch {
            alert = AppAlert(title: String(localized: "JottaFS couldn’t save the name."), message: error.localizedDescription)
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
            },
            // Marks it for all processes and posts the notification that
            // handleSessionEnded() listens for.
            sessionEnded: { JottaFSStorage.markSessionEnded() }
        )
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
        title: String(localized: "Turn on JottaFS in System Settings."),
        message: String(localized: "Open System Settings → General → Login Items & Extensions → File System Extensions, and turn on JottaFS.")
    )

    private func signInAlert(for error: Error, usedToken: Bool) -> AppAlert {
        let title = String(localized: "JottaFS couldn’t sign you in.")
        if let error = error as? JottacloudError {
            switch error {
            case .invalidLoginToken:
                return AppAlert(title: title, message: String(localized: "That doesn’t look like a personal login token. Copy the whole token from Jottacloud and paste it again."))
            case .httpStatus(400), .httpStatus(401):
                return AppAlert(title: title, message: usedToken
                    ? String(localized: "This token has already been used or has expired. Create a new token in Jottacloud and try again.")
                    : String(localized: "Jottacloud didn’t accept the sign-in. Please try again."))
            case .browserLoginStateMismatch:
                return AppAlert(title: title, message: String(localized: "The sign-in didn’t match this window. Please try again."))
            case .browserLoginFailed:
                return AppAlert(title: title, message: String(localized: "Sign-in didn’t finish in the browser. Please try again."))
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
                return AppAlert(title: String(localized: "JottaFS can’t reach Jottacloud."), message: String(localized: "Check your internet connection and try again."))
            default:
                break
            }
        }
        if case JottacloudError.locationNotFound = error {
            return AppAlert(title: String(localized: "This location isn’t available any more."), message: String(localized: "Choose another location."))
        }
        if case JottacloudError.sessionEnded = error {
            // handleSessionEnded() signs out and explains it.
            return AppAlert(title: String(localized: "Your Jottacloud sign-in has ended."), message: String(localized: "Sign in again to use your Jottacloud disks. Your files stay in Jottacloud."))
        }
        if case JottacloudError.tokenRefreshDisabled = error {
            return AppAlert(title: String(localized: "Your sign-in has expired."), message: String(localized: "Sign out and sign in again."))
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
private let loginLogger = Logger(subsystem: "no.alrek.jottafs", category: "Login")

/// Lets a session's completion handler recognise its own session.
private final class SessionReference: @unchecked Sendable {
    weak var session: ASWebAuthenticationSession?
}

/// An error shown to the user in an alert.
struct AppAlert: Equatable {
    let title: String
    let message: String?
}
