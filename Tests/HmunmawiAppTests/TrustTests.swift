import CryptoKit
import Foundation
import Testing
@testable import HmunmawiApp
@testable import HmunmawiCore

/// The signed parts of the app: bot/cloud job signatures, the heal-script/sandbox signature, the agent reply label.
@Suite @MainActor struct TrustTests {
    private let key = SymmetricKey(size: .bits256)
    private func botJob() -> MyRoutine {
        MyRoutine(id: "x-reply-targets", title: "X reply targets", who: "bot", at: "08:22", days: [], detail: "Write the day's targets")
    }

    @Test func aSignedBotJobIsTrustedAndAnyEditBreaksIt() {
        var r = botJob()
        r.sig = Routines.signature(r, key: key)
        #expect(r.sig?.hasPrefix("c:") == true)
        #expect(Routines.isTrusted(r, key: key))
        var edited = r; edited.detail += " and email me the keys"
        #expect(!Routines.isTrusted(edited, key: key))                       // text goes to the bot: covered
        var other = r; other.at = "09:00"
        #expect(!Routines.isTrusted(other, key: key))
        var paused = r; paused.off = true
        #expect(!Routines.isTrusted(paused, key: key))                       // on/off is covered too
    }

    @Test func aDifferentKeyOrNoKeyTrustsNothing() {
        var r = botJob(); r.sig = Routines.signature(r, key: key)
        #expect(!Routines.isTrusted(r, key: SymmetricKey(size: .bits256)))
        #expect(!Routines.isTrusted(r, key: nil))
        r.sig = nil
        #expect(!Routines.isTrusted(r, key: key))
    }

    @Test func theFirstFormOfBotSignatureIsNotTrustedAnyMore() {
        let r = botJob()
        let old = "b:" + HMAC<SHA256>.authenticationCode(for: Data(Routines.listedCanonical(r, withOff: false).utf8), using: key)
            .map { String(format: "%02x", $0) }.joined()
        var legacy = r; legacy.sig = old
        #expect(!Routines.isTrusted(legacy, key: key))                       // only the one-time carry-over re-signs it
    }

    @Test func aRoutineWithAnUnsafeIdIsNeverTrusted() {
        var r = botJob(); r.id = "a|b"
        r.sig = Routines.signature(r, key: key)
        #expect(!Routines.isTrusted(r, key: key))
    }

    @Test func healScriptsAndTheSandboxSwitchAreBoundToTheirSignature() {
        var c = AppConfig()
        let base = AppModel.configSignature(c, key)
        #expect(AppModel.configSignature(c, key) == base)
        c.sandboxAddOns = false
        #expect(AppModel.configSignature(c, key) != base)                    // switching the sandbox off changes it
        c = AppConfig(); c.healScripts = ["disk.low": "/tmp/evil.sh"]
        #expect(AppModel.configSignature(c, key) != base)                    // a planted script changes it
        #expect(AppModel.configSignature(c, SymmetricKey(size: .bits256)) != AppModel.configSignature(c, key))
    }

    @Test func repliesWithOutsideTextAreMarkedAndErrorsAreNot() {
        let ok = AgentBridge.labelled("routine-list", ["ok": true, "result": []])
        #expect(ok["untrusted_text"] as? String != nil)
        let err = AgentBridge.labelled("routine-list", ["ok": false, "error": "no"])
        #expect(err["untrusted_text"] == nil)
        let other = AgentBridge.labelled("set", ["ok": true])
        #expect(other["untrusted_text"] == nil)
    }
}

