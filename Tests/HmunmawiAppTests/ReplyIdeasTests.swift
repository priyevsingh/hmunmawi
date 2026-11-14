import Foundation
import Testing
@testable import HmunmawiApp

@Suite struct ReplyIdeasTests {
    // A real post id from 14 Nov 2026 (its time is inside the id).
    static let url = "https://x.com/example/status/2121610856794411128"
    static let posted = ReplyIdeas.postedAt(url)!

    @Test func readsTheTimeFromThePostID() {
        let day = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: Self.posted)
        #expect(day.year == 2026 && day.month == 11 && day.day == 14)
    }

    @Test func parsesTheBotsFile() {
        let list: [[String: Any]] = [["tweet_url": Self.url, "author": "example", "tweet_text": "Shipping SwiftUI widgets", "reply_text": "I hit the same thing with widgets"],
                                     ["tweet_url": Self.url, "reply_text": "  "], ["author": "no link"]]
        let parsed = ReplyIdeas.parse(list)
        #expect(parsed.count == 2 && parsed[1].reply.isEmpty)   // no draft = a post for you to reply to yourself; no link = dropped
    }

    @Test func checksEachTarget() {
        let ok = ReplyIdeas.Target(url: Self.url, author: "example", tweet: "Shipping SwiftUI widgets", reply: "I hit the same thing with widgets last week")
        let soon = Self.posted.addingTimeInterval(3600)
        #expect(ReplyIdeas.problem(ok, topics: ["swiftui"], versions: [:], now: soon) == nil)
        #expect(ReplyIdeas.problem(ok, topics: ["gardening"], versions: [:], now: soon) == "off your topics")
        #expect(ReplyIdeas.problem(ok, topics: [], versions: [:], now: Self.posted.addingTimeInterval(49 * 3600)) == "post older than 48 hours")
        var link = ok; link.reply = "see https://example.com"
        #expect(ReplyIdeas.problem(link, topics: [], versions: [:], now: soon) == "a link in the reply")
        var bad = ok; bad.url = "https://example.com/status/1"
        #expect(ReplyIdeas.problem(bad, topics: [], versions: [:], now: soon) == "not an X post link")
    }
}

@Suite struct UnfollowListTests {
    @Test func readsTheBotsListAndSkipsKeeps() {
        let file: [String: Any] = ["non_followbacks": [["handle": "alpha", "suggestion": "unfollow"], ["handle": "beta", "suggestion": "keep (engaged)"],
                                                      ["handle": "gamma"], ["handle": "bad handle!"]]]
        #expect(UnfollowList.parse(file) == ["alpha", "gamma"])
        #expect(UnfollowList.parse(["delta", "@epsilon"]) == ["delta", "epsilon"])
    }

    @Test func batchesFromWhereItLeftOff() {
        let all = ["a1", "a2", "a3", "a4", "a5"]
        let (first, next) = UnfollowList.batch(all, from: 0, count: 2, keep: ["a2"])
        #expect(first == ["a1", "a3"] && next == 3)
        let (second, end) = UnfollowList.batch(all, from: next, count: 10, keep: [])
        #expect(second == ["a4", "a5"] && end == 5)
        #expect(UnfollowList.batch(all, from: end, count: 2, keep: []).0.isEmpty)
    }
}
