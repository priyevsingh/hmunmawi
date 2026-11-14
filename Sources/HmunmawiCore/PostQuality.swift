import Foundation

/// Which post drafts are worth your time, and which goes first. The weights follow X's published ranking code
/// (github.com/xai-org/x-algorithm): `XAlgorithm` reads its numbers and turns them into these rules, so the drafts
/// adapt when X changes what it rewards. Pure: no files, no network.
public struct PostRules: Codable, Sendable, Equatable {
    public var minWords = 18
    /// Score for each number in the draft (concrete facts), up to `numbersMax` of them.
    public var numbersEach = 0.5
    public var numbersMax = 3
    /// About 30+ words: enough to keep someone reading for 10+ seconds.
    public var longPost = 1.0
    /// How-to and lesson wording ("fix", "because", "learned"): the kind of post people pass on.
    public var lessonWords = 1.0
    /// Ends with a question: invites replies.
    public var question = 1.5
    /// X's own weights for engagement on a post (for "best posting hours"): like, reply, repost, quote.
    public var likeWeight = 0.708, replyWeight = 5.0, repostWeight = 1.0, quoteWeight = 5.0
    /// Where these numbers came from (an X commit, or "built in").
    public var source = "built in (X's ranking as of 13 Nov 2026)"
    public var updated = "2026-11-14"

    public init() {}

    /// Every weight stays within 0...3 and the word minimum within 10...40, whatever a rules file says.
    public func clamped() -> PostRules {
        var r = self
        func c(_ v: Double) -> Double { min(max(v.isFinite ? v : 0, 0), 3) }
        r.numbersEach = c(numbersEach); r.longPost = c(longPost); r.lessonWords = c(lessonWords); r.question = c(question)
        r.numbersMax = min(max(numbersMax, 0), 6); r.minWords = min(max(minWords, 10), 40)
        return r
    }
}

public enum PostQuality {
    private static var ownVoice: Regex<(Substring, Substring)> { /\b(I|I'm|I've|I'd|my|me|we|we're|our|us)\b/ }
    private static var liftedFact: Regex<(Substring, Substring, Substring?, Substring?, Substring?, Substring?)> { /^(?i)(The (study|decrease|increase|trial|review|authors|researchers|data|paper)|According to|This (study|means|was)|It (was|is)|They (found|were))\b/ }
    private static var lesson: Regex<(Substring, Substring)> { /(?i)\b(how to|step|fix|because|instead|lesson|learned|checklist|why)\b/ }

    /// Why a draft isn't worth sending, or nil when it is: long enough to stand alone, in your own voice or asking
    /// something, and not a sentence lifted from an article.
    public static func problem(_ text: String, rules: PostRules = PostRules()) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = t.split(whereSeparator: \.isWhitespace).count
        let voice = t.contains(ownVoice), asks = t.contains("?")
        if words < rules.clamped().minWords { return "too short to stand alone (\(words) words)" }
        if t.prefixMatch(of: liftedFact) != nil, !voice { return "a lifted fact sentence, no point of view" }
        if !voice && !asks { return "no voice and nothing to reply to" }
        return nil
    }

    /// Which draft goes first: higher is better.
    public static func score(_ text: String, rules: PostRules = PostRules()) -> Double {
        let r = rules.clamped()
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let numbers = t.matches(of: /\d+/).count
        var s = Double(min(numbers, r.numbersMax)) * r.numbersEach
        if t.split(whereSeparator: \.isWhitespace).count >= 30 { s += r.longPost }
        if t.contains(lesson) { s += r.lessonWords }
        if t.hasSuffix("?") { s += r.question }
        return s
    }
}

/// Reads X's published ranking weights and turns them into `PostRules` by fixed formulas (no AI, so the same code
/// always gives the same rules). The baseline is X's code of 13 Nov 2026: reply 5, share by DM 5, copy link 0, dwell 0.05.
public enum XAlgorithm {
    public static let repo = "xai-org/x-algorithm"
    public static let paramsPath = "home-mixer/params/param.rs"

