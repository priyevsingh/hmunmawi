import Foundation

/// Plan steps that name an app version ("Planned for 4.1.8: …") go stale the moment that version ships. This checks a
/// step against what is really live, so Planned steps never tell you to do something already done. Pure.
public enum PlanFreshness {
    /// Version numbers written in the text ("4.1.8", "1.3"); prices ("$2.99"), percentages ("99.87%") and dotted
    /// words are not versions.
    public static func versions(in text: String) -> [[Int]] {
        text.matches(of: /\d{1,3}\.\d{1,3}(?:\.\d{1,3})?/).compactMap { m in
            // What touches the number decides: not after a letter, digit, dot or currency sign; not before a letter, digit, dot or %.
            if m.range.lowerBound > text.startIndex {
                let before = text[text.index(before: m.range.lowerBound)]
                if before.isLetter || before.isNumber || before == "." || "$₹€£".contains(before) { return nil }
            }
            if m.range.upperBound < text.endIndex {
                let after = text[m.range.upperBound]
                if after.isLetter || after.isNumber || after == "." || after == "%" { return nil }
            }
            let parts = String(text[m.range]).split(separator: ".").compactMap { Int($0) }
            return parts.count >= 2 ? parts : nil
        }
    }

    static func atLeast(_ a: [Int], _ b: [Int]) -> Bool {   // a >= b, missing parts count as 0
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return true
    }

    /// True when the step's newest named version is already live: the step is done.
    public static func alreadyLive(_ text: String, liveVersion: String?) -> Bool {
        guard let live = liveVersion?.split(separator: ".").compactMap({ Int($0) }), !live.isEmpty,
              let newest = versions(in: text).max(by: { !atLeast($0, $1) }) else { return false }
        return atLeast(live, newest)
    }

    /// The live version of each app, from the newest release check/snapshot that names one.
    public static func liveVersions(_ events: [StoredEvent]) -> [String: String] {
        var out: [String: String] = [:], seen = Set<String>()
        for e in events.sorted(by: { $0.occurredAt > $1.occurredAt }) where e.kind == "release.check" || e.kind == "release.snapshot" {
            guard let app = e.app, !seen.contains(app), let v = e.payload[path: "live_version"]?.string, !v.isEmpty else { continue }
            seen.insert(app); out[app] = v
        }
        return out
    }

    /// The live version for a plan step's app ("Body Vitals" also matches "Body Vitals: Health Widgets").
    public static func live(for app: String?, in versions: [String: String]) -> String? {
        guard let app, !app.isEmpty else { return nil }
        return versions[app] ?? versions.first { $0.key.hasPrefix(app + ":") || app.hasPrefix($0.key + ":") }?.value
    }

    /// Plan events that are still worth showing.
    /// Steps a script stopped sending (older than `maxAgeDays`) are hidden too: old text is not advice.
    public static func current(_ steps: [StoredEvent], liveVersions: [String: String], now: Date = .now, maxAgeDays: Double = 3) -> [StoredEvent] {
        let oldest = Int64((now.timeIntervalSince1970 - maxAgeDays * 86_400) * 1000)
        return steps.filter { s in
            guard s.occurredAt >= oldest else { return false }
            let text = (s.payload[path: "step"]?.string ?? "") + " " + (s.payload[path: "page"]?.string ?? "")
            return !alreadyLive(text, liveVersion: live(for: s.app, in: liveVersions))
        }
    }
}
