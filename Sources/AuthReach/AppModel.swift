import AppKit
import AuthReachCore
import Foundation
import UserNotifications

/// Composition root: settings + keychain + OAuth + Gmail + poll loop +
/// local API, published for SwiftUI and the tray.
@MainActor
final class AppModel: ObservableObject {
    let settingsStore = SettingsStore.standard()
    let keychain = KeychainStore()
    let oauth: GoogleOAuth
    let center: OtpCenter
    private var apiServer: LocalApiServer?
    private var pollTimer: Timer?

    @Published var settings: Settings
    @Published var recent: [OtpEntry] = []
    @Published var accountStatus: [String: String] = [:] // accountId -> error or ""
    @Published var googleCredentialsSet: Bool
    @Published var notice: String?
    @Published var localApiError: String?

    /// Fires whenever recent codes change, so the tray can refresh.
    var onRecentChanged: (() -> Void)?

    private static let credentialsKey = "google-credentials"

    init() {
        let settings = settingsStore.load()
        self.settings = settings
        let keychain = self.keychain
        self.googleCredentialsSet = keychain.get(GoogleCredentials.self, forKey: Self.credentialsKey) != nil
        let oauth = GoogleOAuth(keychain: keychain) {
            keychain.get(GoogleCredentials.self, forKey: Self.credentialsKey)
        }
        self.oauth = oauth
        let gmail = GmailClient(tokenProvider: { accountId in
            try await oauth.accessToken(accountId: accountId)
        })
        self.center = OtpCenter(provider: gmail)

        Task {
            await center.configureAccounts(settings.accounts)
            await center.setOnNewCode { [weak self] entry in
                Task { @MainActor in self?.handleNewCode(entry) }
            }
            self.startPolling()
            self.syncLocalApi()
            if settings.notify { Self.requestNotificationPermission() }
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
        recent = await center.recent
        var status: [String: String] = [:]
        for account in settings.accounts {
            status[account.id] = await center.runtime(accountId: account.id)?.lastError ?? ""
        }
        accountStatus = status
        onRecentChanged?()
    }

    private func handleNewCode(_ entry: OtpEntry) {
        if settings.autoCopy { copy(entry.code) }
        if settings.notify { Self.notify(entry) }
        Task { recent = await center.recent; onRecentChanged?() }
    }

    // MARK: - Actions

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copyEntry(_ entry: OtpEntry) {
        copy(entry.code)
        notice = "Copied \(entry.code) (\(entry.service))"
    }

    func saveGoogleCredentials(clientId: String, clientSecret: String) {
        do {
            try keychain.set(GoogleCredentials(clientId: clientId.trimmingCharacters(in: .whitespaces),
                                               clientSecret: clientSecret.trimmingCharacters(in: .whitespaces)),
                             forKey: Self.credentialsKey)
            googleCredentialsSet = true
            notice = "Google credentials saved"
        } catch {
            notice = error.localizedDescription
        }
    }

    func addGoogleAccount() {
        guard googleCredentialsSet else {
            notice = "Add your Google API credentials first."
            return
        }
        let accountId = UUID().uuidString
        Task {
            do {
                try await oauth.authorize(accountId: accountId) { url in
                    Task { @MainActor in NSWorkspace.shared.open(url) }
                }
                let gmail = GmailClient(tokenProvider: { [oauth] id in
                    try await oauth.accessToken(accountId: id)
                })
                let email = try await gmail.profileEmail(accountId: accountId)
                settings = try settingsStore.update { s in
                    s.accounts.append(ConnectedAccount(id: accountId, email: email))
                }
                await center.configureAccounts(settings.accounts)
                notice = "Connected \(email)"
                await pollNow()
            } catch {
                oauth.signOut(accountId: accountId)
                notice = error.localizedDescription
            }
        }
    }

    func disconnect(account: ConnectedAccount) {
        oauth.signOut(accountId: account.id)
        do {
            settings = try settingsStore.update { s in
                s.accounts.removeAll { $0.id == account.id }
            }
        } catch { notice = error.localizedDescription }
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
        } catch { notice = error.localizedDescription }
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
        notice = "API token regenerated"
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
