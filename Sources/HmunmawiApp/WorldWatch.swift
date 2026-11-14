import Foundation
import HmunmawiCore
import SwiftUI

/// The world around your apps, from free public sources (read-only, no keys):
///   • Apple developer system status (App Store Connect, TestFlight, APNs…), so an outage isn't mistaken for your bug
///   • Apple developer news (new requirements and deadlines are flagged)
///   • mentions of your apps on Hacker News and Bluesky
///   • your open-source repo on GitHub (stars, open issues, latest release)
/// Checked at most every 30 minutes (news and mentions every 6 hours). Each source says when it last answered.
@MainActor @Observable
final class WorldWatch {
    static let shared = WorldWatch()

    struct Outage: Hashable { let service: String; let message: String }
    struct News: Hashable, Identifiable { let id: String; let title: String; let link: URL?; let date: Date?; let deadline: Bool }
    struct Mention: Hashable, Identifiable { let id: String; let source: String; let text: String; let link: URL?; let date: Date? }
    struct Repo: Hashable { let name: String; let stars: Int; let issues: Int; let release: String? }

    private(set) var outages: [Outage] = []
    private(set) var statusChecked: Date?
    private(set) var news: [News] = []
    private(set) var mentions: [Mention] = []
    private(set) var repo: Repo?
    private(set) var problems: [String] = []
    private var slowChecked: Date?

    static let repoKey = "HMWatchRepo"          // "owner/name"
    static let termsKey = "HMWatchTerms"        // extra words for mentions

    var repoName: String {
        get { UserDefaults.standard.string(forKey: Self.repoKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Self.repoKey) }
    }

