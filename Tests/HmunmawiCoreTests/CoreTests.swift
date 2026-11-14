import Foundation
import Synchronization
import Testing
@testable import HmunmawiCore

final class TestClock: Sendable {
    private let value = Mutex<Millis>(1_000_000)
    var now: Millis { value.withLock { $0 } }
    func advance(seconds: Int64) { value.withLock { $0 += seconds * 1000 } }
}

private func makeStore(_ clock: TestClock = TestClock()) throws -> Store {
    try Store(path: ":memory:", now: { clock.now })
}

private func refund(_ key: String, amount: Double = 9.99, app: String = "com.example.app") -> Event {
    Event(source: "demo", kind: "revenue.refund", app: app,
          payload: .object(["amount": .number(amount)]), occurredAt: 0, dedupeKey: key)
}

private func refundRule(approval: Approval = .auto, dryRun: Bool = false, cooldown: Int = 0) -> Rule {
    Rule(id: "refund-alert", when: "revenue.*",
         conditions: [Condition(field: "amount", op: .gt, value: .number(5))],
         actions: [RuleAction(action: "notify", resource: "imessage")],
         priority: 2, cooldownSeconds: cooldown, approval: approval, dryRun: dryRun)
}

@Suite struct RuleTests {
    @Test func decodesWithSafeDefaults() throws {
        let json = #"{"id":"r","when":"revenue.refund","do":[{"action":"notify"}]}"#
        let rule = try JSONDecoder().decode(Rule.self, from: Data(json.utf8))
        #expect(rule.approval == .ask)
        #expect(rule.dryRun)
        #expect(rule.enabled)
        #expect(rule.conditions.isEmpty)
    }

    @Test func matchesKindWildcardAndConditions() {
        let rule = refundRule()
        #expect(rule.matches(refund("a", amount: 10)))
        #expect(!rule.matches(refund("a", amount: 1)))
        #expect(!rule.matches(Event(source: "demo", kind: "review.new", occurredAt: 0, dedupeKey: "x")))
    }

    @Test func matchesAppAndContains() {
        let byApp = Condition(field: "app", op: .eq, value: .string("com.example.app"))
        #expect(byApp.holds(for: refund("a")))
        let event = Event(source: "demo", kind: "review.new",
                          payload: .object(["review": .object(["text": .string("Crashes on launch")])]),
                          occurredAt: 0, dedupeKey: "r1")
        #expect(Condition(field: "review.text", op: .contains, value: .string("crash")).holds(for: event))
    }

    @Test func matchesStarsAndCountriesFromAList() {
        let review = { (stars: Double, country: String) in
            Event(source: "demo", kind: "review.new", payload: .object(["rating": .number(stars), "territory": .string(country)]),
                  occurredAt: 0, dedupeKey: "r\(stars)")
        }
        let oneOrFive = Condition(field: "rating", op: .oneOf, value: .array([.number(1), .number(5)]))
        #expect(oneOrFive.holds(for: review(1, "IND")))
        #expect(oneOrFive.holds(for: review(5, "IND")))
        #expect(!oneOrFive.holds(for: review(3, "IND")))
        let countries = Condition(field: "territory", op: .oneOf, value: .array([.string("ind"), .string("USA")]))
        #expect(countries.holds(for: review(2, "IND")))
        #expect(!countries.holds(for: review(2, "DEU")))
    }
}

@Suite struct IngestTests {
    @Test func duplicateEventIsDropped() async throws {
        let store = try makeStore()
        let first = try await store.ingest(refund("tx-1"), rules: [])
        let second = try await store.ingest(refund("tx-1"), rules: [])
        #expect(!first.duplicate)
        #expect(second.duplicate)
    }

    @Test func matchingRuleQueuesJob() async throws {
        let store = try makeStore()
        let result = try await store.ingest(refund("tx-1"), rules: [refundRule()])
        #expect(result.jobIDs.count == 1)
        let job = try #require(try await store.job(result.jobIDs[0]))
        #expect(job.state == .queued)
        #expect(job.resource == "imessage")
        #expect(job.priority == 2)
    }

    @Test func dryRunOnlyRecords() async throws {
        let store = try makeStore()
        let result = try await store.ingest(refund("tx-1"), rules: [refundRule(dryRun: true)])
        #expect(result.jobIDs.isEmpty)
        #expect(result.dryRunRuleIDs == ["refund-alert"])
        #expect(try await store.recentAudit().contains { $0.action == "rule.dry_run" })
    }

