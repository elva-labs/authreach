import Foundation
import XCTest
@testable import AuthReachCore

final class LocalApiServerTests: XCTestCase {
    let token = "secret-token"
    var entries: [OtpEntry] = []
    var expose = true
    var server: LocalApiServer!

    override func setUp() {
        entries = [
            OtpEntry(id: "a:1", code: "111111", service: "GitHub", sender: "no@github.com",
                     subject: "code", receivedAt: Date().timeIntervalSince1970 * 1000 - 5_000,
                     expiresAt: nil, accountEmail: "me@x.com"),
            OtpEntry(id: "a:2", code: "222222", service: "Stripe", sender: "no@stripe.com",
                     subject: "code", receivedAt: Date().timeIntervalSince1970 * 1000 - 400_000,
                     expiresAt: nil, accountEmail: "me@x.com"),
        ]
        server = LocalApiServer(config: .init(
            getRecent: { [weak self] in self?.entries ?? [] },
            getToken: { [weak self] in self?.token ?? "" },
            exposeMetadata: { [weak self] in self?.expose ?? true }))
    }

    func request(_ target: String, headers: [String] = []) async -> String {
        let head = (["GET \(target) HTTP/1.1", "Host: 127.0.0.1"] + headers).joined(separator: "\r\n")
        return await server.handle(rawRequest: head + "\r\n\r\n")
    }

    func testRootNeedsNoAuth() async {
        let response = await request("/")
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200"))
        XCTAssertTrue(response.contains("AuthReach local API"))
    }

    func testMissingOrWrongTokenRejected() async {
        var response = await request("/v1/otps/latest")
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 401"))
        response = await request("/v1/otps/latest", headers: ["Authorization: Bearer nope"])
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 401"))
    }

    func testOriginHeaderRejectedEvenWithValidToken() async {
        let response = await request("/v1/otps/latest",
                                     headers: ["Authorization: Bearer \(token)", "Origin: http://evil.test"])
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 403"))
    }

    func testLatestJsonAndMetadataToggle() async {
        var response = await request("/v1/otps/latest", headers: ["Authorization: Bearer \(token)"])
        XCTAssertTrue(response.contains("\"code\":\"111111\""))
        XCTAssertTrue(response.contains("\"sender\""))
        expose = false
        response = await request("/v1/otps/latest", headers: ["Authorization: Bearer \(token)"])
        XCTAssertTrue(response.contains("\"code\":\"111111\""))
        XCTAssertFalse(response.contains("\"sender\""))
    }

    func testPlainTextVariants() async {
        for target in ["/v1/otps/latest/code", "/v1/otps/latest?raw=1", "/v1/otps/latest?format=text"] {
            let response = await request(target, headers: ["Authorization: Bearer \(token)"])
            XCTAssertTrue(response.hasSuffix("\r\n\r\n111111"), target)
        }
        let response = await request("/v1/otps/latest",
                                     headers: ["Authorization: Bearer \(token)", "Accept: text/plain"])
        XCTAssertTrue(response.hasSuffix("\r\n\r\n111111"))
    }

    func testFilters() async {
        var response = await request("/v1/otps/latest?service=stripe",
                                     headers: ["Authorization: Bearer \(token)"])
        XCTAssertTrue(response.contains("\"code\":\"222222\""), "service filter is case-insensitive")
        response = await request("/v1/otps/latest?service=git-hub",
                                 headers: ["Authorization: Bearer \(token)"])
        XCTAssertTrue(response.contains("\"code\":\"111111\""), "punctuation-insensitive")
        response = await request("/v1/otps/latest?maxAgeSeconds=60",
                                 headers: ["Authorization: Bearer \(token)"])
        XCTAssertTrue(response.contains("\"code\":\"111111\""))
        response = await request("/v1/otps/latest?service=stripe&maxAgeSeconds=60",
                                 headers: ["Authorization: Bearer \(token)"])
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 404"), "stripe entry is too old")
    }

    func testNonGetRejected() async {
        let response = await server.handle(rawRequest: "POST /v1/otps/latest HTTP/1.1\r\n\r\n")
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 405"))
    }

    func testTimingSafeEqual() {
        XCTAssertTrue(LocalApiServer.timingSafeEqual("abc", "abc"))
        XCTAssertFalse(LocalApiServer.timingSafeEqual("abc", "abd"))
        XCTAssertFalse(LocalApiServer.timingSafeEqual("abc", "abcd"))
    }

    func testRealSocketRoundTrip() async throws {
        try server.start(port: 39321)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 200_000_000)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:39321/v1/otps/latest/code")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "111111")
    }
}
