import Foundation
import Testing
@testable import HmunmawiCore

@Suite struct XUnfollowTests {
    private func page(_ o: [String: Any]) -> XUnfollow.Page {
        var base: [String: Any] = ["ready": "complete", "me": "Me\n@me_dev", "username": "Quiet One\n@quiet", "page_id": "42",
                                   "btn": "following", "btn_text": "Following"]
        for (k, v) in o { base[k] = v }
        let d = try! JSONSerialization.data(withJSONObject: base)
        return XUnfollow.Page(json: String(decoding: d, as: UTF8.self))!
    }
    private let quiet = XUnfollow.Account(handle: "quiet", id: "42")

    @Test func snapshotFromFollowingKeepsOnlyNonFollowbacksWithIdsAndNoBigAccounts() throws {
        let json = #"{"users":[{"handle":"friend","id":"1","back":true,"followers":10},{"handle":"quiet","id":"42","back":false,"followers":300},{"handle":"famous","id":"7","back":false,"followers":2000000},{"handle":"noid","id":"","back":false},{"handle":"bad handle!","id":"9","back":false},{"handle":"quiet","id":"42","back":false}]}"#
        let list = try #require(XUnfollow.snapshot(fromFollowing: json))
        #expect(list == [XUnfollow.Account(handle: "quiet", id: "42", followers: 300)])
        #expect(XUnfollow.snapshot(fromFollowing: #"{"error":"still loading"}"#) == nil)
    }

    @Test func snapshotFromBotFileDropsKeepsMutualsAndBigAccounts() {
        let doc: [String: Any] = ["mutuals": ["Pal"], "non_followbacks": [
            ["handle": "a1", "id": "11", "suggestion": "unfollow"],
            ["handle": "keepme", "id": "12", "suggestion": "keep (big account)"],
            ["handle": "pal", "id": "13"],
            ["handle": "huge", "id": "14", "followers": 90_000],
            ["handle": "noid"],
            ["handle": "a1", "id": "11"]]]
        let list = XUnfollow.snapshot(fromFile: doc)
        #expect(list.map(\.handle) == ["a1", "noid"])
        #expect(list[0].key == "id:11" && list[1].key == "@noid")
        #expect(XUnfollow.snapshot(fromFile: ["x_one", "bad handle"]).map(\.handle) == ["x_one"])
    }

    @Test func remainingSkipsDoneSkippedAndKeeps() {
        var s = XUnfollow.State()
        s.snapshot = [quiet, .init(handle: "b", id: "2"), .init(handle: "Keeper", id: "3"), .init(handle: "c", id: "4")]
        XUnfollow.record(&s, day: "2026-11-20", account: quiet, result: .unfollowed, note: "ok", at: .now)
        XUnfollow.record(&s, day: "2026-11-20", account: .init(handle: "b", id: "2"), result: .skip, note: "mutual", at: .now)
        #expect(XUnfollow.remaining(s, keep: XUnfollow.keepSet(" @keeper, x")).map(\.handle) == ["c"])
        #expect(s.days["2026-11-20"]?.done == 1 && s.days["2026-11-20"]?.skipped == 1)
    }

    @Test func classifyFollowsTheSafetyOrder() {
        #expect(XUnfollow.classify(page([:]), account: quiet, me: "me_dev") == .following(.following))
        #expect(XUnfollow.classify(page(["login": true]), account: quiet, me: "me_dev") == .safety("X showed its login page"))
        #expect(XUnfollow.classify(page(["challenge": true]), account: quiet, me: "me_dev") == .safety("X showed a challenge or unusual-activity page"))
        #expect(XUnfollow.classify(page(["ratelimit": true]), account: quiet, me: "me_dev") == .safety("X rate limit"))
        #expect(XUnfollow.classify(page(["wrong": true]), account: quiet, me: "me_dev") == .safety("X said \"Something went wrong\""))
        #expect(XUnfollow.classify(page(["me": "Other\n@someone"]), account: quiet, me: "me_dev") == .safety("Safari is signed in to X as someone else"))
        // Never someone who follows you, never a different person, never a missing signed-in account.
        #expect(XUnfollow.classify(page(["follows_you": true]), account: quiet, me: "me_dev") == .skip("now follows you (mutual), kept"))
        #expect(XUnfollow.classify(page(["username": "Q\n@quiet2"]), account: quiet, me: "me_dev") == .skip("page is a different user (handle changed?)"))
        // X's real name line has no space before the handle.
        #expect(XUnfollow.classify(page(["username": "Josh “Pizza” Holtz 💪🍕@quiet\nFollows you", "follows_you": true]), account: quiet, me: "me_dev") == .skip("now follows you (mutual), kept"))
        #expect(XUnfollow.classify(page(["username": "Josh “Pizza” Holtz 💪🍕@quiet"]), account: quiet, me: "me_dev") == .following(.following))
        #expect(XUnfollow.classify(page(["username": "Q🍕@quiet_x"]), account: quiet, me: "me_dev") == .skip("page is a different user (handle changed?)"))
        #expect(XUnfollow.classify(page(["me": "Me Dev@me_dev"]), account: quiet, me: "me_dev") == .following(.following))
        #expect(XUnfollow.classify(page(["page_id": "99"]), account: quiet, me: "me_dev") == .skip("page is a different user (id changed)"))
        #expect(XUnfollow.classify(page(["me": ""]), account: quiet, me: "me_dev") == .fail("could not confirm the signed-in account"))
        #expect(XUnfollow.classify(page(["btn": "follow", "btn_text": "Follow"]), account: quiet, me: "me_dev") == .skip("already not following"))
        #expect(XUnfollow.classify(page(["btn": "", "username": ""]), account: quiet, me: "me_dev") == .fail("profile did not load"))
        // Subscribe-style profile with the exact "Unfollow @handle" icon: aria path; any other label is not clicked.
        #expect(XUnfollow.classify(page(["btn": "subscribe", "btn_text": "Subscribe", "aria_unfollow": "Unfollow @quiet"]), account: quiet, me: "me_dev") == .following(.aria))
        #expect(XUnfollow.classify(page(["btn": "subscribe", "btn_text": "Subscribe", "aria_unfollow": "Unfollow @other"]), account: quiet, me: "me_dev") == .skip("already not following (button says Subscribe)"))
    }

