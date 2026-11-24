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
        try parsesAccountStorageAndReportsNonZeroVolumeSizes()
        try confinesWritesToTheScopeFolder()
        try validatesNewNames()
        try stagesWritesInLocalFiles()
        try encodesUploadRequestsAndParsesResponses()
        try classifiesTransientUploadFailures()
        try parsesCompleteListingsAndSkipsDeletedOrIncompleteItems()
        try parsesDevicesAndTheirMountpoints()
        try doesNotListTheListedFolderItself()
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

    private static func parsesAccountStorageAndReportsNonZeroVolumeSizes() throws {
        let limited = parseAccountStorage(Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <user time="2026-11-24-T12:00:00Z" host="dn">
          <username>internal-id</username>
          <capacity>1099511627776</capacity>
          <usage>52428800</usage>
          <devices>
            <device><name>Jotta</name><usage>999</usage></device>
          </devices>
        </user>
        """.utf8))
        // Nested per-device <usage> must not override the account total.
        precondition(limited == JottacloudStorage(capacity: 1_099_511_627_776, usage: 52_428_800))
        let limitedSizes = limited.volumeSizes(blockSize: 4096)
        precondition(limitedSizes.total == 1_099_511_627_776)
        precondition(limitedSizes.used == 52_428_800)
        precondition(limitedSizes.free == 1_099_511_627_776 - 52_428_800)

        let unlimited = parseAccountStorage(Data(
            "<user><capacity>-1</capacity><usage>8192</usage></user>".utf8
        ))
        precondition(unlimited == JottacloudStorage(capacity: nil, usage: 8192))
        let unlimitedSizes = unlimited.volumeSizes(blockSize: 4096)
        let nominal = JottacloudStorage.unlimitedFreeBytes
        precondition(unlimitedSizes == (8192 + nominal, 8192, nominal))

        let missing = parseAccountStorage(Data("<user><devices/></user>".utf8))
        precondition(missing == JottacloudStorage(capacity: nil, usage: nil))
        // Unknown quota: writable nominal free space, never a zero size.
        precondition(missing.volumeSizes(blockSize: 4096) == (nominal, 0, nominal))
        precondition(
            JottacloudStorage(capacity: 0, usage: 0).volumeSizes(blockSize: 4096) == (4096, 4096, 0)
        )
        // Over quota: treated like an unknown quota, reported full.
        precondition(
            JottacloudStorage(capacity: 100, usage: 500).volumeSizes(blockSize: 4096) == (4096, 4096, 0)
        )
    }

    private static func confinesWritesToTheScopeFolder() throws {
        let inside: [(String, String, String)] = [
            ("Jotta", "Archive", "JottaFS-Test/a.txt"),
            ("Jotta", "Archive", "JottaFS-Test/dir/b.txt"),
            ("jotta", "archive", "jottafs-test/a.txt"), // Jottacloud is case-insensitive
        ]
        for (device, mountpoint, path) in inside {
            precondition(JottaFSWriteScope.contains(device: device, mountpoint: mountpoint, path: path), path)
        }
        let outside: [(String, String, String)] = [
            ("Jotta", "Archive", "JottaFS-Test"),            // the scope folder itself
            ("Jotta", "Archive", "Documents/a.txt"),
            ("Jotta", "Archive", "JottaFS-Test-old/a.txt"),  // shared prefix
            ("Jotta", "Archive", "JottaFS‐Test/a.txt"),      // Unicode hyphen look-alike
            ("Jotta", "Archive", "JottaFS-Test/../a.txt"),
            ("Jotta", "Archive", "JottaFS-Test/./a.txt"),
            ("Jotta", "Archive", "JottaFS-Test//a.txt"),
            ("Jotta", "Archive", "/JottaFS-Test/a.txt"),
            ("Jotta", "Archive", ""),
            ("Jotta", "Sync", "JottaFS-Test/a.txt"),
            ("Thomass Mac mini", "Archive", "JottaFS-Test/a.txt"),
        ]
        for (device, mountpoint, path) in outside {
            precondition(!JottaFSWriteScope.contains(device: device, mountpoint: mountpoint, path: path), path)
        }
        precondition(JottaFSWriteScope.isScopeRoot(device: "Jotta", mountpoint: "Archive", path: "JottaFS-Test"))
        precondition(!JottaFSWriteScope.isScopeRoot(device: "Jotta", mountpoint: "Archive", path: "JottaFS-Test/a"))
        precondition(!JottaFSWriteScope.isScopeRoot(device: "Jotta", mountpoint: "Sync", path: "JottaFS-Test"))
    }

    private static func validatesNewNames() throws {
        // Mac metadata files are allowed (Finder aborts folder copies otherwise).
        for name in ["a.txt", "Notes 2026.md", "æøå.txt", ".hidden", ".DS_Store", "._a.txt",
                     String(repeating: "x", count: 255)] {
            try JottaFSNames.validate(name)
        }
        for name in ["", ".", "..", "a/b", "a:b", "a*b", "a?b", "a|b", "a<b", "a>b", "a\"b", "a%b",
                     "a\u{0}b", "a\nb", String(repeating: "x", count: 256)] {
            do {
                try JottaFSNames.validate(name)
                throw CheckFailure.expectedAnError
            } catch JottaFSNameError.invalid {
            }
        }
    }

    private static func stagesWritesInLocalFiles() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jottafs-check-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }

        let sizeAfterFirstWrite = try JottaFSStagingFile.write(Data("hello".utf8), to: url, at: 0)
        precondition(sizeAfterFirstWrite == 5)
        let sizeAfterGapWrite = try JottaFSStagingFile.write(Data("XY".utf8), to: url, at: 8)
        precondition(sizeAfterGapWrite == 10)
        let whole = try JottaFSStagingFile.read(from: url, at: 0, length: 100)
        precondition(whole == Data("hello".utf8) + Data([0, 0, 0]) + Data("XY".utf8))
        let middle = try JottaFSStagingFile.read(from: url, at: 1, length: 3)
        precondition(middle == Data("ell".utf8))
        try JottaFSStagingFile.truncate(url, to: 4)
        let truncatedSize = try JottaFSStagingFile.size(of: url)
        precondition(truncatedSize == 4)
        let truncated = try JottaFSStagingFile.read(from: url, at: 0, length: 100)
        precondition(truncated == Data("hell".utf8))
        let md5 = try JottaFSStagingFile.md5(of: url)
        precondition(md5 == "4229d691b07b13341da53f17ab9f2416")
        try JottaFSStagingFile.truncate(url, to: 0)
        let emptyMD5 = try JottaFSStagingFile.md5(of: url)
        precondition(emptyMD5 == "d41d8cd98f00b204e9800998ecf8427e")
    }

    private static func encodesUploadRequestsAndParsesResponses() throws {
        let date = Date(timeIntervalSince1970: 1_795_000_000)
        let request = AllocateRequest(
            device: "Jotta",
            mountpoint: "Archive",
            path: "JottaFS-Test/a b+c.txt",
            bytes: 5,
            md5: "5d41402abc4b2a76b9719d911017c592",
            created: date,
            modified: date
        )
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        precondition(json?["path"] as? String == "/jfs/Jotta/Archive/JottaFS-Test/a b+c.txt")
        precondition(json?["bytes"] as? Int == 5)
        precondition(json?["md5"] as? String == "5d41402abc4b2a76b9719d911017c592")
        precondition(json?["created"] as? String == "2026-11-18T11:06:40Z")
        precondition(json?["modified"] as? String == "2026-11-18T11:06:40Z")

        let response = try JSONDecoder().decode(AllocateResponse.self, from: Data(
            #"{"name":"a","path":"/x","state":"NEW","upload_id":"u","upload_url":"https://up.jottacloud.com/x","bytes":5,"resume_pos":0}"#.utf8
        ))
        precondition(response == AllocateResponse(state: "NEW", uploadURL: "https://up.jottacloud.com/x", resumePosition: 0))

        precondition(JottacloudClient.trustedUploadURL("https://up.jottacloud.com/u/1") != nil)
        precondition(JottacloudClient.trustedUploadURL("https://up-no-001.jotta.cloud/files/v1/upload/x") != nil)
        precondition(JottacloudClient.trustedUploadURL("https://jotta.cloud.evil.com/u") == nil)
        precondition(JottacloudClient.trustedUploadURL("https://evil-jotta.cloud/u") == nil)
        for untrusted in ["http://up.jottacloud.com/u", "https://evil.com/u", "https://jottacloud.com.evil.com/u",
                          "https://user@up.jottacloud.com/u", "https://notjottacloud.com/u"] {
            precondition(JottacloudClient.trustedUploadURL(untrusted) == nil, untrusted)
        }

        let base = try JottacloudClient.makeJFSURL(
            username: "u", device: "Jotta", mountpoint: "Archive", path: "JottaFS-Test/old name"
        )
        let move = try JottacloudClient.jfsMutationURL(
            base, trailingSlash: false, query: ("mv", "/u/Jotta/Archive/JottaFS-Test/new+name & more")
        )
        precondition(move.absoluteString
            == "https://jfs.jottacloud.com/jfs/u/Jotta/Archive/JottaFS-Test/old%20name?mv=/u/Jotta/Archive/JottaFS-Test/new%2Bname%20%26%20more")
        let trashFolder = try JottacloudClient.jfsMutationURL(base, trailingSlash: true, query: ("dlDir", "true"))
        precondition(trashFolder.absoluteString
            == "https://jfs.jottacloud.com/jfs/u/Jotta/Archive/JottaFS-Test/old%20name/?dlDir=true")

        let revision = try parseFileRevision(Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <file name="a.txt" uuid="x" time="2026-11-24-T12:00:00Z" host="h">
          <path>/u/Jotta/Archive/JottaFS-Test</path>
          <currentRevision>
            <number>1</number><state>COMPLETED</state>
            <created>2026-11-24-T12:00:00Z</created><modified>2026-11-24-T12:00:00Z</modified>
            <mime>text/plain</mime><size>5</size><md5>5D41402ABC4B2A76B9719D911017C592</md5>
            <updated>2026-11-24-T12:00:01Z</updated>
          </currentRevision>
        </file>
        """.utf8))
        precondition(revision?.entry.name == "a.txt")
        precondition(revision?.entry.size == 5)
        precondition(revision?.md5 == "5d41402abc4b2a76b9719d911017c592")
        let incomplete = try parseFileRevision(Data(
            "<file name=\"a\"><currentRevision><state>INCOMPLETE</state><size>5</size></currentRevision></file>".utf8
        ))
        precondition(incomplete == nil)
    }

    private static func classifiesTransientUploadFailures() throws {
        for code in [URLError.Code.networkConnectionLost, .timedOut, .notConnectedToInternet, .cannotConnectToHost] {
            precondition(JottacloudClient.isTransientUploadFailure(URLError(code)), "\(code)")
        }
        for status in [429, 500, 502, 503, 504] {
            precondition(JottacloudClient.isTransientUploadFailure(JottacloudError.httpStatus(status)), "\(status)")
        }
        // Permanent: client errors, cancellation, verification and trust failures.
        for status in [400, 401, 403, 404, 409, 421, 507] {
            precondition(!JottacloudClient.isTransientUploadFailure(JottacloudError.httpStatus(status)), "\(status)")
        }
        precondition(!JottacloudClient.isTransientUploadFailure(URLError(.cancelled)))
        precondition(!JottacloudClient.isTransientUploadFailure(JottacloudError.uploadNotVerified))
        precondition(!JottacloudClient.isTransientUploadFailure(JottacloudError.untrustedUploadURL(host: "x")))
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

    private static func doesNotListTheListedFolderItself() throws {
        // An empty folder's listing has only its own root <folder> element.
        let empty = try parseDirectory(Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <folder name="sub-b" time="2026-11-24-T13:12:00Z" host="h">
          <path>/u/Jotta/Archive/JottaFS-Test</path>
          <abspath>/u/Jotta/Archive/JottaFS-Test</abspath>
        </folder>
        """.utf8))
        precondition(empty.isEmpty)

        let listing = try parseDirectory(Data("""
        <folder name="JottaFS-Test">
          <path>/u/Jotta/Archive</path>
          <folders><folder name="child"/></folders>
          <files>
            <file name="a.txt"><currentRevision><state>COMPLETED</state><size>3</size></currentRevision></file>
          </files>
        </folder>
        """.utf8))
        precondition(listing.map(\.name) == ["child", "a.txt"])
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
