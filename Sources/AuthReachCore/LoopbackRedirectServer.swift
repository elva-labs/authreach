import Foundation
import Network

/// One-shot HTTP server for the OAuth redirect of an installed app
/// (RFC 8252 §7.3): bound to an explicit high port on 127.0.0.1, it hands
/// back the query of the first `/callback` request and keeps the latest
/// `/callback` request open until `finish(_:)`. The browser therefore shows
/// the real outcome —
/// token exchange and account lookup included — instead of claiming success
/// as soon as Google redirects.
final class LoopbackRedirectServer: @unchecked Sendable {
    let port: UInt16
    private let listener: NWListener
    private let lock = NSLock()
    // Guarded by `lock`.
    private var callback: Result<[String: String], Error>?
    private var waiter: CheckedContinuation<[String: String], Error>?
    private var callbackConnection: NWConnection?
    private var closed = false

    /// Picks a random port, retrying on collisions. Returns once the
    /// listener is ready, so the browser is never sent to a dead port.
    static func start() throws -> LoopbackRedirectServer {
        var lastError: Error = GoogleOAuth.OAuthError.flowFailed("could not open loopback listener")
        for _ in 0..<10 {
            do {
                return try LoopbackRedirectServer(port: UInt16.random(in: 49152...65500))
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private init(port: UInt16) throws {
        self.port = port
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: parameters)

        let ready = DispatchSemaphore(value: 0)
        let state = LockedBox<NWListener.State>(.setup)
        listener.stateUpdateHandler = { newState in
            switch newState {
            case .ready, .failed, .cancelled:
                state.set(newState)
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: .global())

        guard ready.wait(timeout: .now() + 3) == .success else {
            listener.cancel()
            throw GoogleOAuth.OAuthError.flowFailed("loopback listener timed out while starting")
        }
        guard case .ready = state.get() else {
            listener.cancel()
            throw GoogleOAuth.OAuthError.flowFailed("loopback port \(port) unavailable")
        }
    }

    /// The redirect's query parameters. Throws `OAuthError.timedOut` when
    /// no redirect arrives in time (the user closed the tab, or Google
    /// showed an error page and never redirected), and `CancellationError`
    /// when the calling task is cancelled; either closes the server.
    func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.fail(GoogleOAuth.OAuthError.timedOut)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let callback {
                    lock.unlock()
                    continuation.resume(with: callback)
                } else if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiter = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            fail(CancellationError())
        }
    }

    /// Answers the held redirect request with `page` and shuts down.
    func finish(_ page: String) {
        lock.lock()
        let connection = callbackConnection
        callbackConnection = nil
        closed = true
        lock.unlock()
        listener.cancel()
        guard let connection else { return }
        connection.send(content: Data(Self.response(page).utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Ends a wait that hasn't produced a callback yet. A callback that
    /// already arrived wins, and its request is answered by `finish`.
    private func fail(_ error: Error) {
        lock.lock()
        guard callback == nil else { lock.unlock(); return }
        callback = .failure(error)
        let pending = waiter
        waiter = nil
        closed = true
        lock.unlock()
        listener.cancel()
        pending?.resume(throwing: error)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .global())
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let requestLine = request.split(separator: "\r\n").first.map(String.init) ?? ""
            // Browsers also probe for /favicon.ico; only the redirect counts.
            guard let query = Self.callbackQuery(requestLine: requestLine) else {
                connection.cancel()
                return
            }
            lock.lock()
            if closed {
                lock.unlock()
                // A request after the flow ended: say so rather than hang.
                connection.send(content: Data(Self.response(Self.page(
                    title: "Nothing to do here",
                    message: "This sign-in has already finished. You can close this window.")).utf8),
                    completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            if callback != nil {
                // The tab was reloaded while the sign-in finishes. The browser
                // has given up on the earlier request, so the outcome goes to
                // this one.
                let abandoned = callbackConnection
                callbackConnection = connection
                lock.unlock()
                abandoned?.cancel()
                return
            }
            callback = .success(query)
            callbackConnection = connection
            let pending = waiter
            waiter = nil
            lock.unlock()
            pending?.resume(returning: query)
        }
    }

    // MARK: - Parsing and pages

    /// Query parameters of a `GET /callback?…` request line, or nil for any
    /// other path. Values are percent-decoded (codes look like `4/0Ab…`).
    static func callbackQuery(requestLine: String) -> [String: String]? {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let components = URLComponents(string: String(parts[1])),
              components.path == "/callback" else { return nil }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] where query[item.name] == nil {
            query[item.name] = item.value ?? ""
        }
        return query
    }

    static func page(title: String, message: String, isError: Bool = false) -> String {
        let accent = isError ? "#c0392b" : "#1e8e3e"
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>AuthReach</title></head>
        <body style="font-family:-apple-system,sans-serif;max-width:32rem;margin:4rem auto;padding:0 1rem;line-height:1.45">
        <h2 style="color:\(accent)">\(escapeHTML(title))</h2><p>\(escapeHTML(message))</p></body></html>
        """
    }

    static func escapeHTML(_ text: String) -> String {
        var escaped = ""
        for character in text {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&#39;"
            default: escaped.append(character)
            }
        }
        return escaped
    }

    private static func response(_ page: String) -> String {
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(page.utf8.count)\r\n\r\n\(page)"
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func set(_ new: T) { lock.lock(); value = new; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}
