import XCTest
@testable import AuthReachCore

final class OtpDetectorTests: XCTestCase {

    // MARK: - detectCode

    func testCuedCodeForms() {
        XCTAssertEqual(OtpDetector.detectCode(in: "Your verification code is 123456"), "123456")
        XCTAssertEqual(OtpDetector.detectCode(in: "OTP: 481920"), "481920")
        XCTAssertEqual(OtpDetector.detectCode(in: "Your login passcode 12 34 56 expires soon"), "123456")
        XCTAssertEqual(OtpDetector.detectCode(in: "2FA PIN: 9876"), "9876")
        XCTAssertEqual(OtpDetector.detectCode(in: "Use security code 44-55-66 to sign in"), "445566")
    }

    func testGoogleStyle() {
        XCTAssertEqual(OtpDetector.detectCode(in: "Your Google verification code is G-732901"), "732901")
    }

    func testFallbackPrefersSixDigits() {
        XCTAssertEqual(
            OtpDetector.detectCode(in: "Sign-in attempt. 1234 was not it, use 987654 instead"),
            "987654")
    }

    func testKeywordGateRejectsOrdinaryMail() {
        XCTAssertNil(OtpDetector.detectCode(in: "Your order 483920 has shipped, arriving Tuesday"))
        XCTAssertNil(OtpDetector.detectCode(in: "Invoice 2024 total 123456 due"))
        XCTAssertNil(OtpDetector.detectCode(in: ""))
    }

    func testYearsAreNotCodes() {
        XCTAssertNil(OtpDetector.detectCode(in: "Verify your account before 2026"))
    }

    func testKeywordPresentButNoPlausibleCode() {
        XCTAssertNil(OtpDetector.detectCode(in: "Please verify your email address by clicking the link"))
    }

    // MARK: - detectExpirySeconds

    func testExpiryDurations() {
        XCTAssertEqual(OtpDetector.detectExpirySeconds(in: "Code 123456 expires in 10 minutes"), 600)
        XCTAssertEqual(OtpDetector.detectExpirySeconds(in: "valid for 5 min"), 300)
        XCTAssertEqual(OtpDetector.detectExpirySeconds(in: "will expire within the next 30 seconds"), 30)
        XCTAssertEqual(OtpDetector.detectExpirySeconds(in: "expires in 1 hour"), 3600)
    }

    func testExpiryClampsAndAbsolutesIgnored() {
        XCTAssertNil(OtpDetector.detectExpirySeconds(in: "expires in 5 seconds"))     // < 10s
        XCTAssertNil(OtpDetector.detectExpirySeconds(in: "valid for 48 hours"))       // > 24h
        XCTAssertNil(OtpDetector.detectExpirySeconds(in: "expires at 3:45 PM"))
        XCTAssertNil(OtpDetector.detectExpirySeconds(in: "no expiry here"))
    }

    // MARK: - sender helpers

    func testServiceFromSender() {
        XCTAssertEqual(OtpDetector.serviceFromSender("\"GitHub\" <noreply@github.com>"), "GitHub")
        XCTAssertEqual(OtpDetector.serviceFromSender("Stripe Support <support@stripe.com>"), "Stripe Support")
        XCTAssertEqual(OtpDetector.serviceFromSender("noreply@auth.linear.app"), "Linear")
        XCTAssertEqual(OtpDetector.serviceFromSender("weird-no-at-sign"), "weird-no-at-sign")
        XCTAssertEqual(OtpDetector.serviceFromSender(""), "Unknown")
    }

    func testAddressFromSender() {
        XCTAssertEqual(OtpDetector.addressFromSender("\"GitHub\" <noreply@github.com>"), "noreply@github.com")
        XCTAssertEqual(OtpDetector.addressFromSender("plain@example.com"), "plain@example.com")
    }
}
