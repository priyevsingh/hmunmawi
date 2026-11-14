import Foundation
import Testing
@testable import HmunmawiCore

@Suite struct XSafariFindsTests {
    @Test func nonFollowbacksKeepBigAccountsAndSkipOddHandles() throws {
        let page = #"{"users":[{"handle":"friend","back":true,"followers":10},{"handle":"quiet","back":false,"followers":300},{"handle":"famous","back":false,"followers":2000000},{"handle":"bad handle!","back":false},{"handle":"Quiet","back":false}]}"#
        let list = try #require(XSafariFinds.nonFollowbacks(page))
        #expect(list.map { $0["handle"]! } == ["quiet", "famous"])
        #expect(list[0]["suggestion"] == "unfollow" && list[1]["suggestion"]!.hasPrefix("keep"))
        #expect(XSafariFinds.nonFollowbacks(#"{"error":"still loading"}"#) == nil)
    }

    @Test func searchURLIsEncodedAndFiltered() throws {
        let url = try #require(XSafariFinds.searchURL(topics: ["SwiftUI", "indie apps", " "]))
        #expect(url.hasPrefix("https://x.com/search?q=") && url.hasSuffix("&f=live") && !url.contains(" "))
        #expect(url.removingPercentEncoding!.contains(#"(SwiftUI OR "indie apps") min_faves:3 -filter:replies -filter:links"#))
        #expect(XSafariFinds.searchURL(topics: []) == nil)
    }

    @Test func picksFreshOnTopicConversationOnePerAuthor() {
        let now = try! Date("2026-11-15T12:00:00Z", strategy: .iso8601)
        let page = """
        {"tweets":[
         {"id":"1","author":"dev_a","followers":900,"created_at":"2026-11-15T10:00:00.000Z","text":"Shipped a SwiftUI widget today, what broke for you?","likes":4,"replies":6},
         {"id":"2","author":"dev_a","followers":900,"created_at":"2026-11-15T09:00:00.000Z","text":"SwiftUI again","likes":50,"replies":0},
         {"id":"3","author":"dev_b","followers":500,"created_at":"2026-11-13T10:00:00.000Z","text":"old SwiftUI post","likes":99,"replies":9},
         {"id":"4","author":"dev_c","followers":500,"created_at":"2026-11-15T11:00:00.000Z","text":"cooking pasta","likes":30,"replies":9},
         {"id":"5","author":"dev_d","followers":500,"created_at":"2026-11-15T11:00:00.000Z","text":"SwiftUI tip https://t.co/x","likes":30,"replies":9},
         {"id":"6","author":"huge","followers":5000000,"created_at":"2026-11-15T11:00:00.000Z","text":"SwiftUI","likes":900,"replies":90}]}
        """
        let picks = XSafariFinds.pick(page, topics: ["swiftui"], now: now, count: 5)
        #expect(picks.map(\.url) == ["https://x.com/dev_a/status/1"])   // one per author, fresh, on topic, no link, not huge
    }

    @Test func cleanReplyRefusesSkipLinksAndHashtags() {
        #expect(XSafariFinds.cleanReply(" \"Tried that: the widget timeline reloads only every 15 min for me.\" ") == "Tried that: the widget timeline reloads only every 15 min for me.")
        #expect(XSafariFinds.cleanReply("SKIP") == nil && XSafariFinds.cleanReply("see https://a.b") == nil && XSafariFinds.cleanReply("nice #buildinpublic") == nil)
    }
}

@Suite struct XReplyDrafterTests {
    @Test func autoIsFreeFirst() {
        #expect(XSafariFinds.drafter(choice: nil, onDevice: true, aiKey: true) == .onDevice)      // Apple's free model before a paid key
        #expect(XSafariFinds.drafter(choice: "auto", onDevice: false, aiKey: true) == .aiKey)
        #expect(XSafariFinds.drafter(choice: "auto", onDevice: false, aiKey: false) == XSafariFinds.Drafter.none)
    }

    @Test func explicitChoicesNeverFallBackToSomethingElse() {
        #expect(XSafariFinds.drafter(choice: "ai", onDevice: true, aiKey: false) == XSafariFinds.Drafter.none)       // never spends on-device as a substitute silently
        #expect(XSafariFinds.drafter(choice: "ondevice", onDevice: false, aiKey: true) == XSafariFinds.Drafter.none) // never spends the key unasked
        #expect(XSafariFinds.drafter(choice: "none", onDevice: true, aiKey: true) == XSafariFinds.Drafter.none)
    }

    @Test func promptForbidsInventedFacts() {
        let c = XSafariFinds.Candidate(url: "https://x.com/a/status/1", author: "a", text: "t", likes: 0, replies: 0, posted: .now)
        #expect(XSafariFinds.replyPrompt(c, about: "x").contains("Never invent numbers"))
    }
}
