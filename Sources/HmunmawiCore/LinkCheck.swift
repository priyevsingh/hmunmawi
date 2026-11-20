import Foundation

/// "Check links on my site": the pure parts. Pages come from your sitemap (or the one page you give), outside links
/// from those pages; each link's answer is judged here, and a link is called dead only when two runs in a row
/// found it dead. Sites that refuse robots (401, 403, 429) or are briefly down (5xx, timeouts) are "unknown", never
/// dead. App Store links are judged by Apple's public lookup instead (an app Apple no longer lists).
public enum LinkCheck {
    public enum Verdict: String, Codable, Sendable { case ok, dead, unknown }

    public static let maxPages = 200
    public static let maxLinks = 400

    /// `<loc>` addresses in a sitemap (or sitemap index), https only, in order, each once.
    public static func sitemapLocations(_ xml: String) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for m in xml.matches(of: /<loc>\s*([^<\s]+)\s*<\/loc>/) {
            let u = decodeEntities(String(m.1))
            guard u.hasPrefix("https://"), seen.insert(u).inserted else { continue }
            out.append(u)
        }
        return out
    }

    /// True when the text looks like a sitemap index (a list of sitemaps rather than pages).
    public static func isSitemapIndex(_ xml: String) -> Bool { xml.contains("<sitemapindex") }

    /// Every `href` on a page, made absolute against the page's address. Fragments dropped; mailto:, tel:,
    /// javascript: and data: skipped.
    public static func links(in html: String, base: URL) -> [URL] {
        var out: [URL] = [], seen = Set<String>()
        for m in html.matches(of: /(?i)<a\b[^>]*?\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/) {
            let raw = decodeEntities(String(m.1 ?? m.2 ?? m.3 ?? "")).trimmingCharacters(in: .whitespaces)
            let lower = raw.lowercased()
            guard !raw.isEmpty, !raw.hasPrefix("#"),
                  !["mailto:", "tel:", "javascript:", "data:", "sms:"].contains(where: lower.hasPrefix),
                  var c = URLComponents(string: raw, encodingInvalidCharacters: true)?.url(relativeTo: base)?.absoluteURL,
                  ["http", "https"].contains(c.scheme?.lowercased() ?? "") else { continue }
            if var comps = URLComponents(url: c, resolvingAgainstBaseURL: false) { comps.fragment = nil; c = comps.url ?? c }
            if seen.insert(c.absoluteString).inserted { out.append(c) }
        }
        return out
    }

    /// The host without "www.", lowercased.
    public static func site(_ host: String?) -> String {
        let h = (host ?? "").lowercased()
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    /// Links that leave your site (another host than any of `ownHosts`).
    public static func outside(_ links: [URL], ownHosts: Set<String>) -> [URL] {
        let own = Set(ownHosts.map { site($0) })
        return links.filter { !own.contains(site($0.host)) }
    }

    /// An App Store app link's numeric id ("…/app/name/id1234567890") and its storefront ("us" when not given).
    public static func appStoreID(_ url: URL) -> (id: String, country: String)? {
        guard ["apps.apple.com", "itunes.apple.com"].contains(url.host?.lowercased() ?? ""),
              let m = url.path.firstMatch(of: /\/id(\d{5,12})/) else { return nil }
        let first = url.pathComponents.dropFirst().first ?? ""
        let country = first.count == 2 && first.allSatisfy(\.isLetter) ? first.lowercased() : "us"
        return (String(m.1), country)
    }

    /// One answer judged. `status` nil with `noSuchHost` = the name doesn't resolve (dead); nil otherwise = no answer (unknown).
    public static func verdict(status: Int?, noSuchHost: Bool = false) -> Verdict {
        if noSuchHost { return .dead }
        guard let status else { return .unknown }
        if status == 404 || status == 410 { return .dead }
        if (200..<400).contains(status) { return .ok }
        return .unknown   // 401, 403, 405, 429, 5xx: the site is there but won't say
    }

    /// An App Store link: dead only when Apple's lookup finds nothing AND the page itself answers 404.
    public static func appStoreVerdict(lookupCount: Int?, pageStatus: Int?) -> Verdict {
        guard let lookupCount else { return .unknown }
        if lookupCount > 0 { return .ok }
        return pageStatus == 404 ? .dead : .unknown
    }

    /// What's remembered between runs: links found dead, with the day first seen dead and on which page.
    public struct State: Codable, Sendable, Equatable {
        public var suspects: [String: Entry] = [:]   // dead once, waiting for a second run
        public var dead: [String: Entry] = [:]       // dead twice in a row: told once
        public var lastRun: String?
        public var pages: Int?
        public var checked: Int?
        public init() {}
        public struct Entry: Codable, Sendable, Equatable {
            public var page: String
            public var since: String
            public var status: String
            public init(page: String, since: String, status: String) { self.page = page; self.since = since; self.status = status }
        }
    }

    /// Folds one run's results into the state. Returns the newly confirmed dead links (to tell once) and the ones
    /// that work again. Links not checked this run keep their place.
    public static func fold(_ state: State, results: [String: (verdict: Verdict, page: String, status: String)], day: String)
        -> (state: State, newDead: [String], fixed: [String]) {
        var s = state, newDead: [String] = [], fixed: [String] = []
        for (link, r) in results.sorted(by: { $0.key < $1.key }) {
            switch r.verdict {
            case .dead:
                if s.dead[link] != nil { continue }
                if let first = s.suspects.removeValue(forKey: link) {
                    s.dead[link] = State.Entry(page: r.page, since: first.since, status: r.status)
                    newDead.append(link)
                } else {
                    s.suspects[link] = State.Entry(page: r.page, since: day, status: r.status)
                }
            case .ok:
                s.suspects[link] = nil
                if s.dead.removeValue(forKey: link) != nil { fixed.append(link) }
            case .unknown:
                break   // neither proves nor clears anything
            }
        }
        s.lastRun = day
        return (s, newDead, fixed)
    }

    static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#38;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
    }
}
