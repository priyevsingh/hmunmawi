import Foundation
import Testing
@testable import HmunmawiCore

@Suite struct XNativeTests {
    // The shape X's page store returns (from a real read, made-up account and numbers).
    static let answer = """
    {"followers":120,"following":300,"tweets":[
     {"id":"111","created_at":"2026-11-14T14:04:00.000Z","text":"Shipped 1.0 today","reply":false,"views":"900","likes":12,"replies":2,"reposts":1,"quotes":0,"bookmarks":3},
     {"id":"222","created_at":"Fri Nov 13 10:00:00 +0000 2026","text":"@someone nice","reply":true,"views":40,"likes":1,"replies":0,"reposts":0,"quotes":0,"bookmarks":0},
     {"id":"333","created_at":"2026-10-01T10:00:00.000Z","text":"old","reply":false,"views":5,"likes":0,"replies":0,"reposts":0,"quotes":0,"bookmarks":0}]}
    """

    @Test func handles() {
        #expect(XNative.validHandle("@example_1") == "example_1")
        #expect(XNative.validHandle("bad handle!") == nil && XNative.validHandle("waytoolonghandle123") == nil)
    }

    @Test func parsesBothDateFormatsAndCounts() throws {
        let r = try XNative.parse(Self.answer, handle: "example")
        #expect(r.followers == 120 && r.posts.count == 3)
        let first = try #require(r.posts.first { $0.url.hasSuffix("/111") })
        #expect(first.impressions == 900 && first.likes == 12 && first.type == "post")
        #expect(r.posts.first { $0.url.hasSuffix("/222") }?.type == "reply")
    }

    @Test func signedOutIsAReadableProblem() {
        #expect(throws: XNative.Problem.self) { try XNative.parse(#"{"error":"signed out or wrong account"}"#, handle: "example") }
        #expect(throws: XNative.Problem.self) { try XNative.parse("not json", handle: "example") }
    }

    @Test func fileKeepsSevenDaysAndFollowerChange() throws {
        let r = try XNative.parse(Self.answer, handle: "example")
        let now = try Date("2026-11-14T16:00:00Z", strategy: .iso8601)
        var history = ["2026-11-13": 115]
        let doc = XNative.file(handle: "example", read: r, now: now, today: "2026-11-14", history: &history)
        #expect((doc["posts"] as? [Any])?.count == 2)                 // the October post is older than 7 days
        #expect(doc["followers_delta_1d"] as? Int == 5 && history["2026-11-14"] == 120)
        let totals = try #require(doc["totals_7d"] as? [String: Int])
        #expect(totals["impressions"] == 940 && totals["likes"] == 13)
    }
}

@Suite struct XGlanceTests {
    /// Pinned article, a reply to someone, four originals this week (one far above the rest), invented numbers.
    static let answer = """
    {"followers":120,"following":300,"pinned":"900","tweets":[
     {"id":"900","created_at":"2026-10-20T09:00:00.000Z","text":"https://x.com/i/article/1","reply":false,"article":"The free machine instead of a growth budget","views":600,"likes":5,"replies":3,"reposts":0,"quotes":0,"bookmarks":0},
     {"id":"901","created_at":"2026-11-14T09:00:00.000Z","text":"Launch day notes","reply":false,"views":400,"likes":9,"replies":4,"reposts":1,"quotes":0,"bookmarks":0},
     {"id":"902","created_at":"2026-11-13T09:00:00.000Z","text":"a","reply":false,"views":20,"likes":0,"replies":0,"reposts":0,"quotes":0,"bookmarks":0},
     {"id":"903","created_at":"2026-11-12T09:00:00.000Z","text":"b","reply":false,"views":30,"likes":0,"replies":0,"reposts":0,"quotes":0,"bookmarks":0},
     {"id":"904","created_at":"2026-11-11T09:00:00.000Z","text":"c","reply":false,"views":10,"likes":0,"replies":0,"reposts":0,"quotes":0,"bookmarks":0},
     {"id":"905","created_at":"2026-11-14T10:00:00.000Z","text":"@friend agreed","reply":true,"reply_to":"friend","views":1200,"likes":2,"replies":0,"reposts":0,"quotes":0,"bookmarks":0},
     {"id":"906","created_at":"2026-11-14T11:00:00.000Z","text":"@other yes","reply":true,"reply_to":"bad handle!","views":50,"likes":0,"replies":0,"reposts":0,"quotes":0,"bookmarks":0}]}
    """
    static let now = try! Date("2026-11-14T16:00:00Z", strategy: .iso8601)

