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
