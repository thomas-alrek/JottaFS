import CryptoKit
import Foundation
import Security

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
    /// An upload sent nothing for too long (`UploadRetryPolicy.stallLimit`).
    case uploadStalled
    case unexpectedAllocateResponse(keys: [String])
    case grpcStatus(Int)
    case notInTrash
    case browserLoginFailed(String)
    case browserLoginStateMismatch
    case invalidPath
    case locationNotFound
    /// Jottacloud no longer accepts the refresh token: the sign-in has
    /// ended (revoked, or unused for too long). The user must sign in again.
    case sessionEnded

    public var errorDescription: String? {
        switch self {
        case .invalidLoginToken:
            String(localized: "Invalid Jottacloud personal login token.", bundle: .jottaFSCore)
        case .unsafeIdentityURL:
            String(localized: "Jottacloud authentication URLs must use HTTPS on id.jottacloud.com.", bundle: .jottaFSCore)
        case .missingRefreshToken:
            String(localized: "Jottacloud authentication response did not include a refresh token.", bundle: .jottaFSCore)
        case .missingUsername:
            String(localized: "Jottacloud customer response did not include a username.", bundle: .jottaFSCore)
        case .noRemoteVolumes:
            String(localized: "No Jottacloud devices or mountpoints were found for this account.", bundle: .jottaFSCore)
        case .invalidXML:
            String(localized: "Jottacloud returned invalid directory XML.", bundle: .jottaFSCore)
        case .httpStatus(let status):
            String(localized: "Jottacloud returned HTTP status \(status).", bundle: .jottaFSCore)
        case .invalidRangeResponse:
            String(localized: "Jottacloud returned an unexpected response to a ranged read.", bundle: .jottaFSCore)
        case .tokenRefreshDisabled:
            String(localized: "The saved access token is expired or rejected, and token refresh is disabled.", bundle: .jottaFSCore)
        case .untrustedUploadURL(let host):
            String(localized: "Jottacloud returned an upload URL on an untrusted host (\(host)).", bundle: .jottaFSCore)
        case .uploadNotVerified:
            String(localized: "Jottacloud did not confirm the uploaded file's size and checksum.", bundle: .jottaFSCore)
        case .uploadStalled:
            String(localized: "The upload to Jottacloud stopped making progress.", bundle: .jottaFSCore)
        case .unexpectedAllocateResponse(let keys):
            String(localized: "Unexpected upload allocation response (keys: \(keys.joined(separator: ", "))).", bundle: .jottaFSCore)
        case .grpcStatus(let status):
            String(localized: "Jottacloud returned gRPC status \(status).", bundle: .jottaFSCore)
        case .notInTrash:
            String(localized: "The item is not in the Jottacloud trash, so it was not deleted permanently.", bundle: .jottaFSCore)
        case .browserLoginFailed(let reason):
            String(localized: "Jottacloud did not complete the sign-in (\(reason)).", bundle: .jottaFSCore)
        case .browserLoginStateMismatch:
            String(localized: "The sign-in response did not match this sign-in attempt.", bundle: .jottaFSCore)
        case .invalidPath:
            String(localized: "The path cannot be used in a Jottacloud request.", bundle: .jottaFSCore)
        case .locationNotFound:
            String(localized: "The chosen Jottacloud location no longer exists.", bundle: .jottaFSCore)
        case .sessionEnded:
            String(localized: "Your Jottacloud sign-in has ended. Sign in again.", bundle: .jottaFSCore)
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
    /// MD5 of a file's current revision (lower-case hex), when known. Keys the
    /// extension's block cache.
    public let md5: String?

    public init(name: String, kind: Kind, size: UInt64, modified: Date?, md5: String? = nil) {
        self.name = name
        self.kind = kind
        self.size = size
        self.modified = modified
        self.md5 = md5
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
    /// Jottacloud's own device (Archive, Sync, Shared…); other devices are
    /// computer backups.
    public static let builtInDevice = "Jotta"

    public let device: String
    public let mountpoint: String

    public var isBuiltIn: Bool {
        device == Self.builtInDevice
    }

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
    /// The Jottacloud location (device/mountpoint) mounted as the volume.
    public var device: String
    public var mountpoint: String
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var tokenEndpoint: URL
    /// The account holder's name and email, for display only (optional:
    /// credentials saved before these were added do not have them).
    public var accountName: String?
    public var accountEmail: String?

    public init(
        username: String,
        device: String = JottacloudRemoteVolume.builtInDevice,
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
    /// Identifies JottaFS in requests (the app version, from the bundle).
    static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "jottafs/\(version)"
    }()
    private static let clientID = "jottacli"
    private static let apiRoot = URL(string: "https://api.jottacloud.com/")!
    private static let jfsRoot = "https://jfs.jottacloud.com/jfs/"
    public static let maxReadSize = 1024 * 1024

    private let http: URLSession
    private let authHTTP: URLSession
    private let allowsTokenRefresh: Bool
    private var credentials: JottacloudCredentials
    private let persistCredentials: (@Sendable (JottacloudCredentials) async throws -> Void)?
    /// Reads the newest saved credentials. The app and the file system
    /// extension each hold a client for the same account; refresh tokens
    /// rotate, so before refreshing, a client adopts tokens the other one
    /// saved instead of using an already rotated refresh token.
    private let loadSavedCredentials: (@Sendable () -> JottacloudCredentials?)?
    private var refreshTask: Task<JottacloudCredentials, Error>?
    /// Called once when Jottacloud refuses the refresh token (the sign-in
    /// has ended), before the request fails with `sessionEnded`.
    private let sessionEnded: (@Sendable () -> Void)?

    public init(
        credentials: JottacloudCredentials,
        allowsTokenRefresh: Bool = true,
        persistCredentials: (@Sendable (JottacloudCredentials) async throws -> Void)? = nil,
        loadSavedCredentials: (@Sendable () -> JottacloudCredentials?)? = nil,
        sessionEnded: (@Sendable () -> Void)? = nil
    ) {
        self.credentials = credentials
        self.allowsTokenRefresh = allowsTokenRefresh
        self.persistCredentials = persistCredentials
        self.loadSavedCredentials = loadSavedCredentials
        self.sessionEnded = sessionEnded
        self.http = URLSession(configuration: Self.dataSessionConfiguration)
        self.authHTTP = Self.identitySession
    }

    deinit {
        http.finishTasksAndInvalidate()
    }

    /// For identity requests (discovery, tokens): never follows redirects.
    /// Shared and never invalidated, so it does not leak per client.
    /// The data session: up to 16 connections per host (the default is 6),
    /// so the extension's read-ahead (up to 8 blocks per file) can run for
    /// more than one file next to listings and uploads.
    static var dataSessionConfiguration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 16
        return configuration
    }

    static let identitySession = URLSession(
        configuration: .ephemeral,
        delegate: NoRedirectDelegate(),
        delegateQueue: nil
    )

    public static func authenticate(
        loginToken: String,
        device: String = JottacloudRemoteVolume.builtInDevice,
        mountpoint: String = "Archive",
        persistCredentials: (@Sendable (JottacloudCredentials) async throws -> Void)? = nil
    ) async throws -> JottacloudClient {
        let login = try decodeLoginToken(loginToken)
        let discoveryURL = try officialIdentityURL(login.wellKnownLink)
        let authHTTP = identitySession

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
        return try await makeSignedInClient(
            tokens: tokens,
            tokenEndpoint: tokenEndpoint,
            device: device,
            mountpoint: mountpoint,
            persistCredentials: persistCredentials
        )
    }

    private static func makeSignedInClient(
        tokens: TokenResponse,
        tokenEndpoint: URL,
        device: String,
        mountpoint: String,
        persistCredentials: (@Sendable (JottacloudCredentials) async throws -> Void)?
    ) async throws -> JottacloudClient {
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
        let customer = try await client.fetchCustomer()
        credentials.username = customer.username
        credentials.accountName = customer.name
        credentials.accountEmail = customer.email
        await client.replaceCredentials(credentials)
        return client
    }

    /// The account holder's name and email (for display).
    public func fetchAccountProfile() async throws -> (name: String?, email: String?) {
        let customer = try await fetchCustomer()
        credentials.accountName = customer.name
        credentials.accountEmail = customer.email
        return (customer.name, customer.email)
    }

    /// Changes the location mounted as the volume (saved with the
    /// credentials by the caller).
    public func setLocation(device: String, mountpoint: String) {
        credentials.device = device
        credentials.mountpoint = mountpoint
    }

    public func currentCredentials() -> JottacloudCredentials {
        credentials
    }

    func replaceCredentials(_ credentials: JottacloudCredentials) {
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
            let mountpoints = try await listMountpoints(device: device)
            volumes.append(contentsOf: mountpoints.map {
                JottacloudRemoteVolume(device: device, mountpoint: $0)
            })
        }
        return (volumes, storage)
    }

    /// The mountpoints of one device (for a backup device, its backup sets).
    public func listMountpoints(device: String) async throws -> [String] {
        let deviceURL = try Self.makeJFSPathURL([credentials.username, device])
        let deviceResponse = try await authorizedGet(url: deviceURL)
        try Self.checkSuccess(deviceResponse.statusCode)
        return try parseDeviceMountpointNames(deviceResponse.data)
    }

    public func listDirectory(
        volume: JottacloudRemoteVolume,
        path: String
    ) async throws -> [RemoteEntry] {
        let response = try await authorizedGet(url: jfsURL(volume: volume, path: path))
        try Self.checkSuccess(response.statusCode)
        return try parseDirectory(response.data)
    }

    /// Reads `length` bytes at `offset` (one ranged request). Reads are
    /// limited to `maximumLength` (1 MiB unless a caller reads ahead in
    /// larger blocks).
    public func readRange(
        volume: JottacloudRemoteVolume,
        path: String,
        offset: UInt64,
        length: Int,
        fileSize: UInt64,
        maximumLength: Int = maxReadSize
    ) async throws -> Data {
        guard let (boundedLength, rangeEnd) = Self.byteRange(
            offset: offset,
            length: length,
            fileSize: fileSize,
            maximumLength: maximumLength
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
        let range = "bytes=\(offset)-\(rangeEnd)"
        var accessToken = try await validAccessToken()
        var result = try await Self.boundedData(
            http,
            for: Self.getRequest(url: url, accessToken: accessToken, range: range),
            limit: boundedLength,
            allowsFullResponse: offset == 0
        )
        if result.response.statusCode == 401 {
            accessToken = try await refreshAfterRejection(accessToken)
            result = try await Self.boundedData(
                http,
                for: Self.getRequest(url: url, accessToken: accessToken, range: range),
                limit: boundedLength,
                allowsFullResponse: offset == 0
            )
        }
        let httpResponse = result.response
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
        // A 200 ignores the range: fine at offset 0 (the start is read), but
        // at any other offset it would mean downloading and discarding
        // everything before it, possibly gigabytes (the download was
        // cancelled as soon as the status arrived).
        if statusCode == 200, offset > 0 {
            throw JottacloudError.invalidRangeResponse
        }
        return result.data
    }

    /// Downloads at most `limit` bytes of a response, in chunks as they
    /// arrive (collecting a large range byte by byte was the bottleneck of
    /// sequential reads), and cancels the transfer when `limit` is reached.
    /// Without `allowsFullResponse`, a 200 (a server ignoring the range) is
    /// cancelled before its body is downloaded.
    static func boundedData(
        _ session: URLSession,
        for request: URLRequest,
        limit: Int,
        allowsFullResponse: Bool
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        let collector = BoundedDataCollector(limit: limit, allowsFullResponse: allowsFullResponse)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                collector.start(session: session, request: request, continuation: continuation)
            }
        } onCancel: {
            collector.cancel()
        }
    }

    /// Returns the request length and inclusive range end, or nil when there is
    /// nothing to read. Jottacloud answers 416 (instead of a truncated 206) when
    /// the requested range extends past the end of the file, so the range is
    /// clamped to the size from the directory listing.
    static func byteRange(
        offset: UInt64,
        length: Int,
        fileSize: UInt64,
        maximumLength: Int = maxReadSize
    ) -> (length: Int, end: UInt64)? {
        guard length > 0, offset < fileSize else {
            return nil
        }
        let available = fileSize - offset
        let boundedLength = Int(min(UInt64(min(length, maximumLength)), available))
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

    private func fetchCustomer() async throws -> CustomerInfo {
        let url = Self.apiRoot.appending(path: "account/v1/customer")
        let response = try await authorizedGet(url: url)
        try Self.checkSuccess(response.statusCode)
        let customer = try JSONDecoder().decode(CustomerInfo.self, from: response.data)
        guard !customer.username.isEmpty else {
            throw JottacloudError.missingUsername
        }
        return customer
    }

    func authorizedGet(
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
            adoptTokens(try await refreshTask.value)
            return credentials.accessToken
        }
        if adoptSavedTokens(), credentials.expiresAt.timeIntervalSinceNow > 30 {
            // Another process already rotated the tokens.
            return credentials.accessToken
        }
        do {
            return try await refreshNow()
        } catch JottacloudError.httpStatus(let status) where status == 400 || status == 401 {
            // Our refresh token may have been rotated by the other process
            // meanwhile: retry once with the newest saved one.
            guard adoptSavedTokens() else {
                throw endSession()
            }
            if credentials.expiresAt.timeIntervalSinceNow > 30 {
                return credentials.accessToken
            }
            do {
                return try await refreshNow()
            } catch JottacloudError.httpStatus(let status) where status == 400 || status == 401 {
                throw endSession()
            }
        }
    }

    /// The identity server refused the newest refresh token (400 is
    /// `invalid_grant`: revoked or expired): the sign-in has ended.
    private func endSession() -> JottacloudError {
        sessionEnded?()
        return .sessionEnded
    }

    /// Refreshes the tokens now, whatever their expiry, so the offline
    /// session does not pass Jottacloud's idle limit while nothing uses it.
    /// Throws `sessionEnded` if the sign-in has ended.
    public func refreshSession() async throws {
        guard allowsTokenRefresh else {
            throw JottacloudError.tokenRefreshDisabled
        }
        if let refreshTask {
            adoptTokens(try await refreshTask.value)
            return
        }
        _ = adoptSavedTokens()
        do {
            _ = try await refreshNow()
        } catch JottacloudError.httpStatus(let status) where status == 400 || status == 401 {
            guard adoptSavedTokens() else {
                throw endSession()
            }
            do {
                _ = try await refreshNow()
            } catch JottacloudError.httpStatus(let status) where status == 400 || status == 401 {
                throw endSession()
            }
        }
    }

    /// Takes over tokens another process saved; true if they were newer.
    private func adoptSavedTokens() -> Bool {
        guard let saved = loadSavedCredentials?(),
              saved.username == credentials.username,
              saved.refreshToken != credentials.refreshToken
        else {
            return false
        }
        adoptTokens(saved)
        return true
    }

    /// Updates only the token fields, so changes made to other fields while
    /// a refresh was running (location, profile) are kept.
    private func adoptTokens(_ source: JottacloudCredentials) {
        credentials.accessToken = source.accessToken
        credentials.refreshToken = source.refreshToken
        credentials.expiresAt = source.expiresAt
    }

    private func refreshNow() async throws -> String {
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
            adoptTokens(try await task.value)
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

    func jfsURL(
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
            throw JottacloudError.invalidPath
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
        request.setValue(JottacloudClient.userAgent, forHTTPHeaderField: "User-Agent")
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
        request.setValue(JottacloudClient.userAgent, forHTTPHeaderField: "User-Agent")
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

    static func checkSuccess(_ statusCode: Int) throws {
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
    let authorizationEndpoint: String?

    enum CodingKeys: String, CodingKey {
        case tokenEndpoint = "token_endpoint"
        case authorizationEndpoint = "authorization_endpoint"
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
    let name: String?
    let email: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        username = try container.decode(String.self, forKey: .username)
        // Display only: ignore missing or unexpected values.
        name = (try? container.decodeIfPresent(String.self, forKey: .name))?.nilIfBlank
        email = (try? container.decodeIfPresent(String.self, forKey: .email))?.nilIfBlank
    }

    enum CodingKeys: String, CodingKey {
        case username, name, email
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
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
    private var currentMountpointDeleted = false
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
            // A mountpoint moved to the trash (FileService.Delete) is still
            // listed, with a `<deleted>` child element (seen live
            // 2026-11-27); a `deleted` attribute, as on files, counts too.
            currentMountpointDeleted = attributeDict["deleted"] != nil
        } else if collection == .mountpoints, elementName == "deleted", parent == "mountPoint",
                  currentMountpointName != nil {
            currentMountpointDeleted = true
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
            if validName(name), !currentMountpointDeleted {
                names.append(name)
            }
            currentMountpointName = nil
            currentMountpointDeleted = false
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
                modified: revision.modified,
                md5: revision.md5
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
    // Listings can hold tens of thousands of entries: reuse the parsers.
    return (try? Date(normalized, strategy: .iso8601))
        ?? (try? Date(normalized, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
}

// MARK: - Mutations
//
// The client only performs the requests; the file system decides what may
// change. `trash` sends items to the Jottacloud trash.
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
        modified: Date,
        progress: (@Sendable (_ bytesSent: Int64) -> Void)? = nil,
        phase: (@Sendable (_ name: String) -> Void)? = nil,
        policy: UploadRetryPolicy = .standard
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

        // Allocate and send; on a transient failure (dropped connection,
        // timeout, stall, 5xx/429) allocate again with the same MD5 and send
        // only what Jottacloud has not kept (it keeps interrupted uploads in
        // 32 MiB blocks, reported as resume_pos). The caller (close(2), and
        // so Finder) waits for this, so attempts that send nothing end the
        // upload early (`UploadRetryPolicy`).
        var attemptsWithoutProgress = 0
        // Jottacloud checks the body against the allocated size and MD5 and
        // fails the upload otherwise (421, see the API notes), so a response
        // that says COMPLETED needs no separate check afterwards.
        var confirmed = false
        for attempt in 1...policy.maximumAttempts {
            let watchdog = UploadStallWatchdog(limit: policy.stallLimit, responseLimit: policy.responseLimit)
            do {
                let allocated = try await allocateUpload(url: allocateURL, body: body, phase: phase)
                phase?("allocated (state \(allocated.state ?? "none"), resume \(allocated.resumePosition ?? 0))")
                if allocated.state == "COMPLETED" {
                    // Identical content already there: nothing to send.
                    confirmed = true
                    break
                }
                let response = try await sendUpload(
                    allocated,
                    from: fileURL,
                    size: size,
                    watchdog: watchdog,
                    progress: progress,
                    phase: phase
                )
                confirmed = Self.uploadConfirmed(response, size: size, md5: md5)
                phase?(confirmed
                    ? "transferred (confirmed by the response)"
                    : "transferred (response \(Self.uploadResponseSummary(response)))")
                break
            } catch {
                attemptsWithoutProgress = watchdog.bytesSent > 0 ? 0 : attemptsWithoutProgress + 1
                guard policy.shouldRetry(after: error, attempt: attempt, attemptsWithoutProgress: attemptsWithoutProgress) else {
                    phase?("gave up on attempt \(attempt) (\(attemptsWithoutProgress) without progress)")
                    throw error
                }
                let delay = policy.delay(afterAttempt: attempt)
                phase?("transient failure on attempt \(attempt); retrying in \(Int(delay))s")
                try await Task.sleep(for: .seconds(delay))
            }
        }

        if confirmed {
            return RemoteEntry(
                name: path.split(separator: "/").last.map(String.init) ?? path,
                kind: .file,
                size: size,
                modified: modified,
                md5: md5
            )
        }

        // Not confirmed by the response: ask for the revision, polling
        // briefly because the listing can lag slightly behind the upload.
        for attempt in 0..<8 {
            if let revision = try await fileRevision(volume: volume, path: path),
               revision.entry.size == size,
               revision.md5 == nil || revision.md5 == md5 {
                phase?("verified after \(attempt + 1) check(s)")
                return revision.entry
            }
            try await Task.sleep(for: .milliseconds(250 * (attempt + 1)))
        }
        throw JottacloudError.uploadNotVerified
    }

    // MARK: Helpers

    private func allocateUpload(
        url: URL,
        body: Data,
        phase: (@Sendable (String) -> Void)?
    ) async throws -> AllocateResponse {
        let response = try await authorizedSend { token in
            Self.mutationRequest(url: url, accessToken: token, contentType: "application/json", body: body)
        }
        if !(200..<300).contains(response.statusCode) {
            phase?("allocate rejected: HTTP \(response.statusCode)\(Self.errorSummary(response.data))")
        }
        try Self.checkSuccess(response.statusCode)
        do {
            return try JSONDecoder().decode(AllocateResponse.self, from: response.data)
        } catch {
            // Report only the field names, never values (they include tokens).
            let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any]
            throw JottacloudError.unexpectedAllocateResponse(keys: object.map { $0.keys.sorted() } ?? ["not a JSON object"])
        }
    }

    /// Sends the file from the allocation's resume position to the end.
    private func sendUpload(
        _ allocated: AllocateResponse,
        from fileURL: URL,
        size: UInt64,
        watchdog: UploadStallWatchdog,
        progress: (@Sendable (_ bytesSent: Int64) -> Void)?,
        phase: (@Sendable (String) -> Void)?
    ) async throws -> Data {
        guard let uploadURLString = allocated.uploadURL else {
            throw JottacloudError.unexpectedAllocateResponse(keys: ["missing upload_url"])
        }
        guard let uploadURL = Self.trustedUploadURL(uploadURLString) else {
            throw JottacloudError.untrustedUploadURL(host: URL(string: uploadURLString)?.host ?? "unparseable")
        }
        let resume = min(allocated.resumePosition ?? 0, size)
        let (bodyFile, temporary) = try Self.uploadBody(fileURL, from: resume)
        defer {
            if temporary {
                try? FileManager.default.removeItem(at: bodyFile)
            }
        }
        let alreadySent = Int64(resume)
        progress?(alreadySent)
        watchdog.start(expectedBytes: Int64(size - resume))
        let delegate = UploadProgressDelegate { sent in
            watchdog.progressed(to: sent)
            progress?(alreadySent + sent)
        }
        // The upload races a watchdog that ends it when no bytes go out for
        // `stallLimit` (a poor connection can otherwise hold an attempt, and
        // the close(2) waiting for it, for many minutes).
        let response = try await withThrowingTaskGroup(of: (data: Data, statusCode: Int)?.self) { group in
            group.addTask {
                try await self.authorizedSend(bodyFile: bodyFile, delegate: delegate) { token in
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
            }
            group.addTask {
                while true {
                    try await Task.sleep(for: .seconds(1))
                    if watchdog.isStalled() {
                        phase?("stalled after \(watchdog.bytesSent) bytes")
                        throw JottacloudError.uploadStalled
                    }
                }
            }
            defer { group.cancelAll() }
            while let result = try await group.next() {
                if let result {
                    return result
                }
            }
            throw JottacloudError.uploadStalled
        }
        if !(200..<300).contains(response.statusCode) {
            phase?("upload rejected: HTTP \(response.statusCode)\(Self.errorSummary(response.data))")
        }
        try Self.checkSuccess(response.statusCode)
        return response.data
    }

    /// Whether an upload response confirms the upload: it reports the
    /// stored file's MD5 and size and both match, or it says COMPLETED and
    /// whatever MD5 and size it reports match. Anything else (no JSON, a
    /// mismatch, neither) is not a confirmation.
    static func uploadConfirmed(_ data: Data, size: UInt64, md5: String) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        let reportedMD5 = (object["md5"] as? String)?.lowercased()
        let reportedSize = ["bytes", "size"].lazy.compactMap { (object[$0] as? NSNumber)?.uint64Value }.first
        if let reportedMD5, reportedMD5 != md5.lowercased() {
            return false
        }
        if let reportedSize, reportedSize != size {
            return false
        }
        let completed = (object["state"] as? String)?.uppercased() == "COMPLETED"
        return completed || (reportedMD5 != nil && reportedSize != nil)
    }

    /// For logs: the upload response's key names and its state, never the
    /// values (paths and ids).
    static func uploadResponseSummary(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "not a JSON object (\(data.count) bytes)"
        }
        let state = (object["state"] as? String).map { ", state \($0)" } ?? ""
        return "keys \(object.keys.sorted().joined(separator: ","))\(state)"
    }

    /// Jottacloud's error id and cause (an exception name) from an error
    /// response, for logs. Never the message, which can contain paths.
    static func errorSummary(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }
        var parts: [String] = []
        if let cause = object["cause"] as? String {
            parts.append("cause \(cause.split(separator: ":").first.map(String.init) ?? cause)")
        }
        if let id = object["error_id"] as? String {
            parts.append("error_id \(id)")
        }
        return parts.isEmpty ? " (keys: \(object.keys.sorted().joined(separator: ",")))" : " (\(parts.joined(separator: ", ")))"
    }

    /// Failures worth retrying with a resumed upload: network interruptions
    /// and server-side overload. Client errors (4xx) are permanent.
    static func isTransientUploadFailure(_ error: Error) -> Bool {
        if let error = error as? URLError {
            switch error.code {
            case .networkConnectionLost, .timedOut, .notConnectedToInternet,
                 .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                 .resourceUnavailable, .secureConnectionFailed, .dataNotAllowed,
                 .internationalRoamingOff, .callIsActive, .backgroundSessionWasDisconnected:
                return true
            default:
                return false
            }
        }
        if case JottacloudError.uploadStalled = error {
            return true
        }
        if case JottacloudError.httpStatus(let status) = error {
            // Overload and temporary server errors; 507 (quota full) and
            // other statuses are not worth retrying.
            return [429, 500, 502, 503, 504].contains(status)
        }
        return false
    }

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
        delegate: URLSessionTaskDelegate? = nil,
        _ build: @Sendable (String) -> URLRequest
    ) async throws -> (data: Data, statusCode: Int) {
        let initialToken = try await validAccessToken()
        var response = try await send(build(initialToken), bodyFile: bodyFile, delegate: delegate)
        if response.statusCode == 401 {
            let latestToken = try await refreshAfterRejection(initialToken)
            response = try await send(build(latestToken), bodyFile: bodyFile, delegate: delegate)
        }
        return response
    }

    private func send(
        _ request: URLRequest,
        bodyFile: URL?,
        delegate: URLSessionTaskDelegate? = nil
    ) async throws -> (data: Data, statusCode: Int) {
        guard let bodyFile else {
            return try await Self.perform(http, request: request)
        }
        let (data, response) = try await http.upload(for: request, fromFile: bodyFile, delegate: delegate)
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
        request.setValue(JottacloudClient.userAgent, forHTTPHeaderField: "User-Agent")
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
            throw JottacloudError.invalidPath
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
            throw JottacloudError.invalidPath
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

/// How long an upload may take while close(2) waits for it: attempts end when
/// nothing is sent for `stallLimit`, and the upload gives up once
/// `maximumAttemptsWithoutProgress` attempts in a row sent nothing. A slow
/// connection that keeps sending is never cut off; a dead one fails in about
/// a minute instead of after many (seen: 13 minutes, Finder unresponsive).
public struct UploadRetryPolicy: Sendable {
    public var maximumAttempts = 5
    public var maximumAttemptsWithoutProgress = 2
    /// Longest time without a byte sent while the body is being sent.
    public var stallLimit: TimeInterval = 30
    /// Longest wait for the response once the whole body is sent.
    public var responseLimit: TimeInterval = 120
    /// Delay before attempt `n + 1`.
    public var baseDelay: TimeInterval = 1

    public static let standard = UploadRetryPolicy()

    public init() {}

    /// Whether to try again after attempt `attempt` failed with `error`;
    /// `attemptsWithoutProgress` counts the failed attempts in a row
    /// (including this one) that sent nothing.
    public func shouldRetry(after error: Error, attempt: Int, attemptsWithoutProgress: Int) -> Bool {
        attempt < maximumAttempts
            && attemptsWithoutProgress < maximumAttemptsWithoutProgress
            && JottacloudClient.isTransientUploadFailure(error)
    }

    public func delay(afterAttempt attempt: Int) -> TimeInterval {
        baseDelay * Double(1 << min(attempt, 6))
    }
}

/// Notices when an upload attempt stops sending (see `UploadRetryPolicy`).
public final class UploadStallWatchdog: @unchecked Sendable {
    private let limit: TimeInterval
    private let responseLimit: TimeInterval
    private let lock = NSLock()
    private var lastProgress: Date
    private var sent: Int64 = 0
    private var expected: Int64 = .max

    public init(limit: TimeInterval, responseLimit: TimeInterval, now: Date = Date()) {
        self.limit = limit
        self.responseLimit = responseLimit
        lastProgress = now
    }

    /// The body is about to be sent (`expectedBytes` long).
    public func start(expectedBytes: Int64, now: Date = Date()) {
        lock.withLock {
            expected = expectedBytes
            lastProgress = now
        }
    }

    /// Bytes of the body sent so far in this attempt.
    public var bytesSent: Int64 {
        lock.withLock { sent }
    }

    public func progressed(to bytes: Int64, now: Date = Date()) {
        lock.withLock {
            guard bytes > sent else {
                return
            }
            sent = bytes
            lastProgress = now
        }
    }

    public func isStalled(now: Date = Date()) -> Bool {
        lock.withLock {
            let allowed = sent >= expected ? responseLimit : limit
            return now.timeIntervalSince(lastProgress) > allowed
        }
    }
}

/// Reports bytes sent for one upload task.
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: @Sendable (Int64) -> Void

    init(report: @escaping @Sendable (Int64) -> Void) {
        self.report = report
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        report(totalBytesSent)
    }
}