    @Test func pinnedArticleTakingOffAndTopReplies() throws {
        let r = try XNative.parse(Self.answer, handle: "example")
        #expect(r.pinned == "900")
        let g = XNative.glance(read: r, now: Self.now)
        let pinned = try #require(g["pinned"] as? [String: Any])
        #expect(pinned["kind"] as? String == "article" && pinned["title"] as? String == "The free machine instead of a growth budget")
        #expect((g["latest_article"] as? [String: Any])?["url"] as? String == "https://x.com/example/status/900")
        // Average of the 4 originals this week is 115; 400 is 3.5×, so it's taking off.
        #expect((g["taking_off"] as? [String: Any])?["url"] as? String == "https://x.com/example/status/901")
        let replies = try #require(g["top_replies"] as? [[String: Any]])
        #expect(replies.count == 2 && replies[0]["to"] as? String == "@friend" && replies[0]["views"] as? Int == 1200)
        #expect(replies[1]["to"] as? String == "a reply")           // an odd handle from the page is never shown
    }

    @Test func nothingTakingOffSaysWhy() throws {
        let flat = Self.answer.replacingOccurrences(of: #""views":400"#, with: #""views":25"#)
        let g = XNative.glance(read: try XNative.parse(flat, handle: "example"), now: Self.now)
        #expect(g["taking_off"] == nil && (g["taking_off_reason"] as? String)?.hasPrefix("Nothing yet") == true)
    }

    @Test func botWrittenGlanceIsChecked() {
        let raw: [String: Any] = [
            "pinned": ["title": "Mine", "url": "https://x.com/example/status/1", "views": 10],
            "latest_article": ["title": "Bad", "url": "https://evil.example.com/x"],
            "top_replies": [["to": "@friend", "url": "https://x.com/example/status/2", "views": 5],
                            ["to": "@x", "url": "javascript:alert(1)"]],
        ]
        let g = XFileNumbers.glance(raw)
        #expect(g[path: "pinned.url"]?.string == "https://x.com/example/status/1")
        #expect(g[path: "latest_article"] == .null)
        #expect(g[path: "top_replies"]?.array?.count == 1)
        #expect(XFileNumbers.glance(["latest_article": ["url": "nope"]]) == .null)
    }

    @Test func tracksAllPinnedItemsAndAllArticles() throws {
        let multi = """
        {"followers":120,"following":300,"pinned":"900","pinned_ids":["900","899"],"tweets":[
         {"id":"899","created_at":"2026-10-10T09:00:00.000Z","text":"https://x.com/i/article/0","reply":false,"article":"Older pinned article","views":300,"likes":4,"replies":1,"reposts":0,"quotes":0,"bookmarks":0},
         {"id":"900","created_at":"2026-10-20T09:00:00.000Z","text":"https://x.com/i/article/1","reply":false,"article":"Newest pinned article","views":600,"likes":5,"replies":3,"reposts":0,"quotes":0,"bookmarks":0},
         {"id":"901","created_at":"2026-11-14T09:00:00.000Z","text":"https://x.com/i/article/2","reply":false,"article":"Unpinned newer article","views":450,"likes":8,"replies":2,"reposts":1,"quotes":0,"bookmarks":0}]}
        """
        let r = try XNative.parse(multi, handle: "example")
        #expect(r.pinnedIDs == ["900", "899"])
        let g = XNative.glance(read: r, now: Self.now)
        let pinnedItems = try #require(g["pinned_items"] as? [[String: Any]])
        #expect(pinnedItems.count == 2)
        #expect(pinnedItems[0]["url"] as? String == "https://x.com/example/status/900")
        #expect(pinnedItems[1]["url"] as? String == "https://x.com/example/status/899")
        let articles = try #require(g["articles"] as? [[String: Any]])
        #expect(articles.count == 3)
        #expect(articles.map { $0["title"] as? String } == ["Unpinned newer article", "Newest pinned article", "Older pinned article"])
        #expect((g["latest_article"] as? [String: Any])?["title"] as? String == "Unpinned newer article")

        let validated = XFileNumbers.glance([
            "pinned_items": [
                ["title": "Pinned 1", "kind": "article", "url": "https://x.com/example/status/900", "views": 600],
                ["title": "Pinned 1 dup", "kind": "article", "url": "https://x.com/example/status/900", "views": 600],
                ["title": "Bad", "kind": "article", "url": "https://evil.example.com/status/1"]
            ],
            "articles": [
                ["title": "Art 2", "url": "https://x.com/example/status/901", "views": 450],
                ["title": "Art 1", "url": "https://x.com/example/status/900", "views": 600],
                ["title": "Bad", "url": "javascript:alert(1)"]
            ]
        ])
        #expect(validated[path: "pinned_items"]?.array?.count == 1)
        #expect(validated[path: "articles"]?.array?.count == 2)
    }
}

@Suite struct XGlanceFileTests {
    func write(_ obj: Any, _ name: String) throws -> String {
        let url = FileManager.default.temporaryDirectory.appending(path: "hm-glance-\(UUID().uuidString)-\(name)")
        try JSONSerialization.data(withJSONObject: obj).write(to: url)
        return url.path
    }

