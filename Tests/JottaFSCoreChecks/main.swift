import Foundation
@testable import JottaFSCore

@main
enum RemoteAPIChecks {
    static func main() throws {
        try decodesUnpaddedPersonalLoginToken()
        try rejectsNonOfficialIdentityHosts()
        try encodesEachJFSPathComponentAndPlusSigns()
        try validatesPartialContentRanges()
        try clampsByteRangesToFileSize()
        try parsesCompleteListingsAndSkipsDeletedOrIncompleteItems()
        try parsesDevicesAndTheirMountpoints()
        try storesCredentialsAsBinaryPropertyList()
        print("All Jottacloud API checks passed.")
    }

    private static func decodesUnpaddedPersonalLoginToken() throws {
        let payload = Data(
            #"{"username":"user@example.com","well_known_link":"https://id.jottacloud.com/discovery","auth_token":"one-time"}"#.utf8
        )
        let token = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))

        let decoded = try JottacloudClient.decodeLoginToken(token)

        precondition(decoded.username == "user@example.com")
        precondition(decoded.authToken == "one-time")
    }

    private static func rejectsNonOfficialIdentityHosts() throws {
        for value in [
            "https://example.com/discovery",
            "https://user@id.jottacloud.com/discovery",
            "http://id.jottacloud.com/discovery"
        ] {
            do {
                _ = try JottacloudClient.officialIdentityURL(value)
                throw CheckFailure.expectedAnError
            } catch is JottacloudError {
            }
        }
    }

    private static func encodesEachJFSPathComponentAndPlusSigns() throws {
        let url = try JottacloudClient.makeJFSURL(
            username: "internal-id",
            device: "Backup+2",
            mountpoint: "Archive+Cold",
            path: "folder/a+b.txt"
        )
        precondition(
            url.absoluteString
                == "https://jfs.jottacloud.com/jfs/internal-id/Backup%2B2/Archive%2BCold/folder/a%2Bb.txt"
        )
    }

    private static func validatesPartialContentRanges() throws {
        try JottacloudClient.validatePartialContentRange(
                "bytes 12-19/100",
                offset: 12,
                maximumLength: 8
        )
        try JottacloudClient.validatePartialContentRange(
                "bytes 12-19/*",
                offset: 12,
                maximumLength: 8
        )

        for value in [
                nil,
                "bytes 0-7/100",
                "bytes 12-20/100",
                "bytes 12-19/19",
                "items 12-19/100",
                "bytes 12-19"
        ] {
                do {
                    try JottacloudClient.validatePartialContentRange(
                        value,
                        offset: 12,
                        maximumLength: 8
                    )
                    throw CheckFailure.expectedAnError
                } catch is JottacloudError {
                }
        }
    }

    private static func clampsByteRangesToFileSize() throws {
        // A 1 MiB kernel read of a 1,474-byte file must not request past EOF;
        // Jottacloud returns 416 for that instead of a short 206.
        let whole = JottacloudClient.byteRange(offset: 0, length: 1 << 20, fileSize: 1474)
        precondition(whole?.length == 1474 && whole?.end == 1473)
        let tail = JottacloudClient.byteRange(offset: 1400, length: 4096, fileSize: 1474)
        precondition(tail?.length == 74 && tail?.end == 1473)
        let middle = JottacloudClient.byteRange(offset: 10, length: 16, fileSize: 1474)
        precondition(middle?.length == 16 && middle?.end == 25)
        let capped = JottacloudClient.byteRange(offset: 0, length: 4 << 20, fileSize: 8 << 20)
        precondition(capped?.length == 1 << 20 && capped?.end == (1 << 20) - 1)
        precondition(JottacloudClient.byteRange(offset: 1474, length: 10, fileSize: 1474) == nil)
        precondition(JottacloudClient.byteRange(offset: 0, length: 10, fileSize: 0) == nil)
        precondition(JottacloudClient.byteRange(offset: 0, length: 0, fileSize: 10) == nil)
    }

    private static func parsesCompleteListingsAndSkipsDeletedOrIncompleteItems() throws {
        let xml = Data(
            """
            <mountPoint>
              <folders>
                <folder name="docs"><modified>2024-01-02-T03:04:05Z</modified></folder>
                <folder name="no-date"/>
                <folder name="invalid-date"><modified>not-a-date</modified></folder>
                <folder name="gone" deleted="false"/>
                <folder name="../escape"/>
              </folders>
              <files>
                <file name="readme.txt">
                  <currentRevision>
                    <state>COMPLETED</state><size>42</size>
                    <modified>2024-01-02-T03:04:05Z</modified>
                  </currentRevision>
                </file>
                <file name="partial.txt">
                  <currentRevision><state>UPLOADING</state><size>5</size></currentRevision>
                </file>
                <file name="deleted.txt" deleted="false">
                  <currentRevision><state>COMPLETED</state><size>1</size></currentRevision>
                </file>
                <file name="no-date.txt">
                  <currentRevision><state>COMPLETED</state><size>7</size></currentRevision>
                </file>
              </files>
            </mountPoint>
            """.utf8
        )

        let entries = try parseDirectory(xml)

        precondition(
            entries.map(\.name) == [
                "docs",
                "no-date",
                "invalid-date",
                "readme.txt",
                "no-date.txt"
            ]
        )
        precondition(entries[0].kind == .directory)
        precondition(entries[3].kind == .file)
        precondition(entries[3].size == 42)
        precondition(entries[0].modified != nil)
        precondition(entries[1].modified == nil)
        precondition(entries[2].modified == nil)
        precondition(entries[4].modified == nil)
    }

    private static func parsesDevicesAndTheirMountpoints() throws {
        let accountXML = Data(
            """
            <user>
              <devices>
                <device><name>Jotta</name></device>
                <device><name>Backup</name></device>
              </devices>
            </user>
            """.utf8
        )
        let deviceXML = Data(
            """
            <device>
              <mountPoints>
                <mountPoint><name>Archive</name></mountPoint>
                <mountPoint><name>Sync</name></mountPoint>
              </mountPoints>
            </device>
            """.utf8
        )

        let devices = try parseDriveDeviceNames(accountXML)
        let mountpoints = try parseDeviceMountpointNames(deviceXML)
        precondition(devices == ["Jotta", "Backup"])
        precondition(mountpoints == ["Archive", "Sync"])
    }

    private static func storesCredentialsAsBinaryPropertyList() throws {
        let credentials = JottacloudCredentials(
            username: "test-user",
            device: "Backup",
            mountpoint: "Archive",
            accessToken: "test-access",
            refreshToken: "test-refresh",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            tokenEndpoint: URL(string: "https://id.jottacloud.com/token")!
        )
        let data = try JottaFSStorage.encodeCredentials(credentials)
        var format = PropertyListSerialization.PropertyListFormat.xml
        _ = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: &format
        )
        let decoded = try PropertyListDecoder().decode(
            JottacloudCredentials.self,
            from: data
        )

        precondition(format == .binary)
        precondition(decoded == credentials)
    }
}

private enum CheckFailure: Error {
    case expectedAnError
}
