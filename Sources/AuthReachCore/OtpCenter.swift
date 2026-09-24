import Foundation

/// The poll orchestrator — UI-free port of the original otp-manager core.
/// Per-account runtime state (watermark, processed ids) is in-memory and
/// rebuilt on launch, so a fresh start never re-processes old mail: the
/// first poll of an account just establishes a baseline.
public actor OtpCenter {
    public struct AccountRuntime: Sendable {
        public var email: String
        public var watermark: Double?
        public var processed: Set<String> = []
        public var lastError: String?
        public var lastCheckedAt: Date?
    }

    public static let maxRecent = 20

    /// Picks the inbox provider for an account (Gmail vs IMAP).
    public typealias ProviderResolver = @Sendable (ConnectedAccount) -> any InboxProvider

    private let providerFor: ProviderResolver
    private var providers: [String: any InboxProvider] = [:]
    private var runtimes: [String: AccountRuntime] = [:]
    /// Accounts with a poll currently running.
    private var inFlight: Set<String> = []
    public private(set) var recent: [OtpEntry] = []

    /// Called for each genuinely new code, oldest first.
    private var onNewCode: (@Sendable (OtpEntry) -> Void)?

    public init(providerFor: @escaping ProviderResolver) {
        self.providerFor = providerFor
    }

    /// Single-provider convenience (tests, or a Gmail-only setup).
    public init(provider: any InboxProvider) {
        self.init(providerFor: { _ in provider })
    }

    public func setOnNewCode(_ handler: @escaping @Sendable (OtpEntry) -> Void) {
        onNewCode = handler
    }

    public func configureAccounts(_ accounts: [ConnectedAccount]) {
        var next: [String: AccountRuntime] = [:]
        var nextProviders: [String: any InboxProvider] = [:]
        for account in accounts {
            next[account.id] = runtimes[account.id] ?? AccountRuntime(email: account.email)
            next[account.id]?.email = account.email
            nextProviders[account.id] = providerFor(account)
        }
        runtimes = next
        providers = nextProviders
    }

    public func runtime(accountId: String) -> AccountRuntime? {
        runtimes[accountId]
    }

    public func clearRecent() {
        recent = []
    }

    /// One poll tick across every configured account. Accounts poll in
    /// parallel so one slow inbox can't hold up the rest, and an account
    /// whose previous poll is still running is skipped rather than polled
    /// twice. Errors are recorded per-account, never thrown.
    public func pollAll() async {
        let due = runtimes.keys.filter { !inFlight.contains($0) }
        inFlight.formUnion(due)
        await withTaskGroup(of: Void.self) { group in
            for accountId in due {
                group.addTask { await self.poll(accountId: accountId) }
            }
        }
    }

    private func poll(accountId: String) async {
        defer { inFlight.remove(accountId) }
        guard var runtime = runtimes[accountId], let provider = providers[accountId] else { return }
        defer {
            runtime.lastCheckedAt = Date()
            // The account may have been removed or renamed while this poll
            // was suspended; don't resurrect it or clobber the new email.
            if let current = runtimes[accountId] {
                runtime.email = current.email
                runtimes[accountId] = runtime
            }
        }
        do {
            guard let watermark = runtime.watermark else {
                // First cycle: baseline only, skip the backlog.
                runtime.watermark = try await provider.initialWatermark(accountId: accountId)
                runtime.lastError = nil
                return
            }

            let messages = try await provider.messages(accountId: accountId, after: watermark,
                                                       skipping: runtime.processed)
            var newest = watermark
            for message in messages where !runtime.processed.contains(message.id) {
                runtime.processed.insert(message.id)
                newest = max(newest, provider.watermark(for: message))

                // NFC so decomposed "a" + U+0308 still matches the precomposed
                // "ä" in the detector's patterns (ICU regex has no canonical
                // equivalence mode).
                let text = [message.subject, message.snippet, message.text]
                    .joined(separator: " ")
                    .precomposedStringWithCanonicalMapping
                guard let code = OtpDetector.detectCode(in: text) else { continue }

                let expirySeconds = OtpDetector.detectExpirySeconds(in: text)
                let entry = OtpEntry(
                    id: "\(accountId):\(message.id)",
                    code: code,
                    service: OtpDetector.serviceFromSender(message.from),
                    sender: OtpDetector.addressFromSender(message.from),
                    subject: message.subject,
                    receivedAt: message.receivedAt,
                    expiresAt: expirySeconds.map { message.receivedAt + Double($0) * 1000 },
                    accountEmail: runtime.email)
                append(entry)
                onNewCode?(entry)
            }
            runtime.watermark = newest
            runtime.lastError = nil

            // Keep the processed set bounded; ids older than the watermark
            // can never be listed again.
            if runtime.processed.count > 500 { runtime.processed = [] }
        } catch InboxProviderError.baselineReset {
            // Ids were renumbered under us; start over from a fresh baseline
            // next tick rather than trusting the old watermark.
            runtime.watermark = nil
            runtime.processed = []
            runtime.lastError = nil
        } catch {
            runtime.lastError = error.localizedDescription
        }
    }

    private func append(_ entry: OtpEntry) {
        recent.removeAll { $0.id == entry.id }
        recent.insert(entry, at: 0)
        if recent.count > Self.maxRecent {
            recent.removeLast(recent.count - Self.maxRecent)
        }
    }
}
