import Foundation

/// Turns machine text into words people read: "/compare/athlytic-vs-bevel/" becomes "the Athlytic vs Bevel page".
enum Plain {
    static let small: Set<String> = ["vs", "and", "or", "to", "of", "the", "a", "in", "for", "with"]

    static let path = try! NSRegularExpression(pattern: #"(?<![\w.:])/(?:[a-z0-9-]+/)*[a-z0-9-]+/?(?![\w])"#)

    /// A page path used as a label ("Destinations/thenzawl", "blog/inner-line-permit") → its title ("Thenzawl",
    /// "Inner Line Permit"). Anything that isn't a bare path (no "/", a URL, words with capitals) stays as it is.
    static func pageTitle(_ label: String) -> String {
        let t = label.trimmingCharacters(in: .whitespaces)
        guard t.contains("/"), !t.contains("://"), !t.contains(" · ") else { return label }
        let rest = t.dropFirst()   // the feed capitalises only the first letter
        guard rest == rest.lowercased() else { return label }
        guard let last = t.split(separator: "/").last.map(String.init), !last.isEmpty else { return label }
        let words = last.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            .split(separator: " ").enumerated().map { i, w in
                i > 0 && small.contains(w.lowercased()) ? w.lowercased() : w.prefix(1).uppercased() + w.dropFirst()
            }
        return words.isEmpty ? label : words.joined(separator: " ")
    }

    static func readable(_ text: String) -> String {
        var out = text
        for m in path.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let r = Range(m.range, in: out) else { continue }
            let parts = out[r].split(separator: "/").map(String.init)
            let name: String
            if let last = parts.last, !last.isEmpty {
                let words = last.split(separator: "-").enumerated().map { i, w in
                    i > 0 && small.contains(String(w)) ? String(w) : w.prefix(1).uppercased() + w.dropFirst()
                }
                name = "the \(words.joined(separator: " ")) page"
            } else {
                name = "the home page"
            }
            out.replaceSubrange(r, with: name)
        }
        return out
    }
}
