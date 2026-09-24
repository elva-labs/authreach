import Foundation
import XCTest
@testable import AuthReachCore

final class GoogleAPIErrorTests: XCTestCase {
    private func gmail(_ status: Int, _ body: String) -> GoogleAPIError {
        GoogleAPIError.fromGmail(status: status, body: Data(body.utf8))
    }

    /// The case that motivated this: an OAuth client whose project never
    /// enabled the Gmail API signs in fine, then every Gmail call fails.
    func testGmailApiDisabled() {
        let body = """
        {"error":{"code":403,"message":"Gmail API has not been used in project 123 before or it is disabled.",
         "errors":[{"message":"…","domain":"usageLimits","reason":"accessNotConfigured"}],
         "status":"PERMISSION_DENIED",
         "details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"SERVICE_DISABLED"}]}}
        """
        XCTAssertEqual(gmail(403, body), .gmailDisabled)
        // Either reason on its own is enough.
        XCTAssertEqual(gmail(403, #"{"error":{"code":403,"details":[{"reason":"SERVICE_DISABLED"}]}}"#), .gmailDisabled)
    }

    func testInsufficientScope() {
        let body = """
        {"error":{"code":403,"message":"Request had insufficient authentication scopes.",
         "errors":[{"message":"Insufficient Permission","domain":"global","reason":"insufficientPermissions"}],
         "status":"PERMISSION_DENIED",
         "details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"ACCESS_TOKEN_SCOPE_INSUFFICIENT"}]}}
        """
        XCTAssertEqual(gmail(403, body), .scopeNotGranted)
    }

    func testStatusFallbacks() {
        XCTAssertEqual(gmail(401, #"{"error":{"code":401,"status":"UNAUTHENTICATED"}}"#), .unauthorized)
        XCTAssertEqual(gmail(429, "{}"), .rateLimited)
        XCTAssertEqual(gmail(403, #"{"error":{"errors":[{"reason":"userRateLimitExceeded"}]}}"#), .rateLimited)
        XCTAssertEqual(gmail(503, "<html>oops</html>"), .unavailable(status: 503))
    }

    /// Unknown errors carry Google's message, not the raw JSON.
    func testOtherUsesGoogleMessage() {
        XCTAssertEqual(gmail(404, #"{"error":{"code":404,"message":"Requested entity was not found."}}"#),
                       .other(status: 404, message: "Requested entity was not found."))
        XCTAssertEqual(gmail(400, "\n  Bad things\nmore\n"), .other(status: 400, message: "Bad things"))
        XCTAssertEqual(gmail(400, ""), .other(status: 400, message: "no details"))
    }

    func testTokenEndpoint() {
        func token(_ status: Int, _ body: String, refreshing: Bool) -> GoogleAPIError {
            GoogleAPIError.fromTokenEndpoint(status: status, body: Data(body.utf8), refreshing: refreshing)
        }
        let invalidClient = #"{"error":"invalid_client","error_description":"Unauthorized"}"#
        XCTAssertEqual(token(401, invalidClient, refreshing: false), .invalidClient)
        // What Google answers once the OAuth client is deleted in the console.
        let deletedClient = #"{"error":"deleted_client","error_description":"The OAuth client was deleted."}"#
        XCTAssertEqual(token(401, deletedClient, refreshing: true), .invalidClient)
        let invalidGrant = #"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#
        XCTAssertEqual(token(400, invalidGrant, refreshing: true), .signInExpired)
        // A rejected authorization code is not an expired sign-in.
        XCTAssertEqual(token(400, invalidGrant, refreshing: false),
                       .other(status: 400, message: "invalid_grant: Token has been expired or revoked."))
        XCTAssertEqual(token(502, "Bad Gateway", refreshing: true), .unavailable(status: 502))
    }

    /// Only problems the user can fix ask for attention, and only a
    /// sign-in problem offers Reconnect.
    func testRemedies() {
        XCTAssertEqual(AccountProblem(GoogleAPIError.rateLimited).remedy, .automatic)
        XCTAssertEqual(AccountProblem(GoogleAPIError.unavailable(status: 503)).remedy, .automatic)
        XCTAssertFalse(AccountProblem(GoogleAPIError.unavailable(status: 503)).needsAttention)
        XCTAssertEqual(AccountProblem(GoogleAPIError.signInExpired).remedy, .reconnect)
        XCTAssertEqual(AccountProblem(GoogleAPIError.scopeNotGranted).remedy, .reconnect)
        XCTAssertEqual(AccountProblem(GoogleOAuth.OAuthError.notConnected).remedy, .reconnect)
        XCTAssertEqual(AccountProblem(GoogleAPIError.gmailDisabled).remedy, .manual)
        XCTAssertEqual(AccountProblem(GoogleAPIError.invalidClient).remedy, .manual)
        XCTAssertEqual(AccountProblem(URLError(.notConnectedToInternet)).remedy, .automatic)
        XCTAssertEqual(AccountProblem(URLError(.serverCertificateUntrusted)).remedy, .manual)
        XCTAssertEqual(AccountProblem(ImapError.connection("reset")).remedy, .automatic)
        XCTAssertEqual(AccountProblem(ImapError.authentication("bad password")).remedy, .manual)
        let other = AccountProblem(NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"]))
        XCTAssertEqual(other, AccountProblem(message: "boom", remedy: .manual))
        XCTAssertTrue(other.needsAttention)
    }

    func testMessagesPointAtTheFix() {
        XCTAssertTrue(GoogleAPIError.gmailDisabled.localizedDescription.contains("APIs & Services"))
        XCTAssertTrue(GoogleAPIError.signInExpired.localizedDescription.contains("Reconnect"))
    }
}

final class GoogleOAuthFlowTests: XCTestCase {
    func testAuthorizationCodeAndRedirectErrors() throws {
        XCTAssertEqual(try GoogleOAuth.authorizationCode(from: ["code": "4/0Abc", "scope": "x"]), "4/0Abc")
        XCTAssertThrowsError(try GoogleOAuth.authorizationCode(from: ["error": "access_denied"])) { error in
            guard case GoogleOAuth.OAuthError.consentDeclined = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try GoogleOAuth.authorizationCode(from: ["error": "invalid_scope"])) { error in
            guard case GoogleOAuth.OAuthError.flowFailed("invalid_scope") = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try GoogleOAuth.authorizationCode(from: ["code": ""]))
        XCTAssertThrowsError(try GoogleOAuth.authorizationCode(from: [:]))
    }

    /// Reconnect preselects the account in Google's chooser.
    func testConsentURLLoginHint() throws {
        func items(_ url: URL) -> [String: String] {
            Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .map { ($0.name, $0.value ?? "") })
        }
        let hinted = items(GoogleOAuth.consentURL(clientId: "id", redirectUri: "http://127.0.0.1:1/callback",
                                                  loginHint: "me+otp@example.com"))
        XCTAssertEqual(hinted["login_hint"], "me+otp@example.com")
        XCTAssertEqual(hinted["prompt"], "consent")
        XCTAssertEqual(hinted["access_type"], "offline")
        let plain = items(GoogleOAuth.consentURL(clientId: "id", redirectUri: "http://127.0.0.1:1/callback", loginHint: nil))
        XCTAssertNil(plain["login_hint"])
    }

    /// Granular consent: the user can untick Gmail and Google still issues
    /// a token, which then fails on the first Gmail call.
    func testGrantedScope() {
        XCTAssertTrue(GoogleOAuth.grantsGmail(scope: nil))
        XCTAssertTrue(GoogleOAuth.grantsGmail(scope: "https://www.googleapis.com/auth/gmail.readonly"))
        XCTAssertTrue(GoogleOAuth.grantsGmail(scope: "openid https://www.googleapis.com/auth/gmail.readonly"))
        XCTAssertFalse(GoogleOAuth.grantsGmail(scope: ""))
        XCTAssertFalse(GoogleOAuth.grantsGmail(scope: "openid email"))
        XCTAssertFalse(GoogleOAuth.grantsGmail(scope: "https://www.googleapis.com/auth/gmail.readonly.extra"))
    }

    func testCredentialProblems() {
        let id = "123-abc.apps.googleusercontent.com"
        XCTAssertNil(GoogleCredentials(clientId: id, clientSecret: "GOCSPX-secret").problem)
        XCTAssertNotNil(GoogleCredentials(clientId: "", clientSecret: "x").problem)
        XCTAssertNotNil(GoogleCredentials(clientId: "123-abc", clientSecret: "x").problem)
        XCTAssertEqual(GoogleCredentials(clientId: "GOCSPX-secret", clientSecret: id).problem?.contains("swapped"), true)
        XCTAssertNotNil(GoogleCredentials(clientId: id, clientSecret: "GOCSPX- secret").problem)
        // Pasting from the console often brings a trailing newline along.
        let pasted = GoogleCredentials(pastedClientId: " \(id)\n", clientSecret: "GOCSPX-secret\r\n")
        XCTAssertEqual(pasted, GoogleCredentials(clientId: id, clientSecret: "GOCSPX-secret"))
        XCTAssertNil(pasted.problem)
    }
}

final class LoopbackRedirectServerTests: XCTestCase {
    func testCallbackQueryParsing() {
        XCTAssertEqual(LoopbackRedirectServer.callbackQuery(
            requestLine: "GET /callback?code=4%2F0AbCd&scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fgmail.readonly HTTP/1.1"),
            ["code": "4/0AbCd", "scope": "https://www.googleapis.com/auth/gmail.readonly"])
        XCTAssertEqual(LoopbackRedirectServer.callbackQuery(requestLine: "GET /callback?error=access_denied HTTP/1.1"),
                       ["error": "access_denied"])
        XCTAssertEqual(LoopbackRedirectServer.callbackQuery(requestLine: "GET /callback HTTP/1.1"), [:])
        XCTAssertNil(LoopbackRedirectServer.callbackQuery(requestLine: "GET /favicon.ico HTTP/1.1"))
        XCTAssertNil(LoopbackRedirectServer.callbackQuery(requestLine: "GET /callbackx?code=1 HTTP/1.1"))
        XCTAssertNil(LoopbackRedirectServer.callbackQuery(requestLine: "POST /callback?code=1 HTTP/1.1"))
        XCTAssertNil(LoopbackRedirectServer.callbackQuery(requestLine: ""))
    }

    /// Error messages quote Google's text, so the page must escape it.
    func testPageEscapesText() {
        let page = LoopbackRedirectServer.page(title: "Couldn't connect", message: "<script>&\"", isError: true)
        XCTAssertTrue(page.contains("Couldn&#39;t connect"))
        XCTAssertTrue(page.contains("&lt;script&gt;&amp;&quot;"))
        XCTAssertFalse(page.contains("<script>"))
    }

    private func get(_ port: UInt16, _ path: String) async throws -> String {
        let url = URL(string: "http://127.0.0.1:\(port)\(path)")!
        let (data, _) = try await URLSession.shared.data(from: url)
        return String(decoding: data, as: UTF8.self)
    }

    /// The browser's request stays open until the app knows the outcome.
    func testHoldsRedirectUntilFinished() async throws {
        let server = try LoopbackRedirectServer.start()
        let browser = Task { try await get(server.port, "/callback?code=abc") }
        let query = try await server.waitForCallback(timeout: 10)
        XCTAssertEqual(query, ["code": "abc"])

        try await Task.sleep(nanoseconds: 200_000_000)
        let answered = LockedBox(false)
        let watcher = Task { _ = try? await browser.value; answered.set(true) }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(answered.get(), "responded before finish")

        server.finish(LoopbackRedirectServer.page(title: "Connected me@example.com", message: "Done"))
        let page = try await browser.value
        XCTAssertTrue(page.contains("Connected me@example.com"))
        _ = await watcher.value

        // Reloading the page afterwards gets nothing: the server is closed.
        do {
            _ = try await get(server.port, "/callback?code=abc")
            XCTFail("server still listening")
        } catch {}
    }

    /// A callback that lands before anyone waits (a fast browser) is kept.
    func testCallbackBeforeWait() async throws {
        let server = try LoopbackRedirectServer.start()
        let browser = Task { try await get(server.port, "/callback?error=access_denied") }
        try await Task.sleep(nanoseconds: 300_000_000)
        let query = try await server.waitForCallback(timeout: 10)
        XCTAssertEqual(query, ["error": "access_denied"])
        server.finish(LoopbackRedirectServer.page(title: "Couldn't connect", message: "x", isError: true))
        _ = try await browser.value
    }

    func testIgnoresOtherPaths() async throws {
        let server = try LoopbackRedirectServer.start()
        do {
            _ = try await get(server.port, "/favicon.ico")
            XCTFail("favicon got a response")
        } catch {}
        let browser = Task { try await get(server.port, "/callback?code=xyz") }
        let query = try await server.waitForCallback(timeout: 10)
        XCTAssertEqual(query["code"], "xyz")
        server.finish(LoopbackRedirectServer.page(title: "ok", message: "ok"))
        _ = try await browser.value
    }

    /// A reload while the sign-in finishes: the browser drops the first
    /// request, so the outcome goes to the latest one.
    func testReloadGetsTheOutcome() async throws {
        let server = try LoopbackRedirectServer.start()
        let first = Task { try await get(server.port, "/callback?code=abc") }
        _ = try await server.waitForCallback(timeout: 10)
        let reload = Task { try await get(server.port, "/callback?code=abc") }
        try await Task.sleep(nanoseconds: 300_000_000)
        server.finish(LoopbackRedirectServer.page(title: "Connected me@example.com", message: "Done"))
        let page = try await reload.value
        XCTAssertTrue(page.contains("Connected me@example.com"))
        do {
            _ = try await first.value
            XCTFail("abandoned request was answered")
        } catch {}
    }

    /// The user closed the tab, or Google showed its own error page.
    func testTimesOut() async throws {
        let server = try LoopbackRedirectServer.start()
        do {
            _ = try await server.waitForCallback(timeout: 0.2)
            XCTFail("no timeout")
        } catch GoogleOAuth.OAuthError.timedOut {
        } catch {
            XCTFail("\(error)")
        }
    }

    func testCancellation() async throws {
        let server = try LoopbackRedirectServer.start()
        let waiting = Task { try await server.waitForCallback(timeout: 60) }
        try await Task.sleep(nanoseconds: 100_000_000)
        waiting.cancel()
        do {
            _ = try await waiting.value
            XCTFail("not cancelled")
        } catch is CancellationError {
        } catch {
            XCTFail("\(error)")
        }
    }
}

final class GoogleAccountMatchingTests: XCTestCase {
    private let gmail = ConnectedAccount(id: "g", email: "Me@Example.com")
    private let imap = ConnectedAccount(id: "i", email: "other@example.com", provider: .imap)
    private var settings: Settings {
        var settings = Settings.defaults
        settings.accounts = [gmail, imap]
        return settings
    }

    func testSignInRenewsExistingAccountCaseInsensitively() throws {
        XCTAssertEqual(try settings.googleAccount(signedInAs: "me@example.com", reconnecting: nil), gmail)
        XCTAssertEqual(try settings.googleAccount(signedInAs: "me@example.com", reconnecting: gmail), gmail)
    }

    func testNewAddressIsANewAccount() throws {
        XCTAssertNil(try settings.googleAccount(signedInAs: "new@example.com", reconnecting: nil))
        // An IMAP account with the same address is a separate inbox.
        XCTAssertNil(try settings.googleAccount(signedInAs: "other@example.com", reconnecting: nil))
    }

    /// The case that motivated this: Reconnect on one account, then picking
    /// another in Google's chooser.
    func testReconnectAsAnotherAccountFails() {
        XCTAssertThrowsError(try settings.googleAccount(signedInAs: "new@example.com", reconnecting: gmail)) { error in
            guard case GoogleOAuth.OAuthError.wrongAccount("Me@Example.com", "new@example.com") = error else {
                return XCTFail("\(error)")
            }
        }
    }
}

/// In-memory `SecretStore`, JSON-encoded like the Keychain.
final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    var keys: Set<String> { lock.lock(); defer { lock.unlock() }; return Set(items.keys) }

    func set<T: Encodable>(_ value: T, forKey key: String) throws {
        let data = try JSONEncoder().encode(value)
        lock.lock(); items[key] = data; lock.unlock()
    }
    func get<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        lock.lock(); let data = items[key]; lock.unlock()
        return data.flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
    func remove(forKey key: String) {
        lock.lock(); items[key] = nil; lock.unlock()
    }
}

final class GoogleTokenStoreTests: XCTestCase {
    private let store = MemorySecretStore()
    private lazy var oauth = GoogleOAuth(keychain: store) { nil }

    private func tokens(_ access: String, refresh: String?) -> OAuthTokens {
        OAuthTokens(accessToken: access, refreshToken: refresh, expiresAt: 0)
    }

    func testMoveTokensReplacesDestinationAndRemovesSource() async throws {
        try store.set(tokens("old", refresh: "r-old"), forKey: "google-tokens:existing")
        try store.set(tokens("new", refresh: "r-new"), forKey: "google-tokens:signin")
        try await oauth.moveTokens(from: "signin", to: "existing")
        XCTAssertEqual(store.get(OAuthTokens.self, forKey: "google-tokens:existing")?.refreshToken, "r-new")
        XCTAssertEqual(store.keys, ["google-tokens:existing"])
    }

    func testMoveTokensWithoutSourceThrows() async {
        do {
            try await oauth.moveTokens(from: "missing", to: "existing")
            XCTFail("no error")
        } catch GoogleOAuth.OAuthError.notConnected {
        } catch {
            XCTFail("\(error)")
        }
    }

    func testRefreshIsStored() throws {
        try store.set(tokens("old", refresh: "r1"), forKey: "google-tokens:a")
        let refreshed = OAuthTokens(accessToken: "fresh", refreshToken: nil, expiresAt: 99)
        XCTAssertTrue(try oauth.commitRefresh(refreshed, accountId: "a", refreshedWith: "r1"))
        let stored = store.get(OAuthTokens.self, forKey: "google-tokens:a")
        XCTAssertEqual(stored?.accessToken, "fresh")
        XCTAssertEqual(stored?.expiresAt, 99)
        // Google usually leaves the refresh token out; the old one stays.
        XCTAssertEqual(stored?.refreshToken, "r1")
    }

    /// The race that motivated this: a refresh of the old sign-in finishing
    /// after a reconnect stored new tokens must not overwrite them.
    func testRefreshAfterReconnectIsDropped() async throws {
        try store.set(tokens("old", refresh: "r-old"), forKey: "google-tokens:a")
        try store.set(tokens("new", refresh: "r-new"), forKey: "google-tokens:signin")
        try await oauth.moveTokens(from: "signin", to: "a")
        let late = OAuthTokens(accessToken: "refreshed-old", refreshToken: nil, expiresAt: 99)
        XCTAssertFalse(try oauth.commitRefresh(late, accountId: "a", refreshedWith: "r-old"))
        XCTAssertEqual(store.get(OAuthTokens.self, forKey: "google-tokens:a")?.accessToken, "new")
        // Nor may it resurrect an account signed out meanwhile.
        oauth.signOut(accountId: "a")
        XCTAssertFalse(try oauth.commitRefresh(late, accountId: "a", refreshedWith: "r-new"))
        XCTAssertTrue(store.keys.isEmpty)
    }
}