    @Test func appStoreConnectWriteNeverRunsWithoutTheOwner() async throws {
        // Even a rule set to "auto" must park an App Store Connect fix for approval, and never retry it.
        let store = try makeStore()
        let rule = Rule(id: "auto-fix", when: "revenue.*", actions: [RuleAction(action: "asc.fix", resource: "appstoreconnect")],
                        priority: 1, cooldownSeconds: 0, approval: .auto, dryRun: false)
        let result = try await store.ingest(refund("tx-asc"), rules: [rule])
        let job = try #require(try await store.job(result.jobIDs[0]))
        #expect(job.state == .waitingApproval)
        #expect(job.maxAttempts == 1)
    }

    @Test func askRuleWaitsForApproval() async throws {
        let store = try makeStore()
        let result = try await store.ingest(refund("tx-1"), rules: [refundRule(approval: .ask)])
        let id = result.jobIDs[0]
        #expect(try await store.job(id)?.state == .waitingApproval)
        #expect(try await store.claimNext(owner: "w") == nil)
        try await store.approve(id, by: "owner")
        #expect(try await store.claimNext(owner: "w")?.id == id)
    }

    @Test func neverRuleCreatesNoJob() async throws {
        let store = try makeStore()
        let result = try await store.ingest(refund("tx-1"), rules: [refundRule(approval: .never)])
        #expect(result.jobIDs.isEmpty)
    }

    @Test func cooldownSuppressesRepeatsPerApp() async throws {
        let clock = TestClock()
        let store = try makeStore(clock)
        let rule = refundRule(cooldown: 3600)
        #expect(try await store.ingest(refund("tx-1"), rules: [rule]).jobIDs.count == 1)
        #expect(try await store.ingest(refund("tx-2"), rules: [rule]).jobIDs.isEmpty)
        #expect(try await store.ingest(refund("tx-3", app: "other.app"), rules: [rule]).jobIDs.count == 1)
        clock.advance(seconds: 3601)
        #expect(try await store.ingest(refund("tx-4"), rules: [rule]).jobIDs.count == 1)
    }

    @Test func tryOutDoesNotMuteTheFirstRealAlert() async throws {
        let store = try makeStore()
        _ = try await store.ingest(refund("tx-1"), rules: [refundRule(dryRun: true, cooldown: 3600)])
        #expect(try await store.ingest(refund("tx-2"), rules: [refundRule(cooldown: 3600)]).jobIDs.count == 1)
    }

    @Test func crashNeverResendsAnAlert() async throws {
        // An alert interrupted mid-send may already have arrived: it's marked failed, not sent again.
        let store = try makeStore()
        let alert = try await store.enqueue(kind: "notify", resource: "imessage")
        let other = try await store.enqueue(kind: "report", resource: "r")
        _ = try await store.claimNext(owner: "w"); _ = try await store.claimNext(owner: "w")
        _ = try await store.recoverInterrupted()
        #expect(try await store.job(alert)?.state == .failed)
        #expect(try await store.job(other)?.state == .queued)
    }
}

@Suite struct QueueTests {
    @Test func priorityAndResourceLock() async throws {
        let store = try makeStore()
        let a = try await store.enqueue(kind: "a", resource: "r1", priority: 5)
        let b = try await store.enqueue(kind: "b", resource: "r1", priority: 1)
        let c = try await store.enqueue(kind: "c", resource: "r2", priority: 9)
        #expect(try await store.claimNext(owner: "w")?.id == b)
        #expect(try await store.claimNext(owner: "w")?.id == c)
        #expect(try await store.claimNext(owner: "w") == nil)
        try await store.complete(b)
        #expect(try await store.claimNext(owner: "w")?.id == a)
    }

    @Test func retriesWithBackoffThenFails() async throws {
        let clock = TestClock()
        let store = try makeStore(clock)
        let id = try await store.enqueue(kind: "x", resource: "r", maxAttempts: 2)
        _ = try await store.claimNext(owner: "w")
        try await store.fail(id, error: "timeout")
        #expect(try await store.job(id)?.state == .queued)
        #expect(try await store.claimNext(owner: "w") == nil)
        clock.advance(seconds: 30)
        #expect(try await store.claimNext(owner: "w")?.id == id)
        try await store.fail(id, error: "timeout again")
        let job = try #require(try await store.job(id))
        #expect(job.state == .failed)
        #expect(job.lastError == "timeout again")
    }

