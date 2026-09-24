import Foundation

/// Why an account's last poll failed, and what it takes to fix it, so the
/// UI only asks the user to act when acting helps.
public struct AccountProblem: Equatable, Sendable {
    public enum Remedy: Equatable, Sendable {
        /// Clears up on its own (rate limit, outage, network down); the next
        /// poll retries.
        case automatic
        /// Signing in to the account again fixes it.
        case reconnect
        /// Something else the user has to change: credentials, the Cloud
        /// project, the server settings.
        case manual
    }

    public let message: String
    public let remedy: Remedy

    public var needsAttention: Bool { remedy != .automatic }

    public init(message: String, remedy: Remedy) {
        self.message = message
        self.remedy = remedy
    }

    public init(_ error: Error) {
        let remedy: Remedy
        switch error {
        case let error as GoogleAPIError: remedy = error.remedy
        case let error as GoogleOAuth.OAuthError: remedy = error.remedy
        case let error as ImapError: remedy = error.isTransport ? .automatic : .manual
        case let error as URLError: remedy = Self.networkErrors.contains(error.code) ? .automatic : .manual
        default: remedy = .manual
        }
        self.init(message: error.localizedDescription, remedy: remedy)
    }

    /// URL loading failures that mean "no network right now" (asleep,
    /// offline, captive portal), not a problem with the account.
    private static let networkErrors: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
        .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff,
    ]
}
