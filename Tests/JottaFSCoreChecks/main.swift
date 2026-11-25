import CryptoKit
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
        try comparesNamesAndNamesVolumes()
        try buildsBrowserLoginChallenges()
        try decodesBackupDevices()
        try validatesNewNames()
        try stagesWritesInLocalFiles()
        try reservesSpaceForStagedFiles()
        try encodesUploadRequestsAndParsesResponses()
        try classifiesTransientUploadFailures()
        try decodesTrashListingsAndMapsServicePaths()
        try parsesCompleteListingsAndSkipsDeletedOrIncompleteItems()
        try parsesDevicesAndTheirMountpoints()
        try doesNotListTheListedFolderItself()
        try storesCredentialsAsBinaryPropertyList()
        try namesOneMountAnchorPerLocation()
        try continuesAnMD5FromAnOffset()
        try readsShareLinks()
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

    private static func decodesBackupDevices() throws {
        func device(_ id: String, _ name: String, _ path: String) -> Data {
            var message = Data()
            JottacloudClient.appendProtobufString(field: 1, id, to: &message)
            JottacloudClient.appendProtobufString(field: 3, name, to: &message)
            message.append(contentsOf: [0x20, 0x02]) // type
            JottacloudClient.appendProtobufString(field: 5, path, to: &message)
            var wrapped = Data()
            JottacloudClient.appendVarint(1 << 3 | 2, to: &wrapped)
            JottacloudClient.appendVarint(UInt64(message.count), to: &wrapped)
            wrapped.append(message)
            return wrapped
        }
        var response = device("ac68", "My Mac mini", "/backup/ac68")
        response.append(device("x", "Not a backup", "/archive"))
        let devices = JottacloudClient.decodeDeviceList([UInt8](response))
        precondition(devices == [JottacloudBackupDevice(id: "ac68", name: "My Mac mini", path: "/backup/ac68")])
    }

    private static func buildsBrowserLoginChallenges() throws {
        // BASE64URL(SHA256(verifier)) without padding, as computed with
        // Python's hashlib for this verifier.
        precondition(
            JottacloudClient.s256Challenge("dBjftJeZ4CVP-mJ92K9qPPfOSdYPu0J4C4C2tQ_Pab8") ==
                "AJQ-QX6qmSEL5kfN0BFOivwM1hbGERsOCiwRm6yDxjo"
        )
        let random = try JottacloudClient.randomURLSafeString(byteCount: 48)
        precondition(random.count == 64)
        precondition(random.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        let another = try JottacloudClient.randomURLSafeString(byteCount: 48)
        precondition(another != random)
    }

    private static func comparesNamesAndNamesVolumes() throws {
        // Jottacloud is case-insensitive, but look-alikes never match.
        precondition(JottaFSNames.sameName("Archive", "archive"))
        precondition(JottaFSNames.sameName("Æøå", "æØÅ"))
        precondition(!JottaFSNames.sameName("JottaFS-Test", "JottaFS‐Test")) // Unicode hyphen
        precondition(!JottaFSNames.sameName("a", "a "))

        precondition(JottaFSStorage.defaultVolumeName(mountpoint: "Archive") == "Archive")
        precondition(JottaFSStorage.defaultVolumeName(mountpoint: "C:D") == "C-D")
        precondition(JottaFSStorage.defaultVolumeName(mountpoint: "") == "Jottacloud")

        for name in ["Jotta Archive", "Æøå", "  Work  ", String(repeating: "a", count: 255)] {
            precondition(JottaFSStorage.validVolumeName(name) == name.trimmingCharacters(in: .whitespaces), name)
        }
        for name in ["", "   ", ".", "..", "a/b", "a:b", "a\nb", String(repeating: "å", count: 128)] {
            precondition(JottaFSStorage.validVolumeName(name) == nil, name)
        }
    }

    private static func validatesNewNames() throws {
        // Mac metadata files are allowed (Finder aborts folder copies otherwise).
        for name in ["a.txt", "Notes 2026.md", "æøå.txt", ".hidden", ".DS_Store", "._a.txt",
                     String(repeating: "x", count: 255)] {
            try JottaFSNames.validate(name)
        }
        for name in ["", ".", "..", "a/b", "a:b", "a*b", "a?b", "a|b", "a<b", "a>b", "a\"b", "a%b",
                     "a\u{0}b", "a\nb", String(repeating: "x", count: 256),
                     String(repeating: "å", count: 128)] { // 256 bytes of UTF-8
            do {
                try JottaFSNames.validate(name)
                throw CheckFailure.expectedAnError
            } catch JottaFSNameError.invalid {
            }
        }
    }

    private static func reservesSpaceForStagedFiles() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jottafs-check-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }

        // A reservation keeps the size, and writes into it work.
        try JottaFSStagingFile.reserve(8 * 1024 * 1024, for: url)
        let reservedSize = try JottaFSStagingFile.size(of: url)
        precondition(reservedSize == 0)
        let writtenSize = try JottaFSStagingFile.write(Data(count: 1024), to: url, at: 0)
        precondition(writtenSize == 1024)
        // More than any disk holds fails as "out of space", at once.
        do {
            let free = try url.deletingLastPathComponent()
                .resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity ?? 0
            try JottaFSStagingFile.reserve(UInt64(free) + (UInt64(1) << 40), for: url)
            preconditionFailure("an impossible reservation succeeded")
        } catch {
            precondition(JottaFSStagingFile.isOutOfSpace(error), "unexpected error: \(error)")
        }
        precondition(JottaFSStagingFile.isOutOfSpace(CocoaError(.fileWriteOutOfSpace)))
        precondition(!JottaFSStagingFile.isOutOfSpace(POSIXError(.EIO)))
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

    private static func decodesTrashListingsAndMapsServicePaths() throws {
        precondition(JottacloudClient.servicePath(device: "Jotta", mountpoint: "Archive", path: "A/b c") == "/archive/A/b c")
        precondition(JottacloudClient.servicePath(device: "Jotta", mountpoint: "Archive", path: "") == "/archive")
        precondition(JottacloudClient.servicePath(device: "My Mac", mountpoint: "Docs", path: "x") == nil)
        precondition(JottacloudClient.requestPath("/Archive/JottaFS-Test/Developer") == "/archive/JottaFS-Test/Developer")
        precondition(JottacloudClient.requestPath("/trash") == "/trash")

        // PathItem child: path, name, type folder, size, modified, deleted.
        var child = Data()
        JottacloudClient.appendProtobufString(field: 1, "/Archive/T/x", to: &child)
        JottacloudClient.appendProtobufString(field: 2, "x", to: &child)
        child.append(contentsOf: [0x20, 0x02])
        child.append(0x38); JottacloudClient.appendVarint(300, to: &child)
        child.append(0x50); JottacloudClient.appendVarint(1_795_530_000_000, to: &child)
        child.append(0x58); JottacloudClient.appendVarint(1_795_530_442_712, to: &child)
        var parent = Data()
        JottacloudClient.appendProtobufString(field: 1, "/trash", to: &parent)
        JottacloudClient.appendVarint(13 << 3 | 2, to: &parent)
        JottacloudClient.appendVarint(UInt64(child.count), to: &parent)
        parent.append(child)
        var response = Data()
        JottacloudClient.appendVarint(1 << 3 | 2, to: &response)
        JottacloudClient.appendVarint(UInt64(parent.count), to: &response)
        response.append(parent)
        JottacloudClient.appendProtobufString(field: 2, "next", to: &response)

        // gRPC-Web body: one data frame, then a trailer frame.
        var body = [UInt8]([0x00]) + withUnsafeBytes(of: UInt32(response.count).bigEndian, Array.init) + [UInt8](response)
        let trailer = Array("grpc-status:0\r\ngrpc-message:\r\n".utf8)
        body += [0x80] + withUnsafeBytes(of: UInt32(trailer.count).bigEndian, Array.init) + trailer
        let parsed = JottacloudClient.parseGRPCWebBody(body)
        precondition(parsed.status == 0)
        let decoded = JottacloudClient.decodeGetPathResponse(parsed.message)
        precondition(decoded.item?.path == "/trash" && decoded.cursor == "next")
        precondition(decoded.children.count == 1)
        let item = decoded.children[0]
        precondition(item.path == "/Archive/T/x" && item.name == "x" && item.isFolder && item.size == 300)
        precondition(item.deletedAtMillis == 1_795_530_442_712 && item.isTrashed)
        precondition(item.modified == Date(timeIntervalSince1970: 1_795_530_000))

        // A trailers-only error has no frames.
        precondition(JottacloudClient.parseGRPCWebBody([]).status == nil)
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

extension RemoteAPIChecks {
    /// Each location gets its own anchor name, the same for any case of its
    /// name (Jottacloud names are case-insensitive).
    fileprivate static func namesOneMountAnchorPerLocation() throws {
        let archive = JottaFSStorage.anchorName(device: "Jotta", mountpoint: "Archive")
        precondition(archive.count == 32 && JottaFSStorage.isValidAnchorName(archive))
        precondition(archive == JottaFSStorage.anchorName(device: "jotta", mountpoint: "ARCHIVE"))
        precondition(archive != JottaFSStorage.anchorName(device: "Jotta", mountpoint: "Sync"))
        precondition(archive != JottaFSStorage.anchorName(device: "Laptop", mountpoint: "Archive"))
        precondition(JottaFSStorage.isValidAnchorName(""))
        precondition(!JottaFSStorage.isValidAnchorName("../credentials"))
        precondition(!JottaFSStorage.isValidAnchorName(archive.uppercased()))
    }
}

extension RemoteAPIChecks {
    /// The MD5 of a file whose first part was hashed while it was written
    /// equals the MD5 of the whole file.
    fileprivate static func continuesAnMD5FromAnOffset() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jottafs-md5-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try data.write(to: url)
        let whole = try JottaFSStagingFile.md5(of: url)
        for split in [0, 1, 1_048_576, 2_999_999, 3_000_000] {
            var hasher = Insecure.MD5()
            hasher.update(data: data.prefix(split))
            let continued = try JottaFSStagingFile.md5(of: url, continuing: hasher, from: UInt64(split))
            precondition(continued == whole)
        }
    }
}