    @Test func recoversJobsLeftRunning() async throws {
        let store = try makeStore()
        let id = try await store.enqueue(kind: "x", resource: "r")
        _ = try await store.claimNext(owner: "w")
        #expect(try await store.recoverInterrupted() == 1)
        #expect(try await store.job(id)?.state == .queued)
    }

    @Test func rejectsInvalidTransition() async throws {
        let store = try makeStore()
        let id = try await store.enqueue(kind: "x", resource: "r")
        await #expect(throws: StoreError.self) { try await store.approve(id, by: "owner") }
    }
}

@Suite struct AuditTests {
    @Test func chainVerifiesAndDetectsTampering() async throws {
        let store = try makeStore()
        _ = try await store.ingest(refund("tx-1"), rules: [refundRule()])
        try await store.appendAudit(actor: "owner", action: "note")
        #expect(try await store.firstBrokenAuditEntry() == nil)

        try await store.rawExecute("UPDATE audit SET actor = 'someone-else' WHERE id = 2")
        #expect(try await store.firstBrokenAuditEntry() == 2)
    }

    @Test func detectsDeletedEntry() async throws {
        let store = try makeStore()
        for i in 0..<3 { try await store.appendAudit(actor: "owner", action: "note-\(i)") }
        try await store.rawExecute("DELETE FROM audit WHERE id = 2")
        #expect(try await store.firstBrokenAuditEntry() == 3)
    }

    @Test func pruningKeepsTheChainVerifiableAndSales() async throws {
        let clock = TestClock()
        let store = try makeStore(clock)
        for i in 0..<5 { try await store.appendAudit(actor: "owner", action: "old-\(i)") }
        _ = try await store.ingest(Event(source: "demo", kind: "revenue.purchase", payload: .object([:]), occurredAt: clock.now, dedupeKey: "sale"), rules: [])
        _ = try await store.ingest(Event(source: "demo", kind: "app.snapshot", payload: .object([:]), occurredAt: clock.now, dedupeKey: "snap"), rules: [])
        clock.advance(seconds: 100 * 86_400)
        try await store.appendAudit(actor: "owner", action: "recent")
        let removed = try await store.prune(olderThanDays: 90, auditDays: 90)
        #expect(removed.audit > 0)
        #expect(removed.events == 1)                              // the snapshot, not the sale
        #expect(try await store.firstBrokenAuditEntry() == nil)  // continues from the anchor
        // Tampering after pruning is still caught.
        try await store.rawExecute("UPDATE audit SET actor = 'x' WHERE action = 'recent'")
        #expect(try await store.firstBrokenAuditEntry() != nil)
    }
}

@Suite struct OvernightSafetyTests {
    private func twoChannelRule() -> Rule {
        Rule(id: "two", when: "revenue.*", actions: [RuleAction(action: "notify", resource: "imessage"),
                                                    RuleAction(action: "notify", resource: "ntfy")],
             priority: 2, cooldownSeconds: 3600, approval: .auto, dryRun: false)
    }

    @Test func oneFailedChannelKeepsTheCooldownWhenTheOtherWentOut() async throws {
        let store = try makeStore()
        let rule = twoChannelRule()
        #expect(try await store.ingest(refund("tx-1"), rules: [rule]).jobIDs.count == 2)
        let a = try #require(try await store.claimNext(owner: "t")); try await store.complete(a.id)
        let b = try #require(try await store.claimNext(owner: "t")); try await store.fail(b.id, error: "down")
        // The working channel already alerted: a second event inside the cooldown must not alert again.
        #expect(try await store.ingest(refund("tx-2"), rules: [rule]).jobIDs.isEmpty)
    }

