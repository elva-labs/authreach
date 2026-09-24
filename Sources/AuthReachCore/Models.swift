import Foundation

/// A captured one-time code, as shown in the tray, HUD, and local API.
public struct OtpEntry: Codable, Hashable, Sendable, Identifiable {
    /// Account-scoped id (`accountId:messageId`), used for de-duplication.
    public let id: String
    public let code: String
    /// Human-friendly service name, derived from the sender.
    public let service: String
    public let sender: String
    public let subject: String
    /// Epoch milliseconds the message was received.
    public let receivedAt: Double
    /// Epoch milliseconds the code expires, when the email stated a duration.
    public let expiresAt: Double?
    public let accountEmail: String

    public init(id: String, code: String, service: String, sender: String, subject: String,
                receivedAt: Double, expiresAt: Double?, accountEmail: String) {
        self.id = id
        self.code = code
        self.service = service
        self.sender = sender
        self.subject = subject
        self.receivedAt = receivedAt
        self.expiresAt = expiresAt
        self.accountEmail = accountEmail
    }
}

public struct ConnectedAccount: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var email: String
    public var provider: Provider

    public enum Provider: String, Codable, Sendable {
        case google
        case imap
    }

    public init(id: String = UUID().uuidString, email: String, provider: Provider = .google) {
        self.id = id
        self.email = email
        self.provider = provider
    }
}

public struct Settings: Codable, Sendable {
    public var autoCopy: Bool
    public var notify: Bool
    public var pollIntervalSec: Int
    public var localApiEnabled: Bool
    public var localApiPort: Int
    public var localApiToken: String
    public var localApiExposeMetadata: Bool
    public var accounts: [ConnectedAccount]

    public static let defaults = Settings(
        autoCopy: true, notify: true, pollIntervalSec: 15,
        localApiEnabled: false, localApiPort: 8877, localApiToken: "",
        localApiExposeMetadata: true, accounts: [])

    public init(autoCopy: Bool, notify: Bool, pollIntervalSec: Int, localApiEnabled: Bool,
                localApiPort: Int, localApiToken: String, localApiExposeMetadata: Bool,
                accounts: [ConnectedAccount]) {
        self.autoCopy = autoCopy
        self.notify = notify
        self.pollIntervalSec = pollIntervalSec
        self.localApiEnabled = localApiEnabled
        self.localApiPort = localApiPort
        self.localApiToken = localApiToken
        self.localApiExposeMetadata = localApiExposeMetadata
        self.accounts = accounts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings.defaults
        autoCopy = try c.decodeIfPresent(Bool.self, forKey: .autoCopy) ?? d.autoCopy
        notify = try c.decodeIfPresent(Bool.self, forKey: .notify) ?? d.notify
        pollIntervalSec = try c.decodeIfPresent(Int.self, forKey: .pollIntervalSec) ?? d.pollIntervalSec
        localApiEnabled = try c.decodeIfPresent(Bool.self, forKey: .localApiEnabled) ?? d.localApiEnabled
        localApiPort = try c.decodeIfPresent(Int.self, forKey: .localApiPort) ?? d.localApiPort
        localApiToken = try c.decodeIfPresent(String.self, forKey: .localApiToken) ?? d.localApiToken
        localApiExposeMetadata = try c.decodeIfPresent(Bool.self, forKey: .localApiExposeMetadata) ?? d.localApiExposeMetadata
        accounts = try c.decodeIfPresent([ConnectedAccount].self, forKey: .accounts) ?? d.accounts
    }
}

public struct GoogleCredentials: Codable, Hashable, Sendable {
    public var clientId: String
    public var clientSecret: String

    public init(clientId: String, clientSecret: String) {
        self.clientId = clientId
        self.clientSecret = clientSecret
    }

