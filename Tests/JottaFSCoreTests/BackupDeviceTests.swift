import Foundation
import Testing
@testable import JottaFSCore

// Regression tests for backup devices and their locations (2026-11-26).
// They run with `swift test` (`make check`), which the release runs first.

@Suite("Removing locations and backup devices")
struct LocationRemovalTests {
    private final class Record: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [String] = []
        func add(_ event: String) { lock.withLock { events.append(event) } }
        var all: [String] { lock.withLock { events } }
    }

    private struct StillMounted: Error {}

    /// Every affected location is unmounted before anything is removed.
    @Test func unmountsEveryLocationBeforeRemoving() async throws {
        let record = Record()
        try await LocationRemoval.run(
            unmounting: ["Files", "Photos"],
            unmount: { record.add("unmount \($0)") },
            remove: { record.add("remove") }
        )
        #expect(record.all == ["unmount Files", "unmount Photos", "remove"])
    }

    /// A location that cannot be unmounted (a file is open) stops the
    /// removal: nothing is removed.
    @Test func failedUnmountRemovesNothing() async {
        let record = Record()
        await #expect(throws: StillMounted.self) {
            try await LocationRemoval.run(
                unmounting: ["Files", "Photos", "Music"],
                unmount: { name in
                    record.add("unmount \(name)")
                    if name == "Photos" { throw StillMounted() }
                },
                remove: { record.add("remove") }
            )
        }
        #expect(!record.all.contains("remove"))
        #expect(record.all == ["unmount Files", "unmount Photos"])
    }
}

@Suite("Backup device listings")
struct BackupDeviceListingTests {
    /// A mountpoint moved to the trash is still in the JFS device listing,
    /// marked deleted; it must not show as a location.
    @Test func trashedMountpointsAreNotLocations() throws {
        let xml = Data("""
        <device time="2026-11-26-T11:29:10Z" host="dn-000">
          <name xml:space="preserve">JottaFS-Test-F13B</name>
          <mountPoints>
            <mountPoint><name xml:space="preserve">Files</name></mountPoint>
            <mountPoint deleted="2026-11-26-T11:29:10Z"><name xml:space="preserve">Second</name></mountPoint>
          </mountPoints>
        </device>
        """.utf8)
        #expect(try parseDeviceMountpointNames(xml) == ["Files"])
    }