// MARK: - Trash (gRPC-Web FileService; docs/trash-design.md)

/// An item as returned by `FileService.GetPath`. `path` is the service path,
/// for example `/Archive/folder/file` for `Jotta/Archive/folder/file`.
public struct JottacloudPathItem: Sendable, Equatable {
    public let path: String
    public let name: String
    public let isFolder: Bool
    public let size: UInt64
    public let modified: Date?
    /// Milliseconds since 1970 when the item was trashed; 0 if it is live.
    public let deletedAtMillis: UInt64

    public init(path: String, name: String, isFolder: Bool, size: UInt64, modified: Date?, deletedAtMillis: UInt64) {
        self.path = path
        self.name = name
        self.isFolder = isFolder
        self.size = size
        self.modified = modified
        self.deletedAtMillis = deletedAtMillis
    }

    public var isTrashed: Bool {
        deletedAtMillis != 0
    }
}

extension JottacloudClient {
    static let grpcWebRoot = URL(string: "https://grpc.jotta.cloud/")!
    static let fileService = "no.jotta.openapi.file.v2.FileService"
    static let trashPath = "/trash"
    /// gRPC status codes used here.
    static let grpcNotFound = 5
    static let grpcUnauthenticated = 16

    /// The service path of `path` in a `Jotta` mountpoint, for example
    /// `/archive/folder` for `Jotta/Archive/folder`. Other devices (backups)
    /// are not mapped yet and return nil.
    public static func servicePath(device: String, mountpoint: String, path: String) -> String? {
        guard device == JottacloudRemoteVolume.builtInDevice, !mountpoint.isEmpty, !mountpoint.contains("/") else {
            return nil
        }
        let root = "/" + mountpoint.lowercased()
        return path.isEmpty ? root : root + "/" + path
    }