    @Test func allChannelsFailedLiftsTheCooldown() async throws {
        let store = try makeStore()
        let rule = twoChannelRule()
        _ = try await store.ingest(refund("tx-1"), rules: [rule])
        for _ in 0..<2 { let j = try #require(try await store.claimNext(owner: "t")); try await store.fail(j.id, error: "down") }
        #expect(try await store.ingest(refund("tx-2"), rules: [rule]).jobIDs.count == 2)
    }

    @Test func stuckRunningJobIsFailedNotRetried() async throws {
        let clock = TestClock()
        let store = try makeStore(clock)
        _ = try await store.ingest(refund("tx-1"), rules: [refundRule()])
        let j = try #require(try await store.claimNext(owner: "t"))
        #expect(try await store.failStuck() == 0)          // fresh: left alone
        clock.advance(seconds: 21 * 60)
        #expect(try await store.failStuck() == 1)
        #expect(try await store.job(j.id)?.state == .failed)
        #expect(try await store.claimNext(owner: "t") == nil)  // never sent again
    }

    @Test func scriptThatIgnoresStopAndKeepsThePipeIsCutOff() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hm-lc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appending(path: "stuck.sh")
        try "#!/bin/sh\ntrap '' TERM\necho hi\n(sleep 6) &\nsleep 6\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let start = Date()
        await #expect(throws: WireError.self) { _ = try await LocalCommands.run(script.path, timeout: .seconds(1)) }
        #expect(Date().timeIntervalSince(start) < 10)

        let loud = dir.appending(path: "loud.sh")
        try "#!/bin/sh\nyes xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n".write(to: loud, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: loud.path)
        do { _ = try await LocalCommands.run(loud.path, timeout: .seconds(20)); Issue.record("expected too_large") }
        catch let e as WireError { #expect(e.code == "too_large") }

        let ok = dir.appending(path: "ok.sh")
        try "#!/bin/sh\necho '{\"a\":1}'\n".write(to: ok, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ok.path)
        let out = try await LocalCommands.run(ok.path, timeout: .seconds(5))
        #expect(out.stdout == "{\"a\":1}\n" && out.status == 0)
    }

    @Test func timedOutFixSaysItMayHaveRun() {
        let e = Engine.explain(WireError("timeout", "act took longer than 600 seconds"), action: "asc.fix")
        #expect("\(e)".contains("may still have gone through"))
        #expect("\(Engine.explain(WireError("timeout", "x"), action: "notify"))" == "\(WireError("timeout", "x"))")
    }
}

@Suite struct AlertAgeTests {
    @Test func oldEventIsStoredButNeverTexts() async throws {
        let clock = TestClock()
        clock.advance(seconds: 10 * 86_400)
        let store = try Store(path: ":memory:", now: { clock.now })
        let rule = Rule(id: "r", when: "revenue.*", actions: [RuleAction(action: "notify", resource: "imessage")],
                        priority: 2, cooldownSeconds: 3600, approval: .auto, dryRun: false)
        let old = Event(source: "t", kind: "revenue.refund", app: "A", payload: .object([:]),
                        occurredAt: clock.now - 3 * 86_400_000, dedupeKey: "old")
        let r = try await store.ingest(old, rules: [rule])
        #expect(r.eventID != nil && r.jobIDs.isEmpty)
        // And it didn't start the cooldown: a fresh one alerts.
        let fresh = Event(source: "t", kind: "revenue.refund", app: "A", payload: .object([:]), occurredAt: clock.now, dedupeKey: "new")
        #expect(try await store.ingest(fresh, rules: [rule]).jobIDs.count == 1)
    }
}

@Suite struct QuietAndBatchTests {
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Kolkata")!; return c }
    func at(_ h: Int, _ m: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: h, minute: m))! }

    @Test func quietHoursAcrossMidnight() {
        let q = QuietHours(enabled: true, startHour: 22, endHour: 7)
        #expect(q.end(after: at(23, 30), calendar: cal) == cal.date(byAdding: .day, value: 1, to: at(7)))
        #expect(q.end(after: at(3), calendar: cal) == at(7))
        #expect(q.end(after: at(7), calendar: cal) == nil)
        #expect(q.end(after: at(12), calendar: cal) == nil)
        #expect(QuietHours(enabled: false).end(after: at(3), calendar: cal) == nil)
        #expect(QuietHours(enabled: true, startHour: 1, endHour: 6).end(after: at(2), calendar: cal) == at(6))
    }

    @Test func quietAlertWaitsUrgentGoesNow() async throws {
        let clock = TestClock()
        let store = try Store(path: ":memory:", now: { clock.now })
        // Quiet around the clock (00-23 h) so the test doesn't depend on when it runs.
        await store.setQuietHours(QuietHours(enabled: true, startHour: 0, endHour: 23))
        func rule(_ id: String, _ p: Int) -> Rule {
            Rule(id: id, when: "revenue.*", actions: [RuleAction(action: "notify", resource: "imessage")],
                 priority: p, cooldownSeconds: 0, approval: .auto, dryRun: false)
        }
        let e = Event(source: "t", kind: "revenue.refund", app: "A", payload: .object([:]), occurredAt: clock.now, dedupeKey: "e")
        let r = try await store.ingest(e, rules: [rule("normal", 2), rule("urgent", 1)])
        #expect(r.jobIDs.count == 2)
        let next = try #require(try await store.claimNext(owner: "t"))
        #expect(next.ruleID == "urgent")                       // the urgent one now
        #expect(try await store.claimNext(owner: "t") == nil)  // the normal one waits for the quiet hours to end
    }

    @Test func burstGoesOutTogetherAndChannelHasAHourlyCap() async throws {
        let clock = TestClock()
        let store = try Store(path: ":memory:", now: { clock.now })
        let rule = Rule(id: "sale", when: "revenue.*", actions: [RuleAction(action: "notify", resource: "imessage")],
                        priority: 2, cooldownSeconds: 0, approval: .auto, dryRun: false)
        for i in 0..<5 {
            _ = try await store.ingest(Event(source: "t", kind: "revenue.purchase", app: "A", payload: .object([:]),
                                             occurredAt: clock.now, dedupeKey: "p\(i)"), rules: [rule])
        }
        let lead = try #require(try await store.claimNext(owner: "t"))
        let rest = try await store.claimBatch(with: lead, owner: "t")
        #expect(rest.count == 4)
        try await store.complete(lead.id)
        for j in rest { try await store.completeInBatch(j.id, leader: lead.id) }
        #expect(try await store.alertsSentLastHour(resource: "imessage") == 1)   // one message, not five
        // Requeue puts a job back without using up its one try.
        _ = try await store.ingest(Event(source: "t", kind: "revenue.purchase", app: "A", payload: .object([:]),
                                         occurredAt: clock.now, dedupeKey: "p9"), rules: [rule])
        let j = try #require(try await store.claimNext(owner: "t"))
        try await store.requeue([j.id], after: 60_000)
        #expect(try await store.job(j.id)?.attempts == 0)
        #expect(try await store.claimNext(owner: "t") == nil)
        clock.advance(seconds: 61)
        #expect(try await store.claimNext(owner: "t")?.id == j.id)
    }
}

