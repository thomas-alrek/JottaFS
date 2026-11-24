import Foundation
import Network

/// Receives the browser's redirect after signing in to Jottacloud, on
/// `http://localhost:<port>/callback` (as the official desktop app does).
/// It listens on the loopback interface only and accepts one callback that
/// carries the expected `state`; every other request gets a short page.
final class LoopbackCallbackServer: @unchecked Sendable {
    enum ServerError: LocalizedError {
        case couldNotListen
        case cancelled

        var errorDescription: String? {
            switch self {
            case .couldNotListen:
                "JottaFS could not prepare the sign-in. Try again."
            case .cancelled:
                "Sign-in was cancelled."
            }
        }
    }

    /// The scheme the web authentication session waits for.
    static let sessionCallbackScheme = "jottafs"
    static let sessionCallbackURL = "jottafs://signed-in"
    private static let maximumRequestSize = 16 * 1024
    private static let connectionTimeout: TimeInterval = 10

    private let queue = DispatchQueue(label: "no.alrek.jottafs.signin")
    private let lock = NSLock()
    private var isStopped = false
    private var listeners: [NWListener] = []
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var expectedState: String?
    private var redirectsToSession = false
    private var callbackContinuation: CheckedContinuation<[String: String], Error>?
    private var callbackResult: Result<[String: String], Error>?

    /// Starts listening and returns the redirect URI to send to Jottacloud.
    func start() async throws -> String {
        let port = try await listen(on: .ipv4(.loopback), port: .any)
        // Browsers may resolve `localhost` to ::1 first; listen there too
        // (on the same port) when possible.
        if let samePort = NWEndpoint.Port(rawValue: port) {
            _ = try? await listen(on: .ipv6(.loopback), port: samePort)
        }
        return "http://localhost:\(port)/callback"
    }

    /// Only a callback with this `state` ends the sign-in. With
    /// `redirectsToSession`, the browser is sent on to
    /// `jottafs://signed-in`, which completes the web authentication session
    /// (closing its tab); otherwise it shows a page.
    func expect(state: String, redirectsToSession: Bool) {
        lock.withLock {
            expectedState = state
            self.redirectsToSession = redirectsToSession
        }
    }

    /// The query of the matching `/callback` request. Cancelling the
    /// calling task stops the server.
    func waitForCallback() async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let callbackResult {
                    lock.unlock()
                    continuation.resume(with: callbackResult)
                    return
                }
                callbackContinuation = continuation
                lock.unlock()
            }
        } onCancel: {
            stop()
        }
    }

    func stop() {
        finish(.failure(ServerError.cancelled))
        let (oldListeners, oldConnections) = lock.withLock {
            isStopped = true
            defer {
                listeners = []
                connections = [:]
            }
            return (listeners, Array(connections.values))
        }
        oldListeners.forEach { $0.cancel() }
        oldConnections.forEach { $0.cancel() }
    }

    private func listen(on host: NWEndpoint.Host, port: NWEndpoint.Port) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: host, port: port)
        parameters.acceptLocalOnly = true
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        let stopped = lock.withLock {
            if !isStopped {
                listeners.append(listener)
            }
            return isStopped
        }
        guard !stopped else {
            throw ServerError.cancelled
        }
        return try await withCheckedThrowingContinuation { continuation in
            let resumed = ResumedFlag()
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready:
                    guard resumed.set() else {
                        return
                    }
                    if let port = listener?.port?.rawValue {
                        continuation.resume(returning: port)
                    } else {
                        continuation.resume(throwing: ServerError.couldNotListen)
                    }
                case .failed, .cancelled:
                    if resumed.set() {
                        continuation.resume(throwing: ServerError.couldNotListen)
                    }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    // MARK: Requests

    private func handle(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        let accepted = lock.withLock {
            if !isStopped {
                connections[key] = connection
            }
            return !isStopped
        }
        guard accepted else {
            connection.cancel()
            return
        }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.lock.withLock { _ = self?.connections.removeValue(forKey: key) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        // Close connections that never send a complete request line.
        queue.asyncAfter(deadline: .now() + Self.connectionTimeout) { [weak connection] in
            connection?.cancel()
        }
        receive(on: connection, buffer: Data())
    }

    /// Reads until the request line is complete (it can arrive in pieces).
    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maximumRequestSize) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data {
                buffer.append(data)
            }
            let text = String(decoding: buffer, as: UTF8.self)
            if let end = text.range(of: "\r\n") {
                self.respond(to: String(text[..<end.lowerBound]), on: connection)
            } else if isComplete || error != nil || buffer.count >= Self.maximumRequestSize {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(to requestLine: String, on connection: NWConnection) {
        let parts = requestLine.split(separator: " ")
        var status = "404 Not Found"
        var body = Self.page(title: "Not found", message: "")
        var location: String?
        if parts.count >= 2, parts[0] == "GET",
           let components = URLComponents(string: "http://localhost" + parts[1]),
           components.path == "/callback" {
            var query: [String: String] = [:]
            for item in components.queryItems ?? [] {
                query[item.name] = item.value ?? ""
            }
            let (expected, redirect) = lock.withLock { (expectedState, redirectsToSession) }
            if let expected, query["state"] == expected {
                let failed = query["error"] != nil
                body = failed
                    ? Self.page(title: "Sign-in didn’t finish", message: "Return to JottaFS to try again.")
                    : Self.page(title: "You’re signed in", message: "Return to JottaFS to continue.")
                if redirect {
                    // The browser ends the web authentication session, closes
                    // the sign-in tab and returns to JottaFS. The URL carries
                    // no code or token; the page shows if it is not followed.
                    status = "302 Found"
                    location = Self.sessionCallbackURL
                } else {
                    status = "200 OK"
                }
                finish(.success(query))
            } else {
                // Not this sign-in (an old tab, a prefetch, another process).
                status = "400 Bad Request"
                body = Self.page(title: "This sign-in link has expired", message: "Return to JottaFS and sign in again.")
            }
        }
        let locationHeader = location.map { "Location: \($0)\r\n" } ?? ""
        let response = "HTTP/1.1 \(status)\r\n\(locationHeader)Content-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func finish(_ result: Result<[String: String], Error>) {
        lock.lock()
        guard callbackResult == nil else {
            lock.unlock()
            return
        }
        callbackResult = result
        let continuation = callbackContinuation
        callbackContinuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    /// The page the browser shows briefly before the sign-in tab closes (or
    /// if it cannot).
    private static func page(title: String, message: String) -> String {
        """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><title>JottaFS</title>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root { color-scheme: light dark; }
        body { font: 16px -apple-system, BlinkMacSystemFont, sans-serif; display: grid; place-items: center; min-height: 90vh; margin: 0 16px; }
        main { text-align: center; max-width: 28rem; }
        h1 { font-size: 1.6rem; margin-bottom: .5rem; }
        p { opacity: .75; line-height: 1.5; }
        </style></head>
        <body><main><h1>\(title)</h1><p>\(message)</p></main></body></html>
        """
    }
}

private final class ResumedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    /// True the first time only.
    func set() -> Bool {
        lock.withLock {
            defer { value = true }
            return !value
        }
    }
}
