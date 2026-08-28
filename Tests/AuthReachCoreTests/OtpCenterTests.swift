import Foundation
import XCTest
@testable import AuthReachCore

/// Scriptable inbox: messages appear over "time" driven by the watermark.
final class StubInbox: InboxProvider, @unchecked Sendable {
    var mailbox: [FetchedMessage] = []
    var baseline: Double = 1000
    var failNext = false

    func initialWatermark(accountId: String) async throws -> Double { baseline }
    func listMessageIds(accountId: String, after watermark: Double) async throws -> [String] {
        if failNext { failNext = false; throw NSError(domain: "stub", code: 1, userInfo: [NSLocalizedDescriptionKey: "inbox offline"]) }
        return mailbox.filter { $0.receivedAt / 1000 > watermark }.map(\.id)
    }
    func message(accountId: String, id: String) async throws -> FetchedMessage {
        mailbox.first { $0.id == id }!
    }
    func watermark(for message: FetchedMessage) -> Double { message.receivedAt / 1000 }
}

final class OtpCenterTests: XCTestCase {
    var inbox: StubInbox!
    var center: OtpCenter!

    override func setUp() async throws {
        inbox = StubInbox()
        center = OtpCenter(provider: inbox)
        await center.configureAccounts([ConnectedAccount(id: "a1", email: "me@example.com")])
    }

    func mail(_ id: String, at seconds: Double, subject: String, body: String = "",
              from: String = "\"GitHub\" <noreply@github.com>") -> FetchedMessage {
        FetchedMessage(id: id, subject: subject, from: from, snippet: "", text: body,
                       receivedAt: seconds * 1000)
    }

    func testFirstPollBaselinesWithoutProcessingBacklog() async {
        inbox.mailbox = [mail("old", at: 900, subject: "Your code is 111111")]
        await center.pollAll() // baseline only
        await center.pollAll() // nothing newer than baseline
        let recent = await center.recent
        XCTAssertTrue(recent.isEmpty, "backlog must be skipped")
    }

    func testNewOtpMailIsCapturedWithMetadata() async {
        await center.pollAll() // baseline (1000)
        inbox.mailbox = [mail("m1", at: 1010, subject: "Your verification code is 123456",
                              body: "It expires in 10 minutes.")]
        await center.pollAll()
        let recent = await center.recent
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent[0].code, "123456")
        XCTAssertEqual(recent[0].service, "GitHub")
        XCTAssertEqual(recent[0].sender, "noreply@github.com")
        XCTAssertEqual(recent[0].accountEmail, "me@example.com")
        XCTAssertEqual(recent[0].expiresAt, 1010 * 1000 + 600 * 1000)
    }

    func testNonOtpMailIsIgnoredAndNeverReprocessed() async {
        await center.pollAll()
        inbox.mailbox = [mail("m1", at: 1010, subject: "Weekly newsletter 483920")]
        await center.pollAll()
        await center.pollAll()
        let recent = await center.recent
        XCTAssertTrue(recent.isEmpty)
    }

    func testWatermarkAdvancesSoOldMailIsNotRefetched() async {
        await center.pollAll()
        inbox.mailbox = [mail("m1", at: 1010, subject: "Login code 222222")]
        await center.pollAll()
        inbox.mailbox.append(mail("m2", at: 1020, subject: "Login code 333333"))
        await center.pollAll()
        let recent = await center.recent
        XCTAssertEqual(recent.map(\.code), ["333333", "222222"]) // newest first
    }

    func testErrorIsRecordedPerAccountAndRecovers() async {
        await center.pollAll()
        inbox.failNext = true
        await center.pollAll()
        var runtime = await center.runtime(accountId: "a1")
        XCTAssertEqual(runtime?.lastError, "inbox offline")

        inbox.mailbox = [mail("m1", at: 1010, subject: "Your passcode is 444444")]
        await center.pollAll()
        runtime = await center.runtime(accountId: "a1")
        XCTAssertNil(runtime?.lastError)
        let recent = await center.recent
        XCTAssertEqual(recent.first?.code, "444444")
    }

    func testRecentListCapped() async {
        await center.pollAll()
        inbox.mailbox = (1...25).map {
            mail("m\($0)", at: 1000 + Double($0), subject: "Your code is \(100000 + $0)")
        }
        await center.pollAll()
        let recent = await center.recent
        XCTAssertEqual(recent.count, OtpCenter.maxRecent)
        XCTAssertEqual(recent.first?.code, "100025")
    }

    func testRemovedAccountStopsPolling() async {
        await center.configureAccounts([])
        inbox.mailbox = [mail("m1", at: 1010, subject: "code 555555")]
        await center.pollAll()
        let recent = await center.recent
        XCTAssertTrue(recent.isEmpty)
    }
}

final class GmailParsingTests: XCTestCase {
    func testExtractsPlainTextAndHeadersFromMimeTree() throws {
        let b64 = { (s: String) in Data(s.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_") }
        let json = """
        {"id":"m1","internalDate":"1700000000000","snippet":"snip",
         "payload":{"mimeType":"multipart/alternative",
           "headers":[{"name":"Subject","value":"Your code"},{"name":"From","value":"\\"Acme\\" <no@acme.io>"}],
           "parts":[
             {"mimeType":"text/plain","body":{"data":"\(b64("Code is 987654"))"}},
             {"mimeType":"text/html","body":{"data":"\(b64("<b>Code is 987654</b>"))"}}]}}
        """
        let msg = try JSONDecoder().decode(GmailClient.Message.self, from: Data(json.utf8))
        let fetched = GmailClient.fetchedMessage(from: msg)
        XCTAssertEqual(fetched.subject, "Your code")
        XCTAssertEqual(fetched.from, "\"Acme\" <no@acme.io>")
        XCTAssertEqual(fetched.text, "Code is 987654")
        XCTAssertEqual(fetched.receivedAt, 1_700_000_000_000)
    }

    func testHtmlOnlyBodyIsStripped() throws {
        let b64 = Data("<p>Your <b>login</b> code is 445566</p>".utf8).base64EncodedString()
        let json = """
        {"id":"m2","payload":{"mimeType":"text/html","body":{"data":"\(b64)"}}}
        """
        let msg = try JSONDecoder().decode(GmailClient.Message.self, from: Data(json.utf8))
        XCTAssertEqual(GmailClient.fetchedMessage(from: msg).text, "Your login code is 445566")
    }
}
