import Foundation

/// Keeps drafts and reply ideas on your own topics. `topics`: at least one must appear (empty = anything goes);
/// `avoid`: none may appear. Ignoring case, a topic must start at a word ("health" matches "HealthKit", "ai"
/// matches "AI tools" but not "said"); an avoided phrase must be whole words ("app store" matches "App Store's").
/// Pure: no files, no network.
public enum TopicFilter {
    /// "HealthKit, SwiftUI , indie apps" -> ["healthkit", "swiftui", "indie apps"] (at most 40 phrases of 60 characters).
    public static func list(_ text: String?) -> [String] {
        (text ?? "").split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && $0.count <= 60 }
            .prefix(40).map { $0 }
    }

    /// True when `phrase` appears in `text` as whole words (or, with `wholeWord` false, starting at a word).
    public static func contains(_ text: String, phrase: String, wholeWord: Bool = true) -> Bool {
        let hay = text.lowercased(), needle = phrase.lowercased()
        guard !needle.isEmpty else { return false }
        var search = hay.startIndex..<hay.endIndex
        while let r = hay.range(of: needle, range: search) {
            let beforeOK = r.lowerBound == hay.startIndex || !isWordChar(hay[hay.index(before: r.lowerBound)])
            let afterOK = !wholeWord || r.upperBound == hay.endIndex || !isWordChar(hay[r.upperBound])
                // "app" also matches "apps" and "app's": a plain plural or possessive is the same topic.
                || plural(hay, after: r.upperBound)
            // A phrase that itself starts or ends with a non-word character ("c++", ".net") is matched as written.
            let edgesOK = (beforeOK || !isWordChar(needle.first!)) && (afterOK || !isWordChar(needle.last!))
            if edgesOK { return true }
            search = r.upperBound..<hay.endIndex
        }
        return false
    }

    /// Why the text is off-topic, or nil when it's fine.
    public static func problem(_ text: String, topics: [String], avoid: [String]) -> String? {
        if let bad = avoid.first(where: { contains(text, phrase: $0) }) { return "mentions “\(bad)”, which you avoid" }
        if !topics.isEmpty, !topics.contains(where: { contains(text, phrase: $0, wholeWord: false) }) { return "off your topics" }
        return nil
    }

    private static func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

    private static func plural(_ s: String, after i: String.Index) -> Bool {
        let rest = s[i...]
        for suffix in ["s", "es", "'s", "’s"] where rest.hasPrefix(suffix) {
            let end = rest.index(rest.startIndex, offsetBy: suffix.count)
            if end == s.endIndex || !isWordChar(s[end]) { return true }
        }
        return false
    }
}
