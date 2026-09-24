import Foundation

/// One untagged server response line, with any `{n}` literals it carried
/// pulled out as raw bytes (the text keeps the `{n}` markers in place).
struct ImapResponse: Sendable {
    let text: String
    let literals: [Data]
}

/// A single tagged-command IMAP session over a transport: greeting, then
/// `command()` per RFC 3501 exchange. Handles CRLF framing and literal
/// syntax (`{1234}` + raw bytes), which is all the FETCH parsing needs.
actor ImapConnection {
    private let transport: any ImapTransport
    private var buffer = Data()
    private var tagCounter = 0
    private var closed = false

    static let readTimeout: Double = 20
    private static let crlf = Data("\r\n".utf8)

    init(transport: any ImapTransport) {
        self.transport = transport
    }

    func open() async throws {
        let transport = self.transport
        try await withImapTimeout(seconds: 15, "connecting") { try await transport.open() }
        let greeting = String(decoding: try await readLine(), as: UTF8.self)
        guard greeting.hasPrefix("* OK") || greeting.hasPrefix("* PREAUTH") else {
            throw ImapError.unexpected("greeting: \(greeting)")
        }
    }

    /// A piece of a command line: plain text, or a synchronizing literal
    /// (`{n}` CRLF, wait for the server's "+", then the raw bytes) for
    /// values that can't be sent as a quoted string.
    enum Part: Sendable, Equatable {
        case text(String)
        case literal(Data)
    }

    /// Sends one command and returns its untagged responses. `label` names
    /// the command in errors (never echo LOGIN arguments).
    @discardableResult
    func command(_ text: String, label: String) async throws -> [ImapResponse] {
        try await command([.text(text)], label: label)
    }

    @discardableResult
    func command(_ parts: [Part], label: String) async throws -> [ImapResponse] {
        tagCounter += 1
        let tag = "A\(tagCounter)"
        var untagged: [ImapResponse] = []
        var pending = Data("\(tag) ".utf8)
        for part in parts {
            switch part {
            case .text(let text):
                pending.append(Data(text.utf8))
            case .literal(let bytes):
                pending.append(Data("{\(bytes.count)}\r\n".utf8))
                try await send(pending, label: label)
                pending = bytes
                // The server must say "+" before it takes the literal bytes.
                awaitingContinuation: while true {
                    switch try await readResponse(tag: tag, label: label) {
                    case .continuation: break awaitingContinuation
                    case .untagged(let response): untagged.append(response)
                    case .done: throw ImapError.unexpected("\(label) completed before its literal was sent")
                    }
                }
            }
        }
        pending.append(Self.crlf)
        try await send(pending, label: label)

        while true {
            switch try await readResponse(tag: tag, label: label) {
            case .continuation: continue // not expected after the final line; ignore
            case .untagged(let response): untagged.append(response)
            case .done: return untagged
            }
        }
    }

    private enum Response {
        case continuation
        case untagged(ImapResponse)
        /// The command's tagged OK. NO/BAD are thrown instead.
        case done
    }

    private func readResponse(tag: String, label: String) async throws -> Response {
        var line = try await readLine()
        var literals: [Data] = []
        while let length = Self.literalLength(line) {
            literals.append(try await readExactly(length))
            line.append(try await readLine())
        }
        let str = String(decoding: line, as: UTF8.self)
        if str.hasPrefix(tag + " ") {
            let rest = str.dropFirst(tag.count + 1)
            let status = rest.prefix { $0 != " " }
            let message = rest.dropFirst(status.count).trimmingCharacters(in: .whitespaces)
            if status == "OK" { return .done }
            throw ImapError.server(command: label, message: Self.stripResponseCode(message))
        }
        if str.hasPrefix("+") { return .continuation }
        return .untagged(ImapResponse(text: str, literals: literals))
    }

    private func send(_ payload: Data, label: String) async throws {
        let transport = self.transport
        try await withImapTimeout(seconds: Self.readTimeout, "sending \(label)") { try await transport.send(payload) }
    }

    /// Best-effort LOGOUT, then drop the socket. Safe to call repeatedly.
    func close() async {
        guard !closed else { return }
        closed = true
        _ = try? await withImapTimeout(seconds: 5, "logging out") { [self] in
            try await self.command("LOGOUT", label: "LOGOUT")
        }
        transport.close()
    }

    // MARK: - Framing

    private func readLine() async throws -> Data {
        while true {
            let start = buffer.startIndex
            if let range = buffer.range(of: Self.crlf, in: start..<buffer.endIndex) {
                let line = buffer.subdata(in: start..<range.lowerBound)
                buffer.removeSubrange(start..<range.upperBound)
                return line
            }
            try await fill()
        }
    }

    private func readExactly(_ count: Int) async throws -> Data {
        while buffer.count < count { try await fill() }
        let start = buffer.startIndex
        let bytes = buffer.subdata(in: start..<start + count)
        buffer.removeSubrange(start..<start + count)
        return bytes
    }

    private func fill() async throws {
        let transport = self.transport
        let chunk = try await withImapTimeout(seconds: Self.readTimeout, "waiting for a response") {
            try await transport.receive()
        }
        guard !chunk.isEmpty else { throw ImapError.connection("server closed the connection") }
        buffer.append(chunk)
    }

    /// `{n}` at the very end of a line announces n bytes of literal data.
    static func literalLength(_ line: Data) -> Int? {
        guard line.last == 0x7D, let open = line.lastIndex(of: 0x7B) else { return nil } // "}" / "{"
        let digits = line[line.index(after: open)..<line.index(before: line.endIndex)]
        guard !digits.isEmpty, digits.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        return Int(String(decoding: digits, as: UTF8.self))
    }

    /// "[AUTHENTICATIONFAILED] Invalid credentials" → "Invalid credentials".
    static func stripResponseCode(_ message: String) -> String {
        message.replacingOccurrences(of: #"^\[[^\]]*\]\s*"#, with: "", options: .regularExpression)
    }
}
