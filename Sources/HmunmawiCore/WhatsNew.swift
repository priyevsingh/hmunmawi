import Foundation

/// "What's new" after an update and "Start here" on a fresh install. The notes live in one file,
/// Resources/WhatsNew.json, which the Today card reads and scripts/release-notes.py turns into the update window's
/// notes, so both always say the same. Pure apart from the store's UserDefaults.
public enum WhatsNew {
    public struct Item: Codable, Equatable, Sendable {
        public let title: String
        public let detail: String
        /// `settings:<pane>` or `page:<today|apps|log|automations>`; nil = nothing to open.
        public let action: String?
        public init(title: String, detail: String, action: String? = nil) { self.title = title; self.detail = detail; self.action = action }
    }
    public struct Version: Codable, Equatable, Sendable {
        public let version: String
        public let items: [Item]
        public init(version: String, items: [Item]) { self.version = version; self.items = items }
    }
    public struct Notes: Codable, Equatable, Sendable {
        public let versions: [Version]
        public let start_here: [Item]
        public init(versions: [Version], start_here: [Item]) { self.versions = versions; self.start_here = start_here }
    }

    public enum Show: Equatable, Sendable {
        case none
        case whatsNew([Version])
        case startHere([Item])
    }

    /// The most versions one card lists (someone who skipped many updates sees the newest ones).
    public static let maxVersions = 5

    public static func decode(_ data: Data) -> Notes? { try? JSONDecoder().decode(Notes.self, from: data) }

    /// "1.10.0" > "1.9.9"; missing parts count as 0 ("1.5" == "1.5.0"); anything that isn't a number counts as 0.
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// The versions newer than `lastSeen` up to and including `current`, newest first, at most `maxVersions`.
    public static func entries(_ notes: Notes, after lastSeen: String, upTo current: String) -> [Version] {
        let picked = notes.versions.filter { compare($0.version, lastSeen) == .orderedDescending && compare($0.version, current) != .orderedDescending }
        return Array(picked.sorted { compare($0.version, $1.version) == .orderedDescending }.prefix(maxVersions))
    }

    /// What Today shows: on a fresh install the short tour; after an update the notes since the version last seen;
    /// an update from a version older than this feature (nothing noted) shows only the current version's notes.
    public static func decide(_ notes: Notes, lastSeen: String?, current: String, freshInstall: Bool) -> Show {
        guard let lastSeen else {
            if freshInstall { return notes.start_here.isEmpty ? .none : .startHere(notes.start_here) }
            let now = notes.versions.filter { compare($0.version, current) == .orderedSame }
            return now.isEmpty ? .none : .whatsNew(now)
        }
        guard compare(lastSeen, current) == .orderedAscending else { return .none }
        let list = entries(notes, after: lastSeen, upTo: current)
        return list.isEmpty ? .none : .whatsNew(list)
    }

    /// Remembers which version's notes were last seen, so each card shows once.
    public struct Store {
        public static let key = "HMWhatsNewSeen"
        let defaults: UserDefaults
        public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
        public var lastSeen: String? { defaults.string(forKey: Self.key) }
        /// Dismissed (or nothing to show): this version counts as seen.
        public func markSeen(_ version: String) { defaults.set(version, forKey: Self.key) }
    }
}