    func refresh(appNames: [String], force: Bool = false) async {
        problems = []
        if force || (statusChecked.map { Date.now.timeIntervalSince($0) > 1800 } ?? true) {
            if let list = await Self.appleStatus() { outages = list; statusChecked = .now } else { problems.append("Apple's status page didn't answer") }
        }
        if force || (slowChecked.map { Date.now.timeIntervalSince($0) > 6 * 3600 } ?? true) {
            var complete = true
            if let n = await Self.appleNews() { news = n } else { problems.append("Apple's news feed didn't answer"); complete = false }
            var found: [Mention] = [], answered = true
            for name in Set(appNames).prefix(6) {
                if let m = await Self.hackerNews(name) { found += m } else { answered = false }
                if let m = await Self.bluesky(name) { found += m } else { answered = false }
            }
            // A site that didn't answer keeps the mentions you already had (never "nobody's talking" by mistake).
            if answered { mentions = Array(Set(found)).sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) } }
            else { problems.append("Hacker News or Bluesky didn't answer; showing the last mentions"); complete = false }
            if repoName.isEmpty { repo = nil }
            else if let r = await Self.github(repoName) { repo = r }
            else { problems.append("GitHub didn't answer for \(repoName)"); complete = false }   // the last numbers stay
            // Only a complete round waits 6 hours; anything that failed is tried again on the next refresh.
            if complete { slowChecked = .now }
        }
    }

    // MARK: Sources

    nonisolated static func json(_ url: URL) async -> Any? {
        var r = URLRequest(url: url, timeoutInterval: 20)
        r.setValue("Hmunmawi (macOS)", forHTTPHeaderField: "User-Agent")
        guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: d)
    }

    /// Apple's developer system status: a JSONP file; anything not "resolved" today is listed.
    nonisolated static func appleStatus() async -> [Outage]? {
        guard let u = URL(string: "https://www.apple.com/support/systemstatus/data/developer/system_status_en_US.js"),
              let (d, _) = try? await URLSession.shared.data(from: u) else { return nil }
        var text = String(decoding: d, as: UTF8.self)
        if let a = text.firstIndex(of: "("), let b = text.lastIndex(of: ")") { text = String(text[text.index(after: a)..<b]) }
        guard let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let services = root["services"] as? [[String: Any]] else { return nil }
        var out: [Outage] = []
        for s in services {
            for e in (s["events"] as? [[String: Any]]) ?? [] where (e["eventStatus"] as? String)?.lowercased() != "resolved" {
                out.append(Outage(service: s["serviceName"] as? String ?? "Apple", message: e["message"] as? String ?? "Having issues"))
            }
        }
        return out
    }

    /// Apple developer news (RSS). Items about requirements, deadlines or guidelines are flagged.
    nonisolated static func appleNews() async -> [News]? {
        guard let u = URL(string: "https://developer.apple.com/news/rss/news.rss"), let (d, _) = try? await URLSession.shared.data(from: u) else { return nil }
        let xml = String(decoding: d, as: UTF8.self)
        var out: [News] = []
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        for chunk in xml.components(separatedBy: "<item>").dropFirst().prefix(12) {
            func tag(_ t: String) -> String? {
                guard let a = chunk.range(of: "<\(t)>"), let b = chunk.range(of: "</\(t)>", range: a.upperBound..<chunk.endIndex) else { return nil }
                return String(chunk[a.upperBound..<b.lowerBound]).replacingOccurrences(of: "<![CDATA[", with: "").replacingOccurrences(of: "]]>", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let title = tag("title") else { continue }
            let low = title.lowercased()
            let deadline = ["requirement", "deadline", "upcoming", "guideline", "must", "starting", "beginning", "sdk", "age rating"].contains { low.contains($0) }
            out.append(News(id: tag("link") ?? title, title: title, link: tag("link").flatMap(URL.init(string:)), date: tag("pubDate").flatMap { f.date(from: $0) }, deadline: deadline))
        }
        return out
    }

    /// nil when the site didn't answer (kept apart from "no mentions", so a blip never wipes the list).
    nonisolated static func hackerNews(_ term: String) async -> [Mention]? {
        var c = URLComponents(string: "https://hn.algolia.com/api/v1/search_by_date")!
        c.queryItems = [.init(name: "query", value: "\"\(term)\""), .init(name: "hitsPerPage", value: "5")]
        guard let root = await json(c.url!) as? [String: Any] else { return nil }
        return ((root["hits"] as? [[String: Any]]) ?? []).compactMap { h in
            guard let id = h["objectID"] as? String else { return nil }
            let text = (h["title"] as? String) ?? (h["comment_text"] as? String)?.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression) ?? ""
            guard Self.isAboutApp(text, term) else { return nil }
            return Mention(id: "hn-\(id)", source: "Hacker News", text: String(text.prefix(160)),
                           link: URL(string: "https://news.ycombinator.com/item?id=\(id)"),
                           date: (h["created_at"] as? String).flatMap { try? Date($0, strategy: .iso8601) })
        }
    }

    nonisolated static func bluesky(_ term: String) async -> [Mention]? {
        var c = URLComponents(string: "https://public.api.bsky.app/xrpc/app.bsky.feed.searchPosts")!
        c.queryItems = [.init(name: "q", value: "\"\(term)\""), .init(name: "limit", value: "5")]
        guard let root = await json(c.url!) as? [String: Any] else { return nil }
        return ((root["posts"] as? [[String: Any]]) ?? []).compactMap { p in
            guard let uri = p["uri"] as? String, let rec = p["record"] as? [String: Any], let text = rec["text"] as? String, Self.isAboutApp(text, term),
                  let handle = (p["author"] as? [String: Any])?["handle"] as? String else { return nil }
            let rkey = uri.split(separator: "/").last.map(String.init) ?? ""
            return Mention(id: "bs-\(uri)", source: "Bluesky", text: String(text.prefix(160)),
                           link: URL(string: "https://bsky.app/profile/\(handle)/post/\(rkey)"),
                           date: (rec["createdAt"] as? String).flatMap { try? Date($0, strategy: .iso8601) })
        }
    }

    /// Your own sites (web addresses in your projects, e.g. "mysite.com"), set by the app model on each refresh.
    nonisolated(unsafe) static var developerSites: [String] = []

    /// A mention counts only when it's about the app, not the everyday word ("presence", "glow"): the name must
    /// appear next to an app word, or one of your own sites.
    nonisolated static func isAboutApp(_ text: String, _ name: String) -> Bool {
        let t = text.lowercased(), n = name.lowercased()
        guard t.contains(n) else { return false }
        let sites = developerSites.map { $0.lowercased() }.filter { !$0.isEmpty }
        return (["app store", "iphone", "ios app", "\(n) app", "app \(n)", "testflight", "apps.apple.com"] + sites).contains { t.contains($0) }
    }

    nonisolated static func github(_ name: String) async -> Repo? {
        guard name.split(separator: "/").count == 2, name.allSatisfy({ $0.isLetter || $0.isNumber || "-_./".contains($0) }),
              let u = URL(string: "https://api.github.com/repos/\(name)"), let r = await json(u) as? [String: Any] else { return nil }
        let rel = (await json(URL(string: "https://api.github.com/repos/\(name)/releases/latest")!) as? [String: Any])?["tag_name"] as? String
        return Repo(name: name, stars: r["stargazers_count"] as? Int ?? 0, issues: r["open_issues_count"] as? Int ?? 0, release: rel)
    }
}

