import AppKit
import AuthReachCore
import Foundation
import UserNotifications

/// A message at the bottom of the settings window. Errors stay until
/// dismissed or replaced, so a failure is still there when the user comes
/// back from the browser; anything else clears itself.
struct Notice: Equatable, Identifiable {
    let id = UUID()
    let text: String
    let isError: Bool
}

/// Composition root: settings + keychain + OAuth + Gmail + IMAP + poll
/// loop + local API, published for SwiftUI and the tray.
@MainActor
final class AppModel: ObservableObject {
    let settingsStore = SettingsStore.standard()
    let keychain = KeychainStore()
    let oauth: GoogleOAuth
    let gmail: GmailClient
    let imap: ImapProvider
    let center: OtpCenter
    private var apiServer: LocalApiServer?
    private var pollTimer: Timer?

    @Published var settings: Settings
    @Published var recent: [OtpEntry] = []
    /// Failing accounts only, keyed by account id.
    @Published var accountStatus: [String: AccountProblem] = [:]
    @Published var googleCredentialsSet: Bool
    @Published var notice: Notice?
    @Published private var googleSignInTask: Task<Void, Never>?
    var googleSignInPending: Bool { googleSignInTask != nil }
    @Published var localApiError: String?

    /// Fires whenever recent codes change, so the tray can refresh.
    var onRecentChanged: (() -> Void)?

    nonisolated private static let credentialsKey = "google-credentials"
    nonisolated private static func imapKey(_ accountId: String) -> String { "imap-account:\(accountId)" }

    init() {
        let settings = settingsStore.load()
        self.settings = settings
        let keychain = self.keychain
        // Resolved below, off the main thread: a Keychain read can block on a
        // user prompt (e.g. a differently-signed dev build reading items the
        // release created), and this runs before the tray icon exists.
        self.googleCredentialsSet = false
        let oauth = GoogleOAuth(keychain: keychain) {
            keychain.get(GoogleCredentials.self, forKey: Self.credentialsKey)
        }
        self.oauth = oauth
        let gmail = GmailClient(tokenProvider: { accountId in
            try await oauth.accessToken(accountId: accountId)
        })
        self.gmail = gmail
        let imap = ImapProvider(credentialsProvider: { accountId in
            keychain.get(ImapCredentials.self, forKey: Self.imapKey(accountId))
        })
        self.imap = imap
        self.center = OtpCenter(providerFor: { account -> any InboxProvider in
            switch account.provider {
            case .google: return gmail
            case .imap: return imap
            }
        })

        Task {
            await center.configureAccounts(settings.accounts)
            await center.setOnNewCode { [weak self] entry in
                Task { @MainActor in self?.handleNewCode(entry) }
            }
            self.startPolling()
            self.syncLocalApi()
            if settings.notify { Self.requestNotificationPermission() }
            self.googleCredentialsSet = await Task.detached {
                keychain.get(GoogleCredentials.self, forKey: Self.credentialsKey) != nil
            }.value
        }
    }

    // MARK: - Polling

