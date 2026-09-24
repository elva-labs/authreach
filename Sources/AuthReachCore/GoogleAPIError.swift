import Foundation

/// Google error responses, turned into messages that say what to fix.
///
/// Gmail and the other REST APIs answer with
/// `{"error": {"code", "message", "status", "errors": [{"reason"}], "details": [{"reason"}]}}`,
/// where `errors[].reason` is the legacy code (`accessNotConfigured`) and
/// `details[].reason` the newer `google.rpc.ErrorInfo` one (`SERVICE_DISABLED`);
/// either may be missing. The OAuth token endpoint answers with
/// `{"error": "invalid_grant", "error_description": …}` (RFC 6749 §5.2).
public enum GoogleAPIError: LocalizedError, Equatable, Sendable {
    /// The Gmail API is not enabled in the OAuth client's Cloud project.
    case gmailDisabled
    /// The account was not granted `gmail.readonly` (Google lets the user
    /// untick individual scopes on the consent screen).
    case scopeNotGranted
    /// The access token was rejected.
    case unauthorized
    case rateLimited
    case unavailable(status: Int)
    /// Wrong client ID or secret.
    case invalidClient
    /// The refresh token expired or was revoked. Google expires them after
    /// 7 days for External apps still in Testing.
    case signInExpired
    case other(status: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .gmailDisabled:
            return "The Gmail API isn't enabled in your Google Cloud project. Enable it under APIs & Services → Library, wait a minute, then add the account again."
        case .scopeNotGranted:
            return "AuthReach wasn't allowed to read Gmail. Add the account again and tick the Gmail permission on Google's consent screen."
        case .unauthorized:
            return "Google rejected this account's sign-in. Choose Reconnect."
        case .rateLimited:
            return "Gmail is rate-limiting requests; AuthReach will retry on the next check."
        case .unavailable(let status):
            return "Gmail is temporarily unavailable (HTTP \(status)); AuthReach will retry on the next check."
        case .invalidClient:
            return "Google didn't accept your OAuth client ID or secret. Re-enter them under Google API credentials…"
        case .signInExpired:
            return "Google sign-in expired or was revoked. Choose Reconnect. Apps left in Testing have sign-ins expire after 7 days; publishing yours stops that."
        case .other(let status, let message):
            return "Google API error (HTTP \(status)): \(message)"
        }
    }

    /// Classifies a non-2xx Gmail API response.
    public static func fromGmail(status: Int, body: Data) -> GoogleAPIError {
        let error = (try? JSONDecoder().decode(RestEnvelope.self, from: body))?.error
        let reasons = Set((error?.errors ?? []).compactMap(\.reason) + (error?.details ?? []).compactMap(\.reason))
        if !reasons.isDisjoint(with: ["accessNotConfigured", "SERVICE_DISABLED"]) { return .gmailDisabled }
        if !reasons.isDisjoint(with: ["insufficientPermissions", "ACCESS_TOKEN_SCOPE_INSUFFICIENT"]) { return .scopeNotGranted }
        if !reasons.isDisjoint(with: ["rateLimitExceeded", "userRateLimitExceeded", "RATE_LIMIT_EXCEEDED"]) { return .rateLimited }
        switch status {
        case 401: return .unauthorized
        case 429: return .rateLimited
        case 500...599: return .unavailable(status: status)
        default: return .other(status: status, message: error?.message ?? summary(of: body))
        }
    }

    /// Classifies a non-2xx token endpoint response. `invalid_grant` means an
    /// expired sign-in only when refreshing; for a fresh authorization code
    /// it means the code was already used or timed out.
    public static func fromTokenEndpoint(status: Int, body: Data, refreshing: Bool) -> GoogleAPIError {
        let parsed = try? JSONDecoder().decode(TokenError.self, from: body)
        switch parsed?.error {
        case "invalid_client", "unauthorized_client": return .invalidClient
        case "invalid_grant" where refreshing: return .signInExpired
        default:
            if (500...599).contains(status) { return .unavailable(status: status) }
            let message = [parsed?.error, parsed?.error_description].compactMap { $0 }.joined(separator: ": ")
            return .other(status: status, message: message.isEmpty ? summary(of: body) : message)
        }
    }

    /// First line of a body that isn't Google's JSON (e.g. an HTML error
    /// page from a proxy), kept short.
    private static func summary(of body: Data) -> String {
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return firstLine.isEmpty ? "no details" : String(firstLine.prefix(200))
    }

    private struct RestEnvelope: Decodable {
        struct Body: Decodable {
            struct Reason: Decodable { let reason: String? }
            let message: String?
            let errors: [Reason]?
            let details: [Reason]?
        }
        let error: Body?
    }

    private struct TokenError: Decodable {
        let error: String?
        let error_description: String?
    }
}
