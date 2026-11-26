import Foundation

/// Outbound SMTP client over SMTPS (port 465) or STARTTLS (port 587). Plaintext port 25 is always refused.
/// Used only when the owner approves an outbound outreach email in Log → Waiting.
public struct SMTPConfig: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var username: String
    public var password: String
    public var from: String

    public init(host: String, port: Int = 465, username: String, password: String, from: String? = nil) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.from = (from ?? username).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A plain-words reason this SMTP setup can't be used, or nil.
    public var problem: String? {
        let h = host.trimmingCharacters(in: .whitespaces)
        if h.isEmpty || h.count > 253 || !h.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) || !h.contains(".") {
            return "SMTP server name looks wrong (for example smtp.zoho.in or smtp.gmail.com)."
        }
        if port == 25 {
            return "Plaintext port 25 is refused. Use 465 (SMTPS) or 587 (STARTTLS)."
        }
        if port != 465 && port != 587 {
            return "SMTP port must be 465 (SMTPS) or 587 (STARTTLS)."
        }
        if username.isEmpty || username.count > 254 { return "Enter your SMTP username or email address." }
        if password.isEmpty || password.count > 200 { return "Enter the SMTP app password." }
        if !Self.isSingleEmail(from) { return "Sender email address looks wrong." }
        for s in [username, password, from] where !s.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7f }) {
            return "Use plain ASCII letters, numbers and symbols for SMTP credentials and addresses."
        }
        return nil
    }

    public static func isSingleEmail(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count <= 254, !s.contains(where: { $0.isNewline || $0 == "," || $0 == ";" || $0 == "<" || $0 == ">" }) else {
            return false
        }
        return s.wholeMatch(of: /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/) != nil
    }
}

public struct SMTPMessage: Sendable, Equatable {
    public var to: String
    public var subject: String
    public var body: String
    public var inReplyTo: String?

    public init(to: String, subject: String, body: String, inReplyTo: String? = nil) {
        self.to = to.trimmingCharacters(in: .whitespacesAndNewlines)
        self.subject = subject
        self.body = body
        self.inReplyTo = inReplyTo
    }

    public var problem: String? {
        guard SMTPConfig.isSingleEmail(to) else { return "Recipient address must be one valid email address." }
        guard !subject.contains(where: \.isNewline), !subject.trimmingCharacters(in: .whitespaces).isEmpty else {
            return "Subject can't be blank or contain line breaks."
        }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Email body is empty." }
        return nil
    }
}

public struct SMTPError: Error, Sendable, Equatable {
    public let message: String
    public init(_ m: String) { message = m }
}

public protocol SMTPTransport: Sendable {
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func upgradeToTLS() async throws
    func close()
}

public actor SMTPSession {
    private let transport: SMTPTransport
    private var buffer = Data()

    public init(transport: SMTPTransport) { self.transport = transport }

    private func readLine() async throws -> String {
        while true {
            if let r = buffer.range(of: Data("\r\n".utf8)) {
                let line = String(decoding: buffer[buffer.startIndex..<r.lowerBound], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex..<r.upperBound)
                return line
            }
            if let r = buffer.range(of: Data("\n".utf8)) {
                let line = String(decoding: buffer[buffer.startIndex..<r.lowerBound], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex..<r.upperBound)
                return line
            }
            guard buffer.count < 64_000 else { throw SMTPError("The mail server sent an unexpectedly long line.") }
            let d = try await transport.receive()
            if d.isEmpty { throw SMTPError("The mail server closed the connection.") }
            buffer.append(d)
        }
    }

    /// Reads a full single- or multi-line SMTP reply (e.g. `250-` lines followed by `250 `).
    public func readReply() async throws -> (code: Int, lines: [String]) {
        var lines: [String] = []
        while true {
            let line = try await readLine()
            lines.append(line)
            guard line.count >= 3, let code = Int(line.prefix(3)) else {
                throw SMTPError("The mail server sent an unexpected reply.")
            }
            let sep = line.dropFirst(3).first
            if sep == nil || sep == " " {
                return (code, lines)
            }
            if lines.count > 100 { throw SMTPError("The mail server sent too many lines.") }
        }
    }

    public func command(_ line: String, expect: Set<Int>, secret: Bool = false) async throws -> [String] {
        try await transport.send(Data((line + "\r\n").utf8))
        let reply = try await readReply()
        guard expect.contains(reply.code) else {
            if secret || reply.code == 535 {
                throw SMTPError("The SMTP server refused the login. Check your address and app password.")
            }
            let detail = reply.lines.last ?? "status \(reply.code)"
            throw SMTPError("The SMTP server refused the request: \(String(detail.prefix(140)))")
        }
        return reply.lines
    }

    public func close() { transport.close() }
}

