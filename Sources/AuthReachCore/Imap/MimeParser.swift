import Foundation

/// A raw RFC 822 message reduced to what OTP detection needs: decoded
/// Subject/From/Date and the text of every text/plain and text/html leaf.
public struct ParsedMail: Sendable {
    public var subject = ""
    public var from = ""
    public var date: Date?
    public var plain: [String] = []
    public var html: [String] = []

    /// Same policy as the Gmail client: prefer text/plain, fall back to
    /// stripped HTML.
    public var text: String {
        plain.isEmpty ? html.joined(separator: " ") : plain.joined(separator: " ")
    }
}

/// Minimal RFC 5322 / MIME parser for IMAP-fetched mail. Bytes travel as a
/// Latin-1 string (a lossless byte-to-character mapping) so headers and
/// multipart boundaries can be handled as text; each text leaf is converted
/// back to bytes and decoded with its declared transfer encoding and charset.
public enum MimeParser {
    static let maxDepth = 20

    public static func parse(_ raw: Data) -> ParsedMail {
        let text = String(data: raw, encoding: .isoLatin1) ?? String(decoding: raw, as: UTF8.self)
        var mail = ParsedMail()
        let (headers, body) = splitHeaders(text)
        mail.subject = decodeEncodedWords(header(headers, "Subject"))
        mail.from = decodeEncodedWords(header(headers, "From"))
        mail.date = parseDate(header(headers, "Date"))
        collectText(headers: headers, body: body, into: &mail, depth: 0)
        return mail
    }

    // MARK: - Structure

    typealias Header = (name: String, value: String)

    /// Splits a message or part at the first blank line and unfolds the
    /// header section. A part with no blank line is treated as headers only.
    static func splitHeaders(_ text: String) -> (headers: [Header], body: String) {
        let separator = text.range(of: "\r\n\r\n") ?? text.range(of: "\n\n")
        let head = separator.map { String(text[..<$0.lowerBound]) } ?? text
        let body = separator.map { String(text[$0.upperBound...]) } ?? ""

        var headers: [Header] = []
        for rawLine in head.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if let first = line.first, first == " " || first == "\t", !headers.isEmpty {
                headers[headers.count - 1].value += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                headers.append((name: line[..<colon].trimmingCharacters(in: .whitespaces),
                                value: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
            }
        }
        return (headers, body)
    }

    static func header(_ headers: [Header], _ name: String) -> String {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
    }

    private static func collectText(headers: [Header], body: String, into mail: inout ParsedMail, depth: Int) {
        guard depth < maxDepth else { return }
        let contentType = parseContentType(header(headers, "Content-Type"))
        let disposition = header(headers, "Content-Disposition").lowercased()

        if contentType.type.hasPrefix("multipart/"), let boundary = contentType.params["boundary"] {
            for part in splitMultipart(body, boundary: boundary) {
                let (partHeaders, partBody) = splitHeaders(part)
                collectText(headers: partHeaders, body: partBody, into: &mail, depth: depth + 1)
            }
        } else if contentType.type == "message/rfc822" {
            let (innerHeaders, innerBody) = splitHeaders(body)
            collectText(headers: innerHeaders, body: innerBody, into: &mail, depth: depth + 1)
        } else if contentType.type == "text/plain" || contentType.type == "text/html" {
            guard !disposition.hasPrefix("attachment") else { return }
            let bytes = decodeTransferEncoding(body, encoding: header(headers, "Content-Transfer-Encoding"))
            let decoded = decodeString(bytes, charset: contentType.params["charset"])
            if contentType.type == "text/plain" {
                mail.plain.append(decoded.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                mail.html.append(stripHtml(decoded))
            }
        }
    }

    private static let paramPattern = try! NSRegularExpression(
        pattern: #"([A-Za-z0-9\-_*]+)\s*=\s*(?:"([^"]*)"|([^;\s]+))"#)

    /// `text/html; charset="utf-8"` → ("text/html", ["charset": "utf-8"]).
    /// A missing Content-Type means text/plain (RFC 2045 §5.2).
    static func parseContentType(_ value: String) -> (type: String, params: [String: String]) {
        guard let semicolon = value.firstIndex(of: ";") else {
            let type = value.trimmingCharacters(in: .whitespaces).lowercased()
            return (type.isEmpty ? "text/plain" : type, [:])
        }
        let type = value[..<semicolon].trimmingCharacters(in: .whitespaces).lowercased()
        let rest = String(value[value.index(after: semicolon)...])
        let ns = rest as NSString
        var params: [String: String] = [:]
        for m in paramPattern.matches(in: rest, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1)).lowercased()
            let quoted = m.range(at: 2).location != NSNotFound ? m.range(at: 2) : m.range(at: 3)
            params[name] = ns.substring(with: quoted)
        }
        return (type.isEmpty ? "text/plain" : type, params)
    }

    /// The bodies between `--boundary` delimiter lines; preamble and
    /// epilogue are dropped and `--boundary--` ends the walk.
    static func splitMultipart(_ body: String, boundary: String) -> [String] {
        let delimiter = "--" + boundary
        var parts: [String] = []
        var current: [String]?
        for rawLine in body.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if line.hasPrefix(delimiter) {
                let rest = line.dropFirst(delimiter.count).trimmingCharacters(in: .whitespaces)
                if rest.isEmpty || rest == "--" {
                    if let done = current { parts.append(done.joined(separator: "\r\n")) }
                    if rest == "--" { return parts }
                    current = []
                    continue
                }
            }
            current?.append(line)
        }
        if let done = current { parts.append(done.joined(separator: "\r\n")) }
        return parts
    }