@Suite struct AlertTextAndCooldownTests {
    func ev(_ kind: String, _ p: [String: JSONValue], app: String? = nil) -> StoredEvent {
        StoredEvent(id: 1, source: "t", kind: kind, app: app, payload: .object(p), occurredAt: 0)
    }
    @Test func readableAlertText() {
        #expect(EventText.describe(ev("usage.status", ["service": .string("Claude API · Team"), "used_percent": .number(85)])) == "Claude API · Team is at 85% of its limit")
        #expect(EventText.describe(ev("expiry.status", ["kind": .string("Domain"), "name": .string("example.app"), "days_left": .number(12)])) == "Domain example.app expires in 12 days")
        #expect(EventText.describe(ev("expiry.status", ["kind": .string("Certificate"), "name": .string("Dist"), "days_left": .number(0)])) == "Certificate Dist has expired")
        #expect(EventText.describe(ev("offercodes.status", ["offer": .string("OFF60"), "left": .number(10), "total": .number(10000), "days_to_expiry": .number(3)], app: "My App"))
                == "My App: Offer code OFF60 10 of 10,000 left, expires in 3 days")
        #expect(EventText.describe(ev("revenue.daily", ["units": .number(5), "day": .string("2026-11-01")], app: "A")) == "A: 5 downloads on 2026-11-01")
    }

    @Test func differentServicesNeverMuteEachOther() async throws {
        let store = try Store(path: ":memory:", now: { Store.systemNow() })
        let rule = Rule(id: "u", when: "usage.status", actions: [RuleAction(action: "notify", resource: "ntfy")],
                        priority: 2, cooldownSeconds: 86_400, approval: .auto, dryRun: false)
        func usage(_ s: String, _ k: String) -> Event {
            Event(source: "hmunmawi", kind: "usage.status", payload: .object(["service": .string(s), "used_percent": .number(90)]),
                  occurredAt: Store.systemNow(), dedupeKey: k)
        }
        #expect(try await store.ingest(usage("Claude", "a"), rules: [rule]).jobIDs.count == 1)
        #expect(try await store.ingest(usage("Cursor", "b"), rules: [rule]).jobIDs.count == 1)   // another service: alerts
        #expect(try await store.ingest(usage("Claude", "c"), rules: [rule]).jobIDs.isEmpty)      // same service: cooldown
    }
}