    func startPolling() {
        pollTimer?.invalidate()
        let interval = max(5, settings.pollIntervalSec)
        pollTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(interval), repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.pollNow() }
        }
        Task { await pollNow() }
    }

    func pollNow() async {
        await center.pollAll()
        await publishPollResults()
    }

    /// Polls one account right away, e.g. once its sign-in was renewed.
    func pollAgain(accountId: String) async {
        await center.pollAgain(accountId: accountId)
        await publishPollResults()
    }

    private func publishPollResults() async {
        recent = await center.recent
        var status: [String: AccountProblem] = [:]
        for account in settings.accounts {
            status[account.id] = await center.runtime(accountId: account.id)?.lastError
        }
        accountStatus = status
        onRecentChanged?()
    }

    private func handleNewCode(_ entry: OtpEntry) {
        if settings.autoCopy { copy(entry.code) }
        if settings.notify { Self.notify(entry) }
        Task { recent = await center.recent; onRecentChanged?() }
    }

    // MARK: - Notices

    func inform(_ text: String) { notice = Notice(text: text, isError: false) }
    func report(_ text: String) { notice = Notice(text: text, isError: true) }
    func report(_ error: Error) { report(error.localizedDescription) }

    // MARK: - Actions

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copyEntry(_ entry: OtpEntry) {
        copy(entry.code)
        inform("Copied \(entry.code) (\(entry.service))")
    }

    func saveGoogleCredentials(_ credentials: GoogleCredentials) {
        do {
            try keychain.set(credentials, forKey: Self.credentialsKey)
            googleCredentialsSet = true
            inform("Google credentials saved")
        } catch {
            report(error)
        }
    }

    /// Starts the browser sign-in. Adding an address that is already
    /// connected renews that account's sign-in instead of duplicating it.
    /// `reconnecting` is the account whose Reconnect button was used: Google
    /// preselects it, and signing in as anyone else fails.
    func addGoogleAccount(reconnecting account: ConnectedAccount? = nil) {
        guard googleCredentialsSet else {
            report("Add your Google API credentials first.")
            return
        }
        guard googleSignInTask == nil else { return }
        let accountId = UUID().uuidString
        googleSignInTask = Task {
            defer { googleSignInTask = nil }
            do {
                try await oauth.authorize(accountId: accountId, loginHint: account?.email, openURL: { url in
                    Task { @MainActor in NSWorkspace.shared.open(url) }
                }, complete: {
                    try await self.finishGoogleSignIn(accountId: accountId, reconnecting: account)
                })
            } catch {
                oauth.signOut(accountId: accountId)
                if !(error is CancellationError) { report(error) }
            }
        }
    }

    func cancelGoogleSignIn() {
        googleSignInTask?.cancel()
    }

    /// Runs while the browser waits on the redirect, so its page can say
    /// whether the account was really connected. Returns the address.
    private func finishGoogleSignIn(accountId: String, reconnecting: ConnectedAccount?) async throws -> String {
        let email = try await gmail.profileEmail(accountId: accountId)
        try Task.checkCancellation()
        let connectedId: String
        if let existing = try settings.googleAccount(signedInAs: email, reconnecting: reconnecting) {
            try await oauth.moveTokens(from: accountId, to: existing.id)
            connectedId = existing.id
            inform("Reconnected \(email)")
        } else {
            settings = try settingsStore.update { s in
                s.accounts.append(ConnectedAccount(id: accountId, email: email))
            }
            await center.configureAccounts(settings.accounts)
            connectedId = accountId
            inform("Connected \(email)")
        }
        // Not awaited: the browser is still waiting for this to return.
        Task { await pollAgain(accountId: connectedId) }
        return email
    }

    /// Verifies the credentials against the server (sign-in + read-only
    /// INBOX open) before anything is stored. Throws with a user-facing
    /// message so the sheet can show it inline.
    func addImapAccount(email: String, credentials: ImapCredentials) async throws {
        try await imap.verify(credentials)
        // The sheet was cancelled while we were connecting: save nothing.
        try Task.checkCancellation()
        let accountId = UUID().uuidString
        try keychain.set(credentials, forKey: Self.imapKey(accountId))
        settings = try settingsStore.update { s in
            s.accounts.append(ConnectedAccount(id: accountId, email: email, provider: .imap))
        }
        await center.configureAccounts(settings.accounts)
        inform("Connected \(email)")
        await pollNow()
    }

    func disconnect(account: ConnectedAccount) {
        switch account.provider {
        case .google: oauth.signOut(accountId: account.id)
        case .imap:
            keychain.remove(forKey: Self.imapKey(account.id))
            Task { [imap] in await imap.forget(accountId: account.id) }
        }
        do {
            settings = try settingsStore.update { s in
                s.accounts.removeAll { $0.id == account.id }
            }
        } catch { report(error) }
        Task { await center.configureAccounts(settings.accounts); await pollNow() }
    }

    func updateSettings(_ mutate: (inout Settings) -> Void) {
        do {
            let old = settings
            settings = try settingsStore.update(mutate)
            if settings.pollIntervalSec != old.pollIntervalSec { startPolling() }
            if settings.notify && !old.notify { Self.requestNotificationPermission() }
            if settings.localApiEnabled != old.localApiEnabled
                || settings.localApiPort != old.localApiPort { syncLocalApi() }
        } catch { report(error) }
    }

    // MARK: - Local API

    func syncLocalApi() {
        localApiError = nil
        if settings.localApiEnabled {
            if settings.localApiToken.isEmpty {
                updateSettings { $0.localApiToken = LocalApiServer.generateToken() }
                return // updateSettings re-enters syncLocalApi
            }
            let server = apiServer ?? LocalApiServer(config: .init(
                getRecent: { [weak self] in await self?.center.recent ?? [] },
                getToken: { [settingsStore] in settingsStore.load().localApiToken },
                exposeMetadata: { [settingsStore] in settingsStore.load().localApiExposeMetadata }))
            apiServer = server
            do {
                try server.start(port: UInt16(settings.localApiPort))
            } catch {
                localApiError = error.localizedDescription
            }
        } else {
            apiServer?.stop()
        }
    }

    func regenerateApiToken() {
        updateSettings { $0.localApiToken = LocalApiServer.generateToken() }
        inform("API token regenerated")
    }

    // MARK: - Notifications

    static func requestNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return } // bare binary in dev
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notify(_ entry: OtpEntry) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(entry.service) code: \(entry.code)"
        content.body = entry.subject.isEmpty ? entry.accountEmail : entry.subject
        let request = UNNotificationRequest(identifier: entry.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - Display helpers

func relativeTime(_ epochMs: Double) -> String {
    let seconds = Int(Date().timeIntervalSince1970 - epochMs / 1000)
    if seconds < 60 { return "just now" }
    if seconds < 3600 { return "\(seconds / 60)m ago" }
    if seconds < 86400 { return "\(seconds / 3600)h ago" }
    return "\(seconds / 86400)d ago"
}

/// "Expires in M:SS" / "Expired", or nil when the email stated no duration.
func expiryLabel(_ expiresAt: Double?) -> (label: String, expired: Bool, urgent: Bool)? {
    guard let expiresAt else { return nil }
    let remaining = Int(expiresAt / 1000 - Date().timeIntervalSince1970)
    if remaining <= 0 { return ("Expired", true, false) }
    return (String(format: "Expires in %d:%02d", remaining / 60, remaining % 60),
            false, remaining <= 60)
}
