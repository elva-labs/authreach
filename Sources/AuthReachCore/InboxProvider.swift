import Foundation

/// The four-function surface the poll loop consumes — Gmail today, IMAP
/// later, stubs in tests. Watermarks are opaque doubles (epoch seconds for
/// Gmail, UID for a future IMAP provider).
public protocol InboxProvider: Sendable {
    func initialWatermark(accountId: String) async throws -> Double
    func listMessageIds(accountId: String, after watermark: Double) async throws -> [String]
    func message(accountId: String, id: String) async throws -> FetchedMessage
    func watermark(for message: FetchedMessage) -> Double
}
