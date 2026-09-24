import Foundation
import XCTest
@testable import AuthReachCore

final class MimeParserTests: XCTestCase {
    func testMultipartAlternativePrefersPlainAndDecodesQuotedPrintable() {
        let raw = """
        From: =?UTF-8?Q?Bank_ID?= <noreply@bankid.com>\r
        Subject: =?UTF-8?B?\(Data("Din säkerhetskod".utf8).base64EncodedString())?=\r
        Date: Sun, 20 Sep 2026 10:11:12 +0200 (CEST)\r
        MIME-Version: 1.0\r
        Content-Type: multipart/alternative; boundary="b1"\r
        \r
        preamble to ignore\r
        --b1\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Transfer-Encoding: quoted-printable\r
        \r
        Din s=C3=A4kerhetskod =C3=A4r 481920. Koden g=C3=A4ller i 10 =\r
        minuter.\r
        --b1\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <p>Din s&auml;kerhetskod &auml;r <b>481920</b></p>\r
        --b1--\r
        epilogue\r

        """
        let mail = MimeParser.parse(Data(raw.utf8))
        XCTAssertEqual(mail.subject, "Din säkerhetskod")
        XCTAssertEqual(mail.from, "Bank ID <noreply@bankid.com>")
        XCTAssertEqual(mail.plain, ["Din säkerhetskod är 481920. Koden gäller i 10 minuter."])
        XCTAssertEqual(mail.html, ["Din säkerhetskod är 481920"])
        XCTAssertEqual(mail.text, "Din säkerhetskod är 481920. Koden gäller i 10 minuter.")
        XCTAssertEqual(mail.date, ISO8601DateFormatter().date(from: "2026-09-20T08:11:12Z"))
        XCTAssertEqual(OtpDetector.detectCode(in: mail.text), "481920")
    }

    func testHtmlOnlyBase64Latin1Body() {
        let html = "<p>Din engångskod är <b>224466</b></p>"
        let latin1 = html.data(using: .isoLatin1)!.base64EncodedString(options: [.lineLength64Characters])
        let raw = "Subject: Kod\r\nContent-Type: text/html; charset=\"iso-8859-1\"\r\nContent-Transfer-Encoding: base64\r\n\r\n\(latin1)\r\n"
        let mail = MimeParser.parse(Data(raw.utf8))
        XCTAssertEqual(mail.text, "Din engångskod är 224466")
    }

    func testNestedMultipartSkipsAttachmentsAndUnfoldsHeaders() {
        let raw = """
        Subject: Your\r
         verification code\r
        Content-Type: multipart/mixed; boundary=outer\r
        \r
        --outer\r
        Content-Type: multipart/alternative; boundary=inner\r
        \r
        --inner\r
        Content-Type: text/plain\r
        \r
        Code: 135790\r
        --inner--\r
        --outer\r
        Content-Type: text/plain; name="notes.txt"\r
        Content-Disposition: attachment; filename="notes.txt"\r
        \r
        attachment 999999\r
        --outer--\r

        """
        let mail = MimeParser.parse(Data(raw.utf8))
        XCTAssertEqual(mail.subject, "Your verification code")
        XCTAssertEqual(mail.plain, ["Code: 135790"])
    }

    func testMissingContentTypeIsPlainText() {
        let mail = MimeParser.parse(Data("Subject: Hi\r\n\r\nYour code is 246810\r\n".utf8))
        XCTAssertEqual(mail.text, "Your code is 246810")
    }

    func testEncodedWordsJoinAdjacentAndHandleLatin1() {
        XCTAssertEqual(MimeParser.decodeEncodedWords("=?UTF-8?Q?Din_s=C3=A4kerhetskod?= =?UTF-8?Q?_fr=C3=A5n_Acme?="),
                       "Din säkerhetskod från Acme")
        XCTAssertEqual(MimeParser.decodeEncodedWords("Re: =?ISO-8859-1?Q?G=E4ller?= nu"), "Re: Gäller nu")
        XCTAssertEqual(MimeParser.decodeEncodedWords("=?utf-8*sv?B?w6U=?="), "å")
        XCTAssertEqual(MimeParser.decodeEncodedWords("plain subject"), "plain subject")
    }

    func testQuotedPrintableSoftBreaksAndLiteralEquals() {
        let decoded = MimeParser.decodeQuotedPrintable(Data("a=3Db =\r\nc=\nd =zz e_f".utf8), header: false)
        XCTAssertEqual(String(decoding: decoded, as: UTF8.self), "a=b cd =zz e_f")
        let header = MimeParser.decodeQuotedPrintable(Data("a_b".utf8), header: true)
        XCTAssertEqual(String(decoding: header, as: UTF8.self), "a b")
    }

    func testBase64ToleratesLineBreaksAndMissingPadding() {
        XCTAssertEqual(String(decoding: MimeParser.decodeBase64(Data("aGVs\r\nbG8".utf8)), as: UTF8.self), "hello")
    }

    func testDateHeaderVariants() {
        let expected = ISO8601DateFormatter().date(from: "2026-09-05T06:00:00Z")
        XCTAssertEqual(MimeParser.parseDate("Sat, 5 Sep 2026 08:00:00 +0200"), expected)
        XCTAssertEqual(MimeParser.parseDate("5 Sep 2026 06:00:00 GMT"), expected)
        XCTAssertNil(MimeParser.parseDate(""))
    }

    func testContentTypeParams() {
        let ct = MimeParser.parseContentType("Text/HTML; charset=\"UTF-8\"; boundary=abc")
        XCTAssertEqual(ct.type, "text/html")
        XCTAssertEqual(ct.params["charset"], "UTF-8")
        XCTAssertEqual(ct.params["boundary"], "abc")
        XCTAssertEqual(MimeParser.parseContentType("").type, "text/plain")
    }
}
