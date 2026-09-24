import Foundation
import XCTest
@testable import AuthReachCore

/// In-memory IMAP server: `respond` maps a command (without its tag) to the
/// reply, with `{T}` standing in for the tag. Replies can be delivered in
/// small chunks to exercise framing across reads.
final class ScriptedTransport: ImapTransport, @unchecked Sendable {
    let respond: @Sendable (String) -> String
    let greeting: String
    let chunkSize: Int
    private let lock = NSLock()
    private var chunks: [Data] = []
    private(set) var sent: [String] = []
    private(set) var closedCount = 0

    init(greeting: String = "* OK IMAP4rev1 ready\r\n", chunkSize: Int = .max,
         respond: @escaping @Sendable (String) -> String) {
        self.greeting = greeting
        self.chunkSize = chunkSize
        self.respond = respond
    }

    func open() async throws { enqueue(greeting) }

    func send(_ data: Data) async throws {
        let line = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        let tag = String(line.prefix { $0 != " " })
        let command = String(line.dropFirst(tag.count + 1))
        lock.lock(); sent.append(command); lock.unlock()
        enqueue(respond(command).replacingOccurrences(of: "{T}", with: tag))
    }

    func receive() async throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard !chunks.isEmpty else { throw ImapError.connection("scripted server closed") }
        return chunks.removeFirst()
    }

    func close() { lock.lock(); closedCount += 1; lock.unlock() }

    private func enqueue(_ text: String) {
        let data = Data(text.utf8)
        lock.lock(); defer { lock.unlock() }
        var offset = 0
        while offset < data.count {
            let end = min(data.count, offset + chunkSize)
            chunks.append(data.subdata(in: offset..<end))
            offset = end
        }
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

    /// A server whose INBOX holds UIDs 5 and 6.
    static func server(uidValidity: Int = 1, uidNext: Int? = 7, search: String = "5 6",
                       fetch: String? = nil) -> @Sendable (String) -> String {
        let fetch = fetch ?? """
        * 5 FETCH (UID 5 INTERNALDATE "20-Sep-2026 10:11:13 +0200" BODY[]<0> \(literal(swedishMail)))\r
        * 6 FETCH (INTERNALDATE " 5-Sep-2026 08:00:00 +0000" BODY[]<0> \(literal(htmlMail)) UID 6)\r

        """
        return { command in
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

    func makeProvider(chunkSize: Int = .max, respond: @escaping @Sendable (String) -> String)
        -> (ImapProvider, TransportLog) {
        let log = TransportLog()
        let provider = ImapProvider(credentialsProvider: { _ in Self.credentials }) { _, _ in
            let transport = ScriptedTransport(chunkSize: chunkSize, respond: respond)
            log.add(transport)
            return transport
        }
        return (provider, log)
    }

    final class TransportLog: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var transports: [ScriptedTransport] = []
        func add(_ t: ScriptedTransport) { lock.lock(); transports.append(t); lock.unlock() }
        var allSent: [String] { transports.flatMap(\.sent) }
    }

    func testInitialWatermarkIsUidNextMinusOne() async throws {
        let (provider, log) = makeProvider(respond: Self.server(uidNext: 42))
        let watermark = try await provider.initialWatermark(accountId: "a1")
        XCTAssertEqual(watermark, 41)
        XCTAssertEqual(log.allSent, ["LOGIN \"me@example.com\" \"p\\\"w\\\\d\"", "EXAMINE INBOX", "LOGOUT"])
        XCTAssertEqual(log.transports.first?.closedCount, 1)
    }

    func testInitialWatermarkFallsBackToHighestUid() async throws {
        let (provider, _) = makeProvider(respond: Self.server(uidNext: nil))
        let watermark = try await provider.initialWatermark(accountId: "a1")
        XCTAssertEqual(watermark, 6)
    }

    func testListsAndParsesNewMessages() async throws {
        let (provider, log) = makeProvider(respond: Self.server())
        let ids = try await provider.listMessageIds(accountId: "a1", after: 4)
        XCTAssertEqual(ids, ["5", "6"])
        XCTAssertTrue(log.allSent.contains("UID SEARCH UID 5:*"))
        XCTAssertTrue(log.allSent.contains("UID FETCH 5,6 (UID INTERNALDATE BODY.PEEK[]<0.\(ImapProvider.maxBodyBytes)>)"))

        let swedish = try await provider.message(accountId: "a1", id: "5")
        XCTAssertEqual(swedish.subject, "Din säkerhetskod")
        XCTAssertEqual(swedish.from, "Bank ID <noreply@bankid.com>")
        XCTAssertEqual(swedish.text, "Din säkerhetskod är 481920. Koden gäller i 10 minuter.")
        XCTAssertEqual(swedish.receivedAt, ISO8601DateFormatter().date(from: "2026-09-20T08:11:13Z")!.timeIntervalSince1970 * 1000)
        XCTAssertEqual(provider.watermark(for: swedish), 5)

        let html = try await provider.message(accountId: "a1", id: "6")
        XCTAssertEqual(html.text, "Your login code is 445566")
        XCTAssertEqual(html.receivedAt, ISO8601DateFormatter().date(from: "2026-09-05T08:00:00Z")!.timeIntervalSince1970 * 1000)
    }

    func testLiteralsSurviveChunkedReads() async throws {
        let (provider, _) = makeProvider(chunkSize: 7, respond: Self.server())
        let ids = try await provider.listMessageIds(accountId: "a1", after: 4)
        XCTAssertEqual(ids, ["5", "6"])
        let message = try await provider.message(accountId: "a1", id: "5")
        XCTAssertEqual(OtpDetector.detectCode(in: message.text), "481920")
    }

    func testSearchEchoingTheWatermarkYieldsNothing() async throws {
        // "7:*" on a mailbox whose highest UID is 6 answers "6" (RFC 3501 §6.4.8).
        let (provider, log) = makeProvider(respond: Self.server(search: "6"))
        let ids = try await provider.listMessageIds(accountId: "a1", after: 6)
        XCTAssertEqual(ids, [])
        XCTAssertFalse(log.allSent.contains { $0.hasPrefix("UID FETCH") }, "no FETCH for an empty batch")
    }

    func testEsearchResponseIsParsed() {
        let responses = [ImapResponse(text: "* ESEARCH (TAG \"A3\") UID ALL 4:6,9", literals: [])]
        XCTAssertEqual(ImapProvider.parseSearch(responses), [4, 5, 6, 9])
    }

    func testUidValidityChangeRequestsBaselineReset() async throws {
        let validity = Counter()
        let (provider, _) = makeProvider { command in
            Self.server(uidValidity: validity.value)(command)
        }
        _ = try await provider.initialWatermark(accountId: "a1")
        validity.value = 2
        do {
            _ = try await provider.listMessageIds(accountId: "a1", after: 6)
            XCTFail("expected baselineReset")
        } catch InboxProviderError.baselineReset {
            // expected
        }
        // The new validity is now the known one, so the next poll proceeds.
        let ids = try await provider.listMessageIds(accountId: "a1", after: 4)
        XCTAssertEqual(ids, ["5", "6"])
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

    func testMissingCredentialsIsAnError() async {
        let provider = ImapProvider(credentialsProvider: { _ in nil }) { _, _ in
            ScriptedTransport { _ in "{T} OK\r\n" }
        }
        do {
            _ = try await provider.initialWatermark(accountId: "a1")
            XCTFail("expected notConfigured")
        } catch {
            XCTAssertEqual(error.localizedDescription, "IMAP credentials are missing. Please reconnect this account.")
        }
    }

    func testEndToEndWithOtpCenter() async throws {
        let (provider, _) = makeProvider(respond: Self.server(uidNext: 5))
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
