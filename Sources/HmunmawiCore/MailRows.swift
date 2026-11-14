import Foundation

/// One message as a mail source lists it (headers only, no body): what the outreach reply watch needs.
public struct MailRow: Sendable, Equatable {
    public var id: String
    public var from: String
    public var subject: String
    public var folder: String          // "INBOX" or "SENT"
    public var sentMs: Int64?
    public var messageID: String?
    public var inReplyTo: String?
    public init(id: String, from: String, subject: String, folder: String, sentMs: Int64?, messageID: String?, inReplyTo: String?) {
        self.id = id; self.from = from; self.subject = subject; self.folder = folder
        self.sentMs = sentMs; self.messageID = messageID; self.inReplyTo = inReplyTo
    }
}

/// Reading mail headers the way RFC 5322 and RFC 2047 write them. Pure text handling, so it is tested without a server.
public enum MailHeaders {
    /// "Name: value" lines with continuation lines (starting with space or tab) folded into the value. Names lowercased.
    public static func parse(_ block: String) -> [String: String] {
        var out: [String: String] = [:], name: String?, value = ""
        func flush() { if let n = name, out[n] == nil { out[n] = value.trimmingCharacters(in: .whitespaces) } }
        for raw in block.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.first == " " || line.first == "\t" { value += " " + line.trimmingCharacters(in: .whitespaces); continue }
            flush(); name = nil; value = ""
            if let colon = line.firstIndex(of: ":"), colon != line.startIndex {
                name = line[..<colon].lowercased(); value = String(line[line.index(after: colon)...])
            }
        }
        flush()
        return out
    }

    /// "=?UTF-8?B?...?=" and "=?UTF-8?Q?...?=" words turned into text (other text is left as it is).
    public static func decodeWords(_ s: String) -> String {
        guard s.contains("=?") else { return s }
        var result = "", rest = Substring(s), lastWasWord = false
        while let start = rest.range(of: "=?") {
            let before = rest[..<start.lowerBound]
            let tail = rest[start.upperBound...]
            let parts = tail.split(separator: "?", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4, parts[3].hasPrefix("="), let enc = parts[1].lowercased().first, "bq".contains(enc) else {
                result += rest[..<start.upperBound]; rest = rest[start.upperBound...]; lastWasWord = false; continue
            }
            let charset = String(parts[0]).lowercased()
            let payload = String(parts[2])
            var data: Data?
            if enc == "b" { data = Data(base64Encoded: payload.padding(toLength: (payload.count + 3) / 4 * 4, withPad: "=", startingAt: 0)) }
            else {
                var bytes: [UInt8] = [], chars = Array(payload.utf8), i = 0
                while i < chars.count {
                    if chars[i] == UInt8(ascii: "_") { bytes.append(0x20); i += 1 }
                    else if chars[i] == UInt8(ascii: "="), i + 2 < chars.count + 0, let b = UInt8(String(decoding: chars[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) { bytes.append(b); i += 3 }
                    else { bytes.append(chars[i]); i += 1 }
                }
                data = Data(bytes)
            }
            let encoding: String.Encoding = charset.contains("8859-1") || charset == "latin1" ? .isoLatin1 : charset.contains("1252") ? .windowsCP1252 : .utf8
            let text = data.flatMap { String(data: $0, encoding: encoding) } ?? ""
            // Whitespace between two encoded words is not part of the text.
            if !(lastWasWord && before.allSatisfy(\.isWhitespace)) { result += before }
            result += text
            lastWasWord = true
            rest = parts[3].dropFirst(1)   // after "?="
        }
        return result + rest
    }

    /// The Date header as milliseconds, or nil.
    public static func dateMs(_ s: String?) -> Int64? {
        guard var s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if let paren = s.firstIndex(of: "(") { s = String(s[..<paren]).trimmingCharacters(in: .whitespaces) }   // "(UTC)" comments
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "EEE, d MMM yyyy HH:mm:ss zzz"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return Int64(d.timeIntervalSince1970 * 1000) }
        }
        return nil
    }

    /// Message-ID style value without angle brackets, first one only.
    public static func messageID(_ s: String?) -> String? {
        guard let s, let a = s.firstIndex(of: "<"), let b = s[a...].firstIndex(of: ">") else { return s.flatMap { $0.isEmpty ? nil : $0 } }
        return String(s[s.index(after: a)..<b])
    }

    /// One row from a header block (From, Subject, Date, Message-ID, In-Reply-To).
    public static func row(id: String, folder: String, block: String) -> MailRow {
        let h = parse(block)
        return MailRow(id: id, from: decodeWords(h["from"] ?? ""), subject: decodeWords(h["subject"] ?? ""), folder: folder,
                       sentMs: dateMs(h["date"]), messageID: messageID(h["message-id"]), inReplyTo: messageID(h["in-reply-to"]))
    }
}