    @Test func newerGlanceWins() throws {
        let now = try Date("2026-11-14T16:00:00Z", strategy: .iso8601)
        let xfile = try write(["generated": "2026-11-14T15:00:00Z", "account": ["followers": 10],
                               "glance": ["updated": "2026-11-14T15:00:00Z", "pinned": ["title": "From Safari", "url": "https://x.com/example/status/1"]]], "x.json")
        let newer = try write(["updated": "2026-11-14T15:30:00Z", "pinned": ["title": "From the bot", "url": "https://x.com/example/status/2"]], "g1.json")
        let older = try write(["updated": "2026-11-13T08:00:00Z", "pinned": ["title": "Old bot", "url": "https://x.com/example/status/3"]], "g2.json")
        #expect(XFileNumbers.load(file: xfile, digest: nil, glanceFile: newer, now: now)[path: "glance.pinned.title"]?.string == "From the bot")
        #expect(XFileNumbers.load(file: xfile, digest: nil, glanceFile: older, now: now)[path: "glance.pinned.title"]?.string == "From Safari")
        #expect(XFileNumbers.load(file: xfile, digest: nil, glanceFile: "/nope", now: now)[path: "glance.pinned.title"]?.string == "From Safari")
    }
}

@Suite struct XSafariGlanceCompetesTests {
    @Test func safariFileGlanceWinsWhenNewer() throws {
        let now = try Date("2026-11-15T12:00:00Z", strategy: .iso8601)
        let dir = FileManager.default.temporaryDirectory.appending(path: "hm-g-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let x = dir.appending(path: "native.json"), safari = dir.appending(path: "x-file.json"), bot = dir.appending(path: "g.json")
        try JSONSerialization.data(withJSONObject: ["generated": "2026-11-15T11:00:00Z", "account": ["followers": 1]]).write(to: x)
        try JSONSerialization.data(withJSONObject: ["updated": "2026-11-12T08:00:00Z", "pinned": ["title": "Bot", "url": "https://x.com/e/status/1"]]).write(to: bot)
        try JSONSerialization.data(withJSONObject: ["generated": "2026-11-15T11:30:00Z",
            "glance": ["updated": "2026-11-15T11:30:00Z", "pinned": ["title": "Safari", "url": "https://x.com/e/status/2"]]]).write(to: safari)
        let out = XFileNumbers.load(file: x.path, digest: nil, glanceFile: bot.path, glanceFiles: [safari.path], now: now)
        #expect(out[path: "glance.pinned.title"]?.string == "Safari")
    }
}