    /// The service accepts lower-case first components (`/archive/...`, as
    /// the web app sends); listings return them capitalised (`/Archive/...`).
    public static func requestPath(_ path: String) -> String {
        let parts = path.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
        guard let first = parts.first else {
            return path
        }
        let rest = parts.count > 1 ? "/" + parts[1] : ""
        return "/" + first.lowercased() + rest
    }

    /// One page of the Jottacloud trash, newest first; the returned cursor
    /// is nil after the last page.
    public func trashPage(cursor: String?, limit: UInt64) async throws -> (items: [JottacloudPathItem], cursor: String?) {
        let page = try await getPath(
            Self.trashPath,
            includeChildren: true,
            includeDeleted: true,
            limit: limit,
            sort: 4,
            cursor: cursor
        )
        let next = page.cursor.isEmpty || page.children.isEmpty ? nil : page.cursor
        return (page.children, next)
    }

    /// One item, or nil if it does not exist. With `includeDeleted`, a
    /// trashed item at `path` is returned too.
    public func pathItem(_ path: String, includeDeleted: Bool) async throws -> JottacloudPathItem? {
        do {
            return try await getPath(path, includeChildren: false, includeDeleted: includeDeleted, limit: 1, sort: 0, cursor: nil).item
        } catch JottacloudError.grpcStatus(Self.grpcNotFound) {
            return nil
        }
    }

