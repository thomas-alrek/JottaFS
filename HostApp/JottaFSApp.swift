import AppKit
import FinderSync
import FSKit
import JottaFSCore
import SwiftUI
import UserNotifications

@main
struct JottaFSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // The main window is created by the app delegate (AppKit), not by a
    // SwiftUI scene, so a launch at login never shows (or flashes) a window.
    // The Settings window (JottaFS → Settings…) only opens on request.
    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(appDelegate.model)
                .environmentObject(appDelegate.updater)
        }
        .commands {
            LocationCommands(model: appDelegate.model, window: appDelegate.windowState)
        }
    }
}

/// A device, for a sheet that needs only its name.
struct DeviceReference: Identifiable {
    let name: String
    var id: String { name.lowercased() }
}

/// What the main window shows on top of the list: sheets and confirmations.
/// Shared, so the menu bar commands can open them too.
@MainActor
final class WindowState: ObservableObject {
    /// The location being renamed.
    @Published var renaming: JottacloudRemoteVolume?
    /// The device whose description is being changed.
    @Published var describing: DeviceReference?
    /// The "new backup device / new location" sheet.
    @Published var locationSheet: LocationSheet?
    /// A removal waiting for its confirmation.
    @Published var removal: RemovalRequest?
    /// The location whose Unmount is being confirmed.
    @Published var confirmsUnmount: JottacloudRemoteVolume?
    /// Brings the main window to the front (set by the app delegate).
    var showMainWindow: () -> Void = {}
}

/// The menu bar commands for locations: File → New Backup Device and New
/// Location, and a Location menu with the actions of the selected location
/// (the same as its context menu).
private struct LocationCommands: Commands {
    @ObservedObject var model: AppModel
    @ObservedObject var window: WindowState

    private var location: JottacloudRemoteVolume? {
        model.phase == .signedIn ? model.selectedLocation : nil
    }

    private var unavailable: Bool {
        model.phase != .signedIn || model.isBusy
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Backup Device…") {
                show { window.locationSheet = .newBackupDevice }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(unavailable || model.locations.isEmpty || model.extensionEnabled == false)
            Button(location.map { $0.isBuiltIn ? String(localized: "New Location…") : String(localized: "New Location in “\($0.device)”…") } ?? String(localized: "New Location…")) {
                if let location {
                    show { window.locationSheet = .newLocation(device: location.device) }
                }
            }
            .keyboardShortcut("n")
            .disabled(unavailable || location == nil || location?.isBuiltIn == true)
        }
        CommandMenu("Location") {
            if let location, model.isMounted(location) {
                Button("Show in Finder") {
                    Task { await model.mountSelected() }
                }
                .keyboardShortcut("o")
                .disabled(unavailable)
                Button("Unmount…") {
                    show { window.confirmsUnmount = location }
                }
                .keyboardShortcut("e")
                .disabled(unavailable || !model.canUnmount)
            } else if let location, model.mountedDevice(of: location) != nil {
                // A folder in its mounted device volume.
                Button("Show in Finder") {
                    Task { await model.mountSelected() }
                }
                .keyboardShortcut("o")
                .disabled(unavailable)
                Button("Unmount…") {}
                    .keyboardShortcut("e")
                    .disabled(true)
            } else {
                Button("Mount") {
                    Task { await model.mountSelected() }
                }
                .keyboardShortcut("o")
                .disabled(unavailable || location == nil || model.extensionEnabled == false)
                Button("Unmount…") {}
                    .keyboardShortcut("e")
                    .disabled(true)
            }
            Toggle("Mount at login", isOn: Binding(
                get: { location.map(model.mountsAtLogin) ?? false },
                set: { enabled in
                    if let location {
                        model.setMountAtLogin(enabled, for: location)
                    }
                }
            ))
            .disabled(unavailable || location == nil)
            Divider()
            Button("Rename…") {
                if let location {
                    show { window.renaming = location }
                }
            }
            .disabled(unavailable || location == nil)
            Divider()
            Button("Move to Trash…") {
                if let location {
                    show { window.removal = RemovalRequest(location: location, kind: .moveToTrash) }
                }
            }
            .keyboardShortcut(.delete)
            .disabled(unavailable || location == nil || location?.isBuiltIn == true || location?.isWholeDevice == true)
            Button(location.map { $0.isBuiltIn ? String(localized: "Delete Backup Device…") : String(localized: "Delete the backup device “\($0.device)”…") } ?? String(localized: "Delete Backup Device…")) {
                if let location {
                    show { window.removal = RemovalRequest(location: location, kind: .deleteBackupDevice) }
                }
            }
            .disabled(unavailable || location == nil || location?.isBuiltIn == true)
        }
    }

    /// Opens a sheet or confirmation on the main window, in front.
    private func show(_ change: () -> Void) {
        window.showMainWindow()
        change()
    }
}

/// A switch with a title and a line of explanation, in a Form row. It only
/// shows a state: switching it runs `action` (which opens System Settings,
/// where the user decides).
private struct SettingsSwitch: View {
    let isOn: Bool
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { isOn }, set: { _ in action() })) {
            Text(title)
            Text(detail)
        }
        .toggleStyle(.switch)
    }
}

