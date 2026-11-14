import Foundation

/// The Wall of Apps: public App Store apps whose developers use Hmunmawi, kept in docs/wall-of-apps.json in the
/// project's repository and added by pull request (like other open-source tools' walls). Pure parts, testable.
public enum WallOfApps {
    public struct Entry: Codable, Equatable, Sendable {
        public var app: String
        public var link: String
        public var icon: String
        /// The App Store id, the developer's name and the day it joined the wall (YYYY-MM-DD). Optional, so older
        /// entries without them still read.
        public var id: String?
        public var developer: String?
        public var added: String?
        public init(app: String, link: String, icon: String, id: String? = nil, developer: String? = nil, added: String? = nil) {
            self.app = app; self.link = link; self.icon = icon; self.id = id; self.developer = developer; self.added = added
        }
        /// The id, from the entry or its App Store link.
        public var appID: String? { id ?? WallOfApps.appID(link) }
    }

    public static let repo = "priyevsingh/hmunmawi"
    public static let path = "docs/wall-of-apps.json"

    /// An App Store app id: digits only, 6–12 of them.
    public static func appID(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if let m = t.firstMatch(of: /id(\d{6,12})/) { return String(m.1) }   // a pasted App Store link
        return t.wholeMatch(of: /\d{6,12}/) != nil ? t : nil
    }

    /// The public lookup address (Apple's iTunes Search API, no key needed).
    public static func lookupURL(_ id: String) -> URL? { URL(string: "https://itunes.apple.com/lookup?id=\(id)") }

    /// The entry from Apple's lookup answer: name, store link and 512 px icon. nil when the app isn't found.
    public static func entry(fromLookup data: Data) -> Entry? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let r = (j["results"] as? [[String: Any]])?.first,
              let name = r["trackName"] as? String, let link = r["trackViewUrl"] as? String,
              let icon = (r["artworkUrl512"] ?? r["artworkUrl100"]) as? String,
              link.hasPrefix("https://apps.apple.com/"), icon.hasPrefix("https://") else { return nil }
        let id = (r["trackId"] as? Int).map(String.init) ?? appID(link)
        let dev = (r["artistName"] as? String).map { String($0.prefix(120)) }
        return Entry(app: String(name.prefix(120)), link: link, icon: icon, id: id, developer: dev)
    }

    /// The wall with `e` added (an app already there, by id or link, is replaced), newest first, then by name.
    /// `today` stamps the day it joined when the entry has none.
    public static func merged(_ wall: [Entry], adding e: Entry, today: String = isoDay(.now)) -> [Entry] {
        var e = e
        if e.added == nil { e.added = today }
        let same: (Entry) -> Bool = { o in
            (o.appID != nil && o.appID == e.appID) || o.link.split(separator: "?").first == e.link.split(separator: "?").first
        }
        return sorted(wall.filter { !same($0) } + [e])
    }

    /// Newest first (by the day each joined), then by name.
    public static func sorted(_ wall: [Entry]) -> [Entry] {
        wall.sorted { a, b in
            let da = a.added ?? "", db = b.added ?? ""
            return da != db ? da > db : a.app.localizedCaseInsensitiveCompare(b.app) == .orderedAscending
        }
    }

    public static func decode(_ data: Data) -> [Entry]? { try? JSONDecoder().decode([Entry].self, from: data) }

    public static func isoDay(_ d: Date) -> String { d.formatted(Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day()) }

    /// Where the public list is read from (the app's "Wall of Apps" view). Nothing private is sent: a plain GET.
    public static let rawURL = URL(string: "https://raw.githubusercontent.com/\(repo)/main/\(path)")!

    /// The post a developer can share once their app is on the wall (they post it themselves).
    public static func shareText(_ e: Entry) -> String {
        "My app \(e.app) is on the Hmunmawi Wall of Apps, apps shipped by indie developers who use Hmunmawi. https://github.com/\(repo)#wall-of-apps"
    }

    public static func encode(_ wall: [Entry]) -> Data {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return ((try? enc.encode(wall)) ?? Data("[]".utf8)) + Data("\n".utf8)
    }
}
