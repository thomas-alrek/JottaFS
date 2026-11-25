import AppKit
import FinderSync
import JottaFSCore
import OSLog
import UserNotifications

/// Finder context menu for files and folders on mounted JottaFS volumes:
/// **Copy Jottacloud Link** (shares the item publicly, or reuses its existing
/// link) and, for shared items only, **Stop Sharing**.
///
/// Finder only asks for menus inside `directoryURLs`, which are the mount
/// points of the JottaFS volumes (kept current as volumes mount and
/// unmount); every selected item is also checked again here. Items in the
/// Trash and the volume's top-level folder get no menu.
///
/// Finder needs the menu at once, so whether an item is shared comes from
/// a small cache: filled for the folders Finder shows (one listing request
/// each), by this extension's own Copy and Stop actions, and, for an item
/// not in it, by one request that waits at most `menuLookupTimeout`.
final class FinderSync: FIFinderSync {
    private let logger = Logger(subsystem: "no.alrek.jottafs.findersync", category: "Menu")
    private let shares = ShareCache()
    private var volumeObservers: [NSObjectProtocol] = []
    private static let menuLookupTimeout: TimeInterval = 0.4

    override init() {
        super.init()
        updateDirectories()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            volumeObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.updateDirectories()
            })
        }
    }

    /// Watches the mount points of the JottaFS volumes.
    private func updateDirectories() {
        let mounts = Set((JottaFSStorage.mountedVolumes() ?? []).map(\.mountPoint))
        if FIFinderSyncController.default().directoryURLs != mounts {
            FIFinderSyncController.default().directoryURLs = mounts
        }
    }

    // MARK: Share states of shown folders

    override func beginObservingDirectory(at url: URL) {
        guard let item = JottaFSItem(url: url) else {
            return
        }
        let shares = shares
        Task.detached {
            guard let client = JottaFSItem.client(),
                  let links = try? await client.shareLinks(inFolder: item.volume, path: item.path)
            else {
                return
            }
            shares.setFolder(item.path, volume: item.volume, links: links)
        }
    }

    // MARK: Menu

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems,
              let urls = FIFinderSyncController.default().selectedItemURLs(), !urls.isEmpty
        else {
            return nil
        }
        // Only for items on JottaFS volumes (all of them).
        let items = urls.compactMap(JottaFSItem.init(url:))
        guard items.count == urls.count, items.allSatisfy({ !$0.path.isEmpty && !$0.isInTrash }) else {
            return nil
        }
        let menu = NSMenu(title: "")
        let copy = NSMenuItem(
            title: items.count == 1 ? String(localized: "Copy Jottacloud Link") : String(localized: "Copy Jottacloud Links"),
            action: #selector(copyLinks(_:)),
            keyEquivalent: ""
        )
        copy.image = Self.menuIcon("link")
        menu.addItem(copy)
        if items.allSatisfy({ isShared($0) }) {
            let stop = NSMenuItem(
                title: items.count == 1 ? String(localized: "Stop Sharing Jottacloud Link") : String(localized: "Stop Sharing Jottacloud Links"),
                action: #selector(stopSharing(_:)),
                keyEquivalent: ""
            )
            stop.image = Self.menuIcon("minus.circle")
            menu.addItem(stop)
        }
        return menu
    }

    /// An SF Symbol in the menu's text colour for the current light or dark
    /// appearance. Finder draws template images from a Finder Sync extension
    /// black in dark mode, so the symbol gets a fixed colour (a palette);
    /// it stays a symbol at its normal size (a bitmap is shown too small).
    /// The menu is built again for every click, so it follows appearance
    /// changes.
    private static func menuIcon(_ name: String) -> NSImage? {
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        var color = NSColor.black
        appearance.performAsCurrentDrawingAppearance {
            color = NSColor.labelColor.usingColorSpace(.sRGB) ?? .black
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color]))
        image?.isTemplate = false
        return image
    }

    /// Whether an item is shared: from the cache, else asked once (waiting
    /// at most `menuLookupTimeout`; unknown counts as not shared).
    private func isShared(_ item: JottaFSItem) -> Bool {
        if let known = shares.state(of: item) {
            return known
        }
        let result = SharedResult()
        let done = DispatchSemaphore(value: 0)
        let shares = shares
        Task.detached {
            defer { done.signal() }
            guard let client = JottaFSItem.client() else {
                return
            }
            do {
                let link = try await client.shareLink(volume: item.volume, path: item.path)
                shares.set(item, link: link)
                result.value = link != nil
            } catch {
                // Unknown: no Stop Sharing this time.
            }
        }
        _ = done.wait(timeout: .now() + Self.menuLookupTimeout)
        return result.value ?? false
    }

    // MARK: Actions

    @objc private func copyLinks(_ sender: AnyObject?) {
        let items = (FIFinderSyncController.default().selectedItemURLs() ?? []).compactMap(JottaFSItem.init(url:))
        guard !items.isEmpty else {
            return
        }
        let shares = shares
        let logger = logger
        Task.detached {
            guard let client = JottaFSItem.client() else {
                await Self.notify(String(localized: "JottaFS isn’t signed in."), body: String(localized: "Open JottaFS and sign in to Jottacloud."))
                return
            }
            var links: [String] = []
            do {
                for item in items {
                    let link = try await client.enableSharing(volume: item.volume, path: item.path)
                    shares.set(item, link: link)
                    links.append(link.absoluteString)
                }
            } catch {
                logger.error("Sharing failed (\((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public)).")
                await Self.notify(String(localized: "JottaFS couldn’t create the link."), body: String(localized: "Check your internet connection and try again."))
                return
            }
            let text = links.joined(separator: "\n")
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            await Self.notify(
                items.count == 1 ? String(localized: "Link copied") : String(localized: "\(items.count) links copied"),
                body: items.count == 1
                    ? String(localized: "Anyone with the link can open “\(items[0].name)”.")
                    : String(localized: "Anyone with the links can open these items.")
            )
        }
    }

    @objc private func stopSharing(_ sender: AnyObject?) {
        let items = (FIFinderSyncController.default().selectedItemURLs() ?? []).compactMap(JottaFSItem.init(url:))
        guard !items.isEmpty else {
            return
        }
        let shares = shares
        let logger = logger
        Task.detached {
            guard let client = JottaFSItem.client() else {
                await Self.notify(String(localized: "JottaFS isn’t signed in."), body: String(localized: "Open JottaFS and sign in to Jottacloud."))
                return
            }
            do {
                for item in items {
                    try await client.disableSharing(volume: item.volume, path: item.path)
                    shares.set(item, link: nil)
                }
            } catch {
                logger.error("Stop sharing failed (\((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public)).")
                await Self.notify(String(localized: "JottaFS couldn’t stop sharing."), body: String(localized: "Check your internet connection and try again."))
                return
            }
            await Self.notify(
                String(localized: "Sharing stopped"),
                body: items.count == 1 ? String(localized: "The link to “\(items[0].name)” no longer works.") : String(localized: "The links to these items no longer work.")
            )
        }
    }

    /// A notification from JottaFS (macOS asks the user once whether to
    /// allow them; without permission the action still works).
    private static func notify(_ title: String, body: String) async {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert])) == true else {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

/// Set from a detached task, read after a bounded wait.
private final class SharedResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?
    var value: Bool? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// A file or folder on a mounted JottaFS volume: its Jottacloud location and
/// path inside it.
struct JottaFSItem: Sendable {
    let volume: JottacloudRemoteVolume
    /// Path inside the location ("" is the volume's top-level folder).
    let path: String

    var name: String {
        (path as NSString).lastPathComponent
    }

    var isInTrash: Bool {
        path == ".Trashes" || path.hasPrefix(".Trashes/") || path == ".VolumeIcon.icns"
    }

    var key: String {
        "\(volume.id.lowercased())/\(path.lowercased())"
    }

    /// Nil unless `url` is on a mounted JottaFS volume whose location is
    /// known.
    init?(url: URL) {
        let path = url.standardizedFileURL.path
        guard let mounted = JottaFSStorage.mountedVolumes()?.first(where: {
            path == $0.mountPoint.path || path.hasPrefix($0.mountPoint.path + "/")
        }) else {
            return nil
        }
        let location: (device: String, mountpoint: String)?
        if mounted.anchorName.isEmpty {
            location = Self.credentials().map { ($0.device, $0.mountpoint) }
        } else {
            location = JottaFSStorage.location(ofAnchor: mounted.anchorURL)
        }
        guard let location else {
            return nil
        }
        volume = JottacloudRemoteVolume(device: location.device, mountpoint: location.mountpoint)
        self.path = String(path.dropFirst(mounted.mountPoint.path.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func credentials() -> JottacloudCredentials? {
        JottaFSStorage.credentialsDirectoryURL().flatMap { try? JottaFSStorage.loadCredentials(from: $0) }
    }

    /// A client using the app's saved sign-in (rotated tokens are saved
    /// with the same lock as the app and the file system extension).
    static func client() -> JottacloudClient? {
        guard let directory = JottaFSStorage.credentialsDirectoryURL(),
              let credentials = try? JottaFSStorage.loadCredentials(from: directory)
        else {
            return nil
        }
        return JottacloudClient(
            credentials: credentials,
            persistCredentials: { try JottaFSStorage.saveTokens(of: $0, to: directory) },
            loadSavedCredentials: { try? JottaFSStorage.loadCredentials(from: directory) }
        )
    }
}

/// Known share states, by item, for a few minutes.
final class ShareCache: @unchecked Sendable {
    private static let lifetime: TimeInterval = 300
    private let lock = NSLock()
    private var states: [String: (shared: Bool, time: Date)] = [:]

    /// True or false if known and recent, else nil.
    func state(of item: JottaFSItem) -> Bool? {
        lock.withLock {
            guard let entry = states[item.key], Date().timeIntervalSince(entry.time) < Self.lifetime else {
                return nil
            }
            return entry.shared
        }
    }

    func set(_ item: JottaFSItem, link: URL?) {
        lock.withLock {
            states[item.key] = (link != nil, Date())
        }
    }

    /// Records a folder listing's links. Only shared items are listed, so
    /// the others are left unknown (asked when their menu opens).
    func setFolder(_ path: String, volume: JottacloudRemoteVolume, links: [String: URL]) {
        lock.withLock {
            let now = Date()
            for (name, _) in links {
                let child = path.isEmpty ? name : "\(path)/\(name)"
                states["\(volume.id.lowercased())/\(child.lowercased())"] = (true, now)
            }
            if states.count > 10_000 {
                states = states.filter { now.timeIntervalSince($0.value.time) < Self.lifetime }
            }
        }
    }
}
