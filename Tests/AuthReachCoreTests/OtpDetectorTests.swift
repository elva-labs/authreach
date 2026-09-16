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

    func testSwedishCuedCodeForms() {
        // Real TSV login mail (subject + " " + plain-text body, as joined by
        // OtpCenter) that the English-only keyword gate used to reject.
        let tsv = "Din inloggningskod: 734585 — TSV"
            + " Din inloggningskod för TSV: 734585"
            + " Koden fungerar bara en gång. Om du inte begärde den kan du ignorera detta mejl."
        XCTAssertEqual(OtpDetector.detectCode(in: tsv), "734585")
        XCTAssertEqual(OtpDetector.detectCode(in: "Din engångskod är 481920"), "481920")
        XCTAssertEqual(OtpDetector.detectCode(in: "Ange koden 12 34 56 för att logga in"), "123456")
        XCTAssertEqual(OtpDetector.detectCode(in: "Verifieringskod: 9876"), "9876")
        XCTAssertEqual(OtpDetector.detectCode(in: "Verifikationskod: 123456"), "123456")
        XCTAssertEqual(OtpDetector.detectCode(in: "Din PIN-kod är 4821"), "4821")
        XCTAssertEqual(OtpDetector.detectCode(in: "SMS-kod: 123456"), "123456")
        XCTAssertEqual(OtpDetector.detectCode(in: "Tvåfaktorsautentisering: din kod är 481920"), "481920")
    }

    func testSwedishDefiniteFormsPassTheGate() {
        XCTAssertEqual(OtpDetector.detectCode(in: "Engångskoden: 481920"), "481920")
        XCTAssertEqual(OtpDetector.detectCode(in: "Säkerhetskoden 481920 gäller i 5 minuter"), "481920")
        XCTAssertEqual(OtpDetector.detectCode(in: "Verifieringskoden är 481920"), "481920")
        XCTAssertEqual(OtpDetector.detectCode(in: "Inloggningskoden är 481920"), "481920")
        XCTAssertEqual(OtpDetector.detectCode(in: "Aktiveringskoden: 481920"), "481920")
    }

    func testSwedishCuePrefersCodeNounOverBareAr() {
        // "är" is only a connector after a code noun, never a cue by itself,
        // so an earlier "X är <number>" must not beat the real code.
        XCTAssertEqual(
            OtpDetector.detectCode(in: "Ditt kundnummer är 123456. Din engångskod: 987654"), "987654")
        XCTAssertEqual(
            OtpDetector.detectCode(in: "Bekräftelse: ditt ordernummer är 48392012. Din kod: 734585"), "734585")
        XCTAssertEqual(
            OtpDetector.detectCode(in: "Logga in med koden nedan. Leveransadress: Storgatan 1, postkod 11122. Koden: 481920"),
            "481920")
    }

    func testSwedishOrdinaryMailWithoutGateWordsIsRejected() {
        XCTAssertNil(OtpDetector.detectCode(in: "Din order 483920 har skickats och kommer på tisdag"))
        XCTAssertNil(OtpDetector.detectCode(in: "Faktura 2024, totalt 123456 kr"))
        XCTAssertNil(OtpDetector.detectCode(in: "Använd rabattkoden 483920 vid kassan"))
    }

    func testSwedishDiscountCodeMailIsRejected() {
        // Bare "koden" is not a gate word, so campaign mail with an alpha
        // discount code and a stray order number is not an OTP.
        XCTAssertNil(OtpDetector.detectCode(in: "Använd koden SOMMAR20 i kassan. Ordernummer 483920"))
        XCTAssertNil(OtpDetector.detectCode(in: "Här är koden till dörren: 4821"))
    }

    func testGateParityKnownLeak() {
        // Documented limitation, identical to the English "log in" /
        // "confirmation" gate words: a login CTA plus a stray 6-digit number
        // is reported as a code. Tightening this is an English-side design
        // change, not a Swedish one.
        XCTAssertEqual(
            OtpDetector.detectCode(in: "Din order 483920 har skickats. Logga in för att spåra paketet."), "483920")
        XCTAssertEqual(
            OtpDetector.detectCode(in: "Your order 483920 has shipped. Log in to track the parcel."), "483920")
    }

    func testDecomposedUnicodeIsHandledByCaller() {
        // OtpCenter normalises to NFC before detection; the raw detector does
        // not, so this pins the contract at the boundary.
        let nfd = "Din enga\u{30A}ngskod a\u{308}r 481920. Koden ga\u{308}ller i 10 minuter"
        XCTAssertNil(OtpDetector.detectCode(in: nfd))
        let nfc = nfd.precomposedStringWithCanonicalMapping
        XCTAssertEqual(OtpDetector.detectCode(in: nfc), "481920")
        XCTAssertEqual(OtpDetector.detectExpirySeconds(in: nfc), 600)
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

    func testSwedishExpiryDurations() {
        XCTAssertEqual(OtpDetector.detectExpirySeconds(in: "Koden är giltig i 10 minuter"), 600)
        XCTAssertEqual(OtpDetector.detectExpirySeconds(in: "gäller i 30 sekunder"), 30)
        XCTAssertEqual(OtpDetector.detectExpirySeconds(in: "Koden går ut om 1 timme"), 3600)
        // Definite plurals and abbreviations.
        XCTAssertEqual(OtpDetector.detectExpirySeconds(in: "Koden är giltig under de kommande 10 minuterna"), 600)
        XCTAssertEqual(OtpDetector.detectExpirySeconds(in: "gäller de närmaste 30 sekunderna"), 30)
        XCTAssertEqual(OtpDetector.detectExpirySeconds(in: "Koden gäller i 30 sek"), 30)
        XCTAssertEqual(OtpDetector.detectExpirySeconds(in: "giltig i 1 timma"), 3600)
        XCTAssertEqual(OtpDetector.detectExpirySeconds(in: "giltig i 2 tim"), 7200)
        XCTAssertEqual(OtpDetector.detectExpirySeconds(in: "upphör om 2 timmarna"), 7200)
    }

    func testEveryExpiryUnitSpellingResolves() {
        // The unit alternation is derived from the lookup table, so every
        // spelling the regex can capture must resolve; this guards the
        // longest-first ordering (e.g. "minuter" must not be eaten by "min").
        let cases: [(String, Int)] = [
            ("10 minutes", 600), ("10 minute", 600), ("10 mins", 600), ("10 min", 600),
            ("30 seconds", 30), ("30 secs", 30), ("1 hour", 3600), ("2 hrs", 7200),
            ("10 minuter", 600), ("1 minut", 60), ("30 sekunder", 30), ("30 sekund", 30),
            ("1 timme", 3600), ("2 timmar", 7200),
        ]
        for (phrase, expected) in cases {
            XCTAssertEqual(OtpDetector.detectExpirySeconds(in: "expires in \(phrase)"), expected, phrase)
        }
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
