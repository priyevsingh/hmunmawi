import Foundation

/// Reading your own X numbers from your signed-in X page (no paid X API, no key): the JavaScript that reads the posts
/// X's own page already loaded into its data store, and the X file built from them (docs/X-FILE.md). Pure.
public enum XNative {
    /// X handles: 1-15 letters, digits or underscores (no @).
    public static func validHandle(_ h: String) -> String? {
        let t = h.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "@", with: "")
        return t.wholeMatch(of: /[A-Za-z0-9_]{1,15}/) != nil ? t : nil
    }

    /// Finds X's data store in the page and returns your account's counts and posts as JSON (read-only; no requests).
    public static func storeJS(handle: String) -> String {
        """
        (function(){
          var root=document.getElementById('react-root'); if(!root) return JSON.stringify({error:'not an X page'});
          var key=Object.keys(root).find(function(k){return k.indexOf('__reactContainer')===0});
          var stack=key?[root[key]]:[], seen=0, store=null;
          while(stack.length && seen<30000){ var f=stack.pop(); seen++;
            var p=f.memoizedProps; if(p && p.store && typeof p.store.getState==='function'){ store=p.store; break; }
            if(f.child) stack.push(f.child); if(f.sibling) stack.push(f.sibling); }
          if(!store) return JSON.stringify({error:'still loading'});
          var st=store.getState(), ents=st.entities||{};
          var users=(ents.users&&ents.users.entities)||{}, tweets=(ents.tweets&&ents.tweets.entities)||{};
          var me=Object.values(users).find(function(u){return (u.screen_name||'').toLowerCase()==='\(handle.lowercased())'});
          if(!me) return JSON.stringify({error:'signed out or wrong account'});
          var arts=(ents.publishedArticles&&ents.publishedArticles.entities)||{};
          var out=Object.keys(tweets).filter(function(i){var t=tweets[i]; return (t.user===me.id_str||t.user_id_str===me.id_str) && !t.retweeted_status;})
            .map(function(i){var t=tweets[i], a=t.article&&arts[t.article]; return {id:i, created_at:t.created_at, text:(t.full_text||t.text||'').slice(0,280),
              reply:!!t.in_reply_to_status_id_str, reply_to:t.in_reply_to_screen_name||null, article:(a&&a.title)?String(a.title).slice(0,200):null,
              views:(t.views&&t.views.count)||0, likes:t.favorite_count||0, replies:t.reply_count||0,
              reposts:t.retweet_count||0, quotes:t.quote_count||0, bookmarks:t.bookmark_count||0};});
          return JSON.stringify({followers:me.followers_count, following:me.friends_count,
            pinned:(me.pinned_tweet_ids_str||[])[0]||null, pinned_ids:(me.pinned_tweet_ids_str||[]), tweets:out});
        })()
        """
    }

    public struct Post: Codable, Equatable, Sendable {
        public var type: String, text: String, url: String, created_at: String
        public var impressions: Int, likes: Int, replies: Int, reposts: Int, quotes: Int, bookmarks: Int
        /// Who a reply answered (handle, no @) and an X Article's title; nil when not a reply / not an article.
        public var replyTo: String? = nil, article: String? = nil
    }
    public struct Read: Equatable, Sendable {
        public var followers: Int?; public var following: Int?; public var posts: [Post]
        /// The id of your pinned post, when X's page has one.
        public var pinned: String?
        /// All pinned post/article ids reported by X's page, in order.
        public var pinnedIDs: [String]
        public init(followers: Int?, following: Int?, posts: [Post], pinned: String? = nil, pinnedIDs: [String]? = nil) {
            self.followers = followers; self.following = following; self.posts = posts; self.pinned = pinned
            self.pinnedIDs = pinnedIDs ?? (pinned.map { [$0] } ?? [])
        }
    }

    /// The store's answer -> your posts. Throws a readable reason when the page wasn't ready or you're signed out.
    public static func parse(_ json: String, handle: String) throws -> Read {
        guard let d = json.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            throw Problem("X didn't answer (is Safari's \"Allow JavaScript from Apple Events\" on?)")
        }
        if let e = o["error"] as? String { throw Problem(e) }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]
        let legacy = DateFormatter(); legacy.locale = Locale(identifier: "en_US_POSIX"); legacy.dateFormat = "EEE MMM dd HH:mm:ss Z yyyy"
        func int(_ v: Any?) -> Int { (v as? Int) ?? Int((v as? String) ?? "") ?? Int((v as? Double) ?? 0) }
        let posts: [Post] = ((o["tweets"] as? [[String: Any]]) ?? []).compactMap { t in
            guard let id = t["id"] as? String, id.allSatisfy(\.isNumber) else { return nil }
            let raw = (t["created_at"] as? String) ?? ""
            let frac = ISO8601DateFormatter(); frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let when = iso.date(from: raw) ?? frac.date(from: raw) ?? legacy.date(from: raw)   // X writes "…T14:04:00.000Z"
            guard let when else { return nil }
            let article = (t["article"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return Post(type: (t["reply"] as? Bool) == true ? "reply" : "post", text: (t["text"] as? String) ?? "",
                        url: "https://x.com/\(handle)/status/\(id)", created_at: iso.string(from: when),
                        impressions: int(t["views"]), likes: int(t["likes"]), replies: int(t["replies"]),
                        reposts: int(t["reposts"]), quotes: int(t["quotes"]), bookmarks: int(t["bookmarks"]),
                        replyTo: (t["reply_to"] as? String).flatMap(validHandle),
                        article: article?.isEmpty == false ? String(article!.prefix(200)) : nil)
        }
        let pinned = (o["pinned"] as? String).flatMap { $0.allSatisfy(\.isNumber) && !$0.isEmpty ? $0 : nil }
        var seenPinned: Set<String> = []
        let parsedPinnedIDs = ((o["pinned_ids"] as? [String]) ?? []).filter {
            !$0.isEmpty && $0.allSatisfy(\.isNumber) && seenPinned.insert($0).inserted
        }
        let pinnedIDs = parsedPinnedIDs.isEmpty ? (pinned.map { [$0] } ?? []) : parsedPinnedIDs
        return Read(followers: o["followers"] as? Int, following: o["following"] as? Int, posts: posts,
                    pinned: pinned ?? pinnedIDs.first, pinnedIDs: pinnedIDs)
    }

    /// A post "takes off" when it earns this many times your average views (originals of the last 7 days)…
    public static let takeOffFactor = 3.0
    /// …and only once you have this many originals to compare with.
    public static let takeOffMinPosts = 3

    /// Your X at a glance: pinned post, latest X Article, a post that's taking off (or why none is) and your two
    /// most-viewed replies of the last 7 days. Same shape a bot may write (docs/X-FILE.md). Missing parts are left out.
    public static func glance(read: Read, now: Date) -> [String: Any] {
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]
        let when: (Post) -> Date = { iso.date(from: $0.created_at) ?? .distantPast }
        let cutoff = now.addingTimeInterval(-7 * 86400)
        func title(_ p: Post) -> String {
            if let a = p.article { return a }
            let t = p.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            return t.count > 90 ? String(t.prefix(89)) + "…" : t
        }
        func row(_ p: Post) -> [String: Any] {
            ["title": title(p), "kind": p.article != nil ? "article" : "post", "url": p.url,
             "views": p.impressions, "likes": p.likes, "replies": p.replies, "posted": p.created_at]
        }
        var g: [String: Any] = ["updated": iso.string(from: now)]
        let pinnedRows = read.pinnedIDs.compactMap { id in
            read.posts.first(where: { $0.url.hasSuffix("/status/\(id)") }).map(row)
        }
        if let firstPinned = pinnedRows.first { g["pinned"] = firstPinned }
        if !pinnedRows.isEmpty { g["pinned_items"] = pinnedRows }
        let articleRows = read.posts.filter { $0.article != nil }.sorted { when($0) > when($1) }.map(row)
        if let latestArticle = articleRows.first { g["latest_article"] = latestArticle }
        if !articleRows.isEmpty { g["articles"] = articleRows }
        let originals = read.posts.filter { $0.type == "post" && when($0) >= cutoff }
        if originals.count >= takeOffMinPosts {
            let avg = Double(originals.reduce(0) { $0 + $1.impressions }) / Double(originals.count)
            let best = originals.max { $0.impressions < $1.impressions }!
            let bar = avg * takeOffFactor
            if avg > 0, Double(best.impressions) >= bar {
                g["taking_off"] = row(best)
                g["taking_off_reason"] = "\(best.impressions.formatted()) views, \(String(format: "%.1f", Double(best.impressions) / avg))× your average of \(Int(avg.rounded())) over \(originals.count) posts this week."
            } else {
                g["taking_off_reason"] = "Nothing yet: your best post this week has \(best.impressions.formatted()) views; taking off means \(Int(bar.rounded())) (3× your average of \(Int(avg.rounded())))."
            }
        } else {
            g["taking_off_reason"] = "Needs at least \(takeOffMinPosts) posts this week to compare (you have \(originals.count))."
        }
        g["top_replies"] = read.posts.filter { $0.type == "reply" && when($0) >= cutoff }
            .sorted { $0.impressions > $1.impressions }.prefix(2)
            .map { r -> [String: Any] in ["to": r.replyTo.map { "@\($0)" } ?? "a reply", "url": r.url, "views": r.impressions] }
        return g
    }

    /// The X file: the last 7 days of posts, newest first, 7-day totals and the day-over-day follower change.
    /// `history`: day ("2026-11-14") -> followers; today's count is added and the last 60 days kept.
    public static func file(handle: String, read: Read, now: Date, today: String, history: inout [String: Int]) -> [String: Any] {
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]
        let cutoff = now.addingTimeInterval(-7 * 86400)
        let week = read.posts.filter { (iso.date(from: $0.created_at) ?? .distantPast) >= cutoff }.sorted { $0.created_at > $1.created_at }
        if let f = read.followers { history[today] = f }
        history = Dictionary(uniqueKeysWithValues: history.sorted { $0.key < $1.key }.suffix(60).map { ($0.key, $0.value) })
        let earlier = history.keys.filter { $0 < today }.sorted().last
        var doc: [String: Any] = [
            "generated": iso.string(from: now), "source": "Hmunmawi Safari read of your own X page",
            "posts": week.map { p in ["type": p.type, "text": p.text, "url": p.url, "created_at": p.created_at, "impressions": p.impressions,
                                      "likes": p.likes, "replies": p.replies, "reposts": p.reposts, "quotes": p.quotes, "bookmarks": p.bookmarks] as [String: Any] },
            "totals_7d": ["posts": week.count, "impressions": week.reduce(0) { $0 + $1.impressions }, "likes": week.reduce(0) { $0 + $1.likes },
                          "replies": week.reduce(0) { $0 + $1.replies }, "reposts": week.reduce(0) { $0 + $1.reposts }],
        ]
        var account: [String: Any] = ["username": handle]
        if let f = read.followers { account["followers"] = f }
        if let f = read.following { account["following"] = f }
        doc["account"] = account
        doc["glance"] = glance(read: read, now: now)
        if let f = read.followers, let e = earlier, let was = history[e] { doc["followers_delta_1d"] = f - was }
        return doc
    }

    public struct Problem: Error, CustomStringConvertible { public let description: String; public init(_ d: String) { description = d } }
}
