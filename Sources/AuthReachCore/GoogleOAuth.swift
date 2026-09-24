import Foundation
import Network

/// Google OAuth for installed apps: browser consent + loopback redirect +
/// authorization-code exchange, with refresh-token persistence in the
/// Keychain. One token set per connected account, all sharing the
/// user-supplied OAuth client.
public struct OAuthTokens: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    /// Epoch seconds.
    public var expiresAt: Double

    public var isFresh: Bool { expiresAt > Date().timeIntervalSince1970 + 60 }
}

public final class GoogleOAuth: @unchecked Sendable {
    public static let scope = "https://www.googleapis.com/auth/gmail.readonly"
    private let keychain: KeychainStore
    private let credentialsProvider: @Sendable () -> GoogleCredentials?

    public init(keychain: KeychainStore = KeychainStore(),
                credentialsProvider: @escaping @Sendable () -> GoogleCredentials?) {
        self.keychain = keychain
        self.credentialsProvider = credentialsProvider
    }

    public enum OAuthError: LocalizedError {
        case noCredentials
        case notConnected
        case consentDeclined
        case timedOut
        case flowFailed(String)
        public var errorDescription: String? {
            switch self {
            case .noCredentials: return "Add your Google API credentials before connecting."
            case .notConnected: return "Not signed in to Google. Choose Reconnect."
            case .consentDeclined: return "Sign-in was cancelled on Google's consent screen."
            case .timedOut:
                return "Timed out waiting for Google sign-in. If Google showed an error page instead, check that your OAuth client is a Desktop app and that this Google account is a test user (or the app is published)."
            case .flowFailed(let reason): return "Google sign-in failed: \(reason)"
            }
        }
    }

    /// How long the browser flow may take before the listener gives up.
    static let consentTimeout: TimeInterval = 300

    private func tokenKey(_ accountId: String) -> String { "google-tokens:\(accountId)" }

    public func isConnected(accountId: String) -> Bool {
        keychain.get(OAuthTokens.self, forKey: tokenKey(accountId)) != nil
    }

    public func signOut(accountId: String) {
        keychain.remove(forKey: tokenKey(accountId))
    }

    /// Moves an account's tokens to another id, replacing any there; used
    /// when a sign-in turns out to be an account that is already connected.
    public func moveTokens(from source: String, to destination: String) throws {
        guard let tokens = keychain.get(OAuthTokens.self, forKey: tokenKey(source)) else {
            throw OAuthError.notConnected
        }
        try keychain.set(tokens, forKey: tokenKey(destination))
        keychain.remove(forKey: tokenKey(source))
    }

    // MARK: - Browser flow

    /// Runs the full flow: starts a loopback listener, opens the consent URL
    /// (via `openURL`), waits for the redirect, exchanges the code and
    /// stores tokens for `accountId`. `complete` then finishes connecting the
    /// account and returns what to name it in the browser (its address);
    /// the redirect request is only answered after that, so the browser page
    /// reports the real outcome. Throws `CancellationError` if the calling
    /// task is cancelled while waiting.
    @discardableResult
    public func authorize(accountId: String,
                          openURL: @escaping @Sendable (URL) -> Void,
                          complete: @Sendable () async throws -> String) async throws -> String {
        guard let credentials = credentialsProvider() else { throw OAuthError.noCredentials }

        let server = try LoopbackRedirectServer.start()
        let redirectUri = "http://127.0.0.1:\(server.port)/callback"

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: credentials.clientId),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "access_type", value: "offline"),
            // Force the consent screen so Google re-issues a refresh token.
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        openURL(components.url!)

        let query = try await server.waitForCallback(timeout: Self.consentTimeout)
        do {
            let code = try Self.authorizationCode(from: query)
            let tokens = try await exchange(credentials: credentials, refreshing: false, body: [
                "code": code,
                "client_id": credentials.clientId,
                "client_secret": credentials.clientSecret,
                "redirect_uri": redirectUri,
                "grant_type": "authorization_code",
            ])
            try keychain.set(tokens, forKey: tokenKey(accountId))
            let name = try await complete()
            server.finish(LoopbackRedirectServer.page(
                title: "Connected \(name)",
                message: "You can close this window and return to AuthReach."))
            return name
        } catch {
            // Cancelling mid-exchange surfaces as URLError.cancelled; report
            // it as the cancellation it is, not as a failure.
            let cancelled = Task.isCancelled || error is CancellationError
            server.finish(LoopbackRedirectServer.page(
                title: "Couldn't connect",
                message: cancelled ? "Sign-in was cancelled in AuthReach." : error.localizedDescription,
                isError: true))
            throw cancelled ? CancellationError() : error
        }
    }

    /// The `code` of a redirect, or the error Google redirected with
    /// instead (RFC 6749 §4.1.2.1): `access_denied` when the user declines.
    static func authorizationCode(from query: [String: String]) throws -> String {
        if let error = query["error"] {
            if error == "access_denied" { throw OAuthError.consentDeclined }
            throw OAuthError.flowFailed(error)
        }
        guard let code = query["code"], !code.isEmpty else {
            throw OAuthError.flowFailed("Google returned no authorization code")
        }
        return code
    }

    /// A live access token for the account, refreshing if stale.
    public func accessToken(accountId: String) async throws -> String {
        guard var tokens = keychain.get(OAuthTokens.self, forKey: tokenKey(accountId)) else {
            throw OAuthError.notConnected
        }
        if tokens.isFresh { return tokens.accessToken }
        guard let credentials = credentialsProvider() else { throw OAuthError.noCredentials }
        guard let refreshToken = tokens.refreshToken else { throw OAuthError.notConnected }
        let refreshed = try await exchange(credentials: credentials, refreshing: true, body: [
            "refresh_token": refreshToken,
            "client_id": credentials.clientId,
            "client_secret": credentials.clientSecret,
            "grant_type": "refresh_token",
        ])
        tokens.accessToken = refreshed.accessToken
        tokens.expiresAt = refreshed.expiresAt
        if let newRefresh = refreshed.refreshToken { tokens.refreshToken = newRefresh }
        try keychain.set(tokens, forKey: tokenKey(accountId))
        return tokens.accessToken
    }

    // MARK: - Token endpoint

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Double?
        let scope: String?
    }

    private func exchange(credentials: GoogleCredentials, refreshing: Bool,
                          body: [String: String]) async throws -> OAuthTokens {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value)"
        }.joined(separator: "&").data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OAuthError.flowFailed("unexpected response from the token endpoint")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GoogleAPIError.fromTokenEndpoint(status: http.statusCode, body: data, refreshing: refreshing)
        }
        let parsed = try JSONDecoder().decode(TokenResponse.self, from: data)
        if !Self.grantsGmail(scope: parsed.scope) { throw GoogleAPIError.scopeNotGranted }
        return OAuthTokens(accessToken: parsed.access_token,
                           refreshToken: parsed.refresh_token,
                           expiresAt: Date().timeIntervalSince1970 + (parsed.expires_in ?? 3600))
    }

    /// Whether a token response's space-separated `scope` includes Gmail
    /// read access. Google lets the user untick scopes on the consent
    /// screen (granular consent), and says so here rather than failing;
    /// an absent `scope` means the requested scopes were granted
    /// (RFC 6749 §5.1).
    static func grantsGmail(scope: String?) -> Bool {
        guard let scope else { return true }
        return scope.split(separator: " ").contains { $0 == Self.scope }
    }
}
