import Foundation

/// Heuristic one-time-password detector, originally ported
/// behavior-for-behavior from the TypeScript implementation and since
/// extended with Swedish keywords, cues and expiry forms. Given the combined
/// text of an email (subject + snippet + body), decide whether it contains an
/// OTP and extract the code. A keyword gate keeps ordinary mail with stray
/// numbers from being misreported.
public enum OtpDetector {

    /// Swedish "…kod" compounds, in both indefinite ("engångskod") and
    /// definite ("engångskoden") form. Shared by the gate and the cue regex.
    /// Bare "kod"/"koden" is deliberately not a gate word: it is as common in
    /// discount-code marketing mail as English "code" is.
    private static let swedishCodeNoun =
        #"(?:engångs|säkerhets|verifierings?|verifikations|aktiverings|inloggnings|bekräftelse|pin[\s-]?|sms[\s-]?)kod(?:en)?"#

    private static let keywords = try! NSRegularExpression(
        pattern: #"\b(one[\s-]?time|verification|verify|security code|log[\s-]?in|sign[\s-]?in|auth(?:entication)?|otp|pass[\s-]?code|access code|confirm(?:ation)?|2fa|two[\s-]?factor|your code|"# + swedishCodeNoun + #"|inloggning|logga[\s-]?in|engångslösenord|bekräftelse|tvåfaktor\w*|din kod)\b"#,
        options: [.caseInsensitive])

    /// A code preceded by a strong cue word, e.g. "code is 123456",
    /// "OTP: 481920", "passcode 12 34 56", "koden är 481920". 4-8 digits,
    /// optionally split. Cue words are anchored at a word start so
    /// "postkod 11122" / "här 123456" don't cue, and "is"/"är" only act as
    /// the connector after a noun, never as a cue on their own.
    private static let cuedCode = try! NSRegularExpression(
        pattern: #"(?:\b(?:code|otp|passcode|pass[\s-]?code|pin|password|"# + swedishCodeNoun + #"|kod(?:en)?|lösenord)|:)\s*(?:(?:is|är)\s*)?[:#-]?\s*(\d[\d\s-]{2,10}\d)"#,
        options: [.caseInsensitive])

    private static let googleStyle = try! NSRegularExpression(pattern: #"\bG-(\d{4,8})\b"#)

    private static let standaloneDigits = try! NSRegularExpression(pattern: #"\b(\d{4,8})\b"#)

    /// Every unit spelling the expiry regex can capture, in seconds. This is
    /// the single source for the unit alternation below, so a unit can't be
    /// matched by the regex yet missing from the lookup (or vice versa).
    private static let unitSeconds: [String: Int] = [
        "second": 1, "sec": 1, "minute": 60, "min": 60, "hour": 3600, "hr": 3600,
        "sekund": 1, "sekunder": 1, "sekunderna": 1, "sek": 1,
        "minut": 60, "minuter": 60, "minuterna": 60,
        "timme": 3600, "timma": 3600, "timmar": 3600, "timmarna": 3600, "tim": 3600,
    ]

    /// A duration near "expire"/"valid", e.g. "expires in 10 minutes",
    /// "giltig i 10 minuter". Longest unit first so "minuter" wins over "min".
    private static let expiryDuration: NSRegularExpression = {
        let units = unitSeconds.keys.sorted { ($0.count, $0) > ($1.count, $1) }.joined(separator: "|")
        return try! NSRegularExpression(
            pattern: #"\b(?:expir\w*|valid|giltig\w*|gäller|går\s+ut|upphör\w*)\b[\s\S]{0,25}?\b(\d{1,3})\s*("# + units + #")s?\b"#,
            options: [.caseInsensitive])
    }()

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
