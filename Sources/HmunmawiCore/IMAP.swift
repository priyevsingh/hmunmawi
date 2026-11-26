import Foundation
import Network

/// A read-only IMAP reader for the outreach reply watch. It only ever opens folders with EXAMINE (read-only) and reads
/// headers with BODY.PEEK (which never marks anything as read). It never sends, moves, flags or deletes a message.
public struct IMAPConfig: Sendable, Equatable {
    public var host: String, port: Int, username: String, password: String
    public init(host: String, port: Int = 993, username: String, password: String) {
        self.host = host; self.port = port; self.username = username; self.password = password
    }
    /// A plain-words reason this setup can't be used, or nil. Checked as it is typed and again before connecting.
    public var problem: String? {
        let h = host.trimmingCharacters(in: .whitespaces)
        if h.isEmpty || h.count > 253 || !h.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) || !h.contains(".") {
            return "Server name looks wrong (for example imap.zoho.in)."
        }
        if !(1...65535).contains(port) { return "Port must be a number from 1 to 65535 (usually 993)." }
        if username.isEmpty || username.count > 254 { return "Enter your email address or username." }
        if password.isEmpty || password.count > 200 { return "Enter the app password." }
        for s in [username, password] where !s.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7f }) {
            return "Use an app password and username with plain letters, numbers and symbols (no accents or spaces at the ends)."
        }
        return nil
    }
}

public protocol IMAPTransport: Sendable {
    func send(_ data: Data) async throws
    /// The next bytes from the server; throws when the connection closes or goes quiet.
    func receive() async throws -> Data
    func close()
}

public struct IMAPError: Error, Sendable { public let message: String; public init(_ m: String) { message = m } }

/// One answer line, or the bytes of a "{n}" literal that followed it.
public enum IMAPItem: Sendable, Equatable { case line(String), literal(String) }

public actor IMAPSession {
    /// One header block, and everything one command may bring back (300 messages' headers fit easily).
    static let maxLiteralBytes = 1_000_000
    static let maxAnswerBytes = 20_000_000
    private let transport: IMAPTransport
    private var buffer = Data()
    private var tagNumber = 0

    public init(transport: IMAPTransport) { self.transport = transport }

    private func fill() async throws { let d = try await transport.receive(); if d.isEmpty { throw IMAPError("The mail server closed the connection.") }; buffer.append(d) }

    private func readLine() async throws -> String {
        while true {
            if let r = buffer.range(of: Data("\r\n".utf8)) {
                let line = String(decoding: buffer[buffer.startIndex..<r.lowerBound], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex..<r.upperBound)
                return line
            }
            guard buffer.count < 200_000 else { throw IMAPError("The mail server sent an unexpected answer.") }
            try await fill()
        }
    }

    private func readBytes(_ n: Int) async throws -> Data {
        guard n >= 0, n <= 200_000 else { throw IMAPError("The mail server sent an unexpectedly large header.") }
        while buffer.count < n { try await fill() }
        let d = buffer.prefix(n); buffer.removeFirst(n); return Data(d)
    }

    public func greeting() async throws {
        let line = try await readLine()
        guard line.hasPrefix("* OK") || line.hasPrefix("* PREAUTH") else { throw IMAPError("The mail server didn't greet us as an IMAP server.") }
    }

    /// Sends one command and returns everything the server said until it finished it.
    @discardableResult
    public func command(_ text: String, secret: Bool = false) async throws -> [IMAPItem] {
        tagNumber += 1
        let tag = "h\(tagNumber)"
        try await transport.send(Data("\(tag) \(text)\r\n".utf8))
        var items: [IMAPItem] = []
        var literalTotal = 0
        while true {
            let line = try await readLine()
            if line.hasPrefix(tag + " ") {
                let status = line.dropFirst(tag.count + 1)
                guard status.hasPrefix("OK") else {
                    // The server's words may repeat what was sent; the password never reaches a message.
                    throw IMAPError(Self.plain(String(status), secret: secret))
                }
                return items
            }
            items.append(.line(line))
            if line.hasSuffix("}"), let open = line.lastIndex(of: "{"), let n = Int(line[line.index(after: open)..<line.index(before: line.endIndex)]) {
                // Headers only: one block is small. A negative or huge size is a broken or hostile server.
                guard (0...Self.maxLiteralBytes).contains(n) else { throw IMAPError("The mail server sent an unexpected answer.") }
                literalTotal += n
                guard literalTotal <= Self.maxAnswerBytes else { throw IMAPError("The mail server sent more than expected.") }
                items.append(.literal(String(decoding: try await readBytes(n), as: UTF8.self)))
            }
        }
    }

    static func plain(_ status: String, secret: Bool) -> String {
        if secret || status.uppercased().contains("AUTHENTICATIONFAILED") || status.uppercased().hasPrefix("NO") && status.uppercased().contains("LOGIN") {
            return "The mail server refused the login. Check the address and the app password (many providers need a special app password, not your normal one)."
        }
        return "The mail server said: " + String(status.prefix(120))
    }

    public func close() { transport.close() }
}

public enum IMAPMail {
    public static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The folder name in a LIST answer: `* LIST (\\Sent) "/" "Sent Items"`.
    static func listName(_ line: String) -> String? {
        guard let close = line.firstIndex(of: ")") else { return nil }
        var rest = Substring(line[line.index(after: close)...].trimmingCharacters(in: .whitespaces))
        if rest.hasPrefix("\"") {                                  // the separator, quoted: "/"
            guard let end = rest.dropFirst().firstIndex(of: "\"") else { return nil }
            rest = rest[rest.index(after: end)...]
        } else if rest.uppercased().hasPrefix("NIL") { rest = rest.dropFirst(3) }
        let name = rest.trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 { return String(name.dropFirst().dropLast()) }
        return name.isEmpty ? nil : name
    }

