import AppKit
import JottaFSCore
import SwiftUI

@main
struct JottaFSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // The window is created by the app delegate (AppKit), not by a SwiftUI
    // scene, so a launch at login never shows (or flashes) a window.
    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {}
        }
    }
}

/// Owns the model and the single JottaFS window. At login (macOS opened the
/// app as a login item) it creates no window and no Dock icon, mounts the
/// saved location and quits; the window only appears if that fails.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = AppModel()
    private let updater = Updater()
    private var window: NSWindow?
    private var launchedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        NSApp.setActivationPolicy(launchedAtLogin ? .accessory : .regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.launchedAtLogin = launchedAtLogin
        model.showWindow = { [weak self] in
            NSApp.setActivationPolicy(.regular)
            self?.showWindow()
            self?.updater.start()
        }
        if !launchedAtLogin {
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

    /// Clicking the Dock icon shows the window again.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
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
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: RootView().environmentObject(model).environmentObject(updater))
        // The window follows the fixed size of each screen.
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = "JottaFS"
        // Only the close button: no minimize, and no zoom (fixed size).
        window.styleMask = [.titled, .closable]
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
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
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
        .padding(32)
        // A fixed size per screen; the window is not resizable.
        .frame(width: windowSize.width - 64, height: windowSize.height - 64)
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

    }
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
                    .buttonStyle(.borderedProminent)
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
                .buttonStyle(.borderedProminent)
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
            Text("\(number)")
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
    @State private var confirmsSignOut = false
    /// The location the Advanced sheet is open for.
    @State private var advancedLocation: JottacloudRemoteVolume?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                AppIcon(size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.accountTitle)
                        .font(.title2.bold())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // Just the email: "Signed in as …" did not fit beside
                    // the Sign Out button.
                    Text(model.accountSubtitle ?? "Signed in to Jottacloud")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .layoutPriority(1)
                Spacer()
                Button("Sign Out…") {
                    confirmsSignOut = true
                }
                .disabled(model.isBusy)
            }

            UpdateBanner()

            if model.extensionEnabled == false {
                Notice(
                    systemImage: "exclamationmark.circle.fill",
                    title: "Allow JottaFS in System Settings",
                    message: "macOS needs your permission once before Jottacloud can appear in Finder. Turn on JottaFS under File System Extensions.",
                    buttonTitle: "Open System Settings",
                    action: model.openExtensionSettings
                )
            }

            Group {
                LocationPicker()

                HStack {
                    Toggle(isOn: Binding(
                        get: { model.mountAtLogin },
                        set: { model.setMountAtLogin($0) }
                    )) {
                        Text("Mount automatically when I log in")
                    }
                    Spacer()
                    Button("Advanced…") {
                        advancedLocation = model.selectedLocation
                    }
                    .disabled(model.selectedLocation == nil)
                }
                .disabled(model.isBusy)
            }
            // Nothing can be shown in Finder until JottaFS is allowed in
            // System Settings (the notice above explains it).
            .disabled(model.extensionEnabled == false)

            if model.loginItemNeedsApproval {
                Notice(
                    systemImage: "info.circle.fill",
                    title: "Allow JottaFS in Login Items",
                    message: "To open Jottacloud when you log in, macOS needs you to allow JottaFS in Login Items.",
                    buttonTitle: "Open Login Items",
                    action: model.openLoginItemsSettings
                )
            } else if model.progressAgentNeedsApproval {
                Notice(
                    systemImage: "info.circle.fill",
                    title: "See upload progress in Finder",
                    message: "Allow JottaFS in Login Items to see progress bars while files upload.",
                    buttonTitle: "Open Login Items",
                    action: model.openLoginItemsSettings
                )
            }

            FinderStatus()
                .disabled(model.extensionEnabled == false && model.mountURL == nil)

        }
        .sheet(item: $advancedLocation) { location in
            AdvancedSettingsView(location: location)
                .environmentObject(model)
        }
        .confirmationDialog(
            "Sign out of Jottacloud?",
            isPresented: $confirmsSignOut
        ) {
            Button("Sign Out", role: .destructive) {
                Task { await model.signOut() }
            }
        } message: {
            Text("Jottacloud will be unmounted and removed from Finder. Your files stay in Jottacloud.")
        }
    }
}

