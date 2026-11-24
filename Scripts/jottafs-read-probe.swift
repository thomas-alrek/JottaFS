import Darwin
import Foundation

@main
enum JottacloudReadProbe {
    private static let device = "Thomass Mac mini"
    private static let mountpoint = "Thomas"
    private static let remotePath = "Developer/bergenhardstyle2025/src/index.html"
    private static let chunkSize = 256
    private static let expectedHTML = """
    <!DOCTYPE html>
    <html lang="en">

    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Bergen Hardstyle</title>
        <link rel="stylesheet" href="styles.css">
    </head>

    <body>
        <main>
            <nav class="navbar">
                <a class="navbar-brand" href="#" title="Home">
                    <img src="bergen-hardstyle-brand-icon.png">
                </a>
                <ul>
                    <li>
                        <a href="#events">Events</a>
                    </li>
                    <li>
                        <a href="#artists">Artists</a>
                    </li>
                    <li>
                        <a href="#merch">Merch</a>
                    </li>
                </ul>
            </nav>
            <div class="event-hero" style="background-image: url('concert_illustration.jpg');">
                <div class="event-overlay">
                    <div class="event-wrapper">

                        <div class="event-date">
                            <div class="month">JUL</div>
                            <div class="day">23</div>
                        </div>

                        <div class="event-center">
                            <h1>Event Name</h1>
                            <p>Lorem ipsum dolor sit amet, consectetur adipiscing elit.</p>
                            <a href="#" class="event-button">READ MORE</a>
                        </div>

                    </div>
                </div>
            </div>
            </div>
        </main>
    </body>

    </html>
    """

    static func main() async {
        do {
            try await run()
        } catch {
            fputs("Read probe failed: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func run() async throws {
        guard let credentialsDirectory = JottaFSStorage.credentialsDirectoryURL() else {
            throw JottaFSStorageError.applicationGroupUnavailable
        }
        let credentials = try JottaFSStorage.loadCredentials(
            from: credentialsDirectory
        )
        guard credentials.expiresAt.timeIntervalSinceNow > 60 else {
            throw ProbeError.accessTokenNearExpiry
        }
        let client = JottacloudClient(
            credentials: credentials,
            allowsTokenRefresh: false
        )
        let volumes = try await client.listRemoteVolumes()
        guard let volume = volumes.first(where: {
            $0.device == device && $0.mountpoint == mountpoint
        }) else {
            throw ProbeError.remoteVolumeNotFound
        }
        let parentPath = (remotePath as NSString).deletingLastPathComponent
        let directory = try await client.listDirectory(volume: volume, path: parentPath)
        guard let file = directory.first(where: {
            $0.name == (remotePath as NSString).lastPathComponent && $0.kind == .file
        }), let expectedSize = Int(exactly: file.size) else {
            throw ProbeError.remoteFileNotFound
        }

        let expected = Data(expectedHTML.utf8)
        print("Remote file size: \(file.size) bytes")
        print("Expected text size: \(expected.count) bytes")

        for offset in [1024, 512, 0] {
            let length = min(64, expected.count - offset)
            let actual = try await client.readRange(
                volume: volume,
                path: remotePath,
                offset: UInt64(offset),
                length: length,
                fileSize: file.size
            )
            let expectedRange = expected.subdata(in: offset..<(offset + length))
            print(
                "Seek read offset=\(offset), requested=\(length), received=\(actual.count), matches=\(actual == expectedRange), prefix=\(hexPrefix(actual))"
            )
        }

        var actualFile = Data()
        actualFile.reserveCapacity(expectedSize)
        while actualFile.count < expectedSize {
            let offset = actualFile.count
            let length = min(chunkSize, expectedSize - offset)
            let chunk = try await client.readRange(
                volume: volume,
                path: remotePath,
                offset: UInt64(offset),
                length: length,
                fileSize: file.size
            )
            guard !chunk.isEmpty else {
                throw ProbeError.unexpectedEndOfFile(offset: offset)
            }
            actualFile.append(chunk)
        }

        if actualFile == expected {
            print("PASS: ranged reads reproduce the expected index.html exactly.")
            return
        }

        let mismatchOffset = firstMismatch(in: actualFile, and: expected)
        print(
            "FAIL: direct API data differs at byte \(mismatchOffset); actual size \(actualFile.count), expected size \(expected.count), prefix=\(hexPrefix(actualFile))"
        )
        exit(EXIT_FAILURE)
    }

    private static func firstMismatch(in actual: Data, and expected: Data) -> Int {
        let sharedLength = min(actual.count, expected.count)
        for index in 0..<sharedLength where actual[index] != expected[index] {
            return index
        }
        return sharedLength
    }

    private static func hexPrefix(_ data: Data) -> String {
        data.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}

private enum ProbeError: Error, LocalizedError {
    case remoteVolumeNotFound
    case remoteFileNotFound
    case unexpectedEndOfFile(offset: Int)
    case accessTokenNearExpiry

    var errorDescription: String? {
        switch self {
        case .remoteVolumeNotFound:
            "The requested Jottacloud device and mountpoint were not found."
        case .remoteFileNotFound:
            "The requested remote file was not found."
        case .unexpectedEndOfFile(let offset):
            "The ranged read returned no data at byte offset \(offset)."
        case .accessTokenNearExpiry:
            "The saved access token is too close to expiry; reload the saved account in JottaFS before running this probe."
        }
    }
}