    /// Restores a trashed item to its original location.
    public func restore(path: String) async throws {
        var message = Data()
        Self.appendProtobufString(field: 1, Self.requestPath(path), to: &message)
        _ = try await grpcCall("Restore", message)
    }

    /// Permanently deletes one trashed item. The item at `path` is looked up
    /// first and must be in the trash (and, if given, be the deletion at
    /// `expectedDeletedAtMillis`); a live item is never deleted.
    public func deletePermanently(path: String, expectedDeletedAtMillis: UInt64?) async throws {
        guard let item = try await pathItem(path, includeDeleted: true), item.isTrashed else {
            throw JottacloudError.notInTrash
        }
        if let expectedDeletedAtMillis, item.deletedAtMillis != expectedDeletedAtMillis {
            throw JottacloudError.notInTrash
        }
        var message = Data()
        Self.appendProtobufString(field: 1, Self.requestPath(path), to: &message)
        _ = try await grpcCall("DeletePermanently", message)
    }

    private func getPath(
        _ path: String,
        includeChildren: Bool,
        includeDeleted: Bool,
        limit: UInt64,
        sort: UInt64,
        cursor: String?
    ) async throws -> (item: JottacloudPathItem?, children: [JottacloudPathItem], cursor: String) {
        // GetPathRequest: path 1, sort 2, limit 3, include_children 4,
        // include_deleted 5, cursor 6.
        var message = Data()
        Self.appendProtobufString(field: 1, Self.requestPath(path), to: &message)
        if sort != 0 {
            message.append(0x10)
            Self.appendVarint(sort, to: &message)
        }
        message.append(0x18)
        Self.appendVarint(limit, to: &message)
        if includeChildren { message.append(contentsOf: [0x20, 0x01]) }
        if includeDeleted { message.append(contentsOf: [0x28, 0x01]) }
        if let cursor { Self.appendProtobufString(field: 6, cursor, to: &message) }
        let response = try await grpcCall("GetPath", message)
        return Self.decodeGetPathResponse(response)
    }

