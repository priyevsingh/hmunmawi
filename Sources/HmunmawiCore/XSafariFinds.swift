import Foundation

/// For people without a bot: what Hmunmawi can find on X through your own signed-in Safari, read-only. It reads only
/// what X's page already loaded (no clicks, no posting, no private API calls), and writes the same files a bot would,
/// so the reply-ideas and unfollow-list routines work the same either way. Pure: the app opens the tabs.
public enum XSafariFinds {
    /// Accounts with this many followers are marked "keep": people follow them to read them, not for a follow-back.
    public static let bigAccount = 50_000

    static let storeFinder = """
    var root=document.getElementById('react-root'); if(!root) return JSON.stringify({error:'not an X page'});
    var key=Object.keys(root).find(function(k){return k.indexOf('__reactContainer')===0});
    var stack=key?[root[key]]:[], seen=0, store=null;
    while(stack.length && seen<30000){ var f=stack.pop(); seen++;
      var p=f.memoizedProps; if(p && p.store && typeof p.store.getState==='function'){ store=p.store; break; }
      if(f.child) stack.push(f.child); if(f.sibling) stack.push(f.sibling); }
    if(!store) return JSON.stringify({error:'still loading'});
    var ents=store.getState().entities||{};
    var users=(ents.users&&ents.users.entities)||{}, tweets=(ents.tweets&&ents.tweets.entities)||{};
    """

    // MARK: Unfollow list

    /// On your Following page: every account you follow that X's page loaded, with whether it follows you back.
    public static func followingJS(handle: String) -> String {
        """
        (function(){
          \(storeFinder)
          var me='\(handle.lowercased())';
          var out=Object.values(users).filter(function(u){return u.following===true && (u.screen_name||'').toLowerCase()!==me})
            .map(function(u){return {handle:u.screen_name, back:u.followed_by===true, followers:u.followers_count||0}});
          return JSON.stringify({users:out});
        })()
        """
    }

    /// The page's answer -> the unfollow file's list (`{"handle", "suggestion"}`): accounts that don't follow back,
    /// big accounts marked "keep". Nil when the page didn't answer with a list.
    public static func nonFollowbacks(_ json: String) -> [[String: String]]? {
        guard let d = json.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let users = o["users"] as? [[String: Any]] else { return nil }
        var seen = Set<String>()
        return users.compactMap { u in
            guard (u["back"] as? Bool) != true, let h = (u["handle"] as? String).flatMap(XNative.validHandle),
                  seen.insert(h.lowercased()).inserted else { return nil }
            let big = ((u["followers"] as? Int) ?? 0) >= bigAccount
            return ["handle": h, "suggestion": big ? "keep (big account)" : "unfollow"]
        }
    }

    // MARK: Reply ideas