    /// The days-back search date in the form IMAP wants ("06-Nov-2026").
    static func searchDate(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "dd-MMM-yyyy"
        return f.string(from: d)
    }

    /// Mail from the last `days` days in the Inbox and the Sent folder (headers, plus read-only PEEK body text
    /// for inbox messages matching `matchOutreach`), newest `limit` per folder.
    public static func fetch(_ config: IMAPConfig, transport: IMAPTransport, days: Int = 30, limit: Int = 300,
                             now: Date = .now, matchOutreach: @Sendable (MailRow) -> Bool = { _ in false }) async throws -> [MailRow] {
        if let p = config.problem { throw IMAPError(p) }
        let session = IMAPSession(transport: transport)
        defer { Task { await session.close() } }
        try await session.greeting()
        try await session.command("LOGIN \(quoted(config.username)) \(quoted(config.password))", secret: true)
        let account = String("\(config.username)@\(config.host)".utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }, radix: 36)
        // Which folder is Sent: the one the server flags \Sent, else a folder called Sent / Sent Items / Sent Mail.
        let listing = try await session.command("LIST \"\" \"*\"")
        var sent: String?
        for case .line(let l) in listing where l.hasPrefix("* LIST") && !l.contains("\\Noselect") {
            guard let folder = listName(l) else { continue }
            if l.contains("\\Sent") { sent = folder; break }
            if sent == nil, folder.lowercased().hasPrefix("sent") { sent = folder }
        }
        var rows: [MailRow] = []
        for (folder, tag) in [("INBOX", "INBOX"), sent.map { ($0, "SENT") }].compactMap({ $0 }) {
            let exam = try await session.command("EXAMINE \(quoted(folder))")      // read-only
            let validity = exam.compactMap { item -> String? in
                guard case .line(let l) = item, let r = l.range(of: "[UIDVALIDITY ") else { return nil }
                return String(l[r.upperBound...].prefix { $0.isNumber })
            }.first ?? "0"
            let since = now.addingTimeInterval(-Double(days) * 86_400)
            let found = try await session.command("UID SEARCH SINCE \(searchDate(since))")
            let uids = found.compactMap { item -> [String]? in
                guard case .line(let l) = item, l.hasPrefix("* SEARCH") else { return nil }
                return l.dropFirst(8).split(separator: " ").map(String.init)
            }.flatMap { $0 }.compactMap(Int.init)
            var matchedUIDs: [(uid: String, index: Int)] = []
            for chunk in stride(from: max(0, uids.count - limit), to: uids.count, by: 50).map({ Array(uids[$0..<min($0 + 50, uids.count)]) }) {
                let set = chunk.map(String.init).joined(separator: ",")
                let items = try await session.command("UID FETCH \(set) (UID BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE MESSAGE-ID IN-REPLY-TO)])")
                var uid: String?
                for item in items {
                    switch item {
                    case .line(let l):
                        if let r = l.range(of: "UID ") { uid = String(l[r.upperBound...].prefix { $0.isNumber }) }
                    case .literal(let block):
                        if let u = uid {
                            let row = MailHeaders.row(id: "imap-\(account)-\(tag)-\(validity)-\(u)", folder: tag, block: block)
                            let idx = rows.count
                            rows.append(row)
                            if tag == "INBOX", matchOutreach(row) {
                                matchedUIDs.append((u, idx))
                            }
                        }
                        uid = nil
                    }
                }
            }
            // Second pass (read-only EXAMINE + BODY.PEEK[TEXT], capped at 32 KB) ONLY for matching outreach messages.
            for (u, idx) in matchedUIDs.suffix(25) {
                guard let items = try? await session.command("UID FETCH \(u) BODY.PEEK[TEXT]<0.\(MailBodyText.maxRawBytes)>") else { continue }
                for case .literal(let raw) in items {
                    let clean = MailBodyText.clean(raw)
                    if !clean.isEmpty { rows[idx].text = clean }
                    break
                }
            }
        }
        _ = try? await session.command("LOGOUT")
        return rows
    }
}

/// The real connection: TLS from the first byte, the system's certificate checks, a time limit on every wait.
public final class IMAPTLSTransport: IMAPTransport, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "hmunmawi.imap")
    private let timeout: TimeInterval

    public init(host: String, port: Int, timeout: TimeInterval = 25) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? 993, using: .tls)
        self.timeout = timeout
        connection.start(queue: queue)
    }

    public func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { e in e.map { c.resume(throwing: IMAPError("Couldn't reach the mail server (\($0.localizedDescription)).")) } ?? c.resume() })
        }
    }

    public func receive() async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { [connection] in
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isDone, error in
                        if let error { c.resume(throwing: IMAPError("Couldn't reach the mail server (\(error.localizedDescription)).")) }
                        else if let data, !data.isEmpty { c.resume(returning: data) }
                        else { c.resume(returning: Data()) }   // closed
                        _ = isDone
                    }
                }
            }
            group.addTask { [timeout] in
                try await Task.sleep(for: .seconds(timeout)); throw IMAPError("The mail server didn't answer in time.")
            }
            defer { group.cancelAll() }
            return try await group.next() ?? Data()
        }
    }

    public func close() { connection.cancel() }
}
