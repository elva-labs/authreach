import Foundation

/// Everything needed to reach one IMAP inbox. Stored whole in the Keychain
/// under `imap-account:<accountId>`.
public struct ImapCredentials: Codable, Hashable, Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var password: String

    public init(host: String, port: Int = 993, username: String, password: String) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }
}

/// IMAP inbox provider. Watermarks are UIDs. Read-only by construction:
/// the mailbox is opened with EXAMINE and bodies fetched with BODY.PEEK, so
/// nothing is ever marked seen.
///
/// Each poll opens a fresh TLS connection, fetches the batch of new
/// messages in one FETCH, and logs out. That costs one login per tick but
/// is immune to half-dead sockets after sleep/wake, which a long-lived
/// session would have to detect and recover from.
public actor ImapProvider: InboxProvider {
    public typealias CredentialsProvider = @Sendable (_ accountId: String) -> ImapCredentials?
    typealias TransportFactory = @Sendable (_ host: String, _ port: UInt16) -> any ImapTransport

    public static let mailbox = "INBOX"
    public static let maxMessagesPerPoll = 25
    /// Bodies are fetched as a partial (`<0.n>`) so an oversized newsletter
    /// can't stall a poll; OTP mail is a few KB.
    public static let maxBodyBytes = 262_144

    private let credentialsProvider: CredentialsProvider
    private let makeTransport: TransportFactory
    /// UIDVALIDITY seen per account; a change means UIDs were renumbered.
    private var uidValidity: [String: Int] = [:]
    /// Messages fetched by the most recent `listMessageIds`, served by `message`.
    private var batch: [String: [String: FetchedMessage]] = [:]

    public init(credentialsProvider: @escaping CredentialsProvider) {
        self.init(credentialsProvider: credentialsProvider,
                  transport: { NWImapTransport(host: $0, port: $1) })
    }

    init(credentialsProvider: @escaping CredentialsProvider, transport: @escaping TransportFactory) {
        self.credentialsProvider = credentialsProvider
        self.makeTransport = transport
    }

    // MARK: - InboxProvider

    public func initialWatermark(accountId: String) async throws -> Double {
        let credentials = try credentials(for: accountId)
        return try await withConnection(credentials) { connection in
            let mailbox = try await Self.examine(connection)
            if let validity = mailbox.uidValidity { uidValidity[accountId] = validity }
            if let next = mailbox.uidNext { return Double(max(0, next - 1)) }
            return Double(try await Self.highestUid(connection))
        }
    }

    public func listMessageIds(accountId: String, after watermark: Double) async throws -> [String] {
        let credentials = try credentials(for: accountId)
        return try await withConnection(credentials) { connection in
            let mailbox = try await Self.examine(connection)
            if let validity = mailbox.uidValidity {
                let previous = uidValidity[accountId]
                uidValidity[accountId] = validity
                if let previous, previous != validity {
                    batch[accountId] = [:]
                    throw InboxProviderError.baselineReset
                }
            }

            // "n:*" also matches the highest UID when nothing is newer than n
            // (RFC 3501 §6.4.8), so filter client-side too.
            let floor = Int(watermark)
            let search = try await connection.command("UID SEARCH UID \(floor + 1):*", label: "SEARCH")
            let uids = Array(Self.parseSearch(search).filter { $0 > floor }.sorted().prefix(Self.maxMessagesPerPoll))
            guard !uids.isEmpty else {
                batch[accountId] = [:]
                return []
            }

            let set = uids.map(String.init).joined(separator: ",")
            let fetch = try await connection.command(
                "UID FETCH \(set) (UID INTERNALDATE BODY.PEEK[]<0.\(Self.maxBodyBytes)>)", label: "FETCH")
            var messages: [String: FetchedMessage] = [:]
            for response in fetch {
                if let message = Self.fetchedMessage(from: response) { messages[message.id] = message }
            }
            batch[accountId] = messages
            return uids.map(String.init).filter { messages[$0] != nil }
        }
    }

    public func message(accountId: String, id: String) async throws -> FetchedMessage {
        guard let message = batch[accountId]?[id] else { throw ImapError.messageNotInBatch(id) }
        return message
    }

    nonisolated public func watermark(for message: FetchedMessage) -> Double {
        Double(message.id) ?? 0
    }

    /// Connects, signs in and opens INBOX read-only, then logs out. Used by
    /// the "add account" flow before anything is saved.
    public func verify(_ credentials: ImapCredentials) async throws {
        try await withConnection(credentials) { connection in
            _ = try await Self.examine(connection)
        }
    }

    // MARK: - Session

    private func credentials(for accountId: String) throws -> ImapCredentials {
        guard let credentials = credentialsProvider(accountId) else { throw ImapError.notConfigured }
        return credentials
    }

    private func withConnection<T>(_ credentials: ImapCredentials,
                                   _ body: (ImapConnection) async throws -> T) async throws -> T {
        let transport = makeTransport(credentials.host, UInt16(clamping: credentials.port))
        let connection = ImapConnection(transport: transport)
        do {
            try await connection.open()
            try await Self.login(connection, credentials)
            let result = try await body(connection)
            await connection.close()
            return result
        } catch {
            await connection.close()
            throw error
        }
    }

    static func login(_ connection: ImapConnection, _ credentials: ImapCredentials) async throws {
        guard let user = quoted(credentials.username), let password = quoted(credentials.password) else {
            throw ImapError.unexpected("username or password contains a line break")
        }
        do {
            try await connection.command("LOGIN \(user) \(password)", label: "LOGIN")
        } catch ImapError.server(_, let message) {
            throw ImapError.authentication(message)
        }
    }

    /// RFC 3501 quoted string; nil when the value can't be quoted.
    static func quoted(_ value: String) -> String? {
        guard !value.contains("\r"), !value.contains("\n"), !value.contains("\0") else { return nil }
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    struct MailboxInfo {
        var uidValidity: Int?
        var uidNext: Int?
    }

    static func examine(_ connection: ImapConnection) async throws -> MailboxInfo {
        let responses = try await connection.command("EXAMINE \(mailbox)", label: "EXAMINE")
        var info = MailboxInfo()
        for response in responses {
            if let v = capture(response.text, #"\[UIDVALIDITY (\d+)\]"#) { info.uidValidity = Int(v) }
            if let n = capture(response.text, #"\[UIDNEXT (\d+)\]"#) { info.uidNext = Int(n) }
        }
        return info
    }

    /// Fallback baseline for servers that omit UIDNEXT: the last message's
    /// UID, or 0 for an empty mailbox (some servers answer BAD to `*` then).
    static func highestUid(_ connection: ImapConnection) async throws -> Int {
        do {
            let responses = try await connection.command("UID FETCH * (UID)", label: "FETCH")
            return responses.compactMap { capture($0.text, #"\bUID (\d+)"#).flatMap(Int.init) }.max() ?? 0
        } catch ImapError.server {
            return 0
        }
    }

    // MARK: - Response parsing

    /// `* SEARCH 4 5 6`, or the RFC 4731 form `* ESEARCH (TAG "A2") UID ALL 4:6`.
    static func parseSearch(_ responses: [ImapResponse]) -> [Int] {
        var uids: [Int] = []
        for response in responses {
            if response.text.hasPrefix("* SEARCH") {
                uids += response.text.dropFirst("* SEARCH".count).split(separator: " ").compactMap { Int($0) }
            } else if response.text.hasPrefix("* ESEARCH"), let set = capture(response.text, #"\bALL ([0-9:,]+)"#) {
                for item in set.split(separator: ",") {
                    let bounds = item.split(separator: ":").compactMap { Int($0) }
                    if bounds.count == 2 { uids += Array(min(bounds[0], bounds[1])...max(bounds[0], bounds[1])) }
                    else if bounds.count == 1 { uids.append(bounds[0]) }
                }
            }
        }
        return uids
    }

    /// One `* n FETCH (UID … INTERNALDATE "…" BODY[]<0> {len})` response.
    static func fetchedMessage(from response: ImapResponse) -> FetchedMessage? {
        guard response.text.contains(" FETCH "), let uid = capture(response.text, #"\bUID (\d+)"#) else { return nil }
        let internalDate = capture(response.text, #"INTERNALDATE "([^"]+)""#).flatMap(parseInternalDate)
        let mail = response.literals.first.map(MimeParser.parse) ?? ParsedMail()
        let received = internalDate ?? mail.date ?? Date()
        return FetchedMessage(
            id: uid,
            subject: mail.subject,
            from: mail.from,
            snippet: "",
            text: mail.text,
            receivedAt: (received.timeIntervalSince1970 * 1000).rounded())
    }

    /// `"20-Sep-2026 10:11:12 +0200"` (day may be space-padded).
    static func parseInternalDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d-MMM-yyyy HH:mm:ss Z"
        return formatter.date(from: value.trimmingCharacters(in: .whitespaces))
    }

    private static func capture(_ text: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
              match.numberOfRanges > 1 else { return nil }
        return (text as NSString).substring(with: match.range(at: 1))
    }
}
