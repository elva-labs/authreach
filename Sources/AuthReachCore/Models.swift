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
        case imap // storage-compatible with the original; not yet supported natively
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
}

/// A fetched, text-extracted email — the provider-agnostic unit the poll
/// loop and detector consume (same surface for Gmail today, IMAP later).
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
    s = s.replacingOccurrences(of: "&nbsp;", with: " ", options: .caseInsensitive)
    s = s.replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
    s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    return s.trimmingCharacters(in: .whitespaces)
}