extension RemoteAPIChecks {
    fileprivate static func readsShareLinks() throws {
        let file = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <file name="a.bin" uuid="x"><path>/u/Jotta/Archive/T</path>
        <publicURI>13f86255648645d197b10a8fddcd9d13</publicURI>
        <publicSharePath>/s/32013f86255648645d197b10a8fddcd9d13</publicSharePath>
        <currentRevision><number>1</number><state>COMPLETED</state></currentRevision></file>
        """.utf8)
        let shared = try ShareLinkParser.parse(file)
        precondition(shared.own?.absoluteString == "https://www.jottacloud.com/s/32013f86255648645d197b10a8fddcd9d13")
        precondition(shared.children.isEmpty)

        let folder = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <folder name="T"><path>/u/Jotta/Archive</path>
        <folders><folder name="Sub"><publicSharePath>/s/320aa</publicSharePath></folder></folders>
        <files><file name="a.bin"><currentRevision><state>COMPLETED</state></currentRevision></file>
        <file name="b.bin"><publicSharePath>/s/320bb</publicSharePath></file></files></folder>
        """.utf8)
        let listing = try ShareLinkParser.parse(folder)
        precondition(listing.own == nil)
        precondition(listing.children.mapValues(\.absoluteString) == [
            "Sub": "https://www.jottacloud.com/s/320aa",
            "b.bin": "https://www.jottacloud.com/s/320bb",
        ])
        precondition(JottacloudClient.shareLink(forPath: "https://evil.example/s/1") == nil)
        precondition(JottacloudClient.shareLink(forPath: "/s/../x") == nil)
    }
}

private enum CheckFailure: Error {
    case expectedAnError
}
