import Foundation

public enum JottacloudError: Error, LocalizedError {
    case invalidLoginToken
    case unsafeIdentityURL
    case missingRefreshToken
    case missingUsername
    case noRemoteVolumes
    case invalidXML
    case httpStatus(Int)
    case invalidRangeResponse
    case tokenRefreshDisabled
    case untrustedUploadURL(host: String)
    case uploadNotVerified
    case unexpectedAllocateResponse(keys: [String])

    public var errorDescription: String? {
        switch self {
        case .invalidLoginToken:
            "Invalid Jottacloud personal login token."
        case .unsafeIdentityURL:
            "Jottacloud authentication URLs must use HTTPS on id.jottacloud.com."
        case .missingRefreshToken:
            "Jottacloud authentication response did not include a refresh token."
        case .missingUsername:
            "Jottacloud customer response did not include a username."
        case .noRemoteVolumes:
            "No Jottacloud devices or mountpoints were found for this account."
        case .invalidXML:
            "Jottacloud returned invalid directory XML."
        case .httpStatus(let status):
            "Jottacloud returned HTTP status \(status)."
        case .invalidRangeResponse:
            "Jottacloud returned an unexpected response to a ranged read."
        case .tokenRefreshDisabled:
            "The saved access token is expired or rejected, and token refresh is disabled."
        case .untrustedUploadURL(let host):
            "Jottacloud returned an upload URL on an untrusted host (\(host))."
        case .uploadNotVerified:
            "Jottacloud did not confirm the uploaded file's size and checksum."
        case .unexpectedAllocateResponse(let keys):
            "Unexpected upload allocation response (keys: \(keys.joined(separator: ", ")))."
        }
    }
}

public struct RemoteEntry: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case file
        case directory
    }

    public let name: String
    public let kind: Kind
    public let size: UInt64
    public let modified: Date?

    public init(name: String, kind: Kind, size: UInt64, modified: Date?) {
        self.name = name
        self.kind = kind
        self.size = size
        self.modified = modified
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name
            && lhs.kind == rhs.kind
            && lhs.size == rhs.size
            && lhs.modified == rhs.modified
    }
}

/// Account storage figures from the JFS account document (`<capacity>`, where
/// `-1` means unlimited, and `<usage>`, both in bytes). Either may be missing.
public struct JottacloudStorage: Sendable, Equatable {
    public let capacity: UInt64?
    public let usage: UInt64?

    public init(capacity: UInt64?, usage: UInt64?) {
        self.capacity = capacity
        self.usage = usage
    }

    /// Free space reported for an unlimited (or unknown) quota. The kernel
    /// refuses writes with ENOSPC on a volume reporting no free space.
    public static let unlimitedFreeBytes: UInt64 = 1 << 40

    /// Byte totals to report for the volume. Never reports a zero total:
    /// Finder hides volumes without a size. With a known quota the volume is
    /// the quota; with an unlimited or unknown quota it is the usage plus a
    /// nominal `unlimitedFreeBytes`; over quota it is reported full.
    public func volumeSizes(blockSize: UInt64) -> (total: UInt64, used: UInt64, free: UInt64) {
        let used = usage ?? 0
        guard let capacity else {
            return (used + Self.unlimitedFreeBytes, used, Self.unlimitedFreeBytes)
        }
        if capacity >= used, capacity > 0 {
            return (capacity, used, capacity - used)
        }
        let total = max(used, blockSize)
        return (total, total, 0)
    }
}

public struct JottacloudRemoteVolume: Sendable, Equatable, Identifiable {
    public let device: String
    public let mountpoint: String

    public var id: String {
        "\(device)/\(mountpoint)"
    }

    public var displayName: String {
        "\(device) / \(mountpoint)"
    }

    public init(device: String, mountpoint: String) {
        self.device = device
        self.mountpoint = mountpoint
    }
}

public struct JottacloudCredentials: Codable, Sendable, Equatable {
    public var username: String
    public let device: String
    public let mountpoint: String
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var tokenEndpoint: URL

    public init(
        username: String,
        device: String = "Jotta",
        mountpoint: String = "Archive",
        accessToken: String,
        refreshToken: String,
        expiresAt: Date,
        tokenEndpoint: URL
    ) {
        self.username = username
        self.device = device
        self.mountpoint = mountpoint
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.tokenEndpoint = tokenEndpoint
    }
}

