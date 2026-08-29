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
        case flowFailed(String)
        public var errorDescription: String? {
            switch self {
            case .noCredentials: return "Add your Google API credentials before connecting."
            case .notConnected: return "Not connected to Gmail. Please reconnect this account."
            case .flowFailed(let reason): return "Google sign-in failed: \(reason)"
            }
        }
    }

    private func tokenKey(_ accountId: String) -> String { "google-tokens:\(accountId)" }

    public func isConnected(accountId: String) -> Bool {
        keychain.get(OAuthTokens.self, forKey: tokenKey(accountId)) != nil
    }

    public func signOut(accountId: String) {
        keychain.remove(forKey: tokenKey(accountId))
    }

    // MARK: - Browser flow

    /// Runs the full flow: starts a one-shot loopback listener, opens the
    /// consent URL (via `openURL`), waits for the redirect, exchanges the
    /// code, and stores tokens for `accountId`.
    public func authorize(accountId: String, openURL: @escaping @Sendable (URL) -> Void) async throws {
        guard let credentials = credentialsProvider() else { throw OAuthError.noCredentials }

        let (port, codeTask) = try startLoopbackListener()
        let redirectUri = "http://127.0.0.1:\(port)/callback"

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

        let code = try await codeTask.value
        let tokens = try await exchange(credentials: credentials, body: [
            "code": code,
            "client_id": credentials.clientId,
            "client_secret": credentials.clientSecret,
            "redirect_uri": redirectUri,
            "grant_type": "authorization_code",
        ])
        try keychain.set(tokens, forKey: tokenKey(accountId))
    }

    /// A live access token for the account, refreshing if stale.
    public func accessToken(accountId: String) async throws -> String {
        guard var tokens = keychain.get(OAuthTokens.self, forKey: tokenKey(accountId)) else {
            throw OAuthError.notConnected
        }
        if tokens.isFresh { return tokens.accessToken }
        guard let credentials = credentialsProvider() else { throw OAuthError.noCredentials }
        guard let refreshToken = tokens.refreshToken else { throw OAuthError.notConnected }
        let refreshed = try await exchange(credentials: credentials, body: [
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
    }

    private func exchange(credentials: GoogleCredentials, body: [String: String]) async throws -> OAuthTokens {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value)"
        }.joined(separator: "&").data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw OAuthError.flowFailed("token endpoint: \(detail.prefix(200))")
        }
        let parsed = try JSONDecoder().decode(TokenResponse.self, from: data)
        return OAuthTokens(accessToken: parsed.access_token,
                           refreshToken: parsed.refresh_token,
                           expiresAt: Date().timeIntervalSince1970 + (parsed.expires_in ?? 3600))
    }

    // MARK: - Loopback listener

    /// One-shot HTTP listener bound to an explicit high port on loopback;
    /// resolves with the `code` query parameter of the first /callback
    /// request. The port is chosen before building the redirect URI, and the
    /// browser is only opened once the listener reports ready — never a
    /// ":0" redirect.
    private func startLoopbackListener() throws -> (UInt16, Task<String, Error>) {
        var lastError: Error = OAuthError.flowFailed("could not open loopback listener")
        for _ in 0..<10 {
            let port = UInt16.random(in: 49152...65500)
            do {
                return (port, try listen(on: port))
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func listen(on port: UInt16) throws -> Task<String, Error> {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)

        // Wait for ready/failed before returning, so a port collision is
        // retried instead of sending the browser to a dead port.
        let readySemaphore = DispatchSemaphore(value: 0)
        let readyState = LockedBox<NWListener.State>(.setup)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled:
                readyState.set(state)
                readySemaphore.signal()
            default:
                break
            }
        }

        let resumed = ResumeGuard()
        let task = Task<String, Error> {
            try await withCheckedThrowingContinuation { continuation in
                listener.newConnectionHandler = { connection in
                    connection.start(queue: .global())
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                        let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                        let firstLine = request.split(separator: "\r\n").first ?? ""
                        // Ignore stray probes (favicon etc.) that aren't the callback.
                        guard firstLine.contains("/callback") else {
                            connection.cancel()
                            return
                        }
                        let result: Result<String, Error>
                        let page: String
                        if let range = firstLine.range(of: #"code=([^&\s]+)"#, options: .regularExpression) {
                            let code = String(firstLine[range].dropFirst("code=".count))
                                .removingPercentEncoding ?? ""
                            result = .success(code)
                            page = "<html><body style=\"font-family:sans-serif\"><h3>Connected.</h3>You can close this window and return to AuthReach.</body></html>"
                        } else {
                            result = .failure(OAuthError.flowFailed("consent was denied or no code returned"))
                            page = "<html><body style=\"font-family:sans-serif\"><h3>Sign-in failed.</h3>You can close this window.</body></html>"
                        }
                        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\nContent-Length: \(page.utf8.count)\r\n\r\n\(page)"
                        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                            connection.cancel()
                            listener.cancel()
                            if resumed.claim() { continuation.resume(with: result) }
                        })
                    }
                }
                listener.start(queue: .global())
            }
        }

        if readySemaphore.wait(timeout: .now() + 3) == .timedOut {
            listener.cancel()
            task.cancel()
            throw OAuthError.flowFailed("loopback listener timed out while starting")
        }
        guard case .ready = readyState.get() else {
            listener.cancel()
            task.cancel()
            throw OAuthError.flowFailed("loopback port \(port) unavailable")
        }
        return task
    }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func set(_ new: T) { lock.lock(); value = new; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}

/// Ensures a continuation resumes exactly once even if multiple connections
/// race (browsers often probe with a favicon request).
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}
