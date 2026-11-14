import Foundation
import HmunmawiCore

/// Reply targets Grok Bot saves: one JSON file a day, `<folder>/<YYYY-MM-DD>.json`, a list of
/// `{"tweet_url", "author", "tweet_text", "reply_text"}` (or `{"targets": [...]}`). Finding the posts and reading X is
/// Grok Bot's job; Hmunmawi checks each one and hands it to you at your reply times. Nothing is posted for you.
enum ReplyIdeas {
    struct Target: Equatable { var url: String; var author: String?; var tweet: String; var reply: String }

    /// "safari": Hmunmawi finds the posts itself through your Safari login (no bot needed).
    static func fromSafari(_ r: MyRoutine) -> Bool { r.params?["source"] == "safari" }

    static func folder(_ r: MyRoutine) -> URL {
        if fromSafari(r) { return XSafariReader.findsFolder }
        if let f = r.params?["folder"], !f.isEmpty { return URL(fileURLWithPath: f) }
        return URL.hmSupport.appending(path: "reply-targets", directoryHint: .isDirectory)
    }

    static func topics(_ r: MyRoutine) -> [String] {
        (r.params?["topics"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }

    static func load(_ r: MyRoutine, day: String) -> [Target]? {
        guard let d = try? Data(contentsOf: folder(r).appending(path: day + ".json")),
              let any = try? JSONSerialization.jsonObject(with: d) else { return nil }
        let list = (any as? [[String: Any]]) ?? ((any as? [String: Any])?["targets"] as? [[String: Any]]) ?? ((any as? [String: Any])?["items"] as? [[String: Any]]) ?? []
        return parse(list)
    }

    static func parse(_ list: [[String: Any]]) -> [Target] {
        list.compactMap { o in
            // An empty reply is fine: the post is handed on for you to reply in your own words.
            guard let url = o["tweet_url"] as? String else { return nil }
            let reply = ((o["reply_text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return Target(url: url, author: o["author"] as? String, tweet: (o["tweet_text"] as? String) ?? "", reply: reply)
        }
    }

    /// Why a target isn't handed on, or nil when it's good to go.
    static func problem(_ t: Target, topics: [String], versions: [String: String], now: Date) -> String? {
        guard t.url.wholeMatch(of: /https:\/\/(x|twitter)\.com\/[A-Za-z0-9_]{1,15}\/status\/[0-9]{5,25}(\?.*)?/) != nil else { return "not an X post link" }
        if t.reply.count > 280 { return "reply longer than 280 characters" }
        if t.reply.contains("http") { return "a link in the reply" }
        if let posted = postedAt(t.url), now.timeIntervalSince(posted) > 48 * 3600 { return "post older than 48 hours" }
        if !topics.isEmpty {
            let hay = (t.tweet + " " + t.reply).lowercased()
            if !topics.contains(where: { hay.contains($0) }) { return "off your topics" }
        }
        if !t.reply.isEmpty, let why = DraftGuard.problem(t.reply, versions: versions) { return why }
        return nil
    }

    /// What to paste to your bot so it saves reply targets in the format this routine reads.
    static func botRequest(folder: String) -> String {
        """
        Every morning, find 4 fresh posts (under 24 hours old) on X from accounts in my niche that I should reply to, and \
        draft a short, specific reply for each in my own voice (no links, no hashtags, under 280 characters, never \
        generic or AI-sounding). Follow X's current ranking: real conversation and replies count most; off-topic, \
        copy-paste or bait replies are penalised. Save them as \(folder)/<YYYY-MM-DD>.json, a JSON list of \
        {"tweet_url": "https://x.com/<author>/status/<id>", "author": "<handle>", "tweet_text": "<the post>", "reply_text": "<my reply>"}. \
        Never post anything yourself.
        """
    }

    /// X post ids carry their time (a "snowflake": milliseconds since 4 Nov 2010, shifted 22 bits).
    static func postedAt(_ url: String) -> Date? {
        guard let m = url.firstMatch(of: /status\/([0-9]{5,25})/), let id = UInt64(m.1) else { return nil }
        return Date(timeIntervalSince1970: Double((id >> 22) + 1_288_834_974_657) / 1000)
    }
}
