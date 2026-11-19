import Foundation
import Testing
@testable import HmunmawiCore

@Suite struct TodayTests {
    @Test func routineFailureClearsOnlyAfterALaterSuccess() {
        func ev(_ id: Int64, _ kind: String, _ routine: String, _ at: Millis) -> StoredEvent {
            StoredEvent(id: id, source: "routine", kind: kind, app: "Daily social to-do", payload: .object(["routine": .string(routine)]), occurredAt: at)
        }
        let fail = ev(1, "job.failed", "r1", 1_000)
        // No later success: still failing.
        #expect(JobFailures.withoutRecovered([fail], states: [:], readAt: 0).map(\.id) == [1])
        // A later success of the same routine clears it.
        #expect(JobFailures.withoutRecovered([fail, ev(2, "job.finished", "r1", 2_000)], states: [:], readAt: 0).isEmpty == false)
        #expect(JobFailures.withoutRecovered([fail, ev(2, "job.finished", "r1", 2_000)], states: [:], readAt: 0).map(\.id) == [2])
        // An earlier success, or another routine's success, does not.
        #expect(JobFailures.withoutRecovered([fail, ev(2, "job.finished", "r1", 500)], states: [:], readAt: 0).map(\.id) == [1, 2])
        #expect(JobFailures.withoutRecovered([fail, ev(2, "job.finished", "r2", 2_000)], states: [:], readAt: 0).map(\.id) == [1, 2])
        // A failure after the success is real again.
        #expect(JobFailures.stillFailing([ev(3, "job.failed", "r1", 3_000)], states: [:], readAt: 0,
                                         successes: [ev(2, "job.finished", "r1", 2_000)]).map(\.id) == [3])
    }

    @Test func errorLinePrefersTheLineThatExplainsTheFailure() {
        let out = "sending message\nError: iMessage send failed (not authorized)\ncalendar event created"
        #expect(JobFailures.errorLine(out) == "Error: iMessage send failed (not authorized)")
        #expect(JobFailures.errorLine("step one\nstep two\n") == "step two")
        #expect(JobFailures.errorLine("") == "")
        #expect(JobFailures.errorLine("Traceback (most recent call last)\nValueError: bad\ndone").hasPrefix("ValueError"))
        #expect(JobFailures.errorLine("error: " + String(repeating: "x", count: 400)).count == 160)
    }

    @Test func recoveredMacJobIsNotTodaysWorry() throws {
        let label = "com.example.x-unfollow"
        let failedAt: Millis = 1_000_000
        let fail = StoredEvent(id: 7, source: "macjobs", kind: "job.failed", app: "x-unfollow",
                               payload: .object(["label": .string(label), "status": .number(1)]), occurredAt: failedAt)
        let other = StoredEvent(id: 8, source: "x", kind: "review.new", app: "A", payload: .object([:]), occurredAt: failedAt)
        // Still failing at the next launchd reading: stays.
        #expect(JobFailures.withoutRecovered([fail, other], states: [label: "failed"], readAt: failedAt + 1).map(\.id) == [7, 8])
        // Ran fine since (launchd's last exit is 0): dropped, so the card turns green by itself.
        #expect(JobFailures.withoutRecovered([fail, other], states: [label: "ok"], readAt: failedAt + 1).map(\.id) == [8])
        // A reading older than the failure can't have seen a recovery: stays.
        #expect(JobFailures.withoutRecovered([fail], states: [label: "ok"], readAt: failedAt - 1).map(\.id) == [7])
        // Unknown to launchd (a routine): stays.
        #expect(JobFailures.withoutRecovered([fail], states: [:], readAt: failedAt + 1).map(\.id) == [7])
        let card = TodayBuilder.build(events: JobFailures.withoutRecovered([fail], states: [label: "ok"], readAt: failedAt + 1),
                                      waitingApprovals: 0, failedJobs: 0, now: failedAt + 60_000)
        #expect(!card.worry.title.contains("x-unfollow"))
        let red = TodayBuilder.build(events: [fail], waitingApprovals: 0, failedJobs: 0, now: failedAt + 60_000)
        #expect(red.worry.title == "Mac job “x-unfollow” failed")
    }

    @Test func demoDataFillsAllThreeItems() async throws {
        let clock = TestClock()
        let store = try Store(path: ":memory:", now: { clock.now })
        try await DemoData.seedIfEmpty(store, now: clock.now)
        let card = try await store.today()

        #expect(card.win.title == "Pocket Garden sales up 60%")
        #expect(card.win.evidence == "8 in the last 24 hours vs 5.0 a day last week")
        // The sample shows a healthy business: a clear win, nothing alarming, nothing waiting.
        #expect(!card.hasWorry)
        #expect(card.worry.title == "Nothing to worry about")
    }

    @Test func demoAppSummaries() async throws {
        let clock = TestClock()
        let store = try Store(path: ":memory:", now: { clock.now })
        try await DemoData.seedIfEmpty(store, now: clock.now)
        let apps = try await store.appSummaries()
        #expect(apps.map(\.name) == ["Pocket Garden", "Night Owl Timer"])
        let garden = try #require(apps.first)
        // The sample includes Apple's daily sales report, which (like a real connection) leads with downloads.
        #expect(garden.metric == "Downloads")
        #expect(garden.daily.count == 7)
        #expect((garden.latest ?? 0) > 0)
        #expect(garden.averageRating == 5)
    }

    @Test func dailyUsersBecomeTheMetricWithoutSales() {
        let now: Millis = 100 * TodayBuilder.day
        // Spelled out step by step: one long expression here was too slow to type-check on CI runners.
        var events: [StoredEvent] = []
        for i in 0..<7 {
            let daysBack: Millis = Millis(6 - i)
            let at: Millis = now - daysBack * TodayBuilder.day - 1000
            let users: Double = Double(100 + i)
            events.append(StoredEvent(id: Int64(i), source: "posthog", kind: "analytics.daily_users", app: "My App",
                                      payload: .object(["users": .number(users)]), occurredAt: at))
        }
        let app = SummaryBuilder.apps(events: events, now: now).first
        #expect(app?.metric == "Daily users")
        #expect(app?.daily == [100, 101, 102, 103, 104, 105, 106])
    }

    @Test func seedingTwiceAddsNothing() async throws {
        let clock = TestClock()
        let store = try Store(path: ":memory:", now: { clock.now })
        try await DemoData.seedIfEmpty(store, now: clock.now)
        let count = try await store.eventCount()
        try await DemoData.seedIfEmpty(store, now: clock.now)
        #expect(try await store.eventCount() == count)
    }

    @Test func quietDayShowsCalmPlaceholders() {
        let card = TodayBuilder.build(events: [], waitingApprovals: 0, failedJobs: 0, now: 1_000_000_000)
        #expect(card.win.isQuiet && card.worry.isQuiet && card.next.isQuiet)
        #expect(!card.hasWorry)
    }

    @Test func lowReviewBecomesWorryAndNext() {
        let review = StoredEvent(id: 1, source: "asc", kind: "review.new", app: "App",
                                 payload: .object(["rating": .number(1), "title": .string("Broken")]),
                                 occurredAt: 999_999_000)
        let card = TodayBuilder.build(events: [review], waitingApprovals: 0, failedJobs: 0, now: 1_000_000_000)
        #expect(card.worry.title == "1 low review for App")
        #expect(card.worry.evidence == "“Broken”")
        #expect(card.next.title == "Reply to 1 low review")
    }
}