public actor JottacloudClient {
    private static let clientID = "jottacli"
    private static let apiRoot = URL(string: "https://api.jottacloud.com/")!
    private static let jfsRoot = "https://jfs.jottacloud.com/jfs/"
    private static let maxReadSize = 1024 * 1024

    private let http: URLSession
    private let authHTTP: URLSession
    private let allowsTokenRefresh: Bool
    private var credentials: JottacloudCredentials
    private let persistCredentials: (@Sendable (JottacloudCredentials) async throws -> Void)?
    private var refreshTask: Task<JottacloudCredentials, Error>?

    public init(
        credentials: JottacloudCredentials,
        allowsTokenRefresh: Bool = true,
        persistCredentials: (@Sendable (JottacloudCredentials) async throws -> Void)? = nil
    ) {
        self.credentials = credentials
        self.allowsTokenRefresh = allowsTokenRefresh
        self.persistCredentials = persistCredentials
        self.http = URLSession(configuration: .ephemeral)
        let configuration = URLSessionConfiguration.ephemeral
        self.authHTTP = URLSession(
            configuration: configuration,
            delegate: NoRedirectDelegate(),
            delegateQueue: nil
        )
    }

    public static func authenticate(
        loginToken: String,
        device: String = "Jotta",
        mountpoint: String = "Archive",
        persistCredentials: (@Sendable (JottacloudCredentials) async throws -> Void)? = nil
    ) async throws -> JottacloudClient {
        let login = try decodeLoginToken(loginToken)
        let discoveryURL = try officialIdentityURL(login.wellKnownLink)
        let authHTTP = URLSession(
            configuration: .ephemeral,
            delegate: NoRedirectDelegate(),
            delegateQueue: nil
        )

        let discoveryData = try await requestData(
            from: authHTTP,
            url: discoveryURL,
            method: "GET"
        )
        let discovery = try JSONDecoder().decode(WellKnown.self, from: discoveryData)
        let tokenEndpoint = try officialIdentityURL(discovery.tokenEndpoint)
        let tokenData = try await requestData(
            from: authHTTP,
            url: tokenEndpoint,
            method: "POST",
            form: [
                "client_id": clientID,
                "grant_type": "password",
                "password": login.authToken,
                "scope": "openid offline_access",
                "username": login.username
            ]
        )
        let tokens = try JSONDecoder().decode(TokenResponse.self, from: tokenData)
        guard let refreshToken = tokens.refreshToken else {
            throw JottacloudError.missingRefreshToken
        }

        let client = JottacloudClient(
            credentials: JottacloudCredentials(
                username: "",
                device: device,
                mountpoint: mountpoint,
                accessToken: tokens.accessToken,
                refreshToken: refreshToken,
                expiresAt: Date().addingTimeInterval(TimeInterval(tokens.expiresIn)),
                tokenEndpoint: tokenEndpoint
            ),
            persistCredentials: persistCredentials
        )
        var credentials = await client.currentCredentials()
        credentials.username = try await client.fetchUsername()
        await client.replaceCredentials(credentials)
        return client
    }

    public func currentCredentials() -> JottacloudCredentials {
        credentials
    }

    public func replaceCredentials(_ credentials: JottacloudCredentials) {
        self.credentials = credentials
    }

    /// Lists devices/mountpoints and reads the account's storage figures from
    /// the same account document.
    public func listAccount() async throws -> (
        volumes: [JottacloudRemoteVolume],
        storage: JottacloudStorage
    ) {
        let accountURL = try Self.makeJFSPathURL([credentials.username])
        let accountResponse = try await authorizedGet(url: accountURL)
        try Self.checkSuccess(accountResponse.statusCode)
        let devices = try parseDriveDeviceNames(accountResponse.data)
        let storage = parseAccountStorage(accountResponse.data)

        var volumes: [JottacloudRemoteVolume] = []
        for device in devices {
            let deviceURL = try Self.makeJFSPathURL([credentials.username, device])
            let deviceResponse = try await authorizedGet(url: deviceURL)
            try Self.checkSuccess(deviceResponse.statusCode)
            let mountpoints = try parseDeviceMountpointNames(deviceResponse.data)
            volumes.append(contentsOf: mountpoints.map {
                JottacloudRemoteVolume(device: device, mountpoint: $0)
            })
        }
        return (volumes, storage)
    }

    public func listDirectory(
        volume: JottacloudRemoteVolume,
        path: String
    ) async throws -> [RemoteEntry] {
        let response = try await authorizedGet(url: jfsURL(volume: volume, path: path))
        try Self.checkSuccess(response.statusCode)
        return try parseDirectory(response.data)
    }

    public func readRange(
        volume: JottacloudRemoteVolume,
        path: String,
        offset: UInt64,
        length: Int,
        fileSize: UInt64
    ) async throws -> Data {
        guard let (boundedLength, rangeEnd) = Self.byteRange(
            offset: offset,
            length: length,
            fileSize: fileSize
        ) else {
            return Data()
        }
        var components = URLComponents(
            url: try jfsURL(volume: volume, path: path),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "mode", value: "bin")]
        guard let url = components.url else {
            throw JottacloudError.invalidRangeResponse
        }
        var accessToken = try await validAccessToken()
        var (bytes, response) = try await http.bytes(
            for: Self.getRequest(url: url, accessToken: accessToken, range: "bytes=\(offset)-\(rangeEnd)")
        )
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            accessToken = try await refreshAfterRejection(accessToken)
            (bytes, response) = try await http.bytes(
                for: Self.getRequest(
                    url: url,
                    accessToken: accessToken,
                    range: "bytes=\(offset)-\(rangeEnd)"
                )
            )
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw JottacloudError.httpStatus(-1)
        }
        let statusCode = httpResponse.statusCode
        if statusCode == 416 {
            return Data()
        }
        guard statusCode == 206 || statusCode == 200 else {
            try Self.checkSuccess(statusCode)
            throw JottacloudError.invalidRangeResponse
        }
        if let contentEncoding = httpResponse.value(forHTTPHeaderField: "Content-Encoding"),
           contentEncoding.caseInsensitiveCompare("identity") != .orderedSame {
            throw JottacloudError.invalidRangeResponse
        }
        if statusCode == 206 {
            try Self.validatePartialContentRange(
                httpResponse.value(forHTTPHeaderField: "Content-Range"),
                offset: offset,
                maximumLength: boundedLength
            )
        }

        var skipRemaining = statusCode == 200 ? offset : 0
        var data = Data()
        data.reserveCapacity(boundedLength)
        for try await byte in bytes {
            if skipRemaining > 0 {
                skipRemaining -= 1
                continue
            }
            data.append(byte)
            if data.count == boundedLength {
                break
            }
        }
        return data
    }

    /// Returns the request length and inclusive range end, or nil when there is
    /// nothing to read. Jottacloud answers 416 (instead of a truncated 206) when
    /// the requested range extends past the end of the file, so the range is
    /// clamped to the size from the directory listing.
    static func byteRange(
        offset: UInt64,
        length: Int,
        fileSize: UInt64
    ) -> (length: Int, end: UInt64)? {
        guard length > 0, offset < fileSize else {
            return nil
        }
        let available = fileSize - offset
        let boundedLength = Int(min(UInt64(min(length, maxReadSize)), available))
        return (boundedLength, offset + UInt64(boundedLength) - 1)
    }

    static func validatePartialContentRange(
        _ value: String?,
        offset: UInt64,
        maximumLength: Int
    ) throws {
        guard let value else {
            throw JottacloudError.invalidRangeResponse
        }
        let components = value.split(whereSeparator: \.isWhitespace)
        guard components.count == 2,
              components[0].caseInsensitiveCompare("bytes") == .orderedSame
        else {
            throw JottacloudError.invalidRangeResponse
        }
        let rangeAndTotal = components[1].split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard rangeAndTotal.count == 2 else {
            throw JottacloudError.invalidRangeResponse
        }
        let bounds = rangeAndTotal[0].split(
            separator: "-",
            omittingEmptySubsequences: false
        )
        guard bounds.count == 2,
              let start = UInt64(bounds[0]),
              let end = UInt64(bounds[1]),
              start == offset,
              end >= start,
              end - start < UInt64(maximumLength)
        else {
            throw JottacloudError.invalidRangeResponse
        }
        if rangeAndTotal[1] != "*" {
            guard let total = UInt64(rangeAndTotal[1]), total > end else {
                throw JottacloudError.invalidRangeResponse
            }
        }
    }

    private func fetchUsername() async throws -> String {
        let url = Self.apiRoot.appending(path: "account/v1/customer")
        let response = try await authorizedGet(url: url)
        try Self.checkSuccess(response.statusCode)
        let customer = try JSONDecoder().decode(CustomerInfo.self, from: response.data)
        guard !customer.username.isEmpty else {
            throw JottacloudError.missingUsername
        }
        return customer.username
    }

    private func authorizedGet(
        url: URL,
        range: String? = nil
    ) async throws -> (data: Data, statusCode: Int) {
        let initialToken = try await validAccessToken()
        var response = try await sendGet(url: url, range: range, accessToken: initialToken)
        if response.statusCode == 401 {
            let latestToken = try await refreshAfterRejection(initialToken)
            response = try await sendGet(url: url, range: range, accessToken: latestToken)
        }
        return response
    }

    private func sendGet(
        url: URL,
        range: String?,
        accessToken: String
    ) async throws -> (data: Data, statusCode: Int) {
        let request = Self.getRequest(url: url, accessToken: accessToken, range: range)
        return try await Self.perform(http, request: request)
    }

    private func validAccessToken() async throws -> String {
        if credentials.expiresAt.timeIntervalSinceNow > 30 {
            return credentials.accessToken
        }
        guard allowsTokenRefresh else {
            throw JottacloudError.tokenRefreshDisabled
        }
        return try await rotateRefreshToken()
    }

    private func refreshAfterRejection(_ rejectedToken: String) async throws -> String {
        guard credentials.accessToken == rejectedToken else {
            return credentials.accessToken
        }
        guard allowsTokenRefresh else {
            throw JottacloudError.tokenRefreshDisabled
        }
        return try await rotateRefreshToken()
    }

    private func rotateRefreshToken() async throws -> String {
        if let refreshTask {
            credentials = try await refreshTask.value
            return credentials.accessToken
        }

        let currentCredentials = credentials
        let session = authHTTP
        let persistCredentials = persistCredentials
        let task = Task {
            let tokens = try await Self.refresh(
                session: session,
                endpoint: currentCredentials.tokenEndpoint,
                refreshToken: currentCredentials.refreshToken
            )
            guard let refreshToken = tokens.refreshToken else {
                throw JottacloudError.missingRefreshToken
            }
            var updated = currentCredentials
            updated.accessToken = tokens.accessToken
            updated.refreshToken = refreshToken
            updated.expiresAt = Date().addingTimeInterval(TimeInterval(tokens.expiresIn))
            try await persistCredentials?(updated)
            return updated
        }
        refreshTask = task
        do {
            credentials = try await task.value
            refreshTask = nil
            return credentials.accessToken
        } catch {
            refreshTask = nil
            throw error
        }
    }

    private static func refresh(
        session: URLSession,
        endpoint: URL,
        refreshToken: String
    ) async throws -> TokenResponse {
        let data = try await requestData(
            from: session,
            url: endpoint,
            method: "POST",
            form: [
                "client_id": clientID,
                "grant_type": "refresh_token",
                "refresh_token": refreshToken
            ]
        )
        let response = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard response.refreshToken != nil else {
            throw JottacloudError.missingRefreshToken
        }
        return response
    }

    private func jfsURL(
        volume: JottacloudRemoteVolume,
        path: String
    ) throws -> URL {
        try Self.makeJFSURL(
            username: credentials.username,
            device: volume.device,
            mountpoint: volume.mountpoint,
            path: path
        )
    }

    static func makeJFSURL(
        username: String,
        device: String,
        mountpoint: String,
        path: String
    ) throws -> URL {
        let segments = [username, device, mountpoint] + path.split(separator: "/").map(String.init)
        return try makeJFSPathURL(segments)
    }

    static func makeJFSPathURL(_ segments: [String]) throws -> URL {
        var components = URLComponents(string: jfsRoot)!
        let rootPath = components.percentEncodedPath.hasSuffix("/")
            ? String(components.percentEncodedPath.dropLast())
            : components.percentEncodedPath
        components.percentEncodedPath = rootPath + segments
            .map(encodePathSegment)
            .map { "/" + $0 }
            .joined()
        guard let url = components.url else {
            throw JottacloudError.invalidLoginToken
        }
        return url
    }

    private static func getRequest(
        url: URL,
        accessToken: String,
        range: String?
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("jottafs/0.1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let range {
            request.setValue(range, forHTTPHeaderField: "Range")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        }
        return request
    }

    private static func encodePathSegment(_ segment: String) -> String {
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
        )
        return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
    }

    static func decodeLoginToken(_ token: String) throws -> LoginToken {
        guard !token.isEmpty, token.utf8.count <= 16 * 1024 else {
            throw JottacloudError.invalidLoginToken
        }
        var base64 = token.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let login = try? JSONDecoder().decode(LoginToken.self, from: data),
              !login.username.isEmpty,
              !login.authToken.isEmpty
        else {
            throw JottacloudError.invalidLoginToken
        }
        return login
    }

    static func officialIdentityURL(_ value: String) throws -> URL {
        guard let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "id.jottacloud.com",
              url.port == nil || url.port == 443,
              url.user == nil,
              url.password == nil
        else {
            throw JottacloudError.unsafeIdentityURL
        }
        return url
    }

    private static func requestData(
        from session: URLSession,
        url: URL,
        method: String,
        form: [String: String]? = nil
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("jottafs/0.1.0", forHTTPHeaderField: "User-Agent")
        if let form {
            request.setValue(
                "application/x-www-form-urlencoded",
                forHTTPHeaderField: "Content-Type"
            )
            request.httpBody = form
                .map { key, value in
                    "\(formEncode(key))=\(formEncode(value))"
                }
                .sorted()
                .joined(separator: "&")
                .data(using: .utf8)
        }
        let response = try await perform(session, request: request)
        try checkSuccess(response.statusCode)
        return response.data
    }

    private static func perform(
        _ session: URLSession,
        request: URLRequest
    ) async throws -> (data: Data, statusCode: Int) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw JottacloudError.httpStatus(-1)
        }
        return (data, http.statusCode)
    }

    private static func checkSuccess(_ statusCode: Int) throws {
        guard (200..<300).contains(statusCode) else {
            throw JottacloudError.httpStatus(statusCode)
        }
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

struct LoginToken: Decodable {
    let username: String
    let wellKnownLink: String
    let authToken: String

    enum CodingKeys: String, CodingKey {
        case username
        case wellKnownLink = "well_known_link"
        case authToken = "auth_token"
    }
}

private struct WellKnown: Decodable {
    let tokenEndpoint: String

    enum CodingKeys: String, CodingKey {
        case tokenEndpoint = "token_endpoint"
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: UInt64

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

private struct CustomerInfo: Decodable {
    let username: String
}

private func formEncode(_ value: String) -> String {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&=+")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}

func parseDirectory(_ data: Data) throws -> [RemoteEntry] {
    let parser = DirectoryXMLParser()
    let xmlParser = XMLParser(data: data)
    xmlParser.delegate = parser
    guard xmlParser.parse() else {
        throw JottacloudError.invalidXML
    }
    return parser.entries
}

/// Parses a single-file metadata response (`GET` on a file's JFS path).
/// Returns nil unless the current revision is `COMPLETED`.
func parseFileRevision(_ data: Data) throws -> RemoteFileRevision? {
    let parser = DirectoryXMLParser(acceptsRootFile: true)
    let xmlParser = XMLParser(data: data)
    xmlParser.delegate = parser
    guard xmlParser.parse() else {
        throw JottacloudError.invalidXML
    }
    return parser.fileRevisions.first
}

func parseDriveDeviceNames(_ data: Data) throws -> [String] {
    try parseJottacloudLocations(data, collecting: .devices)
}

func parseDeviceMountpointNames(_ data: Data) throws -> [String] {
    try parseJottacloudLocations(data, collecting: .mountpoints)
}

/// Reads `<capacity>` and `<usage>` directly under the account's root element.
/// Missing or non-numeric values (and capacity `-1`, unlimited) become nil.
func parseAccountStorage(_ data: Data) -> JottacloudStorage {
    let delegate = AccountStorageParser()
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    guard parser.parse() else {
        return JottacloudStorage(capacity: nil, usage: nil)
    }
    return JottacloudStorage(
        capacity: delegate.values["capacity"].flatMap { UInt64($0) },
        usage: delegate.values["usage"].flatMap { UInt64($0) }
    )
}

private final class AccountStorageParser: NSObject, XMLParserDelegate {
    private(set) var values: [String: String] = [:]
    private var depth = 0
    private var capturing: String?
    private var text = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        depth += 1
        if depth == 2, elementName == "capacity" || elementName == "usage" {
            capturing = elementName
            text = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing != nil {
            text += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if let capturing, capturing == elementName, depth == 2 {
            values[capturing] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            self.capturing = nil
        }
        depth -= 1
    }
}

private func parseJottacloudLocations(
    _ data: Data,
    collecting kind: JottacloudLocationParser.Collection
) throws -> [String] {
    let delegate = JottacloudLocationParser(collection: kind)
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    guard parser.parse(), delegate.sawCollection else {
        throw JottacloudError.invalidXML
    }
    return delegate.names
}

private final class JottacloudLocationParser: NSObject, XMLParserDelegate {
    enum Collection {
        case devices
        case mountpoints
    }

    private enum Capturing {
        case deviceName
        case mountpointName
    }

    let collection: Collection
    private(set) var sawCollection = false
    private(set) var names: [String] = []
    private var elements: [String] = []
    private var currentDeviceName: String?
    private var currentMountpointName: String?
    private var capturing: Capturing?
    private var text = ""

    init(collection: Collection) {
        self.collection = collection
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let parent = elements.last
        if collection == .devices, elementName == "devices" {
            sawCollection = true
        } else if collection == .mountpoints, elementName == "mountPoints" {
            sawCollection = true
        }

        if collection == .devices, elementName == "device", parent == "devices" {
            currentDeviceName = ""
        } else if collection == .mountpoints,
                  elementName == "mountPoint",
                  parent == "mountPoints" {
            currentMountpointName = ""
        } else if elementName == "name" {
            if currentMountpointName != nil {
                capturing = .mountpointName
                text = ""
            } else if currentDeviceName != nil {
                capturing = .deviceName
                text = ""
            }
        }
        elements.append(elementName)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard capturing != nil else {
            return
        }
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "name" {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch capturing {
            case .deviceName:
                currentDeviceName = value
            case .mountpointName:
                currentMountpointName = value
            case nil:
                break
            }
            capturing = nil
            text = ""
        } else if collection == .devices,
                  elementName == "device",
                  let name = currentDeviceName {
            if validName(name) {
                names.append(name)
            }
            currentDeviceName = nil
        } else if collection == .mountpoints,
                  elementName == "mountPoint",
                  let name = currentMountpointName {
            if validName(name) {
                names.append(name)
            }
            currentMountpointName = nil
        }
        if !elements.isEmpty {
            elements.removeLast()
        }
    }
}

private final class DirectoryXMLParser: NSObject, XMLParserDelegate {
    private(set) var entries: [RemoteEntry] = []
    private(set) var fileRevisions: [RemoteFileRevision] = []
    private var currentEntry: PendingEntry?
    private var currentRevision: PendingRevision?
    private var text = ""
    private var elements: [String] = []
    /// A listing's root element (`<folder name=…>` for the listed folder
    /// itself) is not a child: only `<folder>`/`<file>` directly inside a
    /// `<folders>`/`<files>` list are. Single-file metadata responses have a
    /// root `<file>`, which `acceptsRootFile` allows.
    private let acceptsRootFile: Bool

    init(acceptsRootFile: Bool = false) {
        self.acceptsRootFile = acceptsRootFile
    }

    private func isEntryElement(_ name: String) -> Bool {
        let parent = elements.last
        switch name {
        case "folder":
            return parent == "folders"
        case "file":
            return parent == "files" || (acceptsRootFile && parent == nil)
        default:
            return false
        }
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        text = ""
        if currentEntry == nil, isEntryElement(elementName), let name = attributeDict["name"] {
            currentEntry = PendingEntry(
                name: name,
                kind: elementName == "folder" ? .directory : .file,
                deleted: attributeDict["deleted"] != nil,
                depth: elements.count
            )
        } else if elementName == "currentRevision",
                  let entry = currentEntry,
                  entry.depth == elements.count - 1 {
            currentRevision = PendingRevision()
        }
        elements.append(elementName)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if !elements.isEmpty {
            elements.removeLast()
        }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        guard let entry = currentEntry else {
            return
        }
        switch elementName {
        case "state":
            currentRevision?.state = value
        case "size":
            currentRevision?.size = UInt64(value) ?? 0
        case "md5":
            currentRevision?.md5 = value.lowercased()
        case "modified":
            if currentRevision != nil {
                currentRevision?.modified = parseTimestamp(value)
            } else if elements.count == entry.depth + 1 {
                entry.modified = parseTimestamp(value)
            }
        case "currentRevision":
            if currentRevision != nil {
                entry.revision = currentRevision
                currentRevision = nil
            }
        case "folder", "file":
            guard elements.count == entry.depth else {
                return
            }
            finish(entry)
            currentEntry = nil
        default:
            break
        }
    }

    private func finish(_ entry: PendingEntry) {
        guard !entry.deleted, validName(entry.name) else {
            return
        }
        if entry.kind == .directory {
            entries.append(
                RemoteEntry(name: entry.name, kind: .directory, size: 0, modified: entry.modified)
            )
        } else if let revision = entry.revision, revision.state == "COMPLETED" {
            let remoteEntry = RemoteEntry(
                name: entry.name,
                kind: .file,
                size: revision.size,
                modified: revision.modified
            )
            entries.append(remoteEntry)
            fileRevisions.append(RemoteFileRevision(entry: remoteEntry, md5: revision.md5))
        }
    }
}

private final class PendingEntry {
    let name: String
    let kind: RemoteEntry.Kind
    let deleted: Bool
    /// Number of ancestor elements, to tell this entry's own end tag and
    /// direct children apart from nested elements.
    let depth: Int
    var modified: Date?
    var revision: PendingRevision?

    init(name: String, kind: RemoteEntry.Kind, deleted: Bool, depth: Int) {
        self.name = name
        self.kind = kind
        self.deleted = deleted
        self.depth = depth
    }
}

private final class PendingRevision {
    var state = ""
    var size: UInt64 = 0
    var md5: String?
    var modified: Date?
}

private func validName(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
}

private func parseTimestamp(_ value: String) -> Date? {
    let normalized = value.replacingOccurrences(of: "-T", with: "T")
    let formatter = ISO8601DateFormatter()
    if let date = formatter.date(from: normalized) {
        return date
    }
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: normalized)
}

// MARK: - Mutations
//
// Callers must enforce `JottaFSWriteScope` before calling these; the client
// itself only performs the request. Deletes always go to the Jottacloud trash.
extension JottacloudClient {
    public func createFolder(volume: JottacloudRemoteVolume, path: String) async throws {
        let url = try Self.jfsMutationURL(
            try jfsURL(volume: volume, path: path),
            trailingSlash: false,
            query: ("mkDir", "true")
        )
        try await sendMutation(url: url)
    }

    /// Moves a file or folder to the Jottacloud trash (`dl=true` /
    /// `dlDir=true`); never a permanent delete.
    public func trash(
        volume: JottacloudRemoteVolume,
        path: String,
        isDirectory: Bool
    ) async throws {
        let url = try Self.jfsMutationURL(
            try jfsURL(volume: volume, path: path),
            trailingSlash: isDirectory,
            query: isDirectory ? ("dlDir", "true") : ("dl", "true")
        )
        try await sendMutation(url: url)
    }

    /// Renames or moves within one device/mountpoint.
    public func move(
        volume: JottacloudRemoteVolume,
        from source: String,
        to destination: String,
        isDirectory: Bool
    ) async throws {
        let destinationPath = "/" + ([credentials.username, volume.device, volume.mountpoint] + [destination])
            .joined(separator: "/")
        let url = try Self.jfsMutationURL(
            try jfsURL(volume: volume, path: source),
            trailingSlash: isDirectory,
            query: (isDirectory ? "mvDir" : "mv", destinationPath)
        )
        try await sendMutation(url: url)
    }

    /// The file's current completed revision, or nil if it does not exist (or
    /// has no completed revision yet).
    func fileRevision(volume: JottacloudRemoteVolume, path: String) async throws -> RemoteFileRevision? {
        let response = try await authorizedGet(url: try jfsURL(volume: volume, path: path))
        if response.statusCode == 404 {
            return nil
        }
        try Self.checkSuccess(response.statusCode)
        return try parseFileRevision(response.data)
    }

    /// Uploads a complete local file to `path`, replacing any existing file
    /// (Jottacloud keeps the old one as a version), then verifies size and MD5.
    public func upload(
        volume: JottacloudRemoteVolume,
        path: String,
        from fileURL: URL,
        size: UInt64,
        md5: String,
        created: Date,
        modified: Date
    ) async throws -> RemoteEntry {
        let allocation = AllocateRequest(
            device: volume.device,
            mountpoint: volume.mountpoint,
            path: path,
            bytes: size,
            md5: md5,
            created: created,
            modified: modified
        )
        let body = try JSONEncoder().encode(allocation)
        let allocateURL = Self.apiRoot.appending(path: "files/v1/allocate")
        let allocateResponse = try await authorizedSend { token in
            Self.mutationRequest(
                url: allocateURL,
                accessToken: token,
                contentType: "application/json",
                body: body
            )
        }
        try Self.checkSuccess(allocateResponse.statusCode)
        let allocated: AllocateResponse
        do {
            allocated = try JSONDecoder().decode(AllocateResponse.self, from: allocateResponse.data)
        } catch {
            // Report only the field names, never values (they include tokens).
            let object = try? JSONSerialization.jsonObject(with: allocateResponse.data) as? [String: Any]
            throw JottacloudError.unexpectedAllocateResponse(keys: object.map { $0.keys.sorted() } ?? ["not a JSON object"])
        }

        if allocated.state != "COMPLETED" {
            guard let uploadURLString = allocated.uploadURL else {
                throw JottacloudError.unexpectedAllocateResponse(keys: ["missing upload_url"])
            }
            guard let uploadURL = Self.trustedUploadURL(uploadURLString) else {
                throw JottacloudError.untrustedUploadURL(
                    host: URL(string: uploadURLString)?.host ?? "unparseable"
                )
            }
            let resume = min(allocated.resumePosition ?? 0, size)
            let (bodyFile, temporary) = try Self.uploadBody(fileURL, from: resume)
            defer {
                if temporary {
                    try? FileManager.default.removeItem(at: bodyFile)
                }
            }
            let uploadResponse = try await authorizedSend(bodyFile: bodyFile) { token in
                var request = Self.mutationRequest(
                    url: uploadURL,
                    accessToken: token,
                    contentType: "application/octet-stream",
                    body: nil
                )
                if resume > 0, size > 0 {
                    request.setValue("bytes=\(resume)-\(size - 1)", forHTTPHeaderField: "Range")
                }
                return request
            }
            try Self.checkSuccess(uploadResponse.statusCode)
        }

        // The listing can lag slightly behind the upload; poll briefly.
        for attempt in 0..<8 {
            if let revision = try await fileRevision(volume: volume, path: path),
               revision.entry.size == size,
               revision.md5 == nil || revision.md5 == md5 {
                return revision.entry
            }
            try await Task.sleep(for: .milliseconds(250 * (attempt + 1)))
        }
        throw JottacloudError.uploadNotVerified
    }

    // MARK: Helpers

    private func sendMutation(url: URL) async throws {
        let response = try await authorizedSend { token in
            Self.mutationRequest(url: url, accessToken: token, contentType: nil, body: nil)
        }
        try Self.checkSuccess(response.statusCode)
    }

    /// Sends a request built for the current access token, refreshing once on
    /// 401 like `authorizedGet`.
    private func authorizedSend(
        bodyFile: URL? = nil,
        _ build: @Sendable (String) -> URLRequest
    ) async throws -> (data: Data, statusCode: Int) {
        let initialToken = try await validAccessToken()
        var response = try await send(build(initialToken), bodyFile: bodyFile)
        if response.statusCode == 401 {
            let latestToken = try await refreshAfterRejection(initialToken)
            response = try await send(build(latestToken), bodyFile: bodyFile)
        }
        return response
    }

    private func send(
        _ request: URLRequest,
        bodyFile: URL?
    ) async throws -> (data: Data, statusCode: Int) {
        guard let bodyFile else {
            return try await Self.perform(http, request: request)
        }
        let (data, response) = try await http.upload(for: request, fromFile: bodyFile)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw JottacloudError.httpStatus(-1)
        }
        return (data, httpResponse.statusCode)
    }

    static func mutationRequest(
        url: URL,
        accessToken: String,
        contentType: String?,
        body: Data?
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("jottafs/0.1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = body
        return request
    }

    /// Adds a trailing slash (folder operations) and one query parameter,
    /// percent-encoding the value fully so `+`, `&` and spaces survive.
    static func jfsMutationURL(
        _ url: URL,
        trailingSlash: Bool,
        query: (name: String, value: String)
    ) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw JottacloudError.invalidXML
        }
        if trailingSlash, !components.percentEncodedPath.hasSuffix("/") {
            components.percentEncodedPath += "/"
        }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/"
        )
        let value = query.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? query.value
        components.percentEncodedQuery = "\(query.name)=\(value)"
        guard let result = components.url else {
            throw JottacloudError.invalidXML
        }
        return result
    }

    /// Jottacloud's own domains; upload servers may be on `jotta.cloud`.
    static let trustedUploadDomains = ["jottacloud.com", "jotta.cloud"]

    /// Only send the bearer token to Jottacloud's own HTTPS hosts.
    static func trustedUploadURL(_ value: String) -> URL? {
        guard let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              trustedUploadDomains.contains(where: { host == $0 || host.hasSuffix("." + $0) }),
              url.user == nil,
              url.password == nil
        else {
            return nil
        }
        return url
    }

    /// The file to send: the whole staging file, or (when resuming) a
    /// temporary copy of its tail.
    private static func uploadBody(_ fileURL: URL, from offset: UInt64) throws -> (URL, Bool) {
        guard offset > 0 else {
            return (fileURL, false)
        }
        let tail = FileManager.default.temporaryDirectory
            .appendingPathComponent("jottafs-upload-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: tail.path, contents: nil)
        let reader = try FileHandle(forReadingFrom: fileURL)
        defer { try? reader.close() }
        let writer = try FileHandle(forWritingTo: tail)
        defer { try? writer.close() }
        try reader.seek(toOffset: offset)
        while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty {
            try writer.write(contentsOf: chunk)
        }
        return (tail, true)
    }
}