@Suite struct WeeklyScheduleTests {
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Kolkata")!; return c }
    func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m))! }
    // 2 Nov 2026 is a Monday.
    @Test func mondayNineWithADayOfGrace() {
        #expect(WeeklySchedule.dueSlot(now: at(2, 8, 59), weekday: 2, hour: 9, calendar: cal) == nil)        // not yet
        #expect(WeeklySchedule.dueSlot(now: at(2, 9, 0), weekday: 2, hour: 9, calendar: cal) == at(2, 9))     // on time
        #expect(WeeklySchedule.dueSlot(now: at(3, 8, 59), weekday: 2, hour: 9, calendar: cal) == at(2, 9))    // asleep, sent late
        #expect(WeeklySchedule.dueSlot(now: at(3, 9, 1), weekday: 2, hour: 9, calendar: cal) == nil)          // too late: skipped
        #expect(WeeklySchedule.dueSlot(now: at(8, 21), weekday: 1, hour: 20, calendar: cal) == at(8, 20))     // Sunday 8 pm
        #expect(WeeklySchedule.dueSlot(now: at(2, 9), weekday: 9, hour: 9, calendar: cal) == nil)             // bad setting
    }
}

@Suite struct AlertLinkTests {
    @Test func linksOnlyToTheRightAppStoreConnectPage() async throws {
        #expect(Engine.clickURL(kind: "review.new", appID: "1234567890") == "https://appstoreconnect.apple.com/apps/1234567890/distribution/activity/ios/ratingsAndReviews")
        #expect(Engine.clickURL(kind: "testflight.feedback", appID: "1") == "https://appstoreconnect.apple.com/apps/1/testflight/ios")
        #expect(Engine.clickURL(kind: "revenue.purchase", appID: nil) == "https://appstoreconnect.apple.com/trends")
        #expect(Engine.clickURL(kind: "review.new", appID: "12/../evil") == nil)        // only numeric IDs
        #expect(Engine.clickURL(kind: "job.failed", appID: "1") == nil)                 // no sensible page
        let store = try Store(path: ":memory:")
        _ = try await store.ingest(Event(source: "appstoreconnect", kind: "icon.snapshot", app: "My App",
                                         payload: .object(["appID": .string("1234567890"), "url": .string("x")]), occurredAt: 1, dedupeKey: "i"), rules: [])
        #expect(try await store.appStoreID(forApp: "My App") == "1234567890")
        #expect(try await store.appStoreID(forApp: "Other") == nil)
    }
}

@Suite struct SearchSitesTests {
    private func site(_ seen: Double, _ clicks: Double, _ position: Double) -> JSONValue {
        .object(["impressions_28d": .number(seen), "clicks_28d": .number(clicks), "impressions_7d": .number(seen / 4),
                 "clicks_7d": .number(clicks / 4), "position_28d": .number(position)])
    }

    @Test func oneSiteIsUnchangedAndSeveralAreTotalled() throws {
        #expect(SearchSites.merge([]) == nil)
        let a = site(1000, 40, 10), b = site(3000, 60, 20)
        #expect(SearchSites.merge([a]) == a)
        let m = try #require(SearchSites.merge([a, b]))
        #expect(m[path: "impressions_28d"]?.number == 4000 && m[path: "clicks_28d"]?.number == 100)
        #expect(m[path: "impressions_7d"]?.number == 1000 && m[path: "clicks_7d"]?.number == 25)
        // Position is weighted by impressions: (10*1000 + 20*3000) / 4000 = 17.5
        #expect(m[path: "position_28d"]?.number == 17.5)
    }
}
