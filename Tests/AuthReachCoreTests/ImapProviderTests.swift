import Foundation
import XCTest
@testable import AuthReachCore

/// In-memory IMAP server: `respond` maps a command (without its tag) to the
/// reply, with `{T}` standing in for the tag. Replies can be delivered in
/// small chunks to exercise framing across reads. Client literals are
/// answered with "+" and show up inline in `sent` (`{n}` then the bytes).
final class ScriptedTransport: ImapTransport, @unchecked Sendable {
    let respond: @Sendable (String) -> String
    let greeting: String
    let chunkSize: Int
    private let lock = NSLock()
    private var chunks: [Data] = []
    private var inbound = Data()
    private var pendingCommand = Data()
    private var literalRemaining = 0
    private var dead = false
    private var _sent: [String] = []
    private var _closedCount = 0

    init(greeting: String = "* OK IMAP4rev1 ready\r\n", chunkSize: Int = .max,
         respond: @escaping @Sendable (String) -> String) {
        self.greeting = greeting
        self.chunkSize = chunkSize
        self.respond = respond
    }

    var sent: [String] { locked { _sent } }
    var closedCount: Int { locked { _closedCount } }

    func open() async throws { locked { enqueue(greeting) } }

    func send(_ data: Data) async throws {
        try locked {
            if dead { throw ImapError.connection("scripted socket is dead") }
            inbound.append(data)
            process()
        }
    }

    func receive() async throws -> Data {
        try locked {
            guard !dead, !chunks.isEmpty else { throw ImapError.connection("scripted server closed") }
            return chunks.removeFirst()
        }
    }

    func close() { locked { _closedCount += 1 } }

    /// Simulates a socket that died while idle (e.g. across sleep).
    func kill() { locked { dead = true } }

    private func process() {
        while true {
            if literalRemaining > 0 {
                guard inbound.count >= literalRemaining else { return }
                pendingCommand.append(inbound.prefix(literalRemaining))
                inbound.removeFirst(literalRemaining)
                literalRemaining = 0
                continue
            }
            guard let end = inbound.range(of: Data("\r\n".utf8)) else { return }
            let line = Data(inbound[inbound.startIndex..<end.lowerBound])
            inbound.removeSubrange(inbound.startIndex..<end.upperBound)
            pendingCommand.append(line)
            if let length = ImapConnection.literalLength(line) {
                literalRemaining = length
                enqueue("+ Ready for literal\r\n")
                continue
            }
            let text = String(decoding: pendingCommand, as: UTF8.self)
            pendingCommand = Data()
            let tag = String(text.prefix { $0 != " " })
            let command = String(text.dropFirst(tag.count + 1))
            _sent.append(command)
            enqueue(respond(command).replacingOccurrences(of: "{T}", with: tag))
        }
    }

