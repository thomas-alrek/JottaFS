import Foundation
import JottaFSCore
import Testing
@testable import JottaFSKitExtension

// A whole device mounted as one volume: its locations are the root's folders
// (docs/device-volume-design.md).

private let backupPath = "/backup/8c0efb59-cc12-4f79-b687-64c7d5ea7f28"

private func backupTarget() -> MountTarget {
    MountTarget(
        volume: .wholeDevice("JottaFS-Test-1699"),
        deviceServicePath: backupPath,
        anchorName: "",
        volumeName: "JottaFS-Test-1699"
    )
}

private func builtInTarget() -> MountTarget {
    MountTarget(
        volume: .wholeDevice("Jotta"),
        deviceServicePath: nil,
        builtInLocations: ["Archive", "Photos", "Shared", "Sync"],
        anchorName: "",
        volumeName: "Jottacloud"
    )
}

@Suite("Whole-device volumes: what the volume covers")
struct DeviceVolumeTargetTests {
    @Test func aBackupDeviceCoversItsWholeServicePath() {
        let target = backupTarget()
        #expect(target.isWholeDevice)
        #expect(target.canChangeLocations)
        #expect(target.trashPrefixes == [backupPath + "/"])
        if case .device("JottaFS-Test-1699") = target.rootRole {} else {
            Issue.record("The root of a whole-device volume is the device.")
        }
    }

    @Test func jottacloudsOwnDeviceCoversEachOfItsLocations() {
        let target = builtInTarget()
        #expect(!target.canChangeLocations)
        #expect(target.trashPrefixes == ["/archive/", "/photos/", "/shared/", "/sync/"])
    }

    @Test func aLocationVolumeIsUnchanged() {
        let target = MountTarget(
            volume: JottacloudRemoteVolume(device: "Jotta", mountpoint: "Archive"),
            deviceServicePath: nil,
            anchorName: "",
            volumeName: "Archive"
        )
        #expect(!target.isWholeDevice)
        #expect(!target.canChangeLocations)
        #expect(target.trashPrefixes == ["/archive/"])
        let found = target.location(forServicePath: "/Archive/Folder/file.txt")
        #expect(found?.volume == JottacloudRemoteVolume(device: "Jotta", mountpoint: "Archive"))
        #expect(found?.path == "Folder/file.txt")
    }

    /// Trash entries map back to the location they came from; a trashed
    /// location itself has an empty path.
    @Test func trashEntriesMapToTheirLocation() {
        let target = backupTarget()
        let file = target.location(forServicePath: backupPath + "/Beta/Folder/inner.txt")
        #expect(file?.volume == JottacloudRemoteVolume(device: "JottaFS-Test-1699", mountpoint: "Beta"))
        #expect(file?.path == "Folder/inner.txt")
        let location = target.location(forServicePath: backupPath + "/Beta")
        #expect(location?.volume.mountpoint == "Beta")
        #expect(location?.path == "")
        #expect(target.location(forServicePath: "/backup/other-device/Beta") == nil)

        let photo = builtInTarget().location(forServicePath: "/Photos/2026/img.jpg")
        #expect(photo?.volume == JottacloudRemoteVolume(device: "Jotta", mountpoint: "Photos"))
        #expect(photo?.path == "2026/img.jpg")
        #expect(builtInTarget().location(forServicePath: "/backup/x/y") == nil)
    }

    /// The whole device has no service path or file URL of its own: a path
    /// in it would be read as a location's name.
    @Test func theWholeDeviceHasNoPathOfItsOwn() {
        #expect(backupTarget().servicePath(volume: .wholeDevice("JottaFS-Test-1699"), path: "Beta") == nil)
    }
}

@Suite("Whole-device volumes: location folders in the root")
struct DeviceVolumeFolderTests {
    @Test func backupLocationsKeepTheirNames() {
        let folders = DirectoryCache.locationFolders(["Alpha", "Ny mappe æøå"], device: "JottaFS-Test-1699") { _ in "Translated" }
        #expect(folders.map(\.name) == ["Alpha", "Ny mappe æøå"])
        #expect(folders.map(\.mountpoint) == ["Alpha", "Ny mappe æøå"])
    }

    /// Jottacloud's own locations show their Norwegian names, and still
    /// name the real location.
    @Test func builtInLocationsShowTheirTranslatedNames() {
        let names = ["archive": "Arkiv", "sync": "Synk", "shared": "Delt", "photos": "Bilder"]
        let folders = DirectoryCache.locationFolders(["Archive", "Photos", "Shared", "Sync"], device: "Jotta") {
            names[$0.lowercased()]
        }
        #expect(folders.map(\.name) == ["Arkiv", "Bilder", "Delt", "Synk"])
        #expect(folders.map(\.mountpoint) == ["Archive", "Photos", "Shared", "Sync"])
    }