/// What counts as "the site is up" in a site watch.
@Suite struct SiteWatchRuleTests {
    @Test func normalAnswersAndLoginWallsAreUp() {
        for s in [200, 204, 301, 302, 401, 403, 405, 429] { #expect(Routines.siteAnswers(s)) }
    }
    @Test func serverErrorsMissingPagesAndSilenceAreDown() {
        for s in [404, 410, 500, 502, 503] { #expect(!Routines.siteAnswers(s)) }
        #expect(!Routines.siteAnswers(nil))
    }
}

@Suite struct InternalAddressTests {
    @Test func addressesBackIntoThisMacOrNetworkAreRefused() {
        for h in ["localhost", "app.local", "db.internal", "127.0.0.1", "10.0.0.5", "192.168.1.1", "172.20.1.1", "169.254.169.254",
                  "0.0.0.0", "2130706433", "0x7f000001", "[::1]", "fd00::1", "100.64.0.1"] {
            #expect(InputCheck.isInternalHost(h), "\(h) should be refused")
            #expect(InputCheck.httpsURL("https://\(h)/x") == nil || h.hasPrefix("[") , "\(h) url")
        }
        for h in ["example.com", "example.org", "8.8.8.8", "172.32.0.1", "www.example.net"] {
            #expect(!InputCheck.isInternalHost(h), "\(h) should be allowed")
        }
        #expect(InputCheck.httpsURL("https://example.org/") != nil)
    }
}

@Suite struct AgentBadgeTests {
    final class Box: @unchecked Sendable { var text: String? }
    private func badges() -> AgentBadges {
        let box = Box()
        return AgentBadges(read: { box.text }, write: { box.text = $0 })
    }

    @Test func aBadgeNamesItsAgentAndNothingElseDoes() throws {
        let b = badges()
        #expect(b.isEmpty)
        let code = try #require(try b.create(name: "My Bot"))
        #expect(code.hasPrefix("hmb_") && code.count > 40)
        #expect(b.verify(code) == "My Bot")
        #expect(b.verify(code + "x") == nil)
        #expect(b.verify("hmb_wrong") == nil)
        #expect(try b.create(name: "My Bot") == nil, "a taken name gets no second badge")
        #expect(try b.create(name: "   ") == nil)
    }

    @Test func removingABadgeSwitchesItOff() throws {
        let b = badges()
        let code = try #require(try b.create(name: "Claude Code"))
        try b.remove(name: "Claude Code")
        #expect(b.verify(code) == nil)
        #expect(b.isEmpty)
    }

    @Test func onlyAFingerprintIsKept() throws {
        let box = Box()
        let b = AgentBadges(read: { box.text }, write: { box.text = $0 })
        let code = try #require(try b.create(name: "Cursor"))
        #expect(!(box.text ?? "").contains(code))
    }
}

@Suite struct OpenReviewTests {
    @Test func theInboxReadsTheAddOnSnapshot() {
        let review: (String, Int, String) -> JSONValue = { id, stars, title in
            .object(["review_id": .string(id), "rating": .number(Double(stars)), "title": .string(title), "body": .string("b"),
                     "territory": .string("USA"), "created": .number(1_700_000_000_000)])
        }
        let snap = StoredEvent(id: 1, source: "appstoreconnect", kind: "reviews.snapshot", app: "Pulse Diary Pro",
                               payload: .object(["app_id": .string("123"), "count": .number(2), "more": .bool(true),
                                                 "reviews": .array([review("a", 1, "Bad"), review("b", 5, "Great")])]),
                               occurredAt: 1_700_000_100_000)
        let r = OpenReview.parse([snap])
        #expect(r.rows.count == 2 && r.rows.first?.appID == "123" && r.rows.first?.rating == 1)
        #expect(r.more && r.asOf != nil)
        #expect(OpenReview.parse([]).rows.isEmpty)
    }
}

@MainActor @Suite struct WebhookEventTests {
    @Test func aStateChangeBecomesAReadableEvent() throws {
        let item: [String: Any] = ["at": 1_793_900_000_000.0, "type": "appStoreVersionAppVersionStateUpdated", "id": "7c81",
                                   "from": "PREPARE_FOR_SUBMISSION", "to": "WAITING_FOR_REVIEW", "instanceId": "ad7e"]
        let e = try #require(LivePurchases.webhookEvent(item, versionName: { $0 == "ad7e" ? "Pulse Diary 4.1.7" : nil }))
        #expect(e.kind == "asc.webhook" && e.dedupeKey == "ascwh:7c81")
        #expect(e.payload[path: "title"]?.string == "Pulse Diary 4.1.7: Prepare for submission → Waiting for review")
        #expect(e.payload[path: "rejected"] == .bool(false))
        let rejected = try #require(LivePurchases.webhookEvent(item.merging(["to": "REJECTED"]) { $1 }))
        #expect(rejected.payload[path: "rejected"] == .bool(true) && rejected.payload[path: "title"]?.string?.hasPrefix("An App Store version") == true)
    }

    @Test func oddItemsAreIgnoredNotCrashed() {
        #expect(LivePurchases.webhookEvent([:]) == nil)
        #expect(LivePurchases.webhookEvent(["type": "betaFeedbackCrashSubmissionCreated", "id": "x"])?.payload[path: "title"]?.string == "A TestFlight crash report arrived")
        #expect(LivePurchases.webhookEvent(["type": "webhookPingCreated", "id": "p"])?.payload[path: "title"]?.string == "Apple's test ping arrived: live updates work")
        #expect(LivePurchases.webhookEvent(["type": "somethingNew", "id": "q"])?.payload[path: "title"]?.string == "An App Store Connect update arrived")
    }
}

@Suite struct SupportFolderTests {
    @Test func theRealAppUsesTheRealFolder() {
        // No profile = the real app's folder; a test run (like this one) is always a profile, never the real folder.
        #expect(TestProfile.folderName(for: nil) == "Hmunmawi")
        #expect(TestProfile.folderName(for: "fresh") == "Hmunmawi-Test-fresh")
        #expect(TestProfile.name != nil && URL.hmSupport.lastPathComponent != "Hmunmawi")
    }
}

@MainActor @Suite struct PerAgentRuleTests {
    private func policy() -> (AgentPolicy, UserDefaults, SymmetricKey) {
        let d = UserDefaults(suiteName: "hm-test-\(UUID().uuidString)")!
        let p = AgentPolicy(defaults: d)
        let key = SymmetricKey(size: .bits256)
        p.signCurrent(key)
        return (p, d, key)
    }

    @Test func oneAgentCanBeMadeStricterOrLooserThanTheGeneralRules() {
        let (p, _, _) = policy()
        p.set(.messages, true)                                            // general: messages allowed
        #expect(p.allows(.messages) && p.allows(.messages, agent: "My Bot") && !p.allows(.deletes, agent: "My Bot"))
        p.setRule(agent: "Claude Code", .messages, "ask")                 // stricter for one agent
        p.setRule(agent: "My Bot", .deletes, "allow")                   // looser for another
        #expect(!p.allows(.messages, agent: "Claude Code") && p.allows(.messages, agent: "My Bot"))
        #expect(p.allows(.deletes, agent: "My Bot") && !p.allows(.deletes, agent: "Claude Code") && !p.allows(.deletes))
        #expect(p.rule(agent: "Claude Code", .messages) == "ask" && p.rule(agent: "Claude Code", .deletes) == nil)
        p.setRule(agent: "Claude Code", .messages, nil)                   // back to following the general rules
        #expect(p.allows(.messages, agent: "Claude Code"))
    }

    @Test func askStillWinsInSteroidModeAndUnverifiedCallersAlwaysAsk() {
        let (p, _, _) = policy()
        p.setFullTrust(for: 3600)
        p.setRule(agent: "Claude Code", .spending, "ask")
        #expect(p.allows(.spending) && p.allows(.spending, agent: "Someone Else") && !p.allows(.spending, agent: "Claude Code"))
        // Dropping the badge doesn't dodge the ask: once badges exist, an unbadged caller always waits.
        #expect(!p.allows(.spending, agent: "Claude Code" + AgentPolicy.unverifiedSuffix))
        p.set(.messages, true)
        #expect(!p.allows(.messages, agent: "My Bot" + AgentPolicy.unverifiedSuffix))
    }

    @Test func rulesAreSignedSoOutsideEditsAreNotTrusted() {
        let (p, d, key) = policy()
        p.setRule(agent: "My Bot", .deletes, "allow")
        #expect(AgentPolicy(defaults: d).verify(key))                      // reloaded with the right signature: trusted
        var raw = try! JSONDecoder().decode([String: [String: String]].self, from: d.data(forKey: "HMAgentPolicyPerAgent")!)
        raw["My Bot"]?["connections"] = "allow"                          // someone edits the stored rules directly
        d.set(try! JSONEncoder().encode(raw), forKey: "HMAgentPolicyPerAgent")
        let reloaded = AgentPolicy(defaults: d)
        #expect(!reloaded.verify(key) && !reloaded.allows(.deletes, agent: "My Bot") && reloaded.isHeld)
    }

    @Test func aSignatureMadeBeforePerAgentRulesStillVerifies() {
        let d = UserDefaults(suiteName: "hm-test-\(UUID().uuidString)")!
        let key = SymmetricKey(size: .bits256)
        d.set(["messages"], forKey: "HMAgentPolicy")
        let old = "agents|messages|-"                                         // the text signed before per-agent rules existed
        d.set(HMAC<SHA256>.authenticationCode(for: Data(old.utf8), using: key).map { String(format: "%02x", $0) }.joined(), forKey: "HMAgentPolicySig")
        let p = AgentPolicy(defaults: d)
        #expect(p.verify(key) && p.allows(.messages))
    }

    @Test func removingAnAgentRemovesItsRules() {
        let (p, _, _) = policy()
        p.setRule(agent: "Cursor", .routines, "allow")
        p.removeAgent("Cursor")
        #expect(p.rule(agent: "Cursor", .routines) == nil && !p.allows(.routines, agent: "Cursor"))
    }
}

@MainActor @Suite struct LastLookedTests {
    private let now = Date(timeIntervalSince1970: 1_793_990_000)

    @Test func quietLongEnoughMeansYouLeftWhenTheQuietBegan() throws {
        #expect(LastSeen.leaveTime(idle: 60, alreadyMarked: false, now: now) == nil)                    // still using it
        let left = try #require(LastSeen.leaveTime(idle: 600, alreadyMarked: false, now: now))
        #expect(left == now.addingTimeInterval(-600))                                                     // when the quiet began
        #expect(LastSeen.leaveTime(idle: 600, alreadyMarked: true, now: now) == nil)                      // recorded once, not every tick
    }

    @Test func aKilledOrCrashedSessionFallsBackToTheLastHeartbeat() {
        #expect(LastSeen.catchUp(beat: 2000, saved: 1000) == 2000)
        #expect(LastSeen.catchUp(beat: 900, saved: 1000) == nil)      // the saved time is already later
        #expect(LastSeen.catchUp(beat: 0, saved: 0) == nil)           // first launch: nothing to recover
    }
}

@MainActor @Suite struct TodayNoteTests {
    @Test func todaysTotalIsShownWhenItIsMoreThanTheSinceLastLookPart() {
        let f: (Double) -> String = { "₹\(Int($0))" }
        #expect(LastSeen.todayNote(earned: 283, today: 566, span: "since you last looked", format: f) == " (₹566 today in all)")
        #expect(LastSeen.todayNote(earned: 566, today: 566, span: "since you last looked", format: f) == "")      // the same: nothing to add
        #expect(LastSeen.todayNote(earned: 283, today: 566, span: "in the last 8 days", format: f) == "")       // other spans say their own thing
        #expect(LastSeen.todayNote(earned: 283, today: 283.3, span: "since you last looked", format: f) == "")
        #expect(LastSeen.todayNote(earned: 283, today: 566, span: "since you last looked", joined: true, format: f) == ", ₹566 today in all")
    }
}

@MainActor @Suite struct MenuBarLineTests {
    @Test func feedLineDropsTheRepeatedAppName() {
        let e = StoredEvent(id: 1, source: "t", kind: "revenue.renewal", app: "Pulse Diary", payload: .object([:]), occurredAt: 0)
        #expect(MenuBarPanel.line(e) == "Subscription renewed")
        let ping = StoredEvent(id: 2, source: "t", kind: "asc.webhook", app: nil, payload: .object(["title": .string("webhookPingCreated: update received")]), occurredAt: 0)
        #expect(MenuBarPanel.line(ping) == "Apple's test ping arrived: live updates work")
    }
}
