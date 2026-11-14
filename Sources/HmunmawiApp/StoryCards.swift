import HmunmawiCore
import SwiftUI

/// Which findings to tell, and their titles without the app name.
enum StoryCards {
    /// Text that opens with a product name keeps its capital mid-sentence ("Google clicks…", "X followers…").
    nonisolated static func startsWithName(_ text: String) -> Bool {
        ["Google", "Bing", "YouTube", "X ", "App Store", "Apple", "Sentry", "PostHog", "TestFlight", "iOS", "Mac"]
            .contains { text.hasPrefix($0) } || text.first?.isNumber == true
    }

    /// The five to tell: wins first, then worries, strongest first.
    static func pick(_ all: [Finding]) -> [Finding] {
        let wins = all.filter { $0.lane == .win }.sorted { $0.score > $1.score }
        let worries = all.filter { $0.lane == .worry }.sorted { $0.score > $1.score }
        return Array((Array(wins.prefix(2)) + worries).prefix(5))
    }

    /// The one finding for today's headline line, rotated so it isn't the same day after day: chosen once per
    /// day and kept for that day; prefers a strong finding not shown in the last `gapDays` days, else the one shown
    /// longest ago. `shown` maps finding id → the last day ("yyyy-MM-dd") it was the headline. Pure, so testable.
    nonisolated static func today(_ all: [Finding], shown: [String: String], today: String, gapDays: Int = 3,
                                  calendar: Calendar = .current) -> Finding? {
        let ranked = pick(all)
        guard !ranked.isEmpty else { return nil }
        if let id = shown.first(where: { $0.value == today })?.key, let f = ranked.first(where: { $0.id == id }) { return f }
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone; f.dateFormat = "yyyy-MM-dd"
        guard let now = f.date(from: today) else { return ranked.first }
        func age(_ x: Finding) -> Int {
            guard let d = shown[x.id].flatMap(f.date(from:)) else { return .max }
            return calendar.dateComponents([.day], from: d, to: now).day ?? .max
        }
        return ranked.first { age($0) >= gapDays } ?? ranked.max { age($0) < age($1) }
    }

    /// Remembers today's headline finding (kept for 30 days).
    static func noteShown(_ f: Finding, today: String) {
        var m = (UserDefaults.standard.dictionary(forKey: "HMStoryShown") as? [String: String]) ?? [:]
        guard m[f.id] != today else { return }
        for (k, v) in m where v == today { m.removeValue(forKey: k) }
        m[f.id] = today
        if m.count > 60 { m = Dictionary(uniqueKeysWithValues: m.sorted { $0.value > $1.value }.prefix(60).map { ($0.key, $0.value) }) }
        UserDefaults.standard.set(m, forKey: "HMStoryShown")
    }

    /// "My App: Every new subscriber cancelled" → "Every new subscriber cancelled" (the app is in the header).
    static func headline(_ f: Finding) -> String {
        guard let app = f.app, f.title.hasPrefix(app + ": ") else { return f.title }
        return String(f.title.dropFirst(app.count + 2))
    }
}