    private func enqueue(_ text: String) {
        let data = Data(text.utf8)
        var offset = 0
        while offset < data.count {
            let end = min(data.count, offset + chunkSize)
            chunks.append(data.subdata(in: offset..<end))
            offset = end
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
}

final class ImapProviderTests: XCTestCase {
    static let credentials = ImapCredentials(host: "imap.example.com", username: "me@example.com", password: "p\"w\\d")

    static func literal(_ s: String) -> String { "{\(s.utf8.count)}\r\n\(s)" }

    static let swedishMail = """
    From: =?UTF-8?Q?Bank_ID?= <noreply@bankid.com>\r
    Subject: Din s=?UTF-8?Q?=C3=A4?=kerhetskod\r
    Content-Type: text/plain; charset=utf-8\r
    Content-Transfer-Encoding: quoted-printable\r
    \r
    Din s=C3=A4kerhetskod =C3=A4r 481920. Koden g=C3=A4ller i 10 minuter.\r

    """

    static let htmlMail = """
    From: "Acme" <no@acme.io>\r
    Subject: Login\r
    Content-Type: text/html\r
    \r
    <p>Your login code is <b>445566</b></p>\r

    """

    static let defaultFetch = """
    * 5 FETCH (UID 5 INTERNALDATE "20-Sep-2026 10:11:13 +0200" BODY[]<0> \(literal(swedishMail)))\r
    * 6 FETCH (INTERNALDATE " 5-Sep-2026 08:00:00 +0000" BODY[]<0> \(literal(htmlMail)) UID 6)\r

    """

    /// A server whose INBOX holds UIDs 5 and 6.
    static func server(uidValidity: Int = 1, uidNext: Int? = 7, search: String = "5 6",
                       fetch: String = defaultFetch) -> @Sendable (String) -> String {
        { command in
            switch command {
            case _ where command.hasPrefix("LOGIN"):
                return "{T} OK Logged in\r\n"
            case "EXAMINE INBOX":
                let next = uidNext.map { "* OK [UIDNEXT \($0)] Predicted next UID\r\n" } ?? ""
                return "* 6 EXISTS\r\n* OK [UIDVALIDITY \(uidValidity)] UIDs valid\r\n\(next){T} OK [READ-ONLY] Examine completed\r\n"
            case _ where command.hasPrefix("UID SEARCH"):
                return "* SEARCH \(search)\r\n{T} OK Search completed\r\n"
            case "UID FETCH * (UID)":
                return "* 6 FETCH (UID 6)\r\n{T} OK Fetch completed\r\n"
            case _ where command.hasPrefix("UID FETCH"):
                return fetch + "{T} OK Fetch completed\r\n"
            case "LOGOUT":
                return "* BYE\r\n{T} OK Logging out\r\n"
            default:
                return "{T} BAD Unknown command\r\n"
            }
        }
    }

    final class TransportLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _transports: [ScriptedTransport] = []
        var transports: [ScriptedTransport] { lock.lock(); defer { lock.unlock() }; return _transports }
        func add(_ t: ScriptedTransport) { lock.lock(); _transports.append(t); lock.unlock() }
        var allSent: [String] { transports.flatMap(\.sent) }
        var logins: Int { allSent.filter { $0.hasPrefix("LOGIN") }.count }
    }

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var _now = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.lock(); defer { lock.unlock() }; return _now }
        func advance(_ seconds: TimeInterval) { lock.lock(); _now += seconds; lock.unlock() }
    }

    func makeProvider(chunkSize: Int = .max, credentials: ImapCredentials = credentials, clock: Clock = Clock(),
                      respond: @escaping @Sendable (String) -> String) -> (ImapProvider, TransportLog) {
        let log = TransportLog()
        let provider = ImapProvider(credentialsProvider: { _ in credentials }, transport: { _, _ in
            let transport = ScriptedTransport(chunkSize: chunkSize, respond: respond)
            log.add(transport)
            return transport
        }, now: { clock.now })
        return (provider, log)
    }

    func testInitialWatermarkIsUidNextMinusOne() async throws {
        let (provider, log) = makeProvider(respond: Self.server(uidNext: 42))
        let watermark = try await provider.initialWatermark(accountId: "a1")
        XCTAssertEqual(watermark, 41)
        XCTAssertEqual(log.allSent, ["LOGIN \"me@example.com\" \"p\\\"w\\\\d\"", "EXAMINE INBOX"])
        XCTAssertEqual(log.transports.first?.closedCount, 0, "session is kept for the next poll")
    }

    func testInitialWatermarkFallsBackToHighestUid() async throws {
        let (provider, _) = makeProvider(respond: Self.server(uidNext: nil))
        let watermark = try await provider.initialWatermark(accountId: "a1")
        XCTAssertEqual(watermark, 6)
    }

    func testFetchesAndParsesNewMessages() async throws {
        let (provider, log) = makeProvider(respond: Self.server())
        let messages = try await provider.messages(accountId: "a1", after: 4, skipping: [])
        XCTAssertEqual(messages.map(\.id), ["5", "6"])
        XCTAssertTrue(log.allSent.contains("UID SEARCH UID 5:*"))
        XCTAssertTrue(log.allSent.contains("UID FETCH 5,6 (UID INTERNALDATE BODY.PEEK[]<0.\(ImapProvider.maxBodyBytes)>)"))

        let swedish = messages[0]
        XCTAssertEqual(swedish.subject, "Din säkerhetskod")
        XCTAssertEqual(swedish.from, "Bank ID <noreply@bankid.com>")
        XCTAssertEqual(swedish.text, "Din säkerhetskod är 481920. Koden gäller i 10 minuter.")
        XCTAssertEqual(swedish.receivedAt, ISO8601DateFormatter().date(from: "2026-09-20T08:11:13Z")!.timeIntervalSince1970 * 1000)
        XCTAssertEqual(provider.watermark(for: swedish), 5)

        let html = messages[1]
        XCTAssertEqual(html.text, "Your login code is 445566")
        XCTAssertEqual(html.receivedAt, ISO8601DateFormatter().date(from: "2026-09-05T08:00:00Z")!.timeIntervalSince1970 * 1000)
    }

    func testSkippedIdsAreNotFetched() async throws {
        let (provider, log) = makeProvider(respond: Self.server())
        _ = try await provider.messages(accountId: "a1", after: 4, skipping: ["5"])
        XCTAssertTrue(log.allSent.contains { $0.hasPrefix("UID FETCH 6 ") })
    }

    func testLiteralsSurviveChunkedReads() async throws {
        let (provider, _) = makeProvider(chunkSize: 7, respond: Self.server())
        let messages = try await provider.messages(accountId: "a1", after: 4, skipping: [])
        XCTAssertEqual(messages.map(\.id), ["5", "6"])
        XCTAssertEqual(OtpDetector.detectCode(in: messages[0].text), "481920")
    }

    func testUnsolicitedFetchDoesNotReplaceTheMessage() async throws {
        // Another client flags UID 5 mid-FETCH; RFC 3501 requires the UID in
        // that unsolicited response, but it carries no body.
        let fetch = Self.defaultFetch + "* 5 FETCH (FLAGS (\\Seen) UID 5)\r\n"
        let (provider, _) = makeProvider(respond: Self.server(fetch: fetch))
        let messages = try await provider.messages(accountId: "a1", after: 4, skipping: [])
        XCTAssertEqual(messages.map(\.id), ["5", "6"])
        XCTAssertEqual(messages[0].subject, "Din säkerhetskod")
    }

    func testSearchEchoingTheWatermarkYieldsNothing() async throws {
        // "7:*" on a mailbox whose highest UID is 6 answers "6" (RFC 3501 §6.4.8).
        let (provider, log) = makeProvider(respond: Self.server(search: "6"))
        let messages = try await provider.messages(accountId: "a1", after: 6, skipping: [])
        XCTAssertEqual(messages.map(\.id), [])
        XCTAssertFalse(log.allSent.contains { $0.hasPrefix("UID FETCH") }, "no FETCH for an empty batch")
    }

    func testEsearchResponseIsParsed() {
        let responses = [ImapResponse(text: "* ESEARCH (TAG \"A3\") UID ALL 4:6,9", literals: [])]
        XCTAssertEqual(ImapProvider.parseSearch(responses), [4, 5, 6, 9])
    }

    func testSessionIsReusedAcrossPolls() async throws {
        let (provider, log) = makeProvider(respond: Self.server())
        _ = try await provider.initialWatermark(accountId: "a1")
        _ = try await provider.messages(accountId: "a1", after: 4, skipping: [])
        _ = try await provider.messages(accountId: "a1", after: 6, skipping: [])
        XCTAssertEqual(log.transports.count, 1)
        XCTAssertEqual(log.logins, 1)
        XCTAssertEqual(log.allSent.filter { $0 == "EXAMINE INBOX" }.count, 3)
    }

    func testIdleSessionIsReplaced() async throws {
        let clock = Clock()
        let (provider, log) = makeProvider(clock: clock, respond: Self.server())
        _ = try await provider.initialWatermark(accountId: "a1")
        clock.advance(ImapProvider.sessionIdleLimit + 1) // e.g. the Mac slept
        _ = try await provider.messages(accountId: "a1", after: 4, skipping: [])
        XCTAssertEqual(log.transports.count, 2)
        XCTAssertEqual(log.logins, 2)
        XCTAssertEqual(log.transports.first?.sent.last, "LOGOUT")
    }

    func testDeadSessionIsRetriedOnAFreshConnection() async throws {
        let (provider, log) = makeProvider(respond: Self.server())
        _ = try await provider.initialWatermark(accountId: "a1")
        log.transports.first?.kill()
        let messages = try await provider.messages(accountId: "a1", after: 4, skipping: [])
        XCTAssertEqual(messages.map(\.id), ["5", "6"])
        XCTAssertEqual(log.transports.count, 2)
    }

    func testForgetClosesTheSession() async throws {
        let (provider, log) = makeProvider(respond: Self.server())
        _ = try await provider.initialWatermark(accountId: "a1")
        await provider.forget(accountId: "a1")
        XCTAssertEqual(log.transports.first?.closedCount, 1)
    }

    func testUidValidityChangeRequestsBaselineReset() async throws {
        let validity = Counter()
        let (provider, _) = makeProvider { command in
            Self.server(uidValidity: validity.value)(command)
        }
        _ = try await provider.initialWatermark(accountId: "a1")
        validity.value = 2
        do {
            _ = try await provider.messages(accountId: "a1", after: 6, skipping: [])
            XCTFail("expected baselineReset")
        } catch InboxProviderError.baselineReset {
            // expected
        }
        // The new validity is now the known one, so the next poll proceeds.
        let messages = try await provider.messages(accountId: "a1", after: 4, skipping: [])
        XCTAssertEqual(messages.map(\.id), ["5", "6"])
    }

    func testNonAsciiPasswordIsSentAsLiteral() async throws {
        let credentials = ImapCredentials(host: "imap.example.com", username: "me@example.com", password: "lösenord")
        let (provider, log) = makeProvider(credentials: credentials, respond: Self.server())
        try await provider.verify(credentials)
        XCTAssertEqual(log.allSent.first, "LOGIN \"me@example.com\" {9}lösenord")
    }

    func testLoginArguments() {
        XCTAssertEqual(ImapProvider.argument("a\"b\\c"), .text("\"a\\\"b\\\\c\""))
        XCTAssertEqual(ImapProvider.argument("två\r\nrader"), .literal(Data("två\r\nrader".utf8)))
        XCTAssertNil(ImapProvider.argument("nul\0"))
    }

    func testLoginFailureIsReportedWithoutResponseCode() async throws {
        let (provider, log) = makeProvider { command in
            command.hasPrefix("LOGIN") ? "{T} NO [AUTHENTICATIONFAILED] Invalid credentials (Failure)\r\n"
                : "* BYE\r\n{T} OK bye\r\n"
        }
        do {
            try await provider.verify(Self.credentials)
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "IMAP sign-in was rejected: Invalid credentials (Failure)")
        }
        XCTAssertEqual(log.transports.first?.closedCount, 1)
    }

    func testVerifyLogsOut() async throws {
        let (provider, log) = makeProvider(respond: Self.server())
        try await provider.verify(Self.credentials)
        XCTAssertEqual(log.allSent.last, "LOGOUT")
        XCTAssertEqual(log.transports.first?.closedCount, 1)
    }

    func testMissingCredentialsIsAnError() async {
        let provider = ImapProvider(credentialsProvider: { _ in nil }, transport: { _, _ in
            ScriptedTransport { _ in "{T} OK\r\n" }
        })
        do {
            _ = try await provider.initialWatermark(accountId: "a1")
            XCTFail("expected notConfigured")
        } catch {
            XCTAssertEqual(error.localizedDescription, "IMAP credentials are missing. Please reconnect this account.")
        }
    }

    func testEndToEndWithOtpCenter() async throws {
        let (provider, log) = makeProvider(respond: Self.server(uidNext: 5))
        let center = OtpCenter(providerFor: { _ in provider })
        await center.configureAccounts([ConnectedAccount(id: "a1", email: "me@example.com", provider: .imap)])
        await center.pollAll() // baseline: UIDNEXT 5 → watermark 4
        await center.pollAll() // UIDs 5 and 6 are new
        let recent = await center.recent
        XCTAssertEqual(recent.map(\.code), ["445566", "481920"])
        XCTAssertEqual(recent.last?.service, "Bank ID")
        XCTAssertEqual(recent.last?.expiresAt, recent.last!.receivedAt + 600_000)
        let runtime = await center.runtime(accountId: "a1")
        XCTAssertNil(runtime?.lastError)
        XCTAssertEqual(runtime?.watermark, 6)
        XCTAssertEqual(log.logins, 1)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = 1
        var value: Int {
            get { lock.lock(); defer { lock.unlock() }; return _value }
            set { lock.lock(); _value = newValue; lock.unlock() }
        }
    }
}
