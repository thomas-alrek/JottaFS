import Foundation

// Public share links (docs/jottacloud-api-internals.md, "Public share links").
// `GET <item>?mode=enableShare` returns the item's XML with
// `<publicSharePath>/s/…</publicSharePath>`; `mode=disableShare` removes it.
// The link is `https://www.jottacloud.com` + that path.

extension JottacloudClient {
    static let shareLinkHost = URL(string: "https://www.jottacloud.com")!

    /// Shares a file or folder publicly (or returns its existing link): the
    /// link anyone can open.
    public func enableSharing(volume: JottacloudRemoteVolume, path: String) async throws -> URL {
        let state = try await sharingRequest(volume: volume, path: path, mode: "enableShare")
        guard let link = state.own else {
            throw JottacloudError.invalidXML
        }
        return link
    }

    /// Stops sharing a file or folder; its link stops working.
    public func disableSharing(volume: JottacloudRemoteVolume, path: String) async throws {
        _ = try await sharingRequest(volume: volume, path: path, mode: "disableShare")
    }

    /// The share link of a file or folder, or nil when it is not shared.
    public func shareLink(volume: JottacloudRemoteVolume, path: String) async throws -> URL? {
        try await sharingRequest(volume: volume, path: path, mode: nil).own
    }

    /// The share links of the files and folders directly in a folder, by
    /// name (only shared items are included), when the listing reports them.
    public func shareLinks(inFolder volume: JottacloudRemoteVolume, path: String) async throws -> [String: URL] {
        try await sharingRequest(volume: volume, path: path, mode: nil).children
    }

    private func sharingRequest(
        volume: JottacloudRemoteVolume,
        path: String,
        mode: String?
    ) async throws -> ShareLinkParser.Result {
        var url = try jfsURL(volume: volume, path: path)
        if let mode {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "mode", value: mode)]
            guard let withMode = components.url else {
                throw JottacloudError.invalidXML
            }
            url = withMode
        }
        let response = try await authorizedGet(url: url)
        try Self.checkSuccess(response.statusCode)
        return try ShareLinkParser.parse(response.data)
    }

    /// The link for a `publicSharePath` (`/s/…`), or nil if it is not one.
    static func shareLink(forPath sharePath: String) -> URL? {
        let trimmed = sharePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/s/"), trimmed.count > 3,
              trimmed.dropFirst(3).allSatisfy({ $0.isLetter || $0.isNumber })
        else {
            return nil
        }
        return URL(string: trimmed, relativeTo: shareLinkHost)?.absoluteURL
    }
}

/// Reads `publicSharePath` from a JFS item document: the item's own (a direct
/// child of the root element), and those of the files and folders listed in
/// it (`<files><file name="…">…<publicSharePath>`).
final class ShareLinkParser: NSObject, XMLParserDelegate {
    struct Result: Equatable {
        var own: URL?
        var children: [String: URL] = [:]
    }

    private var result = Result()
    private var depth = 0
    /// Name of the listed child being read (`<file name>` / `<folder name>`
    /// at depth 3) and its depth.
    private var childName: String?
    private var text = ""

    static func parse(_ data: Data) throws -> Result {
        let delegate = ShareLinkParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw JottacloudError.invalidXML
        }
        return delegate.result
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        depth += 1
        text = ""
        if depth == 3, elementName == "file" || elementName == "folder" {
            childName = attributes["name"]
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        if elementName == "publicSharePath", let link = JottacloudClient.shareLink(forPath: text) {
            if depth == 2 {
                result.own = link
            } else if depth == 4, let childName {
                result.children[childName] = link
            }
        }
        if depth == 3 {
            childName = nil
        }
        depth -= 1
        text = ""
    }
}
