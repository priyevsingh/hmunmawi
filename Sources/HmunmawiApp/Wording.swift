import Foundation
import HmunmawiCore

/// "Words I never use" (Settings → Rules): the file `wording-rules.json` in Hmunmawi's folder, read fresh each
/// time (it's small), so a script or an agent can edit it too.
enum Wording {
    static var url: URL { URL.hmSupport.appending(path: WordingRules.fileName) }
    static var rules: WordingRules { WordingRules.load(url) }

    /// Saves the rules (atomically) and returns any that couldn't be used.
    @discardableResult
    static func save(_ rules: [WordingRules.Rule]) -> [String] {
        let data = WordingRules.encode(rules)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        return WordingRules.parse(data).problems
    }

    /// One rule per line: "phrase" or "phrase | why" (a `re:` pattern works too).
    static func lines(_ rules: [WordingRules.Rule]) -> String {
        rules.map { r in r.why.map { "\(r.text) | \($0)" } ?? r.text }.joined(separator: "\n")
    }

    static func parseLines(_ text: String) -> [WordingRules.Rule] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = parts.first, !first.isEmpty else { return nil }
            return WordingRules.Rule(text: String(first.prefix(300)), why: parts.count > 1 && !parts[1].isEmpty ? String(parts[1].prefix(200)) : nil)
        }.prefix(WordingRules.maxRules).map { $0 }
    }
}
