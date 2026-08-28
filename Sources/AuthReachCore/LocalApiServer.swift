import Foundation
import Network

/// Loopback-only HTTP API for scripts:
///   GET /                      info (no auth)
///   GET /v1/otps/latest        latest matching code (JSON, or text via
///                              Accept: text/plain / ?raw=1 / ?format=text)
///   GET /v1/otps/latest/code   always plain-text code
/// Filters: ?service=&sender=&accountEmail=&maxAgeSeconds=
///
/// Every request except "/" needs `Authorization: Bearer <token>` (compared
/// in constant time). Any request carrying an Origin header is rejected so
/// browser-page fetch/XHR — including DNS-rebinding attempts — can't reach
/// it; legitimate callers are curl/scripts, which never send Origin.
public final class LocalApiServer: @unchecked Sendable {
    public struct Config: Sendable {
        public var getRecent: @Sendable () async -> [OtpEntry]
        public var getToken: @Sendable () -> String
        public var exposeMetadata: @Sendable () -> Bool
        public init(getRecent: @escaping @Sendable () async -> [OtpEntry],
                    getToken: @escaping @Sendable () -> String,
                    exposeMetadata: @escaping @Sendable () -> Bool) {
            self.getRecent = getRecent
            self.getToken = getToken
            self.exposeMetadata = exposeMetadata
        }
    }

    private var listener: NWListener?
    private let config: Config
    public private(set) var port: UInt16 = 0

    public init(config: Config) {
        self.config = config
    }

    public func start(port: UInt16) throws {
        stop()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1",
                                                               port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                    connection.cancel()
                    return
                }
                Task {
                    let response = await self.handle(rawRequest: request)
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                }
            }
        }
        listener.start(queue: .global())
        self.listener = listener
        self.port = port
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        port = 0
    }

    public var isRunning: Bool { listener != nil }

    // MARK: - Request handling (pure-ish, testable)

    func handle(rawRequest: String) async -> String {
        let lines = rawRequest.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return Self.response(400, "bad request") }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return Self.response(405, "method not allowed") }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] =
                String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }

        // Browser requests always carry Origin; scripts never do.
        if headers["origin"] != nil { return Self.response(403, "forbidden") }

        let target = String(parts[1])
        let pathAndQuery = target.split(separator: "?", maxSplits: 1)
        let path = String(pathAndQuery[0])
        let query = Self.parseQuery(pathAndQuery.count > 1 ? String(pathAndQuery[1]) : "")

        if path == "/" {
            return Self.response(200, #"{"name":"AuthReach local API","endpoints":["/v1/otps/latest","/v1/otps/latest/code"]}"#,
                                 contentType: "application/json")
        }

        guard isAuthorized(headers: headers) else { return Self.response(401, "unauthorized") }

        switch path {
        case "/v1/otps/latest", "/v1/otps/latest/code":
            let recent = await config.getRecent()
            guard let entry = recent.first(where: { Self.matches($0, query: query) }) else {
                return Self.response(404, "no matching code")
            }
            let wantsText = path.hasSuffix("/code")
                || query["raw"] == "1" || query["format"] == "text"
                || (headers["accept"]?.contains("text/plain") ?? false)
            if wantsText {
                return Self.response(200, entry.code, contentType: "text/plain")
            }
            return Self.response(200, Self.shape(entry, exposeMetadata: config.exposeMetadata()),
                                 contentType: "application/json")
        default:
            return Self.response(404, "not found")
        }
    }

    func isAuthorized(headers: [String: String]) -> Bool {
        let token = config.getToken()
        guard !token.isEmpty,
              let auth = headers["authorization"],
              auth.hasPrefix("Bearer ") else { return false }
        return Self.timingSafeEqual(String(auth.dropFirst("Bearer ".count)), token)
    }

    /// Constant-time comparison so response timing can't leak the token.
    static func timingSafeEqual(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8), bb = Array(b.utf8)
        guard ab.count == bb.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<ab.count { diff |= ab[i] ^ bb[i] }
        return diff == 0
    }

    static func parseQuery(_ query: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            result[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
        }
        return result
    }

    /// Case/punctuation-insensitive comparison for service names.
    static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func matches(_ entry: OtpEntry, query: [String: String]) -> Bool {
        if let service = query["service"], normalize(entry.service) != normalize(service) { return false }
        if let sender = query["sender"], entry.sender.lowercased() != sender.lowercased() { return false }
        if let account = query["accountEmail"], entry.accountEmail.lowercased() != account.lowercased() { return false }
        if let maxAge = query["maxAgeSeconds"], let seconds = Double(maxAge) {
            let age = Date().timeIntervalSince1970 - entry.receivedAt / 1000
            if age > seconds { return false }
        }
        return true
    }

    static func shape(_ entry: OtpEntry, exposeMetadata: Bool) -> String {
        var object: [String: Any] = [
            "code": entry.code,
            "service": entry.service,
            "receivedAt": entry.receivedAt,
            "expiresAt": entry.expiresAt as Any,
        ]
        if exposeMetadata {
            object["sender"] = entry.sender
            object["subject"] = entry.subject
            object["accountEmail"] = entry.accountEmail
        }
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    static func response(_ status: Int, _ body: String, contentType: String = "text/plain") -> String {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                      404: "Not Found", 405: "Method Not Allowed"][status] ?? "OK"
        return "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
    }

    public static func generateToken() -> String {
        (0..<24).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}