    /// X's "Latest" search for your topics: original posts in English with a little traction, no replies, no links.
    public static func searchURL(topics: [String]) -> String? {
        let words = topics.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0.count <= 40 }.prefix(8)
        guard !words.isEmpty else { return nil }
        let any = words.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " OR ")
        let q = "(\(any)) min_faves:3 -filter:replies -filter:links lang:en"
        var c = URLComponents(string: "https://x.com/search")!
        c.queryItems = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "f", value: "live")]
        return c.url?.absoluteString
    }

    /// On a search page: the posts X loaded, with their authors (yours left out).
    public static func searchJS(handle: String) -> String {
        """
        (function(){
          \(storeFinder)
          var me='\(handle.lowercased())';
          var out=Object.keys(tweets).map(function(i){var t=tweets[i], u=users[t.user]||{};
              return {id:i, author:u.screen_name||'', followers:u.followers_count||0, created_at:t.created_at,
                text:(t.full_text||t.text||'').slice(0,600), reply:!!t.in_reply_to_status_id_str, retweet:!!t.retweeted_status,
                likes:t.favorite_count||0, replies:t.reply_count||0, views:(t.views&&t.views.count)||0}; })
            .filter(function(t){return t.author && t.author.toLowerCase()!==me && !t.reply && !t.retweet});
          return JSON.stringify({tweets:out});
        })()
        """
    }

    public struct Candidate: Equatable, Sendable {
        public var url: String, author: String, text: String, likes: Int, replies: Int, posted: Date
    }

    /// The best posts to reply to: under 24 hours old, on one of your topics, no link, not from a huge account (your
    /// reply would drown), ranked by X's own like and reply weights, newer first. At most one per author.
    public static func pick(_ json: String, topics: [String], now: Date, count: Int) -> [Candidate] {
        guard let d = json.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let list = o["tweets"] as? [[String: Any]] else { return [] }
        let iso = ISO8601DateFormatter(), frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let legacy = DateFormatter(); legacy.locale = Locale(identifier: "en_US_POSIX"); legacy.dateFormat = "EEE MMM dd HH:mm:ss Z yyyy"
        let words = topics.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        func int(_ v: Any?) -> Int { (v as? Int) ?? Int((v as? String) ?? "") ?? 0 }
        var authors = Set<String>()
        let scored: [(Double, Candidate)] = list.compactMap { t in
            guard let id = t["id"] as? String, id.allSatisfy(\.isNumber), let author = (t["author"] as? String).flatMap(XNative.validHandle),
                  let text = t["text"] as? String, let raw = t["created_at"] as? String,
                  let when = iso.date(from: raw) ?? frac.date(from: raw) ?? legacy.date(from: raw) else { return nil }
            let age = now.timeIntervalSince(when) / 3600
            guard age >= 0, age <= 24, !text.contains("http"), !text.hasPrefix("@"), int(t["followers"]) < 1_000_000 else { return nil }   // "@brand …" is aimed at someone, not a conversation
            let lower = text.lowercased()
            guard words.isEmpty || words.contains(where: { lower.contains($0) }) else { return nil }
            let c = Candidate(url: "https://x.com/\(author)/status/\(id)", author: author, text: text,
                              likes: int(t["likes"]), replies: int(t["replies"]), posted: when)
            return ((0.708 * Double(c.likes) + 5 * Double(c.replies) + 1) / (age + 2).squareRoot(), c)   // X's like and reply weights
        }
        return scored.sorted { $0.0 > $1.0 }.map(\.1).filter { authors.insert($0.author.lowercased()).inserted }.prefix(count).map { $0 }
    }

    /// What the AI is asked for one reply. Plain rules from X's current ranking: real conversation, no bait, no links.
    public static func replyPrompt(_ c: Candidate, about: String) -> String {
        """
        Write one reply to this X post, as me: an indie developer. \(about.isEmpty ? "" : "What I work on: \(about).")
        Add something specific that invites a real answer: a sharp question, or a general lesson from building apps. \
        Never invent numbers, results or facts about me or my apps. \
        Under 220 characters, plain words, no hashtags, no links, no emoji spam, no flattery, never generic or \
        AI-sounding, no "Great post". If you can't add anything real, answer exactly: SKIP.

        Post by @\(c.author):
        \(c.text)
        """
    }

    /// The model's standing role for reply drafts (Apple's on-device model or your AI key).
    public static let replyInstructions = "You draft short, specific replies for an indie app developer to post on X. Output only the reply text."

    /// Who drafts the Safari route's replies. `choice`: auto (free first: Apple's on-device model, else your AI key),
    /// ondevice, ai or none.
    public enum Drafter: String, Sendable { case onDevice = "ondevice", aiKey = "ai", none }
    public static func drafter(choice: String?, onDevice: Bool, aiKey: Bool) -> Drafter {
        switch choice ?? "auto" {
        case "ondevice": return onDevice ? .onDevice : .none
        case "ai": return aiKey ? .aiKey : .none
        case "none": return .none
        default: return onDevice ? .onDevice : aiKey ? .aiKey : .none
        }
    }

    /// A drafted reply, cleaned; nil when the AI passed or wrote something unusable.
    public static func cleanReply(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("\""), t.hasSuffix("\""), t.count > 2 { t = String(t.dropFirst().dropLast()) }
        guard !t.isEmpty, t.uppercased() != "SKIP", t.count <= 280, !t.contains("http"), !t.contains("#") else { return nil }
        return t
    }
}
