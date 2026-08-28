import Foundation

/// Gmail REST client. Gmail returns the MIME tree pre-parsed, so text
/// extraction is a tree walk with base64url decoding — no MIME parser.
public struct GmailClient: InboxProvider {
    /// Supplies a live access token for an account (refreshing as needed).
    public typealias TokenProvider = @Sendable (_ accountId: String) async throws -> String

    static let base = "https://gmail.googleapis.com/gmail/v1/users/me"
    let tokenProvider: TokenProvider
    let session: URLSession

    public init(tokenProvider: @escaping TokenProvider, session: URLSession = .shared) {
        self.tokenProvider = tokenProvider
        self.session = session
    }

    public enum GmailError: LocalizedError {
        case api(status: Int, body: String)
        case badResponse
        public var errorDescription: String? {
            switch self {
            case .api(let status, let body): return "Gmail API error \(status): \(body.prefix(300))"
            case .badResponse: return "Unexpected Gmail API response."
            }
        }
    }

    func fetch<T: Decodable>(_ type: T.Type, accountId: String, pathAndQuery: String) async throws -> T {
        let token = try await tokenProvider(accountId)
        var request = URLRequest(url: URL(string: Self.base + pathAndQuery)!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GmailError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw GmailError.api(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - API surface

    struct Profile: Decodable { let emailAddress: String }

    public func profileEmail(accountId: String) async throws -> String {
        try await fetch(Profile.self, accountId: accountId, pathAndQuery: "/profile").emailAddress
    }

    struct ListResponse: Decodable {
        struct Ref: Decodable { let id: String }
        let messages: [Ref]?
    }

    public func initialWatermark(accountId: String) async throws -> Double {
        // Skip the existing backlog: only mail newer than "now" matters.
        Date().timeIntervalSince1970.rounded(.down)
    }

    public func listMessageIds(accountId: String, after watermark: Double) async throws -> [String] {
        let query = "in:inbox after:\(Int(watermark))"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let response = try await fetch(ListResponse.self, accountId: accountId,
                                       pathAndQuery: "/messages?q=\(query)&maxResults=25")
        return (response.messages ?? []).map(\.id)
    }

    public func watermark(for message: FetchedMessage) -> Double {
        (message.receivedAt / 1000).rounded(.down)
    }

    // MARK: - Message parsing

    struct Part: Decodable {
        let mimeType: String?
        let headers: [Header]?
        let body: Body?
        let parts: [Part]?
        struct Header: Decodable { let name: String; let value: String }
        struct Body: Decodable { let data: String? }
    }

    struct Message: Decodable {
        let id: String
        let internalDate: String?
        let snippet: String?
        let payload: Part?
    }

    public func message(accountId: String, id: String) async throws -> FetchedMessage {
        let msg = try await fetch(Message.self, accountId: accountId,
                                  pathAndQuery: "/messages/\(id)?format=full")
        return Self.fetchedMessage(from: msg)
    }

    static func fetchedMessage(from msg: Message) -> FetchedMessage {
        FetchedMessage(
            id: msg.id,
            subject: header(msg.payload, "Subject"),
            from: header(msg.payload, "From"),
            snippet: msg.snippet ?? "",
            text: extractText(msg.payload),
            receivedAt: msg.internalDate.flatMap(Double.init) ?? Date().timeIntervalSince1970 * 1000)
    }

    static func header(_ part: Part?, _ name: String) -> String {
        part?.headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
    }

    static func decodeBase64Url(_ data: String) -> String {
        var b64 = data.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let decoded = Data(base64Encoded: b64) else { return "" }
        return String(data: decoded, encoding: .utf8) ?? ""
    }

    /// Walk the MIME tree, preferring text/plain, falling back to stripped HTML.
    static func extractText(_ part: Part?) -> String {
        guard let part else { return "" }
        var plain: [String] = []
        var html: [String] = []
        func walk(_ node: Part) {
            if let data = node.body?.data, !data.isEmpty {
                if node.mimeType == "text/plain" { plain.append(decodeBase64Url(data)) }
                else if node.mimeType == "text/html" { html.append(stripHtml(decodeBase64Url(data))) }
            }
            node.parts?.forEach(walk)
        }
        walk(part)
        return plain.isEmpty ? html.joined(separator: " ") : plain.joined(separator: " ")
    }
}