    /// A translated name that another location already has (or that is
    /// not a valid name) is not used.
    @Test func clashingTranslationsKeepTheOwnName() {
        let folders = DirectoryCache.locationFolders(["Archive", "Arkiv", "Sync"], device: "Jotta") {
            ["archive": "Arkiv", "sync": "a/b"][$0.lowercased()]
        }
        #expect(folders.map(\.name) == ["Archive", "Arkiv", "Sync"])
    }

    @Test func namesTheRootNeedsAreLeftOut() {
        let folders = DirectoryCache.locationFolders([".Trashes", ".fseventsd", ".DS_Store", "Alpha"], device: "JottaFS-Test-1699")
        #expect(folders.map(\.name) == ["Alpha"])
    }
}

@Suite("Whole-device volumes: moving between locations")
struct DeviceVolumeMoveTests {
    private let device = JottacloudRemoteVolume.wholeDevice("JottaFS-Test-1699")

    private func folder(_ name: String, _ role: JottacloudItemRole) -> JottacloudDirectoryEntry {
        JottacloudDirectoryEntry(entry: RemoteEntry(name: name, kind: .directory, size: 0, modified: nil), role: role)
    }

    /// A folder moved into another location takes its contents along: they
    /// now name the new location (they kept the old one before).
    @Test func movedDescendantsNameTheNewLocation() throws {
        let store = ItemStore(rootRole: .device(device.device))
        let root = store.rootItem()
        let alpha = try store.child(of: root, entry: folder("Alpha", .mountpoint(device.location(named: "Alpha"))))
        let beta = try store.child(of: root, entry: folder("Beta", .mountpoint(device.location(named: "Beta"))))
        let moved = try store.child(of: alpha, entry: folder("Folder", .remote(device.location(named: "Alpha"), path: "Folder")))
        let inner = try store.child(of: moved, entry: JottacloudDirectoryEntry(
            entry: RemoteEntry(name: "inner.txt", kind: .file, size: 1, modified: nil),
            role: .remote(device.location(named: "Alpha"), path: "Folder/inner.txt")
        ))
        let local = try store.child(of: moved, entry: JottacloudDirectoryEntry(
            entry: RemoteEntry(name: ".DS_Store", kind: .file, size: 0, modified: nil),
            role: .localFile(path: "Alpha/Folder/.DS_Store")
        ))

        try store.move(moved, to: beta, name: "Folder")

        #expect(inner.path == "Beta/Folder/inner.txt")
        #expect(inner.remoteLocation?.volume.mountpoint == "Beta")
        #expect(inner.remoteLocation?.path == "Folder/inner.txt")
        if case .localFile(let path) = local.role {
            #expect(path == "Beta/Folder/.DS_Store")
        } else {
            Issue.record("A local Finder file stays local.")
        }
    }

    /// Renaming a location folder renames the location of everything in it.
    @Test func renamingALocationRenamesItsContents() throws {
        let store = ItemStore(rootRole: .device(device.device))
        let root = store.rootItem()
        let alpha = try store.child(of: root, entry: folder("Alpha", .mountpoint(device.location(named: "Alpha"))))
        let file = try store.child(of: alpha, entry: JottacloudDirectoryEntry(
            entry: RemoteEntry(name: "a.txt", kind: .file, size: 1, modified: nil),
            role: .remote(device.location(named: "Alpha"), path: "a.txt")
        ))

        try store.move(alpha, to: root, name: "Gamma", role: .mountpoint(device.location(named: "Gamma")))

        #expect(alpha.path == "Gamma")
        #expect(file.path == "Gamma/a.txt")
        #expect(file.remoteLocation?.volume.mountpoint == "Gamma")
        #expect(file.remoteLocation?.path == "a.txt")
    }

    @Test func rebasingPaths() {
        #expect(ItemStore.rebase("a.txt", from: "", to: "Folder") == "Folder/a.txt")
        #expect(ItemStore.rebase("Folder/a.txt", from: "Folder", to: "") == "a.txt")
        #expect(ItemStore.rebase("Folder/sub/a.txt", from: "Folder", to: "New") == "New/sub/a.txt")
        #expect(ItemStore.rebase("a.txt", from: "", to: "") == "a.txt")
    }
}
