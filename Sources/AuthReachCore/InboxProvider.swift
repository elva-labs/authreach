import Foundation

/// The four-function surface the poll loop consumes — Gmail and IMAP in the
/// app, stubs in tests. Watermarks are opaque doubles (epoch seconds for
/// Gmail, UID for IMAP).
public protocol InboxProvider: Sendable {
    func initialWatermark(accountId: String) async throws -> Double
    func listMessageIds(accountId: String, after watermark: Double) async throws -> [String]
    func message(accountId: String, id: String) async throws -> FetchedMessage
    func watermark(for message: FetchedMessage) -> Double
}

public enum InboxProviderError: Error, Sendable {
    /// The provider's id space was renumbered (IMAP UIDVALIDITY changed), so
    /// the stored watermark is meaningless. The poll loop re-baselines the
    /// account on its next tick instead of reporting an error.
    case baselineReset
}