    /// GetPathResponse: path_item 1 (children 13), cursor 2.
    static func decodeGetPathResponse(_ bytes: [UInt8]) -> (item: JottacloudPathItem?, children: [JottacloudPathItem], cursor: String) {
        var item: JottacloudPathItem?
        var children: [JottacloudPathItem] = []
        var cursor = ""
        for field in protobufFields(bytes) {
            if field.number == 1, let itemBytes = field.bytes {
                item = decodePathItem(itemBytes)
                for child in protobufFields(itemBytes) where child.number == 13 {
                    if let childBytes = child.bytes {
                        children.append(decodePathItem(childBytes))
                    }
                }
            } else if field.number == 2, let bytes = field.bytes {
                cursor = String(decoding: bytes, as: UTF8.self)
            }
        }
        return (item, children, cursor)
    }

    /// PathItem: path 1, name 2, type 4 (1 file, 2 folder), size 7,
    /// modified_at_millis 10, deleted_at_millis 11.
    static func decodePathItem(_ bytes: [UInt8]) -> JottacloudPathItem {
        var path = "", name = ""
        var type: UInt64 = 0, size: UInt64 = 0, modified: UInt64 = 0, deleted: UInt64 = 0
        for field in protobufFields(bytes) {
            switch field.number {
            case 1: path = field.bytes.map { String(decoding: $0, as: UTF8.self) } ?? ""
            case 2: name = field.bytes.map { String(decoding: $0, as: UTF8.self) } ?? ""
            case 4: type = field.varint ?? 0
            case 7: size = field.varint ?? 0
            case 10: modified = field.varint ?? 0
            case 11: deleted = field.varint ?? 0
            default: break
            }
        }
        return JottacloudPathItem(
            path: path,
            name: name,
            isFolder: type == 2,
            size: size,
            modified: modified == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(modified) / 1000),
            deletedAtMillis: deleted
        )
    }

    /// One unary gRPC-Web call; returns the response message. A rejected
    /// token (HTTP 401 or UNAUTHENTICATED) is refreshed once.
    private func grpcCall(_ method: String, _ message: Data, service: String = fileService) async throws -> [UInt8] {
        var frame = Data([0x00])
        var length = UInt32(message.count).bigEndian
        frame.append(Data(bytes: &length, count: 4))
        frame.append(message)
        let url = Self.grpcWebRoot.appending(path: "\(service)/\(method)")
        let initialToken = try await validAccessToken()
        var result = try await grpcSend(url: url, frame: frame, token: initialToken)
        if result.httpStatus == 401 || result.grpcStatus == Self.grpcUnauthenticated {
            let latestToken = try await refreshAfterRejection(initialToken)
            result = try await grpcSend(url: url, frame: frame, token: latestToken)
        }
        guard result.httpStatus == 200 else {
            throw JottacloudError.httpStatus(result.httpStatus)
        }
        guard let status = result.grpcStatus else {
            throw JottacloudError.grpcStatus(-1)
        }
        guard status == 0 else {
            throw JottacloudError.grpcStatus(status)
        }
        return result.message
    }

    private func grpcSend(url: URL, frame: Data, token: String) async throws -> (httpStatus: Int, grpcStatus: Int?, message: [UInt8]) {
        var request = Self.mutationRequest(url: url, accessToken: token, contentType: "application/grpc-web+proto", body: frame)
        request.setValue("1", forHTTPHeaderField: "X-Grpc-Web")
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Accept")
        let (data, response) = try await http.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw JottacloudError.httpStatus(-1)
        }
        let parsed = Self.parseGRPCWebBody([UInt8](data))
        // A trailers-only response carries the status in the HTTP headers.
        let headerStatus = httpResponse.value(forHTTPHeaderField: "grpc-status").flatMap(Int.init)
        return (httpResponse.statusCode, parsed.status ?? headerStatus, parsed.message)
    }

    /// Splits a gRPC-Web body into the (first) message and the trailer status.
    static func parseGRPCWebBody(_ body: [UInt8]) -> (message: [UInt8], status: Int?) {
        var message: [UInt8] = []
        var status: Int?
        var offset = 0
        while offset + 5 <= body.count {
            let flag = body[offset]
            let size = Int(UInt32(body[offset + 1]) << 24 | UInt32(body[offset + 2]) << 16 | UInt32(body[offset + 3]) << 8 | UInt32(body[offset + 4]))
            let start = offset + 5
            guard start + size <= body.count else { break }
            let payload = Array(body[start..<start + size])
            if flag & 0x80 != 0 {
                let text = String(decoding: payload, as: UTF8.self)
                for line in text.split(whereSeparator: \.isNewline) {
                    let parts = line.split(separator: ":", maxSplits: 1)
                    if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "grpc-status" {
                        status = Int(parts[1].trimmingCharacters(in: .whitespaces))
                    }
                }
            } else if message.isEmpty {
                message = payload
            }
            offset = start + size
        }
        return (message, status)
    }

    static func appendProtobufString(field: Int, _ value: String, to data: inout Data) {
        let bytes = Array(value.utf8)
        appendVarint(UInt64(field << 3 | 2), to: &data)
        appendVarint(UInt64(bytes.count), to: &data)
        data.append(contentsOf: bytes)
    }

    static func appendVarint(_ value: UInt64, to data: inout Data) {
        var v = value
        while v >= 0x80 {
            data.append(UInt8(v & 0x7f) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }

    static func protobufFields(_ bytes: [UInt8]) -> [(number: UInt64, varint: UInt64?, bytes: [UInt8]?)] {
        var result: [(number: UInt64, varint: UInt64?, bytes: [UInt8]?)] = []
        var index = 0
        func varint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while index < bytes.count, shift < 64 {
                let byte = bytes[index]
                index += 1
                value |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }
        while index < bytes.count {
            guard let key = varint() else { break }
            let number = key >> 3
            switch key & 7 {
            case 0:
                guard let v = varint() else { return result }
                result.append((number, v, nil))
            case 1:
                index += 8
            case 5:
                index += 4
            case 2:
                guard let length = varint(), length <= UInt64(bytes.count - index) else { return result }
                result.append((number, nil, Array(bytes[index..<index + Int(length)])))
                index += Int(length)
            default:
                return result
            }
        }
        return result
    }
}

// MARK: - Browser sign-in (OAuth authorization code with PKCE)

/// One browser sign-in attempt (docs/jottacloud-api-internals.md, "Browser
/// login"). The browser returns to `redirectURI` on this Mac; the code is
/// exchanged with the verifier that never leaves the app.
public struct JottacloudBrowserLogin: Sendable {
    /// Open this in the user's browser.
    public let authorizationURL: URL
    public let redirectURI: String
    public let state: String
    let codeVerifier: String
    let tokenEndpoint: URL
}

extension JottacloudClient {
    static let identityDiscoveryURL = URL(
        string: "https://id.jottacloud.com/auth/realms/jottacloud/.well-known/openid-configuration"
    )!

    /// Starts a browser sign-in returning to `redirectURI` (for example
    /// `http://localhost:<port>/callback`).
    public static func beginBrowserLogin(redirectURI: String) async throws -> JottacloudBrowserLogin {
        let session = identitySession
        let data = try await requestData(from: session, url: identityDiscoveryURL, method: "GET")
        let discovery = try JSONDecoder().decode(WellKnown.self, from: data)
        let tokenEndpoint = try officialIdentityURL(discovery.tokenEndpoint)
        let authorizationEndpoint = try officialIdentityURL(
            discovery.authorizationEndpoint
                ?? "https://id.jottacloud.com/auth/realms/jottacloud/protocol/openid-connect/auth"
        )
        let verifier = try randomURLSafeString(byteCount: 48)
        let state = try randomURLSafeString(byteCount: 24)
        let challenge = Self.s256Challenge(verifier)
        guard var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false) else {
            throw JottacloudError.unsafeIdentityURL
        }
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: "openid offline_access"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let url = components.url else {
            throw JottacloudError.unsafeIdentityURL
        }
        return JottacloudBrowserLogin(
            authorizationURL: url,
            redirectURI: redirectURI,
            state: state,
            codeVerifier: verifier,
            tokenEndpoint: tokenEndpoint
        )
    }

    /// Finishes a browser sign-in with the query of the callback request.
    public static func completeBrowserLogin(
        _ login: JottacloudBrowserLogin,
        callbackQuery: [String: String],
        device: String = JottacloudRemoteVolume.builtInDevice,
        mountpoint: String = "Archive",
        persistCredentials: (@Sendable (JottacloudCredentials) async throws -> Void)? = nil
    ) async throws -> JottacloudClient {
        guard callbackQuery["state"] == login.state else {
            throw JottacloudError.browserLoginStateMismatch
        }
        if let error = callbackQuery["error"] {
            throw JottacloudError.browserLoginFailed(callbackQuery["error_description"] ?? error)
        }
        guard let code = callbackQuery["code"], !code.isEmpty else {
            throw JottacloudError.browserLoginFailed("no authorization code")
        }
        let session = identitySession
        let data = try await requestData(
            from: session,
            url: login.tokenEndpoint,
            method: "POST",
            form: [
                "client_id": clientID,
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": login.redirectURI,
                "code_verifier": login.codeVerifier,
            ]
        )
        let tokens = try JSONDecoder().decode(TokenResponse.self, from: data)
        return try await makeSignedInClient(
            tokens: tokens,
            tokenEndpoint: login.tokenEndpoint,
            device: device,
            mountpoint: mountpoint,
            persistCredentials: persistCredentials
        )
    }

    static func s256Challenge(_ verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func randomURLSafeString(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) == errSecSuccess else {
            throw JottacloudError.browserLoginFailed("no secure random numbers")
        }
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Backup devices

/// A computer backup device as listed by `DeviceService.List`. `path` is its
/// service path, `/backup/<id>`; the JFS name equals `name`.
public struct JottacloudBackupDevice: Sendable, Equatable {
    public let id: String
    public let name: String
    public let path: String
    /// `DeviceType` (WORKSTATION 1, MACBOOK 3, JOTTA 6, CLI 12, …); 0 when
    /// the listing has none.
    public var type: UInt64 = 0

    public init(id: String, name: String, path: String, type: UInt64 = 0) {
        self.id = id
        self.name = name
        self.path = path
        self.type = type
    }
}

extension JottacloudClient {
    /// Backup devices with their service paths (read-only).
    /// Device message: id 1, display_name 3, type 4, path 5.
    public func listBackupDevices() async throws -> [JottacloudBackupDevice] {
        let response = try await grpcCall("List", Data(), service: "no.jotta.openapi.device.v2.DeviceService")
        return Self.decodeDeviceList(response)
    }

    static func decodeDeviceList(_ bytes: [UInt8]) -> [JottacloudBackupDevice] {
        protobufFields(bytes).compactMap { field -> JottacloudBackupDevice? in
            guard field.number == 1, let message = field.bytes else {
                return nil
            }
            var id = "", name = "", path = ""
            var type: UInt64 = 0
            for f in protobufFields(message) {
                let text = f.bytes.map { String(decoding: $0, as: UTF8.self) } ?? ""
                switch f.number {
                case 1: id = text
                case 3: name = text
                case 4: type = f.varint ?? 0
                case 5: path = text
                default: break
                }
            }
            guard !id.isEmpty, !name.isEmpty, path.lowercased().hasPrefix("/backup/") else {
                return nil
            }
            return JottacloudBackupDevice(id: id, name: name, path: path, type: type)
        }
    }
}

// MARK: - Creating and removing backup devices and mountpoints
//
// docs/jottacloud-api-internals.md, "Devices and mountpoints" (verified live
// 2026-11-26). Tests create only devices named `testDevicePrefix…`.

extension JottacloudClient {
    /// Names of the backup devices that tests create (and may delete).
    public static let testDevicePrefix = "JottaFS-Test-"

    /// Creates a backup device (JFS: `POST /jfs/<user>/<name>?type=<type>`).
    /// It stays out of the JFS account listing until it has a mountpoint.
    public func createDevice(named name: String, type: String = "CLI") async throws {
        let url = try Self.jfsMutationURL(
            try Self.makeJFSPathURL([credentials.username, name]),
            trailingSlash: false,
            query: ("type", type)
        )
        try await sendMutation(url: url)
    }

    /// Creates a mountpoint on a device (JFS: `POST
    /// /jfs/<user>/<device>/<name>`, no body).
    public func createMountpoint(device: String, named name: String) async throws {
        try await sendMutation(url: try Self.makeJFSPathURL([credentials.username, device, name]))
    }

    /// Moves a mountpoint of a backup device, with its files, to the trash:
    /// `FileService.Delete` on its service path `/backup/<id>/<name>`
    /// (DeleteRequest: path 1), as the desktop app removes a backup set.
    /// (JFS `dlDir=true` on a mountpoint returns success and does nothing.)
    public func removeMountpoint(_ name: String, of device: JottacloudBackupDevice) async throws {
        guard !name.isEmpty, !name.contains("/") else {
            throw JottacloudError.invalidPath
        }
        var message = Data()
        Self.appendProtobufString(field: 1, Self.requestPath(device.path + "/" + name), to: &message)
        _ = try await grpcCall("Delete", message)
    }

    /// Deletes a whole backup device by its id (`DeviceService.Delete`,
    /// DeleteDeviceRequest: id 1): its mountpoints and files are gone for
    /// good, nothing goes to the trash. Never the built-in device.
    public func deleteDevice(_ device: JottacloudBackupDevice) async throws {
        guard device.name != JottacloudRemoteVolume.builtInDevice, !device.id.isEmpty else {
            throw JottacloudError.invalidPath
        }
        var message = Data()
        Self.appendProtobufString(field: 1, device.id, to: &message)
        _ = try await grpcCall("Delete", message, service: "no.jotta.openapi.device.v2.DeviceService")
    }
}

/// Collects one bounded download (see `JottacloudClient.boundedData`).
private final class BoundedDataCollector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int
    private let allowsFullResponse: Bool
    private let lock = NSLock()
    private var data = Data()
    private var response: HTTPURLResponse?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<(data: Data, response: HTTPURLResponse), Error>?

    init(limit: Int, allowsFullResponse: Bool) {
        self.limit = limit
        self.allowsFullResponse = allowsFullResponse
        super.init()
        data.reserveCapacity(min(limit, 64 * 1024 * 1024))
    }

    func start(
        session: URLSession,
        request: URLRequest,
        continuation: CheckedContinuation<(data: Data, response: HTTPURLResponse), Error>
    ) {
        let task = session.dataTask(with: request)
        task.delegate = self
        lock.withLock {
            self.task = task
            self.continuation = continuation
        }
        task.resume()
    }

    func cancel() {
        let task = lock.withLock { self.task }
        task?.cancel()
        finish(.failure(CancellationError()))
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let httpResponse = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(JottacloudError.httpStatus(-1)))
            return
        }
        lock.withLock { self.response = httpResponse }
        let status = httpResponse.statusCode
        // Only a 206 (or a 200 when allowed) has a body worth reading; error
        // bodies are small and are not needed.
        if status == 206 || (status == 200 && allowsFullResponse) {
            completionHandler(.allow)
        } else {
            completionHandler(.cancel)
            finish(.success(()))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        let complete: Bool = lock.withLock {
            let remaining = limit - data.count
            if remaining > 0 {
                data.append(chunk.prefix(remaining))
            }
            return data.count >= limit
        }
        if complete {
            dataTask.cancel()
            finish(.success(()))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, (error as? URLError)?.code != .cancelled {
            finish(.failure(error))
        } else {
            finish(.success(()))
        }
    }

    private func finish(_ outcome: Result<Void, Error>) {
        let (continuation, result): (CheckedContinuation<(data: Data, response: HTTPURLResponse), Error>?, Result<(data: Data, response: HTTPURLResponse), Error>) = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            switch outcome {
            case .failure(let error):
                return (continuation, .failure(error))
            case .success:
                guard let response else {
                    return (continuation, .failure(JottacloudError.httpStatus(-1)))
                }
                return (continuation, .success((data, response)))
            }
        }
        continuation?.resume(with: result)
    }
}

