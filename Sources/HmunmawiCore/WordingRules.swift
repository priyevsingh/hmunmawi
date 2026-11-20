import Foundation

/// Words you never use: claims you can't back up ("the most accurate"), wording a store or a law forbids
/// ("guaranteed results", "clinically proven"), names you mustn't mention yet. One JSON file you, your scripts or
/// your agents edit: `{"never": [{"text": "clinically proven", "why": "no clinical study"}, "best app ever",
/// {"text": "re:\\bno (cloud|servers?)\\b", "why": "absolute privacy claim"}]}`.
/// A plain entry matches as whole words, ignoring case; `re:` starts a regular expression (ignoring case).
/// Post drafts and reply ideas that hit a rule are refused; `hm lint-text` checks any text. Pure apart from `load`.
public struct WordingRules: Sendable, Equatable {
    public struct Rule: Sendable, Equatable {
        public let text: String
        public let why: String?
        public init(text: String, why: String? = nil) { self.text = text; self.why = why }
        public var isPattern: Bool { text.hasPrefix("re:") }
    }

    public struct Hit: Sendable, Equatable {
        public let rule: String
        public let why: String?
        public let found: String
    }

    public var rules: [Rule]
    /// Entries that couldn't be used (an invalid pattern), so the settings can say which.
    public var problems: [String]

    public init(rules: [Rule] = [], problems: [String] = []) { self.rules = rules; self.problems = problems }

    public static let fileName = "wording-rules.json"
    public static let maxRules = 300

    /// Reads the rules file; a missing or empty file is no rules.
    public static func load(_ url: URL) -> WordingRules {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return WordingRules() }
        return parse(data)
    }

    public static func parse(_ data: Data) -> WordingRules {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return WordingRules(problems: ["The file isn't a JSON object like {\"never\": [...]}."])
        }
        var rules: [Rule] = [], problems: [String] = []
        for entry in (obj["never"] as? [Any] ?? []).prefix(maxRules) {
            let text: String?, why: String?
            if let s = entry as? String { text = s; why = nil }
            else if let o = entry as? [String: Any] { text = o["text"] as? String; why = o["why"] as? String }
            else { text = nil; why = nil }
            guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, t.count <= 300 else { continue }
            if t.hasPrefix("re:"), (try? Regex(String(t.dropFirst(3)))) == nil {
                problems.append("Not a valid pattern: \(t)")
                continue
            }
            rules.append(Rule(text: t, why: why?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty))
        }
        return WordingRules(rules: rules, problems: problems)
    }

    /// The file's text for a list of rules (what Settings saves).
    public static func encode(_ rules: [Rule]) -> Data {
        let list: [Any] = rules.map { r -> Any in
            if let why = r.why { return ["text": r.text, "why": why] }
            return r.text
        }
        return (try? JSONSerialization.data(withJSONObject: ["never": list], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    /// Every rule the text breaks (each rule once).
    public func hits(_ text: String) -> [Hit] {
        rules.compactMap { r in
            if r.isPattern {
                guard let re = try? Regex(String(r.text.dropFirst(3))).ignoresCase(),
                      let m = try? re.firstMatch(in: text) else { return nil }
                return Hit(rule: r.text, why: r.why, found: String(text[m.range]))
            }
            guard TopicFilter.contains(text, phrase: r.text) else { return nil }
            return Hit(rule: r.text, why: r.why, found: r.text)
        }
    }

    /// Why a draft is refused, or nil.
    public func problem(_ text: String) -> String? {
        guard let h = hits(text).first else { return nil }
        return "uses “\(h.found)”, which you never say" + (h.why.map { " (\($0))" } ?? "")
    }
}

fileprivate extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
