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

    private let provider: any InboxProvider
    private var runtimes: [String: AccountRuntime] = [:]
    public private(set) var recent: [OtpEntry] = []

    /// Called for each genuinely new code, oldest first.
    private var onNewCode: (@Sendable (OtpEntry) -> Void)?

    public init(provider: any InboxProvider) {
        self.provider = provider
    }

    public func setOnNewCode(_ handler: @escaping @Sendable (OtpEntry) -> Void) {
        onNewCode = handler
    }

    public func configureAccounts(_ accounts: [ConnectedAccount]) {
        var next: [String: AccountRuntime] = [:]
        for account in accounts {
            next[account.id] = runtimes[account.id] ?? AccountRuntime(email: account.email)
            next[account.id]?.email = account.email
        }
        runtimes = next
    }

    public func runtime(accountId: String) -> AccountRuntime? {
        runtimes[accountId]
    }

    public func clearRecent() {
        recent = []
    }

    /// One poll tick across every configured account. Errors are recorded
    /// per-account, never thrown — one broken inbox must not stop the rest.
    public func pollAll() async {
        for accountId in runtimes.keys {
            await poll(accountId: accountId)
        }
    }

    private func poll(accountId: String) async {
        guard var runtime = runtimes[accountId] else { return }
        defer {
            runtime.lastCheckedAt = Date()
            runtimes[accountId] = runtime
        }
        do {
            guard let watermark = runtime.watermark else {
                // First cycle: baseline only, skip the backlog.
                runtime.watermark = try await provider.initialWatermark(accountId: accountId)
                runtime.lastError = nil
                return
            }

            let ids = try await provider.listMessageIds(accountId: accountId, after: watermark)
            var newest = watermark
            for id in ids where !runtime.processed.contains("\(accountId):\(id)") {
                let message = try await provider.message(accountId: accountId, id: id)
                let entryId = "\(accountId):\(message.id)"
                runtime.processed.insert(entryId)
                newest = max(newest, provider.watermark(for: message))

                let text = [message.subject, message.snippet, message.text].joined(separator: " ")
                guard let code = OtpDetector.detectCode(in: text) else { continue }

                let expirySeconds = OtpDetector.detectExpirySeconds(in: text)
                let entry = OtpEntry(
                    id: entryId,
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