// MARK: - Sign-in session

extension JottacloudClient {
    static let authService = "no.jotta.openapi.auth.v2.AuthService"
    static let appIdentifier = "no.alrek.jottafs"

    /// Names this sign-in in the account's list of signed-in devices
    /// (jottacloud.com → Security): "Enhet" shows `deviceName` and
    /// "Applikasjon" shows "JottaFS" (instead of "Jottacloud CLI" for both).
    /// `AuthService.RegisterSession`: device_name 1, user_agent 2,
    /// app_version 3, device_id 4, app_id 5, app_type 6; the reply is the
    /// session id. Checked 2026-11-25.
    public func registerSession(deviceName: String, appVersion: String, deviceID: String) async throws {
        let system = ProcessInfo.processInfo.operatingSystemVersion
        var message = Data()
        Self.appendProtobufString(field: 1, deviceName, to: &message)
        Self.appendProtobufString(field: 2, "JottaFS/\(appVersion) (Macintosh; macOS \(system.majorVersion).\(system.minorVersion))", to: &message)
        Self.appendProtobufString(field: 3, appVersion, to: &message)
        Self.appendProtobufString(field: 4, deviceID, to: &message)
        Self.appendProtobufString(field: 5, Self.appIdentifier, to: &message)
        Self.appendProtobufString(field: 6, "JottaFS", to: &message)
        _ = try await grpcCall("RegisterSession", message, service: Self.authService)
    }

    /// Ends this sign-in on Jottacloud: OpenID Connect logout with the
    /// newest refresh token (Keycloak's `…/protocol/openid-connect/logout`
    /// next to the token endpoint, on the official identity host). The
    /// session then disappears from the account's list of signed-in devices
    /// and its refresh token stops working. Checked 2026-11-25.
    public func logout() async throws {
        _ = adoptSavedTokens()
        let endpoint = credentials.tokenEndpoint.deletingLastPathComponent().appendingPathComponent("logout")
        guard endpoint.scheme == "https", endpoint.host == credentials.tokenEndpoint.host else {
            throw JottacloudError.unsafeIdentityURL
        }
        _ = try await Self.requestData(
            from: authHTTP,
            url: endpoint,
            method: "POST",
            form: ["client_id": Self.clientID, "refresh_token": credentials.refreshToken]
        )
    }
}