public enum SMTPClient {
    public static func send(_ message: SMTPMessage, config: SMTPConfig, transport: SMTPTransport, now: Date = .now) async throws {
        if let p = config.problem { throw SMTPError(p) }
        if let p = message.problem { throw SMTPError(p) }

        let session = SMTPSession(transport: transport)
        defer { Task { await session.close() } }

        let greet = try await session.readReply()
        guard greet.code == 220 else { throw SMTPError("The mail server didn't greet us as an SMTP server.") }

        let ehloDomain = config.from.split(separator: "@").last.map(String.init) ?? "localhost"
        var caps = try await session.command("EHLO \(ehloDomain)", expect: [250])

        if config.port == 587 {
            let hasStartTLS = caps.contains { $0.uppercased().contains("STARTTLS") }
            guard hasStartTLS else { throw SMTPError("The SMTP server on port 587 did not offer STARTTLS.") }
            _ = try await session.command("STARTTLS", expect: [220])
            try await transport.upgradeToTLS()
            caps = try await session.command("EHLO \(ehloDomain)", expect: [250])
        }

        let authText = caps.filter { $0.uppercased().contains("AUTH") }.joined(separator: " ").uppercased()
        if authText.contains("PLAIN") || !authText.contains("LOGIN") {
            let token = Data("\0\(config.username)\0\(config.password)".utf8).base64EncodedString()
            _ = try await session.command("AUTH PLAIN \(token)", expect: [235], secret: true)
        } else {
            _ = try await session.command("AUTH LOGIN", expect: [334], secret: true)
            _ = try await session.command(Data(config.username.utf8).base64EncodedString(), expect: [334], secret: true)
            _ = try await session.command(Data(config.password.utf8).base64EncodedString(), expect: [235], secret: true)
        }

        _ = try await session.command("MAIL FROM:<\(config.from)>", expect: [250])
        _ = try await session.command("RCPT TO:<\(message.to)>", expect: [250, 251])
        _ = try await session.command("DATA", expect: [354])
        let wire = buildPayload(message: message, from: config.from, now: now)
        try await transport.send(Data(wire.utf8))
        let dataReply = try await session.readReply()
        guard dataReply.code == 250 else {
            throw SMTPError("The SMTP server didn't accept the message: \(String((dataReply.lines.last ?? "").prefix(120)))")
        }
        _ = try? await session.command("QUIT", expect: [221, 250])
    }

    static func buildPayload(message: SMTPMessage, from: String, now: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let domain = from.split(separator: "@").last.map(String.init) ?? "hmunmawi.local"
        let msgID = "<hm-\(UUID().uuidString.lowercased())@\(domain)>"
        let subj = encodeHeader(message.subject)
        var headers = [
            "From: <\(from)>",
            "To: <\(message.to)>",
            "Subject: \(subj)",
            "Date: \(fmt.string(from: now))",
            "Message-ID: \(msgID)",
        ]
        if let replyTo = message.inReplyTo?.trimmingCharacters(in: .whitespacesAndNewlines),
           !replyTo.isEmpty, !replyTo.contains(where: \.isNewline) {
            let clean = replyTo.hasPrefix("<") ? replyTo : "<\(replyTo)>"
            headers.append("In-Reply-To: \(clean)")
            headers.append("References: \(clean)")
        }
        headers += [
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=UTF-8",
            "Content-Transfer-Encoding: 8bit",
        ]
        let normalizedBody = message.body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let s = String(line)
                return s.hasPrefix(".") ? "." + s : s
            }
            .joined(separator: "\r\n")
        return headers.joined(separator: "\r\n") + "\r\n\r\n" + normalizedBody + "\r\n.\r\n"
    }

    static func encodeHeader(_ s: String) -> String {
        if s.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7f }) { return s }
        return "=?UTF-8?B?\(Data(s.utf8).base64EncodedString())?="
    }
}

/// Live TLS/STARTTLS stream transport backed by URLSessionStreamTask (system certificate checks + timeout).
public final class SMTPStreamTransport: SMTPTransport, @unchecked Sendable {
    private let session: URLSession
    private let task: URLSessionStreamTask
    private let timeout: TimeInterval

    public init(host: String, port: Int, timeout: TimeInterval = 25) {
        let session = URLSession(configuration: .ephemeral)
        self.session = session
        self.task = session.streamTask(withHostName: host, port: port)
        self.timeout = timeout
        if port == 465 {
            self.task.startSecureConnection()
        }
        self.task.resume()
    }

    public func upgradeToTLS() async throws {
        task.startSecureConnection()
    }

    public func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            task.write(data, timeout: timeout) { error in
                if let error { c.resume(throwing: SMTPError("Couldn't send to the SMTP server (\(error.localizedDescription)).")) }
                else { c.resume() }
            }
        }
    }

    public func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            task.readData(ofMinLength: 1, maxLength: 65_536, timeout: timeout) { data, atEOF, error in
                if let error { c.resume(throwing: SMTPError("Couldn't read from the SMTP server (\(error.localizedDescription)).")) }
                else if let data, !data.isEmpty { c.resume(returning: data) }
                else { _ = atEOF; c.resume(returning: Data()) }
            }
        }
    }

    public func close() { task.closeRead(); task.closeWrite(); task.cancel(); session.finishTasksAndInvalidate() }
}