    // MARK: - Decoding

    static func decodeTransferEncoding(_ body: String, encoding: String) -> Data {
        let bytes = body.data(using: .isoLatin1) ?? Data(body.utf8)
        switch encoding.trimmingCharacters(in: .whitespaces).lowercased() {
        case "base64": return decodeBase64(bytes)
        case "quoted-printable": return decodeQuotedPrintable(bytes, header: false)
        default: return bytes
        }
    }

    /// Lenient base64: ignores whitespace and line breaks, tolerates
    /// missing padding.
    static func decodeBase64(_ data: Data) -> Data {
        var clean = data.filter { byte in
            (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte)
                || byte == 0x2B || byte == 0x2F || byte == 0x3D
        }
        while let last = clean.last, last == 0x3D { clean.removeLast() }
        while clean.count % 4 != 0 { clean.append(0x3D) }
        return Data(base64Encoded: clean) ?? Data()
    }

    /// RFC 2045 quoted-printable; in `header` mode (RFC 2047 "Q") an
    /// underscore is a space.
    static func decodeQuotedPrintable(_ data: Data, header: Bool) -> Data {
        var out = Data(capacity: data.count)
        let bytes = [UInt8](data)
        var i = 0
        func hex(_ b: UInt8) -> UInt8? {
            switch b {
            case 0x30...0x39: return b - 0x30
            case 0x41...0x46: return b - 0x41 + 10
            case 0x61...0x66: return b - 0x61 + 10
            default: return nil
            }
        }
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x3D { // "="
                if i + 2 < bytes.count, let hi = hex(bytes[i + 1]), let lo = hex(bytes[i + 2]) {
                    out.append(hi << 4 | lo)
                    i += 3
                    continue
                }
                // Soft line break: "=" followed by CRLF or LF (optionally trailing spaces).
                var j = i + 1
                while j < bytes.count, bytes[j] == 0x20 || bytes[j] == 0x09 { j += 1 }
                if j < bytes.count, bytes[j] == 0x0D { j += 1 }
                if j < bytes.count, bytes[j] == 0x0A {
                    i = j + 1
                    continue
                }
                if j >= bytes.count { break } // "=" at end of data
                out.append(b)
                i += 1
            } else if header && b == 0x5F {
                out.append(0x20)
                i += 1
            } else {
                out.append(b)
                i += 1
            }
        }
        return out
    }

    /// Text for a declared charset, falling back to UTF-8 then Latin-1 so
    /// something always comes back.
    static func decodeString(_ data: Data, charset: String?) -> String {
        if let charset, let encoding = stringEncoding(for: charset),
           let s = String(data: data, encoding: encoding) {
            return s
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    static func stringEncoding(for charset: String) -> String.Encoding? {
        let name = charset.trimmingCharacters(in: .whitespaces)
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    private static let encodedWordPattern = try! NSRegularExpression(
        pattern: #"=\?([^?\s]+)\?([bBqQ])\?([^?\s]*)\?="#)

    /// RFC 2047 encoded words (`=?utf-8?B?...?=` / `=?iso-8859-1?Q?...?=`).
    /// Whitespace between two adjacent encoded words is dropped, per §6.2.
    public static func decodeEncodedWords(_ input: String) -> String {
        let joined = input.replacingOccurrences(of: #"\?=\s+=\?"#, with: "?==?", options: .regularExpression)
        let ns = joined as NSString
        var out = ""
        var cursor = 0
        for m in encodedWordPattern.matches(in: joined, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            var charset = ns.substring(with: m.range(at: 1))
            if let star = charset.firstIndex(of: "*") { charset = String(charset[..<star]) } // RFC 2231 language tag
            let encoding = ns.substring(with: m.range(at: 2)).uppercased()
            let payload = Data(ns.substring(with: m.range(at: 3)).utf8)
            let bytes = encoding == "B" ? decodeBase64(payload) : decodeQuotedPrintable(payload, header: true)
            out += decodeString(bytes, charset: charset)
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// RFC 5322 Date header, with or without weekday, trailing "(CEST)"
    /// comments removed.
    static func parseDate(_ value: String) -> Date? {
        var text = value.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z",
                       "EEE, d MMM yyyy HH:mm:ss zzz", "d MMM yyyy HH:mm:ss zzz",
                       "EEE, d MMM yyyy HH:mm Z", "d MMM yyyy HH:mm Z"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
