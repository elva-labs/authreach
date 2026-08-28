import Foundation

/// Heuristic one-time-password detector, ported behavior-for-behavior from
/// the original TypeScript implementation. Given the combined text of an
/// email (subject + snippet + body), decide whether it contains an OTP and
/// extract the code. A keyword gate keeps ordinary mail with stray numbers
/// from being misreported.
public enum OtpDetector {

    private static let keywords = try! NSRegularExpression(
        pattern: #"\b(one[\s-]?time|verification|verify|verify code|security code|login|log[\s-]?in|sign[\s-]?in|auth(?:entication)?|otp|passcode|pass[\s-]?code|access code|confirm(?:ation)?|2fa|two[\s-]?factor|your code)\b"#,
        options: [.caseInsensitive])

    /// A code preceded by a strong cue word, e.g. "code is 123456",
    /// "OTP: 481920", "passcode 12 34 56". 4-8 digits, optionally split.
    private static let cuedCode = try! NSRegularExpression(
        pattern: #"(?:code|otp|passcode|pass[\s-]?code|pin|password|is|:)\s*(?:is\s*)?[:#-]?\s*(\d[\d\s-]{2,10}\d)"#,
        options: [.caseInsensitive])

    private static let googleStyle = try! NSRegularExpression(pattern: #"\bG-(\d{4,8})\b"#)

    private static let standaloneDigits = try! NSRegularExpression(pattern: #"\b(\d{4,8})\b"#)

    /// A duration near "expire"/"valid", e.g. "expires in 10 minutes".
    private static let expiryDuration = try! NSRegularExpression(
        pattern: #"\b(?:expir\w*|valid)\b[\s\S]{0,25}?\b(\d{1,3})\s*(second|sec|minute|min|hour|hr)s?\b"#,
        options: [.caseInsensitive])

    private static let unitSeconds: [String: Int] = [
        "second": 1, "sec": 1, "minute": 60, "min": 60, "hour": 3600, "hr": 3600,
    ]

    private static func isLikelyYear(_ digits: String) -> Bool {
        guard digits.count == 4, let n = Int(digits) else { return false }
        return (1900...2099).contains(n)
    }

    /// Six-digit codes are by far the most common, then 4/5/7/8.
    private static func score(_ digits: String) -> Int {
        switch digits.count {
        case 6: return 100
        case 8: return 80
        case 7: return 70
        case 5: return 60
        case 4: return 50
        default: return 0
        }
    }

    private static func firstMatch(_ regex: NSRegularExpression, in text: String) -> [String]? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return (0..<match.numberOfRanges).map {
            guard let r = Range(match.range(at: $0), in: text) else { return "" }
            return String(text[r])
        }
    }

    /// The extracted code, or nil when the text is not an OTP message.
    public static func detectCode(in text: String) -> String? {
        guard !text.isEmpty, firstMatch(keywords, in: text) != nil else { return nil }

        if let cued = firstMatch(cuedCode, in: text) {
            let digits = cued[1].filter(\.isNumber)
            if (4...8).contains(digits.count) { return digits }
        }

        if let google = firstMatch(googleStyle, in: text) { return google[1] }

        // Fallback: the most code-like standalone digit group.
        let range = NSRange(text.startIndex..., in: text)
        let groups = standaloneDigits.matches(in: text, range: range).compactMap { m -> String? in
            guard let r = Range(m.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
        let candidates = groups.filter { !isLikelyYear($0) }
        if let best = candidates.max(by: { score($0) < score($1) }), score(best) > 0 {
            // Stable preference for the earliest of the best-scoring length,
            // matching the JS sort's behavior.
            return candidates.first { score($0) == score(best) }
        }
        return nil
    }

    /// Seconds until the code expires when the email states a duration
    /// ("expires in 10 minutes"); nil otherwise. Absolute times are not
    /// parsed. Clamped to 10s-24h to reject stray matches.
    public static func detectExpirySeconds(in text: String) -> Int? {
        guard !text.isEmpty, let m = firstMatch(expiryDuration, in: text),
              let amount = Int(m[1]), amount > 0,
              let unit = unitSeconds[m[2].lowercased()] else { return nil }
        let seconds = amount * unit
        guard (10...(24 * 3600)).contains(seconds) else { return nil }
        return seconds
    }

    /// Friendly service name from a raw From header:
    /// `"Display Name" <a@b.com>` -> "Display Name", else capitalised
    /// second-level domain label, else the raw value.
    public static func serviceFromSender(_ from: String) -> String {
        guard !from.isEmpty else { return "Unknown" }
        if let m = firstMatch(try! NSRegularExpression(pattern: #"^\s*"?([^"<]+?)"?\s*<"#), in: from),
           !m[1].trimmingCharacters(in: .whitespaces).isEmpty {
            return m[1].trimmingCharacters(in: .whitespaces)
        }
        if let m = firstMatch(try! NSRegularExpression(pattern: #"@([\w.-]+)"#), in: from) {
            let parts = m[1].split(separator: ".").filter { !$0.isEmpty }
            let label = parts.count >= 2 ? String(parts[parts.count - 2]) : String(parts.first ?? "")
            return label.prefix(1).uppercased() + label.dropFirst()
        }
        return from.trimmingCharacters(in: .whitespaces)
    }

    /// Just the email address from a raw From header.
    public static func addressFromSender(_ from: String) -> String {
        if let m = firstMatch(try! NSRegularExpression(pattern: #"<([^>]+)>"#), in: from) {
            return m[1].trimmingCharacters(in: .whitespaces)
        }
        return from.trimmingCharacters(in: .whitespaces)
    }
}