/// App-wide settings, in a grouped Form like System Settings: the account,
/// the download cache (which the file system extension reads from the
/// shared settings), the extensions and update checks.
private struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var updater: Updater
    /// In MB; 0 is off.
    private static let sizes = [0, 256, 512, 1024, 2048, 4096, 8192]
    @State private var limit = JottaFSStorage.blockCacheLimitMB()
    @State private var used: UInt64 = 0
    @State private var finderExtensionEnabled = FIFinderSyncController.isExtensionEnabled
    /// Whether the file system extension is on (nil until read).
    @State private var fileSystemExtensionEnabled: Bool?
    @State private var confirmsClear = false
    @State private var confirmsSignOut = false
    @State private var failure: String?
    @AppStorage(Updater.automaticChecksKey) private var checksForUpdates = true
    @Environment(\.dismiss) private var dismiss

    /// The limit in bytes (MB in the settings are 1 048 576 bytes).
    private var limitBytes: UInt64 {
        UInt64(limit) * 1024 * 1024
    }

    var body: some View {
        Form {
            Section("Account") {
                if model.phase == .signedIn {
                    LabeledContent("Name", value: model.accountTitle)
                    if let email = model.accountSubtitle {
                        LabeledContent("Email", value: email)
                    }
                    LabeledContent {
                        Button("Sign Out…") {
                            confirmsSignOut = true
                        }
                        .disabled(model.isBusy)
                    } label: {
                        Text("Signed in to Jottacloud")
                    }
                } else {
                    Text("Not signed in. Sign in in the JottaFS window.")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Picker("Cache size", selection: $limit) {
                    ForEach(Self.sizes, id: \.self) { size in
                        Text(Self.title(for: size)).tag(size)
                    }
                }
                .onChange(of: limit) { _, newValue in
                    do {
                        try JottaFSStorage.setBlockCacheLimitMB(newValue)
                    } catch {
                        failure = String(localized: "JottaFS couldn’t save the setting.")
                    }
                }
                usage
            } header: {
                Text("Download Cache")
            } footer: {
                Text("JottaFS keeps recently downloaded file data on your Mac, so files you open again open immediately. When the cache is full, the oldest data is removed. A disk’s data is removed when you unmount it, and all of it when you restart your Mac.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("File System") {
                // macOS does not let an app turn its own extensions on or
                // off: the switch opens System Settings and then shows what
                // the user chose there (read every two seconds below).
                SettingsSwitch(
                    isOn: fileSystemExtensionEnabled ?? false,
                    title: "Jottacloud disks",
                    detail: fileSystemExtensionEnabled == false
                        ? "Turn on JottaFS under File System Extensions to mount Jottacloud locations as disks."
                        : "JottaFS can mount Jottacloud locations as disks in Finder.",
                    action: { _ = FSClient.shared.openFileSystemExtensionsSettings() }
                )
                .disabled(fileSystemExtensionEnabled == nil)
                .help("Opens File System Extensions in System Settings. Turn JottaFS on or off there.")
            }
            Section("Finder") {
                SettingsSwitch(
                    isOn: finderExtensionEnabled,
                    title: "Share links in Finder",
                    detail: finderExtensionEnabled
                        ? "Control-click a file or folder on a Jottacloud disk to copy its link."
                        : "Turn on JottaFS under Finder extensions to copy Jottacloud links from Finder.",
                    action: { FIFinderSyncController.showExtensionManagementInterface() }
                )
                .help("Opens the Finder extensions in System Settings. Turn JottaFS on or off there.")
            }
            Section("Updates") {
                Toggle(isOn: $checksForUpdates) {
                    Text("Check for updates automatically")
                    Text("JottaFS looks for a new version when it opens and once a day.")
                }
                .toggleStyle(.switch)
                .onChange(of: checksForUpdates) { _, enabled in
                    updater.setAutomaticChecks(enabled)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        // Signed out (here, in the window or because the sign-in ended):
        // the settings no longer apply to an account, so the window closes.
        .onChange(of: model.phase) { _, phase in
            if phase == .signedOut {
                dismiss()
            }
        }
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            // Keep the figures current while the window is open (the user
            // may turn the Finder extension on in System Settings).
            while !Task.isCancelled {
                used = JottaFSStorage.blockCacheSize()
                finderExtensionEnabled = FIFinderSyncController.isExtensionEnabled
                if let extensions = try? await FSClient.shared.installedExtensions {
                    fileSystemExtensionEnabled = extensions.first { $0.bundleIdentifier == AppModel.extensionBundleID }?.isEnabled ?? false
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .confirmationDialog("Clear the download cache?", isPresented: $confirmsClear) {
            Button("Clear Cache", role: .destructive) {
                do {
                    try JottaFSStorage.clearBlockCache()
                } catch {
                    failure = String(localized: "JottaFS couldn’t clear the cache.")
                }
                used = JottaFSStorage.blockCacheSize()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Files you open again are downloaded from Jottacloud again. Your files in Jottacloud are not changed.")
        }
        .confirmationDialog("Sign out of Jottacloud?", isPresented: $confirmsSignOut) {
            Button("Sign Out", role: .destructive) {
                Task { await model.signOut() }
            }
        } message: {
            Text("Your Jottacloud locations will be unmounted and removed from Finder. Your files stay in Jottacloud.")
        }
        .alert(failure ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") {}
        }
    }

    /// "384 MB of 2 GB used", a bar that fills up, and Clear Cache.
    private var usage: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if limit > 0 {
                    Text("\(Self.bytes(used)) of \(Self.bytes(limitBytes)) used")
                } else if used > 0 {
                    Text("The cache is off. \(Self.bytes(used)) is still stored.")
                } else {
                    Text("The cache is off.")
                }
            }
            .monospacedDigit()
            if limit > 0 {
                ProgressView(value: Double(min(used, limitBytes)), total: Double(max(limitBytes, 1)))
                    .progressViewStyle(.linear)
                    .tint(used * 10 >= limitBytes * 9 ? .orange : .accentColor)
                    .accessibilityLabel("Cache used")
                    .accessibilityValue("\(Self.bytes(used)) of \(Self.bytes(limitBytes))")
            }
            HStack {
                Spacer()
                Button("Clear Cache…", role: .destructive) {
                    confirmsClear = true
                }
                .disabled(used == 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "384 MB", "2 GB" (binary units, like the size choices).
    private static func bytes(_ value: UInt64) -> String {
        Int64(clamping: value).formatted(.byteCount(style: .memory))
    }

    private static func title(for size: Int) -> String {
        switch size {
        case 0: String(localized: "Off")
        case let size where size >= 1024 && size % 1024 == 0: "\(size / 1024) GB"
        default: "\(size) MB"
        }
    }
}

/// Owns the model and the single JottaFS window. At login (started by the
/// launch agent with `--mount-at-login`) it creates no window and no Dock
/// icon, mounts the locations chosen for login and quits; the window only
/// appears if that fails.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel()
    let updater = Updater()
    let windowState = WindowState()
    private var window: NSWindow?
    private var launchedAtLogin = false
    private var launchedToRefresh = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Started at login by the launch agent (no.alrek.jottafs.login),
        // which passes this argument; any other launch is a normal one.
        launchedAtLogin = CommandLine.arguments.contains(AppModel.mountAtLoginArgument)
        // Started by the refresh agent (no.alrek.jottafs.refresh) to keep
        // the sign-in alive: also hidden.
        launchedToRefresh = CommandLine.arguments.contains(AppModel.refreshSessionArgument)
        // The app starts without a Dock icon (LSUIElement); a normal launch
        // becomes a regular Dock app with a menu bar here, before any window.
        NSApp.setActivationPolicy(launchedAtLogin || launchedToRefresh ? .accessory : .regular)
        // Before launching finishes, so a click on a notification that
        // started the app is delivered too.
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Never reopened by macOS after a restart or log-in ("Reopen windows
        // when logging back in"): such a launch looks like a normal one and
        // shows the window. Mount at login uses the login item instead.
        NSApp.disableRelaunchOnLogin()
        model.launchedAtLogin = launchedAtLogin
        model.launchedToRefresh = launchedToRefresh
        model.showWindow = { [weak self] in
            NSApp.setActivationPolicy(.regular)
            self?.showWindow()
            self?.updater.start()
        }
        model.backgroundWork = { [updater] in
            await updater.checkInBackground()
        }
        windowState.showMainWindow = { [weak self] in
            self?.showWindow()
        }
        if !launchedAtLogin, !launchedToRefresh {
            showWindow()
            updater.start()
        }
        Task { await model.start() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if window != nil, model.phase == .signedIn {
            Task { await model.refreshSystemState() }
        }
    }

    /// JottaFS's notifications (an update, names Jottacloud cannot store)
    /// also show while JottaFS is in front.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    /// A click on a notification opens the window (also when JottaFS runs
    /// hidden, at login or to refresh the sign-in).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run {
            _ = applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        }
    }

    /// Clicking the Dock icon shows the window again.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Opened by the user while the login item was still mounting: become
        // a normal app and stay open.
        if model.launchedAtLogin || model.launchedToRefresh {
            model.launchedAtLogin = false
            model.launchedToRefresh = false
            NSApp.setActivationPolicy(.regular)
            updater.start()
        }
        showWindow()
        return true
    }

    /// The window is not user-resizable; it only changes size when the
    /// screen changes (sign-in ↔ account), and is centered again then.
    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else {
            return
        }
        Self.centerExactly(window)
    }

    /// Closing the window quits the app.
    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }

    private func showWindow() {
        if let window {
            Self.bringToFront(window)
            return
        }
        let hosting = NSHostingController(rootView: RootView().environmentObject(model).environmentObject(updater).environmentObject(windowState))
        // The window follows the fixed size of each screen.
        hosting.sizingOptions = [.preferredContentSize]
        // SwiftUI toolbar items (Settings, account) go to the window's
        // toolbar, in the Liquid Glass layer above the content.
        hosting.sceneBridgingOptions = [.toolbars]
        let window = NSWindow(contentViewController: hosting)
        window.title = "JottaFS"
        // Only the close button: no minimize, and no zoom (fixed size).
        // The content reaches under the transparent title bar, so the
        // window's blurred background (`WindowBackground`) fills it all.
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        // Size the window to its content before centering: the hosting
        // controller would otherwise apply the size only after it is shown.
        hosting.view.layoutSubtreeIfNeeded()
        let size = hosting.view.fittingSize
        if size.width > 0, size.height > 0 {
            window.setContentSize(size)
        }
        Self.centerExactly(window)
        self.window = window
        Self.bringToFront(window)
    }

    /// Makes JottaFS the active app with `window` in front. The app starts
    /// as a background app (`LSUIElement`), so macOS does not activate it at
    /// launch, and since macOS 14 `NSApp.activate()` is only a request. So it
    /// also uses the older forcing call, orders the window front regardless,
    /// and tries once more after the switch to a regular app has taken
    /// effect.
    private static func bringToFront(_ window: NSWindow) {
        NSApp.activate()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard !NSApp.isActive, window.isVisible else {
                return
            }
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Centers exactly (`NSWindow.center()` places windows above the middle).
    static func centerExactly(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else {
            return
        }
        let visible = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: (visible.midX - size.width / 2).rounded(),
            y: (visible.midY - size.height / 2).rounded()
        ))
    }
}

// MARK: - Root

private struct RootView: View {
    @EnvironmentObject private var model: AppModel
    #if DEBUG
    @EnvironmentObject private var windowState: WindowState
    @Environment(\.openSettings) private var openSettings
    #endif

    /// Each screen has its own fixed size: sign-in and progress screens are
    /// compact; the account screen has room for the location list.
    private var windowSize: CGSize {
        model.phase == .signedIn ? CGSize(width: 480, height: 660) : CGSize(width: 480, height: 480)
    }

    var body: some View {
        Group {
            switch model.phase {
            case .starting:
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .signedOut:
                SignInView()
            case .waitingForBrowser:
                WaitingForBrowserView()
            case .finishingSignIn:
                VStack(spacing: 16) {
                    ProgressView().controlSize(.large)
                    Text("Signing in…").font(.title3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .signedIn:
                SignedInView()
            }
        }
        // Apple's usual 20 pt margins; little at the top, where the title
        // bar and toolbar already leave room.
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 20)
        // A fixed size per screen; the window is not resizable.
        .frame(width: windowSize.width - 48, height: windowSize.height - 28)
        // Standard buttons in the content; Liquid Glass is for the toolbar
        // and the one main action of each screen (.glassProminent).
        // What is behind the window shows through, blurred.
        .background {
            WindowBackground()
                .ignoresSafeArea()
        }
        // Errors show in an alert, so the window layout never changes.
        .alert(
            model.alert?.title ?? "",
            isPresented: Binding(
                get: { model.alert != nil },
                set: { if !$0 { model.alert = nil } }
            ),
            presenting: model.alert
        ) { _ in
            Button("OK", role: .cancel) {
                model.alert = nil
            }
        } message: { alert in
            if let message = alert.message {
                Text(message)
            }
        }
        #if DEBUG
        // Screenshots of the Settings window and the sheets without
        // scripted clicks: --preview-settings, --preview-sheet=<kind>.
        .task(id: model.locations.count) {
            let arguments = CommandLine.arguments
            if arguments.contains("--preview-settings") {
                openSettings()
            }
            guard let location = model.locations.first(where: { !$0.isBuiltIn }) else {
                return
            }
            if arguments.contains("--preview-sheet=device") {
                windowState.locationSheet = .newBackupDevice
            } else if arguments.contains("--preview-sheet=location") {
                windowState.locationSheet = .newLocation(device: location.device)
            } else if arguments.contains("--preview-sheet=rename") {
                windowState.renaming = model.locations.first { model.isMounted($0) } ?? location
            } else if arguments.contains("--preview-menu=device") {
                windowState.removal = RemovalRequest(location: location, kind: .deleteBackupDevice)
            }
        }
        #endif

    }
}

/// The window's background: what is behind the window, blurred (the
/// material macOS uses for window backgrounds that let the desktop show
/// through). Liquid Glass stays for the toolbar and the buttons on top.
private struct WindowBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        // Like other windows: less see-through while inactive.
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct AppIcon: View {
    var size: CGFloat

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: - Signing in

private struct SignInView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showsTokenSignIn = false

    var body: some View {
        if showsTokenSignIn {
            TokenSignInView(isShown: $showsTokenSignIn)
        } else {
            VStack(spacing: 20) {
                Spacer(minLength: 0)
                AppIcon(size: 72)
                VStack(spacing: 8) {
                    Text("Welcome to JottaFS")
                        .font(.largeTitle.bold())
                    Text("Work with your Jottacloud files in Finder, just like files on your Mac.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 8) {
                    Button {
                        model.signInWithBrowser()
                    } label: {
                        Text("Sign In with Jottacloud")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    Text("You sign in on jottacloud.com in your browser. JottaFS never sees your password.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button("Sign in with a personal login token instead") {
                    model.alert = nil
                    showsTokenSignIn = true
                }
                .buttonStyle(.link)
                Spacer(minLength: 0)
            }
        }
    }
}

/// Signing in with a personal login token: its own screen, reached from the
/// sign-in screen's secondary link.
private struct TokenSignInView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var isShown: Bool
    @State private var token = ""

    private static let securitySettingsURL = URL(string: "https://www.jottacloud.com/web/secure")!

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                AppIcon(size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sign in with a token")
                        .font(.title2.bold())
                    Text("If you’d rather not sign in through the browser.")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Step(number: 1) {
                    HStack {
                        Text("Open your Jottacloud security settings.")
                        Spacer()
                        Button("Open") {
                            NSWorkspace.shared.open(Self.securitySettingsURL)
                        }
                    }
                }
                Step(number: 2) {
                    Text("Under **Personal login token**, choose **Generate** and copy the token.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                Step(number: 3) {
                    SecureField("Paste the token here", text: $token)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(signIn)
                }
            }

            Text("A token works once. After that, JottaFS keeps you signed in, so you don’t need to keep the token.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            HStack {
                Button("Back") {
                    token = ""
                    model.alert = nil
                    isShown = false
                }
                .controlSize(.large)
                Spacer()
                Button(action: signIn) {
                    Text("Sign In")
                        .frame(minWidth: 100)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func signIn() {
        let value = token
        token = ""
        Task { await model.signIn(withToken: value) }
    }
}

private struct Step<Content: View>: View {
    let number: Int
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: "\(number)")
                .font(.callout.bold())
                .frame(width: 22, height: 22)
                .background(Circle().fill(.tint.opacity(0.15)))
                .accessibilityHidden(true)
            content
        }
    }
}

private struct WaitingForBrowserView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            ProgressView()
                .controlSize(.large)
            Text("Continue in your browser")
                .font(.title2.bold())
            Text("Sign in to Jottacloud in the window that just opened. It closes by itself, and JottaFS continues automatically when you’re done.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel") {
                    model.cancelSignIn()
                }
                Button("Start Over") {
                    model.signInWithBrowser()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Signed in

private struct SignedInView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var window: WindowState

    private var staleNames: String {
        RemovalConfirmation.names(model.staleMounts, model: model, finder: true)
    }

    private var staleTitle: String {
        model.staleMounts.count == 1
            ? String(localized: "\(staleNames) uses an older version of JottaFS")
            : String(localized: "Some disks use an older version of JottaFS")
    }

    private var staleMessage: String {
        model.staleMounts.count == 1
            ? String(localized: "The disk was mounted before JottaFS was updated, or by another copy of JottaFS. It gets the changes of this version when it is mounted again.")
            : String(localized: "\(staleNames) were mounted before JottaFS was updated, or by another copy of JottaFS. They get the changes of this version when they are mounted again.")
    }

    /// The app that holds an extension, with "~" for the home folder:
    /// ".../JottaFS.app/Contents/Extensions/X.appex" → "~/…/JottaFS.app".
    static func shortPath(_ extensionURL: URL) -> String {
        let app = extensionURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = app.pathExtension == "app" ? app.path : extensionURL.path
        // The real home folder (in the sandbox, NSHomeDirectory() is the
        // app's container).
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            UpdateBanner()

            if model.extensionEnabled == false {
                Notice(
                    style: .warning,
                    systemImage: "exclamationmark.circle.fill",
                    title: "Allow JottaFS in System Settings",
                    message: "macOS needs your permission once before Jottacloud can appear in Finder. Turn on JottaFS under File System Extensions.",
                    buttonTitle: "Open System Settings",
                    action: model.openExtensionSettings
                )
            } else if let other = model.otherExtensionURL {
                // macOS runs the disks with another copy's extension (an
                // older version or a development build): this version's
                // changes would not apply.
                Notice(
                    style: .warning,
                    systemImage: "exclamationmark.circle.fill",
                    title: "Turn JottaFS off and on in System Settings",
                    message: "macOS uses the file system extension of another copy of JottaFS (\(Self.shortPath(other))). Turn JottaFS off and on again under File System Extensions, so that this version is used. If the message stays, delete the other copy.",
                    buttonTitle: "Open System Settings",
                    action: model.openExtensionSettings
                )
            } else if !model.staleMounts.isEmpty {
                // Disks mounted before an update keep the old extension
                // until they are mounted again.
                Notice(
                    style: .warning,
                    systemImage: "exclamationmark.circle.fill",
                    title: Text(staleTitle),
                    message: Text(staleMessage),
                    buttonTitle: Text("Mount Again"),
                    action: { Task { await model.remountStaleLocations() } }
                )
                .disabled(model.isBusy)
            }

            LocationPicker()
                // Nothing can be shown in Finder until JottaFS is allowed in
                // System Settings (the notice above explains it).
                .disabled(model.extensionEnabled == false)

            if model.loginItemNeedsApproval {
                Notice(
                    style: .information,
                    systemImage: "info.circle.fill",
                    title: "Allow JottaFS in Login Items",
                    message: "To open Jottacloud when you log in, macOS needs you to allow JottaFS in Login Items.",
                    buttonTitle: "Open Login Items",
                    action: model.openLoginItemsSettings
                )
            } else if model.progressAgentNeedsApproval {
                Notice(
                    style: .information,
                    systemImage: "info.circle.fill",
                    title: "See upload progress in Finder",
                    message: "Allow JottaFS in Login Items to see progress bars while files upload.",
                    buttonTitle: "Open Login Items",
                    action: model.openLoginItemsSettings
                )
            }

            // The selected location: mount at login, and Mount or Unmount.
            HStack {
                Toggle(isOn: Binding(
                    get: { model.selectedLocation.map(model.mountsAtLogin) ?? false },
                    set: { enabled in
                        if let location = model.selectedLocation {
                            model.setMountAtLogin(enabled, for: location)
                        }
                    }
                )) {
                    Text("Mount at login")
                }
                .help(model.selectedLocation.map { String(localized: "Mount “\(model.displayName(of: $0))” automatically when you log in.") } ?? "")
                .disabled(model.selectedLocation == nil || model.isBusy || model.extensionEnabled == false)
                Spacer()
                FinderStatus()
                    .disabled(model.extensionEnabled == false && model.mounts.isEmpty)
            }
        }
        .sheet(item: $window.locationSheet) { sheet in
            NewLocationView(kind: sheet)
                .environmentObject(model)
        }
        .sheet(item: $window.renaming) { location in
            RenameView(location: location)
                .environmentObject(model)
        }
        .sheet(item: $window.describing) { device in
            DescriptionView(device: device.name)
                .environmentObject(model)
        }
        .toolbar {
            // In the window's toolbar (the Liquid Glass layer); the labels
            // are for VoiceOver, the icons are what shows.
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    window.locationSheet = .newBackupDevice
                } label: {
                    Label("New Backup Device…", systemImage: "plus")
                }
                .help("New Backup Device…")
                .disabled(model.isBusy || model.locations.isEmpty || model.extensionEnabled == false)
                // Opens the Settings window, like JottaFS → Settings….
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings")
            }
        }
        .alert("Copy Jottacloud links from Finder?", isPresented: $model.offersFinderExtension) {
            Button("Turn On…") {
                model.openFinderExtensionSettings()
            }
            .keyboardShortcut(.defaultAction)
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("Turn on JottaFS under Finder extensions in System Settings. Then you can Control-click a file or folder on a Jottacloud disk and copy a link to share it. You can also do this later in JottaFS Settings.")
        }
    }
}
/// A removal waiting for its confirmation.
struct RemovalRequest: Identifiable {
    enum Kind {
        case moveToTrash
        case deleteBackupDevice
    }

    let location: JottacloudRemoteVolume
    let kind: Kind

    var id: String {
        location.id + (kind == .moveToTrash ? "|trash" : "|delete")
    }
}

/// The confirmations for moving a location to the trash and deleting a
/// backup device, with what will happen (a location's context menu and a
/// backup device's section header); runs the removal once confirmed.
private struct RemovalConfirmation: ViewModifier {
    @EnvironmentObject private var model: AppModel
    @Binding var request: RemovalRequest?
    var started: () -> Void = {}
    /// nil when it worked, else the error to show.
    var finished: (String?) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            title,
            isPresented: Binding(get: { request != nil }, set: { if !$0 { request = nil } }),
            presenting: request
        ) { request in
            Button(request.kind == .moveToTrash ? "Move to Trash" : "Delete", role: .destructive) {
                run(request)
            }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(message(for: request))
        }
    }

    private var title: String {
        guard let request else {
            return ""
        }
        switch request.kind {
        case .moveToTrash:
            return String(localized: "Move “\(AppModel.ownName(of: request.location))” to the Trash?")
        case .deleteBackupDevice:
            return String(localized: "Delete the backup device “\(request.location.device)”?")
        }
    }

    private func message(for request: RemovalRequest) -> String {
        let location = request.location
        switch request.kind {
        case .moveToTrash:
            var text = String(localized: "The location and its files move to the Jottacloud trash. You can restore them on jottacloud.com.")
            if model.isMounted(location) {
                text += " " + String(localized: "It is unmounted first.")
            }
            // A backup device without locations stays in Jottacloud but does
            // not show in the list (Jottacloud only lists devices with a
            // location).
            if model.locations(on: location.device).count == 1 {
                text += " " + String(localized: "It is the last location in “\(location.device)”: the backup device stays in Jottacloud without locations and no longer shows here. To remove the backup device too, use Delete Backup Device instead.")
            }
            return text
        case .deleteBackupDevice:
            let all = Self.names(model.locations(on: location.device), model: model, finder: false)
            var text = String(localized: "The backup device and everything in it are deleted for good: \(all). Nothing goes to the Jottacloud trash, and it can’t be restored.")
            let mounted = model.mountedLocations(on: location.device)
            if !mounted.isEmpty {
                text += " " + String(localized: "These are unmounted first: \(Self.names(mounted, model: model, finder: true)).")
            }
            return text
        }
    }

    private func run(_ request: RemovalRequest) {
        started()
        Task {
            do {
                switch request.kind {
                case .moveToTrash:
                    try await model.moveLocationToTrash(request.location)
                case .deleteBackupDevice:
                    try await model.deleteBackupDevice(request.location.device)
                }
                finished(nil)
            } catch {
                finished(error.localizedDescription)
            }
        }
    }

    /// "“A”, “B” and “C”" for messages.
    static func names(_ locations: [JottacloudRemoteVolume], model: AppModel, finder: Bool) -> String {
        locations.map { location in
            let name = finder ? model.finderName(of: location) : AppModel.ownName(of: location)
            return String(localized: "“\(name)”", comment: "A name in quotation marks")
        }
        .formatted(.list(type: .and))
    }
}
private struct LocationPicker: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var window: WindowState
    @State private var scrollRequest = 0
    /// The list has keyboard focus when the window opens (arrow keys and
    /// Return work at once; the selection shows in the accent colour).
    @FocusState private var listFocused: Bool

    var body: some View {
        unmountConfirmation(listContent)
            .modifier(RemovalConfirmation(request: $window.removal) { failure in
                if let failure {
                    model.alert = AppAlert(title: String(localized: "JottaFS couldn’t remove the location."), message: failure)
                }
            })
    }

    private var listContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The explanation only until something is mounted.
            if model.mounts.isEmpty {
                Text("Choose what to mount")
                    .font(.headline)
                Text("Select a Jottacloud location and mount it. It appears in Finder like a disk. You can mount more than one.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Group {
                if model.locations.isEmpty {
                    VStack(spacing: 10) {
                        if model.isWaitingForNetwork {
                            ProgressView()
                            Text("Waiting for a network connection…")
                                .foregroundStyle(.secondary)
                        } else if model.isLoadingLocations {
                            ProgressView()
                            Text("Loading your locations…")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Your locations couldn’t be loaded.")
                                .foregroundStyle(.secondary)
                            Button("Try Again") {
                                Task { await model.loadLocations() }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        // A tree: each device (its own row, which mounts the
                        // whole device as one disk) with its locations
                        // indented under it.
                        List(selection: selection) {
                            ForEach(groups, id: \.device) { group in
                                DisclosureGroup(isExpanded: expansion(of: group.device)) {
                                    ForEach(group.locations) { location in
                                        LocationRow(
                                            location: location,
                                            isOpen: model.isMounted(location),
                                            finderName: model.finderNameIfDifferent(of: location),
                                            inVolume: model.mountedDevice(of: location).map(model.finderName),
                                            isSelected: model.selectedLocationID == location.id
                                        )
                                        .tag(location.id)
                                        .id(location.id)
                                    }
                                } label: {
                                    deviceRow(group)
                                        // The disclosure chevron is centred on
                                        // the label's first line of capitals
                                        // (half a cap height above its first
                                        // baseline): move that baseline so the
                                        // chevron sits at the middle of the
                                        // two-line row.
                                        .alignmentGuide(.firstTextBaseline) {
                                            $0[VerticalAlignment.center] + NSFont.preferredFont(forTextStyle: .body).capHeight / 2
                                        }
                                        .tag(group.whole.id)
                                        .id(group.whole.id)
                                }
                            }
                        }
                        .listStyle(.inset)
                        .focused($listFocused)
                        .defaultFocus($listFocused, true)
                        // Double-click (or Return) on a location mounts it,
                        // like the Mount button (a mounted one opens in
                        // Finder).
                        .contextMenu(forSelectionType: String.self) { ids in
                            if let id = ids.first, let location = (model.locations + model.wholeDevices).first(where: { $0.id == id }) {
                                contextMenu(for: location)
                            }
                        } primaryAction: { ids in
                            guard let id = ids.first else {
                                return
                            }
                            if let group = groups.first(where: { $0.whole.id == id }), !model.isMounted(group.whole) {
                                // A device opens or closes; mounting it (which
                                // unmounts its locations) stays an explicit
                                // action.
                                expansion(of: group.device).wrappedValue.toggle()
                                return
                            }
                            guard !model.isBusy, model.extensionEnabled != false else {
                                return
                            }
                            model.selectedLocationID = id
                            Task { await model.mountSelected() }
                        }
                        .frame(minHeight: 120, maxHeight: .infinity)
                        // Scroll again whenever the list's size or contents
                        // change: right after launch the window is still
                        // growing to the account screen's size.
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _ in
                            scrollToSelection(proxy)
                        }
                        .onAppear {
                            scrollToSelection(proxy)
                            // After the window has become key.
                            DispatchQueue.main.async { listFocused = true }
                        }
                        .onChange(of: model.locations.count) { _, _ in scrollToSelection(proxy) }
                    }
                }
            }
            // Rounded like the window and its controls (concentric with the
            // window's corners, at least 12 pt), not a fixed radius.
            .background(.background, in: Self.shape)
            .clipShape(Self.shape)
            .overlay(Self.shape.stroke(.separator, lineWidth: 1))
        }
    }

    private static let shape = ConcentricRectangle(corners: .concentric(minimum: .fixed(12)), isUniform: true)

    /// Right-click on a location: mount or unmount, mount at login, a new
    /// location, rename, move to the trash.
    @ViewBuilder
    private func contextMenu(for location: JottacloudRemoteVolume) -> some View {
        let mounted = model.isMounted(location)
        if model.mountedDevice(of: location) != nil {
            // A folder in its mounted device volume.
            Button("Show in Finder") {
                model.selectedLocationID = location.id
                Task { await model.mountSelected() }
            }
        } else if mounted {
            Button("Show in Finder") {
                model.selectedLocationID = location.id
                Task { await model.mountSelected() }
            }
            Button("Unmount…") {
                window.confirmsUnmount = location
            }
            .disabled(!model.canUnmount || model.isBusy)
        } else if location.isWholeDevice {
            Button("Mount as One Disk") {
                Task { await model.mountWholeDevice(location.device) }
            }
            .disabled(model.isBusy || model.extensionEnabled == false)
        } else {
            Button("Mount") {
                model.selectedLocationID = location.id
                Task { await model.mountSelected() }
            }
            .disabled(model.isBusy || model.extensionEnabled == false)
        }
        Toggle("Mount at login", isOn: Binding(
            get: { model.mountsAtLogin(location) },
            set: { model.setMountAtLogin($0, for: location) }
        ))
        .disabled(model.isBusy)
        Divider()
        if location.isWholeDevice, !location.isBuiltIn {
            Button("New Location…") {
                window.locationSheet = .newLocation(device: location.device)
            }
            .disabled(model.isBusy)
        } else if !location.isBuiltIn {
            Button("New Location in “\(location.device)”…") {
                window.locationSheet = .newLocation(device: location.device)
            }
            .disabled(model.isBusy)
        }
        Button("Rename…") {
            window.renaming = location
        }
        if location.isWholeDevice {
            Button("Edit Description…") {
                window.describing = DeviceReference(name: location.device)
            }
        }
        if !location.isBuiltIn, !location.isWholeDevice {
            Divider()
            Button("Move to Trash…", role: .destructive) {
                window.removal = RemovalRequest(location: location, kind: .moveToTrash)
            }
            .disabled(model.isBusy)
        } else if location.isWholeDevice, !location.isBuiltIn,
                  let first = model.locations(on: location.device).first {
            Divider()
            Button("Delete Backup Device…", role: .destructive) {
                window.removal = RemovalRequest(location: first, kind: .deleteBackupDevice)
            }
            .disabled(model.isBusy)
        }
    }

    /// The Unmount confirmation, for the Unmount button, the context menu
    /// and the menu bar.
    private func unmountConfirmation<Content: View>(_ content: Content) -> some View {
        content.confirmationDialog(
            "Unmount “\(window.confirmsUnmount.map(model.finderName) ?? "Jottacloud")”?",
            isPresented: Binding(get: { window.confirmsUnmount != nil }, set: { if !$0 { window.confirmsUnmount = nil } }),
            presenting: window.confirmsUnmount
        ) { location in
            Button("Unmount") {
                model.selectedLocationID = location.id
                Task { await model.unmountSelected() }
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It will be removed from Finder. Your files stay in Jottacloud. Close any files you have open from it first.")
        }
    }

    private var selection: Binding<String?> {
        Binding(
            get: { model.selectedLocationID },
            set: { model.selectedLocationID = $0 }
        )
    }

    /// Scrolls the selected location (at launch, a mounted one) into the
    /// middle of the list once the layout has settled (repeated calls in
    /// quick succession collapse into one scroll). Not on clicks: the row
    /// clicked is already visible.
    private func scrollToSelection(_ proxy: ScrollViewProxy) {
        guard model.selectedLocationID != nil else {
            return
        }
        scrollRequest += 1
        let request = scrollRequest
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard request == scrollRequest, let id = model.selectedLocationID else {
                return
            }
            withAnimation {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    /// A device's row: the whole device (select it to mount it as one
    /// disk), with "…" for its actions and, for a backup device, "+" for a
    /// new location in it.
    private func deviceRow(_ group: DeviceGroup) -> some View {
        HStack(spacing: 6) {
            LocationRow(
                location: group.whole,
                isOpen: model.isMounted(group.whole),
                finderName: model.finderNameIfDifferent(of: group.whole),
                deviceDescription: model.deviceDescription(of: group.device),
                isSelected: model.selectedLocationID == group.whole.id
            )
            let name = AppModel.ownName(of: group.whole)
            Menu {
                contextMenu(for: group.whole)
            } label: {
                Label("Actions for “\(name)”", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Actions for “\(name)”")
            .disabled(model.isBusy)
            if !group.whole.isBuiltIn {
                Button {
                    window.locationSheet = .newLocation(device: group.device)
                } label: {
                    Label("New Location in “\(group.device)”…", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("New Location in “\(group.device)”…")
                .disabled(model.isBusy)
            }
        }
    }

    /// Devices the user opened or closed in the list, by lower-cased name.
    /// The others are open only while one of their locations is mounted.
    @State private var openedDevices: [String: Bool] = [:]

    private func expansion(of device: String) -> Binding<Bool> {
        Binding(
            get: { openedDevices[device.lowercased()] ?? !model.mountedLocations(on: device).isEmpty },
            set: { openedDevices[device.lowercased()] = $0 }
        )
    }

    typealias DeviceGroup = (device: String, whole: JottacloudRemoteVolume, locations: [JottacloudRemoteVolume])

    /// One group per device: Jottacloud's own first, then the backup
    /// devices.
    private var groups: [DeviceGroup] {
        var order: [String] = []
        var byDevice: [String: [JottacloudRemoteVolume]] = [:]
        for location in model.locations {
            if byDevice[location.device] == nil {
                order.append(location.device)
            }
            byDevice[location.device, default: []].append(location)
        }
        // The built-in Jottacloud locations first, then backups.
        order.sort { lhs, rhs in
            (lhs == JottacloudRemoteVolume.builtInDevice ? 0 : 1, lhs) < (rhs == JottacloudRemoteVolume.builtInDevice ? 0 : 1, rhs)
        }
        return order.map { device in
            (device, JottacloudRemoteVolume.wholeDevice(device), byDevice[device] ?? [])
        }
    }
}
private struct LocationRow: View {
    let location: JottacloudRemoteVolume
    let isOpen: Bool
    /// The name in Finder, when it is not the location's own name.
    var finderName: String?
    /// The device volume the location is a folder in, when its device is
    /// mounted as one volume.
    var inVolume: String?
    /// For a device: the description the user gave it.
    var deviceDescription: String?
    /// The selected row: its icon takes the text colour.
    var isSelected = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 20)
                // The accent colour; in the selected row the text colour
                // (white on the accent-coloured selection, where an
                // accent-coloured icon would disappear).
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
            VStack(alignment: .leading, spacing: 1) {
                Text(AppModel.ownName(of: location))
                    .fontWeight(location.isWholeDevice ? .semibold : nil)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isOpen {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help("Mounted and available in Finder")
                    .accessibilityLabel("Mounted")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        if location.isWholeDevice {
            return location.isBuiltIn ? "cloud" : "desktopcomputer"
        }
        guard location.isBuiltIn else {
            return "folder"
        }
        switch location.mountpoint.lowercased() {
        case "archive": return "archivebox"
        case "sync": return "arrow.triangle.2.circlepath"
        case "shared": return "person.2"
        case "photos": return "photo.on.rectangle.angled"
        default: return "folder"
        }
    }

    private var detail: String? {
        if location.isWholeDevice {
            // The user's description; else, while mounted, what the disk
            // is, and otherwise what the device is.
            if let deviceDescription {
                return deviceDescription
            }
            if isOpen {
                return finderName.map { String(localized: "All locations as one disk, “\($0)”") }
                    ?? String(localized: "All locations as one disk")
            }
            return location.isBuiltIn ? String(localized: "Jottacloud’s own locations") : String(localized: "Backup device")
        }
        if let inVolume {
            return String(localized: "A folder in “\(inVolume)”")
        }
        if let finderName {
            return String(localized: "Shown in Finder as “\(finderName)”")
        }
        guard location.isBuiltIn else {
            return nil
        }
        switch location.mountpoint.lowercased() {
        case "archive": return String(localized: "Files stored only in Jottacloud")
        case "sync": return String(localized: "Files synced with your devices")
        case "shared": return String(localized: "Folders shared with others")
        case "photos": return String(localized: "Your photos and videos")
        default: return nil
        }
    }
}

/// Mount or Unmount for the selected location, by whether it is mounted.
private struct FinderStatus: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var window: WindowState

    var body: some View {
        Group {
            if model.selectedIsMounted, !model.canUnmount {
                // This build cannot unmount (no JottaFSService): the user
                // ejects the disk in Finder.
                Button {} label: {
                    ButtonLabel(title: "Mount", activity: nil)
                }
                .disabled(true)
                .help("Mounted. To unmount, eject “\(selectedName ?? String(localized: "the disk"))” in Finder.")
            } else if let location = model.selectedLocation, model.mountedDevice(of: location) != nil {
                // A folder in its mounted device volume: never mounted on
                // its own as well.
                Button {
                    Task { await model.mountSelected() }
                } label: {
                    ButtonLabel(title: "Show in Finder", activity: nil)
                }
                .keyboardShortcut(.defaultAction)
            } else if model.selectedIsMounted {
                // Not red: unmounting removes nothing from Jottacloud.
                Button {
                    window.confirmsUnmount = model.selectedLocation
                } label: {
                    ButtonLabel(title: "Unmount", activity: model.selectedActivity)
                }
                .help("Removes this location from Finder. Your files stay in Jottacloud.")
            } else {
                Button {
                    Task { await model.mountSelected() }
                } label: {
                    ButtonLabel(title: "Mount", activity: model.selectedActivity)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.selectedLocation == nil || model.extensionEnabled == false)
            }
        }
        // The screen's one main action.
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .disabled(model.isBusy)
    }

    private var selectedName: String? {
        model.selectedLocation.map(model.finderName)
    }
}

/// What the "+" buttons and New Backup Device create.
enum LocationSheet: Identifiable {
    case newBackupDevice
    case newLocation(device: String)

    var id: String {
        switch self {
        case .newBackupDevice: "device"
        case .newLocation(let device): "location:" + device
        }
    }
}

/// A sheet laid out like macOS's own: a grouped Form with the title in its
/// header, and the buttons below.
private struct SheetForm<Fields: View, Buttons: View>: View {
    let title: LocalizedStringKey
    let subtitle: String
    @ViewBuilder var fields: Fields
    @ViewBuilder var buttons: Buttons

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    fields
                } header: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.title2.bold())
                            .foregroundStyle(.primary)
                        Text(subtitle)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.bottom, 6)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                buttons
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 420)
    }
}

