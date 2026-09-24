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
/// Each account keeps one signed-in session between polls, so a tick costs
/// an EXAMINE + SEARCH (+ FETCH) rather than a TLS handshake and a login —
/// providers throttle accounts that log in every few seconds. A session
/// idle for longer than `sessionIdleLimit` (the Mac slept, say) is replaced
/// rather than trusted, and a reused session that fails at the transport
/// level is retried once on a fresh connection.
public actor ImapProvider: InboxProvider {
    public typealias CredentialsProvider = @Sendable (_ accountId: String) -> ImapCredentials?
    typealias TransportFactory = @Sendable (_ host: String, _ port: UInt16) -> any ImapTransport

    public static let mailbox = "INBOX"
    public static let maxMessagesPerPoll = 25
    /// Bodies are fetched as a partial (`<0.n>`) so an oversized newsletter
    /// can't stall a poll; OTP mail is a few KB.
    public static let maxBodyBytes = 262_144
    static let sessionIdleLimit: TimeInterval = 120

    private struct Session {
        let connection: ImapConnection
        let lastUsed: Date
    }

    private let credentialsProvider: CredentialsProvider
    private let makeTransport: TransportFactory
    private let now: @Sendable () -> Date
    /// Idle sessions per account. A session is removed while a call uses it,
    /// so two calls never interleave commands on one connection.
    private var sessions: [String: Session] = [:]
    /// Accounts removed via `forget`; a poll still in flight for one of them
    /// closes its session instead of keeping it.
    private var forgotten: Set<String> = []
    /// UIDVALIDITY seen per account; a change means UIDs were renumbered.
    private var uidValidity: [String: Int] = [:]

    public init(credentialsProvider: @escaping CredentialsProvider) {
        self.init(credentialsProvider: credentialsProvider,
                  transport: { NWImapTransport(host: $0, port: $1) })
    }

    init(credentialsProvider: @escaping CredentialsProvider, transport: @escaping TransportFactory,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.credentialsProvider = credentialsProvider
        self.makeTransport = transport
        self.now = now
    }

    // MARK: - InboxProvider

    public func initialWatermark(accountId: String) async throws -> Double {
        try await withSession(accountId) { connection in
            let mailbox = try await Self.examine(connection)
            if let validity = mailbox.uidValidity { self.uidValidity[accountId] = validity }
            if let next = mailbox.uidNext { return Double(max(0, next - 1)) }
            return Double(try await Self.highestUid(connection))
        }
    }

    public func messages(accountId: String, after watermark: Double,
                         skipping: Set<String>) async throws -> [FetchedMessage] {
        try await withSession(accountId) { connection in
            let mailbox = try await Self.examine(connection)
            if let validity = mailbox.uidValidity {
                let previous = self.uidValidity[accountId]
                self.uidValidity[accountId] = validity
                if let previous, previous != validity { throw InboxProviderError.baselineReset }
            }

            // "n:*" also matches the highest UID when nothing is newer than n
            // (RFC 3501 §6.4.8), so filter client-side too.
            let floor = Int(watermark)
            let search = try await connection.command("UID SEARCH UID \(floor + 1):*", label: "SEARCH")
            let uids = Array(Self.parseSearch(search)
                .filter { $0 > floor && !skipping.contains(String($0)) }
                .sorted()
                .prefix(Self.maxMessagesPerPoll))
            guard !uids.isEmpty else { return [] }

            let set = uids.map(String.init).joined(separator: ",")
            let fetch = try await connection.command(
                "UID FETCH \(set) (UID INTERNALDATE BODY.PEEK[]<0.\(Self.maxBodyBytes)>)", label: "FETCH")
            var byId: [String: FetchedMessage] = [:]
            for response in fetch {
                if let message = Self.fetchedMessage(from: response), byId[message.id] == nil {
                    byId[message.id] = message
                }
            }
            return uids.compactMap { byId[String($0)] }
        }
    }

    nonisolated public func watermark(for message: FetchedMessage) -> Double {
        Double(message.id) ?? 0
    }

    /// Connects, signs in and opens INBOX read-only, then logs out. Used by
    /// the "add account" flow before anything is saved.
    public func verify(_ credentials: ImapCredentials) async throws {
        let connection = try await connect(credentials)
        do {
            _ = try await Self.examine(connection)
        } catch {
            await connection.close()
            throw error
        }
        await connection.close()
    }

    /// Drops an account's session and state after it is disconnected.
    public func forget(accountId: String) async {
        forgotten.insert(accountId)
        uidValidity[accountId] = nil
        if let session = sessions.removeValue(forKey: accountId) {
            await session.connection.close()
        }
    }

    // MARK: - Session

    private func withSession<T: Sendable>(_ accountId: String,
                                          _ body: (ImapConnection) async throws -> T) async throws -> T {
        if let session = sessions.removeValue(forKey: accountId) {
            if now().timeIntervalSince(session.lastUsed) < Self.sessionIdleLimit {
                do {
                    let result = try await body(session.connection)
                    await checkIn(accountId, session.connection)
                    return result
                } catch let error as ImapError where error.isTransport {
                    // Most likely a socket that died under us (network change,
                    // server-side idle drop). Fall through to a fresh one.
                    await session.connection.close()
                } catch {
                    await session.connection.close()
                    throw error
                }
            } else {
                await session.connection.close()
            }
        }

        guard let credentials = credentialsProvider(accountId) else { throw ImapError.notConfigured }
        let connection = try await connect(credentials)
        do {
            let result = try await body(connection)
            await checkIn(accountId, connection)
            return result
        } catch {
            await connection.close()
            throw error
        }
    }

    private func checkIn(_ accountId: String, _ connection: ImapConnection) async {
        guard !forgotten.contains(accountId) else {
            await connection.close()
            return
        }
        if let replaced = sessions.updateValue(Session(connection: connection, lastUsed: now()), forKey: accountId) {
            await replaced.connection.close()
        }
    }

    private func connect(_ credentials: ImapCredentials) async throws -> ImapConnection {
        let transport = makeTransport(credentials.host, UInt16(clamping: credentials.port))
        let connection = ImapConnection(transport: transport)
        do {
            try await connection.open()
            try await Self.login(connection, credentials)
            return connection
        } catch {
            await connection.close()
            throw error
        }
    }

    static func login(_ connection: ImapConnection, _ credentials: ImapCredentials) async throws {
        guard let user = argument(credentials.username), let password = argument(credentials.password) else {
            throw ImapError.unexpected("username or password contains a NUL character")
        }
        do {
            try await connection.command([.text("LOGIN "), user, .text(" "), password], label: "LOGIN")
        } catch ImapError.server(_, let message) {
            throw ImapError.authentication(message)
        }
    }

    /// A LOGIN argument: an RFC 3501 quoted string when the value is plain
    /// ASCII, otherwise a literal (quoted strings are 7-bit and can't carry
    /// line breaks). Nil for values no IMAP string can carry.
    static func argument(_ value: String) -> ImapConnection.Part? {
        let scalars = value.unicodeScalars
        guard !scalars.contains("\0") else { return nil }
        if scalars.allSatisfy({ $0.isASCII && $0 != "\r" && $0 != "\n" }) {
            let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return .text("\"\(escaped)\"")
        }
        return .literal(Data(value.utf8))
    }

    struct MailboxInfo {
        var uidValidity: Int?
        var uidNext: Int?
    }

    static func examine(_ connection: ImapConnection) async throws -> MailboxInfo {
        let responses = try await connection.command("EXAMINE \(mailbox)", label: "EXAMINE")
        var info = MailboxInfo()
        for response in responses {
            if let v = capture(response.text, uidValidityPattern) { info.uidValidity = Int(v) }
            if let n = capture(response.text, uidNextPattern) { info.uidNext = Int(n) }
        }
        return info
    }

    /// Fallback baseline for servers that omit UIDNEXT: the last message's
    /// UID, or 0 for an empty mailbox (some servers answer BAD to `*` then).
    static func highestUid(_ connection: ImapConnection) async throws -> Int {
        do {
            let responses = try await connection.command("UID FETCH * (UID)", label: "FETCH")
            return responses.compactMap { capture($0.text, uidPattern).flatMap(Int.init) }.max() ?? 0
        } catch ImapError.server {
            return 0
        }
    }

    // MARK: - Response parsing

    private static let uidValidityPattern = regex(#"\[UIDVALIDITY (\d+)\]"#)
    private static let uidNextPattern = regex(#"\[UIDNEXT (\d+)\]"#)
    private static let uidPattern = regex(#"\bUID (\d+)"#)
    private static let internalDatePattern = regex(#"INTERNALDATE "([^"]+)""#)
    private static let esearchAllPattern = regex(#"\bALL ([0-9:,]+)"#)

    /// `* SEARCH 4 5 6`, or the RFC 4731 form `* ESEARCH (TAG "A2") UID ALL 4:6`.
    static func parseSearch(_ responses: [ImapResponse]) -> [Int] {
        var uids: [Int] = []
        for response in responses {
            if response.text.hasPrefix("* SEARCH") {
                uids += response.text.dropFirst("* SEARCH".count).split(separator: " ").compactMap { Int($0) }
            } else if response.text.hasPrefix("* ESEARCH"), let set = capture(response.text, esearchAllPattern) {
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
    /// FETCH responses without a body (e.g. an unsolicited flag change made
    /// by another client mid-command) are not messages and yield nil.
    static func fetchedMessage(from response: ImapResponse) -> FetchedMessage? {
        guard response.text.contains(" FETCH "), response.text.contains("BODY["),
              let raw = response.literals.first,
              let uid = capture(response.text, uidPattern) else { return nil }
        let internalDate = capture(response.text, internalDatePattern).flatMap(parseInternalDate)
        let mail = MimeParser.parse(raw)
        let received = internalDate ?? mail.date ?? Date()
        return FetchedMessage(
            id: uid,
            subject: mail.subject,
            from: mail.from,
            snippet: "",
            text: mail.text,
            receivedAt: (received.timeIntervalSince1970 * 1000).rounded())
    }

    private static let internalDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d-MMM-yyyy HH:mm:ss Z"
        return formatter
    }()

    /// `"20-Sep-2026 10:11:12 +0200"` (day may be space-padded).
    static func parseInternalDate(_ value: String) -> Date? {
        internalDateFormatter.date(from: value.trimmingCharacters(in: .whitespaces))
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }

    private static func capture(_ text: String, _ regex: NSRegularExpression) -> String? {
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
              match.numberOfRanges > 1 else { return nil }
        return (text as NSString).substring(with: match.range(at: 1))
    }
}