    /// Regression (2026-11-27): the live listing marks a trashed mountpoint
    /// with a `<deleted>` child element, not an attribute, so trashed
    /// locations stayed in the location list.
    @Test func mountpointsWithADeletedElementAreNotLocations() throws {
        let xml = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <device time="2026-11-27-T15:47:37Z" host="b2-api-jfs">
          <name xml:space="preserve">JottaFS-Test-1699</name>
          <type>CLI</type>
          <mountPoints>
            <mountPoint>
              <name xml:space="preserve">Beta</name>
              <deleted>2026-11-27-T15:47:36Z</deleted>
              <abspath xml:space="preserve">/user/JottaFS-Test-1699</abspath>
              <size></size>
              <modified></modified>
            </mountPoint>
            <mountPoint>
              <name xml:space="preserve">Gamma</name>
              <size></size>
              <modified></modified>
            </mountPoint>
          </mountPoints>
          <metadata first="" max="" total="2" num_mountpoints="2"/>
        </device>
        """.utf8)
        #expect(try parseDeviceMountpointNames(xml) == ["Gamma"])
    }

    /// A device whose mountpoints are all in the trash lists none.
    @Test func aDeviceWithOnlyTrashedMountpointsListsNone() throws {
        let xml = Data("""
        <device><name>JottaFS-Test-1699</name><mountPoints>
          <mountPoint><name>Beta</name><deleted>2026-11-27-T15:47:37Z</deleted></mountPoint>
        </mountPoints></device>
        """.utf8)
        #expect(try parseDeviceMountpointNames(xml) == [])
    }

    /// A whole-device volume has no mountpoint: no file URL may be made
    /// from it, or a path would be read as a location's name.
    @Test func noFileURLWithoutAMountpoint() throws {
        #expect(throws: JottacloudError.self) {
            try JottacloudClient.makeJFSURL(username: "u", device: "JottaFS-Test-1699", mountpoint: "", path: "Beta")
        }
        let url = try JottacloudClient.makeJFSURL(username: "u", device: "Jotta", mountpoint: "Archive", path: "a b")
        #expect(url.absoluteString.hasSuffix("/u/Jotta/Archive/a%20b"))
    }

    /// Whole devices get the device's name as their default disk name.
    @Test func wholeDeviceVolumeNames() {
        #expect(JottaFSStorage.defaultVolumeName(device: "Jotta", mountpoint: "") == "Jottacloud")
        #expect(JottaFSStorage.defaultVolumeName(device: "Thomas sin MacBook", mountpoint: "") == "Thomas sin MacBook")
        #expect(JottacloudRemoteVolume.wholeDevice("Jotta").isWholeDevice)
        #expect(JottacloudRemoteVolume.wholeDevice("Jotta").displayName == "Jotta")
        #expect(JottaFSStorage.anchorName(device: "Jotta", mountpoint: "") != JottaFSStorage.anchorName(device: "Jotta", mountpoint: "Archive"))
    }

    /// Backup devices carry their type (12 is CLI, which jotta-cli also uses).
    @Test func backupDevicesCarryTheirType() {
        func string(_ field: UInt8, _ text: String) -> [UInt8] {
            [field << 3 | 2, UInt8(text.utf8.count)] + Array(text.utf8)
        }
        let device = string(1, "a251") + string(3, "JottaFS-Test-EAEB") + [4 << 3, 12] + string(5, "/backup/a251")
        let list = [1 << 3 | 2, UInt8(device.count)] + device
        let devices = JottacloudClient.decodeDeviceList(list)
        #expect(devices == [JottacloudBackupDevice(id: "a251", name: "JottaFS-Test-EAEB", path: "/backup/a251", type: 12)])
    }
}

@Suite("Upload confirmation")
struct UploadConfirmationTests {
    private let md5 = "d41d8cd98f00b204e9800998ecf8427e"

    /// A response that says COMPLETED (with matching size and MD5, if
    /// given) confirms the upload; no separate revision request is needed.
    @Test func completedResponsesConfirm() {
        #expect(JottacloudClient.uploadConfirmed(Data(#"{"state":"COMPLETED"}"#.utf8), size: 10, md5: md5))
        #expect(JottacloudClient.uploadConfirmed(Data(#"{"state":"COMPLETED","bytes":10,"md5":"D41D8CD98F00B204E9800998ECF8427E"}"#.utf8), size: 10, md5: md5))
        // rclone's upload response: the stored file's MD5 and size, no state.
        #expect(JottacloudClient.uploadConfirmed(Data(#"{"path":"/x","content_id":"c","modified":1,"md5":"d41d8cd98f00b204e9800998ecf8427e","bytes":10}"#.utf8), size: 10, md5: md5))
    }

    /// Anything else falls back to asking for the revision.
    @Test func otherResponsesDoNotConfirm() {
        #expect(!JottacloudClient.uploadConfirmed(Data(#"{"state":"INCOMPLETE"}"#.utf8), size: 10, md5: md5))
        #expect(!JottacloudClient.uploadConfirmed(Data(#"{"state":"COMPLETED","bytes":9}"#.utf8), size: 10, md5: md5))
        #expect(!JottacloudClient.uploadConfirmed(Data(#"{"state":"COMPLETED","md5":"0000"}"#.utf8), size: 10, md5: md5))
        #expect(!JottacloudClient.uploadConfirmed(Data("<file/>".utf8), size: 10, md5: md5))
        #expect(!JottacloudClient.uploadConfirmed(Data(), size: 10, md5: md5))
        // Only one of MD5 and size, without a state: not enough.
        #expect(!JottacloudClient.uploadConfirmed(Data(#"{"md5":"d41d8cd98f00b204e9800998ecf8427e"}"#.utf8), size: 10, md5: md5))
        #expect(!JottacloudClient.uploadConfirmed(Data(#"{"bytes":10}"#.utf8), size: 10, md5: md5))
    }
}