/// Creates a backup device (with its first location) or a location on a
/// backup device; the new location is selected, ready to mount.
private struct NewLocationView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let kind: LocationSheet
    @State private var name = ""
    @State private var firstLocation = String(localized: "Files")
    @State private var deviceDescription = ""
    @State private var failure: String?
    @State private var isCreating = false

    private var canCreate: Bool {
        !isCreating
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (kind.isLocation || !firstLocation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var title: LocalizedStringKey {
        kind.isLocation ? "New Location" : "New Backup Device"
    }

    private var subtitle: String {
        switch kind {
        case .newBackupDevice:
            String(localized: "A backup device holds locations that you can mount, like the backup of a computer. It shows under Backup on jottacloud.com.")
        case .newLocation(let device):
            String(localized: "In the backup device “\(device)”.")
        }
    }

    var body: some View {
        SheetForm(title: title, subtitle: subtitle) {
            TextField("Name", text: $name)
                .onSubmit(create)
            if !kind.isLocation {
                TextField("First location", text: $firstLocation)
                    .onSubmit(create)
                TextField("Description", text: $deviceDescription, prompt: Text("Optional"))
                    .onSubmit(create)
            }
            if let failure {
                Text(failure)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } buttons: {
            if isCreating {
                ProgressView()
                    .controlSize(.small)
                Text("Creating…")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel", role: .cancel) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button("Create", action: create)
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
        }
        .disabled(isCreating)
    }

    private func create() {
        guard canCreate else {
            return
        }
        failure = nil
        isCreating = true
        Task {
            defer { isCreating = false }
            do {
                switch kind {
                case .newBackupDevice:
                    try await model.createBackupDevice(named: name, firstLocation: firstLocation)
                    model.setDeviceDescription(deviceDescription, of: name.trimmingCharacters(in: .whitespacesAndNewlines))
                case .newLocation(let device):
                    try await model.createLocation(named: name, on: device)
                }
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

private extension LocationSheet {
    var isLocation: Bool {
        if case .newLocation = self { return true }
        return false
    }
}

/// Renames a location: the name its disk has in Finder. A mounted disk
/// gets the new name the next time it is mounted.
private struct RenameView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let location: JottacloudRemoteVolume
    @State private var name = ""

    private var defaultName: String {
        AppModel.defaultName(of: location)
    }

    private var isMounted: Bool {
        model.isMounted(location)
    }

    /// Empty means the location's own name.
    private var isValid: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || JottaFSStorage.validVolumeName(name) != nil
    }

    var body: some View {
        SheetForm(
            title: "Rename",
            subtitle: location.isWholeDevice
                ? String(localized: "All locations of “\(AppModel.ownName(of: location))” as one disk")
                : location.isBuiltIn ? AppModel.ownName(of: location) : String(localized: "\(location.mountpoint) · Backup from \(location.device)", comment: "A backed-up folder and the computer it is backed up from")
        ) {
            TextField("Name in Finder", text: $name, prompt: Text(defaultName))
                .onSubmit(save)
            Group {
                if !isValid {
                    Text("This name can’t be used. Avoid “/” and “:”, and use a shorter name.")
                        .foregroundStyle(.red)
                } else if isMounted {
                    Text("“\(model.finderName(of: location))” is mounted. The disk gets the new name the next time you mount it.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Leave it empty to use “\(defaultName)”.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        } buttons: {
            Spacer()
            Button("Cancel", role: .cancel) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button("Rename", action: save)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
        }
        .onAppear {
            name = model.customName(of: location) ?? ""
        }
    }

    private func save() {
        guard isValid else {
            return
        }
        model.setCustomName(name, for: location)
        dismiss()
    }
}

/// Changes a device's description: the line under its name in the list,
/// kept on this Mac (Jottacloud has no description for devices).
private struct DescriptionView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let device: String
    @State private var text = ""

    var body: some View {
        SheetForm(title: "Edit Description", subtitle: AppModel.ownName(of: .wholeDevice(device))) {
            TextField("Description", text: $text, prompt: Text("Optional"))
                .onSubmit(save)
            Text("Shown under the device’s name in JottaFS, on this Mac only.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } buttons: {
            Spacer()
            Button("Cancel", role: .cancel) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button("Save", action: save)
                .keyboardShortcut(.defaultAction)
        }
        .onAppear {
            text = model.deviceDescription(of: device) ?? ""
        }
    }

    private func save() {
        model.setDeviceDescription(text, of: device)
        dismiss()
    }
}

/// Offers a newer JottaFS release and shows the download and install.
/// Nothing shows while there is no update (or GitHub can't be reached).
private struct UpdateBanner: View {
    @EnvironmentObject private var updater: Updater

    var body: some View {
        switch updater.state {
        case .idle:
            EmptyView()
        case .available(let release):
            banner(systemImage: "arrow.down.circle.fill", title: "JottaFS \(release.version) is available.") {
                if let page = release.pageURL {
                    Button("What’s New") { NSWorkspace.shared.open(page) }
                        .buttonStyle(.link)
                }
                Spacer()
                Button("Later", action: updater.dismiss)
                Button("Update", action: updater.install)
                    .keyboardShortcut(.defaultAction)
            }
        case .downloading(let release, let progress):
            banner(systemImage: "arrow.down.circle.fill", title: "Downloading JottaFS \(release.version)…") {
                ProgressView(value: progress)
                Button("Cancel", action: updater.dismiss)
            }
        case .installing(let release):
            banner(systemImage: "arrow.down.circle.fill", title: "Installing JottaFS \(release.version)…") {
                ProgressView()
                    .controlSize(.small)
                Text("JottaFS opens again when it’s done.")
                    .foregroundStyle(.secondary)
            }
        case .failed(let release, let reason):
            banner(systemImage: "exclamationmark.circle.fill", title: "JottaFS \(release.version) couldn’t be installed.") {
                Text(reason)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Later", action: updater.dismiss)
                Button("Try Again", action: updater.install)
            }
        }
    }

    private func banner<Content: View>(
        systemImage: String,
        title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                HStack(spacing: 10) {
                    content()
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: ConcentricRectangle(corners: .concentric(minimum: .fixed(12)), isUniform: true))
    }
}

/// A button title, or a spinner with "Mounting…"/"Unmounting…" while busy.
private struct ButtonLabel: View {
    let title: LocalizedStringKey
    let activity: AppModel.Activity?

    var body: some View {
        Group {
            if let activity {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    if case .mounting = activity {
                        Text("Mounting…")
                    } else {
                        Text("Unmounting…")
                    }
                }
            } else {
                Text(title)
            }
        }
        .frame(minWidth: 140)
    }
}

/// A notice above the list: orange when something must be done, in the
/// accent colour when it is optional.
private struct Notice: View {
    enum Style {
        case warning
        case information
    }

    var style: Style = .warning
    let systemImage: String
    let title: Text
    let message: Text
    let buttonTitle: Text
    let action: () -> Void

    init(style: Style = .warning, systemImage: String, title: Text, message: Text, buttonTitle: Text, action: @escaping () -> Void) {
        self.style = style
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.buttonTitle = buttonTitle
        self.action = action
    }

    init(style: Style = .warning, systemImage: String, title: LocalizedStringKey, message: LocalizedStringKey, buttonTitle: LocalizedStringKey, action: @escaping () -> Void) {
        self.init(style: style, systemImage: systemImage, title: Text(title), message: Text(message), buttonTitle: Text(buttonTitle), action: action)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                title.font(.headline)
                message
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: action) {
                    buttonTitle
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(color.opacity(0.08), in: ConcentricRectangle(corners: .concentric(minimum: .fixed(12)), isUniform: true))
    }

    private var color: Color {
        style == .warning ? .orange : .accentColor
    }
}
