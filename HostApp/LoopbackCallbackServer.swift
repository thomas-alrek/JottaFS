import Foundation
import Network

/// Receives the browser's redirect after signing in to Jottacloud, on
/// `http://localhost:<port>/callback` (as the official desktop app does).
/// It listens on the loopback interface only, accepts one callback and
/// answers every request with a short page; nothing else is served.
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

    private let queue = DispatchQueue(label: "no.alrek.jottafs.signin")
    private let lock = NSLock()
    private var listeners: [NWListener] = []
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

    /// The query of the first `/callback` request.
    func waitForCallback() async throws -> [String: String] {
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
    }

    func stop() {
        finish(.failure(ServerError.cancelled))
        let current = lock.withLock { () -> [NWListener] in
            let current = listeners
            listeners = []
            return current
        }
        current.forEach { $0.cancel() }
    }

    private func listen(on host: NWEndpoint.Host, port: NWEndpoint.Port) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: host, port: port)
        parameters.acceptLocalOnly = true
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        lock.withLock { listeners.append(listener) }
        return try await withCheckedThrowingContinuation { continuation in
            let resumed = ResumedFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.set(), let port = listener.port?.rawValue {
                        continuation.resume(returning: port)
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

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let requestLine = request.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
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
                let failed = query["error"] != nil
                // Redirect to the web authentication session's callback
                // scheme: the browser then ends the session, closes the
                // sign-in tab and returns to JottaFS. The URL carries no
                // code or token; the page below shows if it is not followed.
                status = "302 Found"
                location = Self.sessionCallbackURL
                body = failed
                    ? Self.page(title: "Sign-in didn’t finish", message: "Return to JottaFS to try again.")
                    : Self.page(title: "You’re signed in", message: "Return to JottaFS to continue.")
                self.finish(.success(query))
            }
            let locationHeader = location.map { "Location: \($0)\r\n" } ?? ""
            let response = "HTTP/1.1 \(status)\r\n\(locationHeader)Content-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
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

    /// The page the browser shows briefly before JottaFS closes the sign-in
    /// window (or if it cannot).
    private static func page(title: String, message: String) -> String {
        return """
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