/// On Log: Apple's status and news, mentions, and your repo, in one compact card.
struct WorldCard: View {
    let model: AppModel
    @State private var world = WorldWatch.shared
    @State private var editingRepo = false
    @State private var repoText = ""

    var body: some View {
        KitCard {
            HStack {
                CardHeader(symbol: "globe.europe.africa.fill", title: "Out in the world", tint: Brand.Category.web,
                           caption: world.statusChecked.map { "checked \($0.formatted(.relative(presentation: .named)))" } ?? "Apple status, news and mentions")
                Button { Task { await world.refresh(appNames: names, force: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Check now")
            }
            EqualRowsGrid(minWidth: 360, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Label { Text("Apple's systems").foregroundStyle(.primary) } icon: { Image(systemName: "storefront") }.font(.headline)
                    if world.outages.isEmpty {
                        Text(Quips.pick(["All green at Apple. If something breaks, it's (probably) us.", "Apple's servers are behaving. Blame-free day."]))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(world.outages, id: \.self) { o in
                        Label("\(o.service): \(o.message)", systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Brand.caution)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Label { Text("Apple developer news").foregroundStyle(.primary) } icon: { Image(systemName: "newspaper") }.font(.headline).padding(.top, 6)
                    ForEach(world.news.prefix(4)) { n in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if n.deadline { Image(systemName: "calendar.badge.exclamationmark").foregroundStyle(Brand.caution) }
                            if let link = n.link { Link(n.title, destination: link).font(.callout) } else { Text(n.title).font(.callout) }
                            Spacer(minLength: 4)
                            if let d = n.date { Text(d.formatted(.dateTime.day().month(.abbreviated))).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Label { Text("People talking about you").foregroundStyle(.primary) } icon: { Image(systemName: "bubble.left.and.text.bubble.right") }.font(.headline)
                    if world.mentions.isEmpty {
                        Text(Quips.pick(["No mentions on Hacker News or Bluesky yet. Fame is loading.", "Nobody's talking about you yet. Give them a reason."]))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(world.mentions.prefix(4)) { m in
                        VStack(alignment: .leading, spacing: 1) {
                            if let link = m.link { Link(m.text, destination: link).font(.callout).multilineTextAlignment(.leading) } else { Text(m.text).font(.callout) }
                            Text([m.source, m.date?.formatted(.relative(presentation: .named))].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Label { Text("Your repo on GitHub").foregroundStyle(.primary) } icon: { Image(systemName: "chevron.left.forwardslash.chevron.right") }.font(.headline).padding(.top, 6)
                    if let r = world.repo {
                        Text("\(r.name) · ★ \(r.stars) · \(r.issues) open issue\(r.issues == 1 ? "" : "s")" + (r.release.map { " · latest \($0)" } ?? ""))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    HStack {
                        if editingRepo {
                            TextField("owner/repo", text: $repoText).input(.identifier, $repoText).frame(maxWidth: 220)
                            Button("Save") { world.repoName = repoText; editingRepo = false; Task { await world.refresh(appNames: names, force: true) } }.buttonStyle(.pill)
                        } else {
                            Button(world.repoName.isEmpty ? "Add your repo" : "Change repo") { repoText = world.repoName; editingRepo = true }.buttonStyle(.pill)
                        }
                    }
                }
            }
            ForEach(world.problems, id: \.self) { Text($0).font(.caption).foregroundStyle(Brand.caution) }
        }
        .task {
            while !Task.isCancelled {
                await world.refresh(appNames: names)
                try? await Task.sleep(for: .seconds(1800))
            }
        }
    }

    private var names: [String] { model.snapshots("app.snapshot").compactMap { $0.app.map(ComingSoon.shortName) } }
}
