import Foundation
import Network
import Security

/// Byte stream under an IMAP connection — TLS over TCP in the app, a
/// scripted buffer in tests.
protocol ImapTransport: Sendable {
    func open() async throws
    func send(_ data: Data) async throws
    /// At least one byte; throws once the peer has closed.
    func receive() async throws -> Data
    func close()
}

enum ImapError: LocalizedError, Sendable {
    case notConfigured
    case connection(String)
    case timedOut(String)
    case unexpected(String)
    case authentication(String)
    case server(command: String, message: String)

    /// The connection itself failed (as opposed to the server refusing a
    /// command), so the same request may succeed on a fresh connection.
    var isTransport: Bool {
        switch self {
        case .connection, .timedOut: return true
        default: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "IMAP credentials are missing. Please reconnect this account."
        case .connection(let detail): return "IMAP connection failed: \(detail)"
        case .timedOut(let what): return "IMAP server timed out while \(what)."
        case .unexpected(let detail): return "Unexpected IMAP response: \(detail.prefix(200))"
        case .authentication(let detail): return "IMAP sign-in was rejected: \(detail.prefix(200))"
        case .server(let command, let message): return "IMAP \(command) failed: \(message.prefix(200))"
        }
    }
}

/// Races an operation against a deadline. On timeout the current task is
/// cancelled, which the network transport turns into a connection cancel so
/// the pending callback fires and nothing leaks.
func withImapTimeout<T: Sendable>(seconds: Double, _ what: String,
                                  _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw ImapError.timedOut(what)
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

/// Implicit-TLS IMAP transport (port 993) on Network.framework. Certificate
/// validation and SNI are the framework defaults.
final class NWImapTransport: ImapTransport, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.elva-labs.authreach.imap")

    init(host: String, port: UInt16) {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 15
        let parameters = NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp)
        connection = NWConnection(host: NWEndpoint.Host(host),
                                  port: NWEndpoint.Port(rawValue: port) ?? 993,
                                  using: parameters)
    }

    func open() async throws {
        let once = OnceFlag()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Cancelled before we got here: onCancel already ran, and a
                // connection cancelled before start() may never report a state.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                connection.stateUpdateHandler = { [connection] state in
                    switch state {
                    case .ready:
                        if once.claim() { continuation.resume() }
                    case .failed(let error):
                        if once.claim() { continuation.resume(throwing: ImapError.connection(Self.describe(error))) }
                    case .waiting(let error):
                        // No viable path (DNS, offline). Fail fast; the next poll retries.
                        connection.cancel()
                        if once.claim() { continuation.resume(throwing: ImapError.connection(Self.describe(error))) }
                    case .cancelled:
                        if once.claim() { continuation.resume(throwing: ImapError.connection("connection cancelled")) }
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }
    }

    func send(_ data: Data) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: ImapError.connection(Self.describe(error)))
                    } else {
                        continuation.resume()
                    }
                })
            }
        } onCancel: {
            connection.cancel()
        }
    }

    func receive() async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: ImapError.connection(Self.describe(error)))
                    } else if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(throwing: ImapError.connection(
                            isComplete ? "server closed the connection" : "empty read"))
                    }
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    func close() {
        connection.cancel()
    }

    static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code): return String(cString: strerror(code.rawValue))
        case .dns(let code): return "DNS lookup failed (\(code))"
        case .tls(let status):
            return "TLS error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
        default: return "\(error)"
        }
    }
}

/// Resume-once guard for continuations driven by callbacks that may fire
/// more than once (state handlers).
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}