    /// Pasted values, with the whitespace and newlines that copying from the
    /// Cloud console tends to bring along removed.
    public init(pastedClientId: String, clientSecret: String) {
        self.init(clientId: pastedClientId.trimmingCharacters(in: .whitespacesAndNewlines),
                  clientSecret: clientSecret.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Why these obviously aren't an OAuth client's ID and secret, if so:
    /// catches swapped fields and partial pastes before Google does, since
    /// Google reports a bad client ID on its own error page and never
    /// redirects back.
    public var problem: String? {
        let suffix = ".apps.googleusercontent.com"
        if clientId.isEmpty || clientSecret.isEmpty {
            return "Enter both the client ID and the client secret."
        }
        if clientSecret.hasSuffix(suffix) && !clientId.hasSuffix(suffix) {
            return "The fields look swapped: the client ID is the one ending in \(suffix)."
        }
        if !clientId.hasSuffix(suffix) {
            return "The client ID should end in \(suffix)."
        }
        if (clientId + clientSecret).contains(where: \.isWhitespace) {
            return "The client ID and secret can't contain spaces."
        }
        return nil
    }
}

/// A fetched, text-extracted email — the provider-agnostic unit the poll
/// loop and detector consume, whether it came from Gmail or IMAP.
public struct FetchedMessage: Sendable {
    public let id: String
    public let subject: String
    public let from: String
    public let snippet: String
    public let text: String
    /// Epoch milliseconds.
    public let receivedAt: Double

    public init(id: String, subject: String, from: String, snippet: String, text: String, receivedAt: Double) {
        self.id = id
        self.subject = subject
        self.from = from
        self.snippet = snippet
        self.text = text
        self.receivedAt = receivedAt
    }
}

/// Shared HTML-to-plain-text fallback for bodies that only have an HTML part.
public func stripHtml(_ html: String) -> String {
    var s = html
    for pattern in [#"<style[\s\S]*?</style>"#, #"<script[\s\S]*?</script>"#, #"<[^>]+>"#] {
        s = s.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
    }
    s = decodeHtmlEntities(s)
    s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    return s.trimmingCharacters(in: .whitespaces)
}

private let htmlEntityPattern = try! NSRegularExpression(pattern: #"&(#x[0-9a-fA-F]{1,6}|#[0-9]{1,7}|[a-zA-Z][a-zA-Z0-9]{1,31});"#)

/// Named entities beyond the XML five: the Latin-1 letters that appear in
/// Swedish (and other Western European) mail. Numeric entities are decoded
/// generically. Unknown names are left as-is.
private let namedHtmlEntities: [String: String] = [
    "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
    "aring": "å", "Aring": "Å", "auml": "ä", "Auml": "Ä", "ouml": "ö", "Ouml": "Ö",
    "aelig": "æ", "AElig": "Æ", "oslash": "ø", "Oslash": "Ø", "uuml": "ü", "Uuml": "Ü",
    "eacute": "é", "Eacute": "É", "egrave": "è", "Egrave": "È", "ecirc": "ê",
    "aacute": "á", "agrave": "à", "acirc": "â", "ccedil": "ç", "ntilde": "ñ",
    "iacute": "í", "oacute": "ó", "uacute": "ú", "szlig": "ß",
    "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’",
    "ldquo": "“", "rdquo": "”", "laquo": "«", "raquo": "»", "euro": "€", "copy": "©",
]

/// Decodes numeric (`&#229;`, `&#xE5;`) and common named (`&aring;`) HTML
/// entities. A single pass, so `&amp;auml;` correctly yields the literal
/// text "&auml;" rather than "ä".
func decodeHtmlEntities(_ text: String) -> String {
    let ns = text as NSString
    var out = ""
    var cursor = 0
    for m in htmlEntityPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
        let body = ns.substring(with: m.range(at: 1))
        let decoded: String?
        if body.hasPrefix("#x") || body.hasPrefix("#X") {
            decoded = UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        } else if body.hasPrefix("#") {
            decoded = UInt32(body.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        } else {
            decoded = namedHtmlEntities[body]
        }
        out += decoded ?? ns.substring(with: m.range)
        cursor = m.range.location + m.range.length
    }
    out += ns.substring(from: cursor)
    return out
}
