import Foundation
import HmunmawiCore
import HmunmawiProtocol
import SwiftUI

/// What a text field accepts. Every field in the app filters as you type: a hard length cap, no control or
/// invisible characters (zero-width, bidi overrides), and the field's own character set. Odd input is
/// clamped on entry, so nothing oversized or malformed reaches the Keychain, UserDefaults or a request.
enum InputRule {
    case name            // a short label: letters, digits, spaces, common punctuation; 80
    case identifier      // key/issuer/project IDs, bundle IDs: A–Z a–z 0–9 . _ - ; 128
    case list            // comma-separated names or IDs; 1,000
    case url             // web address; 2,048, no spaces
    case path            // a file path; 1,024
    case secret          // API keys and tokens; one line, no spaces; 4,096
    case pem             // a private key file's text; keeps line breaks; 8,192
    case short           // price, region and similar; 40
    case number          // a count or amount: digits and one dot only; 8
    case numberList      // "30,7,1": digits and commas; 40
    case text(Int)       // free text with its own cap

    var cap: Int {
        switch self {
        case .name: 80; case .identifier: 128; case .list: 1000; case .url: 2048; case .path: 1024
        case .secret: 4096; case .pem: 8192; case .short: 40; case .number: 8; case .numberList: 40; case .text(let n): n
        }
    }

    /// The cleaned value: allowed characters only, capped.
    func clean(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            if out.count >= cap { break }
            if Self.invisible.contains(u) { continue }
            let isNewline = u == "\n"
            if CharacterSet.controlCharacters.contains(u) && !(isNewline && self.keepsNewlines) { continue }
            if !allows(u) { continue }
            out.append(u)
        }
        return String(out)
    }

    private var keepsNewlines: Bool { if case .pem = self { return true }; return false }

    private func allows(_ u: Unicode.Scalar) -> Bool {
        switch self {
        case .identifier: return CharacterSet.alphanumerics.contains(u) && u.isASCII || "._-:".unicodeScalars.contains(u)
        case .url, .secret: return u.isASCII && !CharacterSet.whitespacesAndNewlines.contains(u)
        case .pem: return u.isASCII
        case .number: return CharacterSet.decimalDigits.contains(u) && u.isASCII || u == "."
        case .numberList: return CharacterSet.decimalDigits.contains(u) && u.isASCII || u == ","
        default: return true
        }
    }

    /// Zero-width and direction-override characters that can disguise what a value really says.
    private static let invisible = CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{2060}\u{FEFF}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}")

    /// For settings declared by add-ons: secrets and addresses get the strict rules, the rest a fair cap.
    static func forSetting(key: String, type: String) -> InputRule {
        if type.hasPrefix("secret") { return key.lowercased().contains("pem") || key.lowercased().contains("privatekey") ? .pem : .secret }
        let k = key.lowercased()
        if k.contains("url") || k.contains("address") || k.contains("webhook") { return .url }
        if k.hasSuffix("id") || k.contains("number") || k.contains("region") { return .identifier }
        return .text(512)
    }
}

extension View {
    /// Filters the bound text as it is typed (see `InputRule`).
    func input(_ rule: InputRule, _ text: Binding<String>) -> some View {
        onChange(of: text.wrappedValue) { _, new in
            let c = rule.clean(new)
            if c != new { text.wrappedValue = c }
        }
    }

    /// Keeps a whole number inside a range as it is typed.
    func clamp(_ value: Binding<Int>, _ range: ClosedRange<Int>) -> some View {
        onChange(of: value.wrappedValue) { _, new in
            let c = min(max(new, range.lowerBound), range.upperBound)
            if c != new { value.wrappedValue = c }
        }
    }

    /// Keeps a number inside a sensible range as it is typed.
    func clamp(_ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        onChange(of: value.wrappedValue) { _, new in
            let c = new.isFinite ? min(max(new, range.lowerBound), range.upperBound) : range.lowerBound
            if c != new { value.wrappedValue = c }
        }
    }
}

/// Checks for values that arrive whole (pasted addresses, loaded files).
enum InputCheck {
    /// An https address with a host, or nil.
    static func httpsURL(_ s: String) -> URL? {
        guard let u = URL(string: InputRule.url.clean(s.trimmingCharacters(in: .whitespacesAndNewlines))),
              u.scheme?.lowercased() == "https", let host = u.host, !host.isEmpty, !isInternalHost(host) else { return nil }
        return u
    }

    /// Addresses that point back into this Mac or its own network (an agent or a pasted link must not make the app
    /// call them): localhost, .local / .internal names, and loopback, private, link-local or unspecified IP numbers.
    static func isInternalHost(_ raw: String) -> Bool {
        let h = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        if h == "localhost" || h.hasSuffix(".localhost") || h.hasSuffix(".local") || h.hasSuffix(".internal") || h.hasSuffix(".lan") || h.hasSuffix(".home.arpa") { return true }
        let parts = h.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) {
            let (a, b) = (parts[0], parts[1])
            return a == 0 || a == 10 || a == 127 || (a == 169 && b == 254) || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) || (a == 100 && (64...127).contains(b)) || a >= 224
        }
        // A single number or hex form (http://2130706433, 0x7f000001) is an IP in disguise.
        if h.allSatisfy({ $0.isNumber }) || h.hasPrefix("0x") { return true }
        if h.contains(":") {   // IPv6 literal
            return h == "::" || h == "::1" || h.hasPrefix("fe80") || h.hasPrefix("fc") || h.hasPrefix("fd") || h.hasPrefix("::ffff:")
        }
        return false
    }
}

/// Web reads the app makes for checks (links, outreach pages): http(s) to a public host only, checked again on every
/// redirect, and a 30-second limit for the whole read.
final class WebGuard: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = WebGuard()
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForResource = 30
        return URLSession(configuration: c)
    }()

    static func allowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty, url.user == nil else { return false }
        return !InputCheck.isInternalHost(host)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        request.url.map(Self.allowed) == true ? request : nil
    }
}

/// An error in words the owner can read: the add-on or database message when there is one, never a Swift dump.
func plainError(_ error: any Error) -> String {
    if let w = error as? WireError { return w.message }
    if let q = error as? SQLiteError { return q.plain }
    return error.localizedDescription
}


/// A destructive button that asks first (Apple HIG: confirm actions that can't be undone).
struct ConfirmButton: View {
    let title: String
    let question: String
    let detail: String
    let action: () -> Void
    @State private var asking = false
    var body: some View {
        Button(title, role: .destructive) { asking = true }
            .confirmationDialog(question, isPresented: $asking) {
                Button(title, role: .destructive, action: action)
                Button("Cancel", role: .cancel) {}
            } message: { Text(detail) }
    }
}