private struct LocationPicker: View {
    @EnvironmentObject private var model: AppModel
    @State private var scrollRequest = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose what to mount")
                .font(.headline)
            Text("Pick one of your Jottacloud locations. It appears in Finder like a disk, and you can switch at any time.")
                .foregroundStyle(.secondary)
            Group {
                if model.locations.isEmpty {
                    VStack(spacing: 10) {
                        if model.isLoadingLocations {
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
                        List(selection: selection) {
                            ForEach(groups, id: \.title) { group in
                                Section(group.title) {
                                    ForEach(group.locations) { location in
                                        LocationRow(
                                            location: location,
                                            isOpen: location.id == model.mountedLocationID,
                                            customName: model.customName(of: location)
                                        )
                                        .tag(location.id)
                                        .id(location.id)
                                        // Locked: other rows can't be selected
                                        // (the list still scrolls).
                                        .selectionDisabled(isLocked && location.id != lockedSelection)
                                        .opacity(isLocked && location.id != lockedSelection ? 0.45 : 1)
                                    }
                                }
                            }
                        }
                        .listStyle(.inset)
                        // Double-click (or Return) on a location mounts it,
                        // like the Mount button, while the list is unlocked.
                        .contextMenu(forSelectionType: String.self) { _ in
                            EmptyView()
                        } primaryAction: { ids in
                            guard !isLocked, model.extensionEnabled != false, let id = ids.first else {
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
                            scrollToMounted(proxy)
                        }
                        .onAppear { scrollToMounted(proxy) }
                        .onChange(of: model.mountedLocationID) { _, _ in scrollToMounted(proxy) }
                        .onChange(of: model.locations.count) { _, _ in scrollToMounted(proxy) }
                    }
                }
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        }
    }

    /// While a location is mounted (or the app is busy) the list stays
    /// scrollable but read-only: the mounted location stays selected and
    /// clicks on other rows are ignored. Unmount to choose another.
    private var isLocked: Bool {
        model.isBusy || model.mountURL != nil
    }

    private var lockedSelection: String? {
        model.mountedLocationID ?? model.selectedLocationID
    }

    private var selection: Binding<String?> {
        Binding(
            get: { isLocked ? lockedSelection : model.selectedLocationID },
            set: { newValue in
                guard !isLocked else {
                    return
                }
                model.selectedLocationID = newValue
            }
        )
    }

    /// Scrolls the mounted location into the middle of the list once the
    /// layout has settled (repeated calls in quick succession collapse into
    /// one scroll).
    private func scrollToMounted(_ proxy: ScrollViewProxy) {
        guard model.mountedLocationID != nil else {
            return
        }
        scrollRequest += 1
        let request = scrollRequest
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard request == scrollRequest, let id = model.mountedLocationID else {
                return
            }
            withAnimation {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    private var groups: [(title: String, locations: [JottacloudRemoteVolume])] {
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
            (device == JottacloudRemoteVolume.builtInDevice ? "Jottacloud" : "Backup from \(device)", byDevice[device] ?? [])
        }
    }
}

private struct LocationRow: View {
    let location: JottacloudRemoteVolume
    let isOpen: Bool
    var customName: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 20)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(location.mountpoint)
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
        guard location.isBuiltIn else {
            return "folder"
        }
        switch location.mountpoint.lowercased() {
        case "archive": return "archivebox"
        case "sync": return "arrow.triangle.2.circlepath"
        case "shared": return "person.2"
        default: return "folder"
        }
    }

    private var detail: String? {
        if let customName {
            return "Shown in Finder as “\(customName)”"
        }
        guard location.isBuiltIn else {
            return nil
        }
        switch location.mountpoint.lowercased() {
        case "archive": return "Files stored only in Jottacloud"
        case "sync": return "Files synced with your devices"
        case "shared": return "Folders shared with others"
        default: return nil
        }
    }
}

private struct FinderStatus: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmsUnmount = false

    var body: some View {
        // The list shows which location is mounted (a green checkmark); work
        // in progress shows in the button.
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer()
                // Mount (and open in Finder) when nothing is mounted; Unmount
                // while mounted. The list is locked while mounted.
                if model.mountURL != nil {
                    Button(role: .destructive) {
                        confirmsUnmount = true
                    } label: {
                        ButtonLabel(title: "Unmount", activity: model.activity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.large)
                    .help("Removes Jottacloud from Finder. Your files stay in Jottacloud.")
                } else {
                    Button {
                        Task { await model.mountSelected() }
                    } label: {
                        ButtonLabel(title: "Mount", activity: model.activity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.selectedLocation == nil)
                }
            }
            .disabled(model.isBusy)
        }
        .confirmationDialog(
            "Unmount “\(mountedName ?? "Jottacloud")”?",
            isPresented: $confirmsUnmount
        ) {
            Button("Unmount", role: .destructive) {
                Task { await model.disconnect() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It will be removed from Finder. Your files stay in Jottacloud. Close any files you have open from it first.")
        }
    }

    private var mountedName: String? {
        guard model.mountURL != nil,
              let mounted = model.mountedLocation ?? model.selectedLocation
        else {
            return nil
        }
        return model.displayName(of: mounted)
    }
}

/// Advanced options for the selected location: the name it has in Finder.
private struct AdvancedSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let location: JottacloudRemoteVolume
    @State private var name = ""

    private var defaultName: String {
        JottaFSStorage.defaultVolumeName(mountpoint: location.mountpoint)
    }

    private var isMounted: Bool {
        model.mountURL != nil && model.mountedLocationID == location.id
    }

    /// Empty means the location's own name.
    private var isValid: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || JottaFSStorage.validVolumeName(name) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Advanced")
                    .font(.title2.bold())
                Text(location.isBuiltIn ? location.mountpoint : "\(location.mountpoint) · Backup from \(location.device)")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Name in Finder")
                    .font(.headline)
                TextField(defaultName, text: $name)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isMounted)
                    .onSubmit(save)
                Group {
                    if isMounted {
                        Text("Unmount “\(model.displayName(of: location))” to change its name.")
                    } else if !isValid {
                        Text("This name can’t be used. Avoid “/” and “:”, and use a shorter name.")
                            .foregroundStyle(.red)
                    } else {
                        Text("The disk gets this name the next time you mount it. Leave it empty to use “\(defaultName)”.")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isMounted || !isValid)
            }
        }
        .padding(24)
        .frame(width: 380)
        .onAppear {
            name = model.customName(of: location) ?? ""
        }
    }

    private func save() {
        guard !isMounted, isValid else {
            return
        }
        model.setCustomName(name, for: location)
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
                    .buttonStyle(.borderedProminent)
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
        title: String,
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
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// A button title, or a spinner with "Mounting…"/"Unmounting…" while busy.
private struct ButtonLabel: View {
    let title: String
    let activity: AppModel.Activity?

    var body: some View {
        Group {
            if let activity {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(activity == .mounting ? "Mounting…" : "Unmounting…")
                }
            } else {
                Text(title)
            }
        }
        .frame(minWidth: 140)
    }
}

private struct Notice: View {
    let systemImage: String
    let title: String
    let message: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(buttonTitle, action: action)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}