    /// `param!(Name, f64, "key", value)` entries (single- or multi-line) -> [Name: value].
    public static func parseParams(_ source: String) -> [String: Double] {
        var out: [String: Double] = [:]
        for m in source.matches(of: /param!\(\s*([A-Za-z0-9_]+)\s*,\s*f64\s*,\s*"[^"]*"\s*,\s*(-?[0-9]+(?:\.[0-9]+)?)\s*\)/) {
            if let v = Double(m.2) { out[String(m.1)] = v }
        }
        return out
    }

    /// nil when the weights it needs aren't there (X renamed them): then the current rules stay.
    public static func rules(from p: [String: Double], commit: String, day: String, base: PostRules = PostRules()) -> PostRules? {
        guard let reply = p["ReplyWeight"], let copyLink = p["ShareViaCopyLinkWeight"],
              let dm = p["ShareViaDmWeight"], let dwell = p["DwellWeight"] else { return nil }
        var r = base
        r.question = 1.5 * reply / 5.0              // replies: X's reply weight
        r.numbersEach = 0.5 + 1.0 * copyLink / 20.0 // concrete facts earn copy-link shares only while X counts them
        r.lessonWords = 1.0 * dm / 5.0              // posts people pass on by DM
        r.longPost = 1.0 * dwell / 0.05             // time spent reading
        r.likeWeight = p["FavoriteWeight"] ?? r.likeWeight
        r.replyWeight = reply
        r.repostWeight = p["RetweetWeight"] ?? r.repostWeight
        r.quoteWeight = p["QuoteWeight"] ?? r.quoteWeight
        r.source = "X ranking code \(commit.prefix(10)): reply \(reply), copy link \(copyLink), share by DM \(dm), dwell \(dwell)"
        r.updated = day
        return r.clamped()
    }
}


/// When to send post drafts: the hours your own original posts got the most engagement, weighted the way X's ranking
/// weighs it (likes, replies, reposts, quotes, plus views as a tie-breaker). Ported from the maintainer's posting-time
/// script, generalised: your time zone, your number of drafts a day and your gap. Pure.
public enum PostingHours {
    public struct Post: Sendable { public var hour: Int; public var likes, replies, reposts, quotes, views: Int
        public init(hour: Int, likes: Int, replies: Int, reposts: Int, quotes: Int, views: Int) {
            self.hour = hour; self.likes = likes; self.replies = replies; self.reposts = reposts; self.quotes = quotes; self.views = views } }

    /// `count` hours between `first` and `last` (local), each at least `gap` hours apart; nil when there are fewer than
    /// `minPosts` posts to judge from (then the routine keeps its own times).
    public static func best(_ posts: [Post], count: Int, gap: Int, first: Int = 8, last: Int = 21, minPosts: Int = 5,
                            rules: PostRules = PostRules()) -> [Int]? {
        guard posts.count >= minPosts, count > 0, first <= last else { return nil }
        let r = rules.clamped()
        func engagement(_ p: Post) -> Double {
            r.likeWeight * Double(p.likes) + r.replyWeight * Double(p.replies) + r.repostWeight * Double(p.reposts)
                + r.quoteWeight * Double(p.quotes) + 0.01 * Double(p.views)
        }
        var byHour: [Int: [Double]] = [:]
        for p in posts where (0...23).contains(p.hour) { byHour[p.hour, default: []].append(engagement(p)) }
        let prior = byHour.values.flatMap { $0 }.reduce(0, +) / Double(posts.count)
        func score(_ h: Int) -> Double {   // own hour fully, the hours either side half; an empty hour gets the average
            guard byHour[h] != nil else { return prior }
            var num = 0.0, den = 0.0
            for (dh, w) in [(0, 1.0), (-1, 0.5), (1, 0.5)] { let v = byHour[h + dh] ?? []; num += w * v.reduce(0, +); den += w * Double(v.count) }
            return den > 0 ? num / den : prior
        }
        let ranked = (first...last).sorted { a, b in
            let (sa, sb) = (score(a), score(b))
            return sa != sb ? sa > sb : (abs(a - 13), a) < (abs(b - 13), b)
        }
        var chosen: [Int] = []
        for h in ranked where chosen.allSatisfy({ abs($0 - h) >= max(gap, 1) }) {
            chosen.append(h); if chosen.count == count { break }
        }
        return chosen.isEmpty ? nil : chosen.sorted()
    }
}