    @Test func unfollowedOnlyWhenFollowIsBack() {
        #expect(XUnfollow.unfollowed(page(["btn": "follow", "btn_text": "Follow"])))
        #expect(!XUnfollow.unfollowed(page([:])))
        #expect(!XUnfollow.unfollowed(page(["btn": "follow", "aria_unfollow": "Unfollow @quiet"])))
    }

    @Test func failureIsRetriedOnceThenSkippedAndStreakCounts() {
        var s = XUnfollow.State()
        let b = XUnfollow.Account(handle: "b", id: "2")
        XUnfollow.record(&s, day: "d1", account: quiet, result: .fail, note: "x", at: .now)
        #expect(s.failures[quiet.key] == 1 && s.skipped.isEmpty && s.failStreak.count == 1)
        XUnfollow.record(&s, day: "d1", account: quiet, result: .fail, note: "x", at: .now)
        #expect(s.skipped.count == 1 && s.failures[quiet.key] == nil && s.failStreak.count == 1)
        XUnfollow.record(&s, day: "d1", account: b, result: .fail, note: "x", at: .now)
        #expect(s.failStreak.count == 2)
        XUnfollow.record(&s, day: "d2", account: b, result: .fail, note: "x", at: .now)
        #expect(s.failStreak == [b.key])   // a new day starts a new streak
        XUnfollow.record(&s, day: "d2", account: .init(handle: "c", id: "3"), result: .unfollowed, note: "ok", at: .now)
        #expect(s.failStreak.isEmpty)
    }

    @Test func hardStopTwoDaysRunningHolds() {
        var s = XUnfollow.State()
        let m1 = XUnfollow.stop(&s, day: "2026-11-19", previousDay: "2026-11-18", reason: "X rate limit", left: 10)
        #expect(s.hold == nil && m1.contains("starts again tomorrow"))
        let m2 = XUnfollow.stop(&s, day: "2026-11-20", previousDay: "2026-11-19", reason: "X showed its login page", left: 10)
        #expect(s.hold != nil && m2.contains("Resume"))
        var t = XUnfollow.State()
        _ = XUnfollow.stop(&t, day: "2026-11-19", previousDay: "2026-11-18", reason: "lost its Safari tab", left: 1)
        _ = XUnfollow.stop(&t, day: "2026-11-20", previousDay: "2026-11-19", reason: "X rate limit", left: 1)
        #expect(t.hold == nil)
    }

    @Test func pacingNeverUnderTenMinutesAndSpreadsTheDay() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            #expect(XUnfollow.nextGap(secondsLeftInWindow: 60, doneToday: 0, perDay: 25, using: &rng) >= XUnfollow.minGap)
            let g = XUnfollow.nextGap(secondsLeftInWindow: 10 * 3600, doneToday: 20, perDay: 25, using: &rng)
            #expect(g >= 0.6 * 7200 && g <= 1.3 * 7200)
        }
    }

    @Test func windowsAndLimits() {
        #expect(XUnfollow.window(nil)! == (600, 1200))
        #expect(XUnfollow.window("08:30-22:00")! == (510, 1320))
        #expect(XUnfollow.window("20:00-10:00") == nil && XUnfollow.window("10-20") == nil && XUnfollow.window("10:00-10:30") == nil)
        #expect(XUnfollow.perDay(nil) == 25 && XUnfollow.perDay("500") == XUnfollow.maxPerDay && XUnfollow.perDay("0") == 1)
    }

    @Test func scriptsQuoteHandlesSafely() {
        #expect(XUnfollow.jsString("a\"b'</script>") == #""a\"b'</script>""#)
        #expect(XUnfollow.probeJS(quiet).contains(#"var ID="42", H="quiet";"#))
        #expect(XUnfollow.ariaMenuJS(quiet).contains(#""unfollow @quiet""#))
    }

    @Test func xUnfollowsIsAJobSwitch() throws {
        let obj = try SwitchFile.parse(Data(#"{"x": true, "reddit": false}"#.utf8)).get()
        let sw = SwitchFile.switches(in: obj)
        let s = try #require(sw.first { $0.id == "x_unfollows" })
        #expect(s.value && !s.isSet && s.group == SwitchFile.xGroup)
    }
}
