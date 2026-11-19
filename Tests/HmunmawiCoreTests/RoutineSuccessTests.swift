import Foundation
import Testing
@testable import HmunmawiCore

/// A routine's success is recorded only so a failure can be cleared: internal, never shown, one per routine.
@Suite struct RoutineSuccessTests {
    private func ok(_ routine: String, _ at: Millis) -> Event {
        Event(source: "routine", kind: "routine.ok", app: "Daily social to-do", payload: .object(["routine": .string(routine)]),
              occurredAt: at, dedupeKey: "routine-ok:\(routine)@\(at)")
    }

    @Test func successRecordsLeaveNoActivityRowAndKeepOnlyTheLatestPerRoutine() async throws {
        let store = try Store(path: ":memory:")
        for t in [1_000, 2_000, 3_000] as [Millis] { _ = try await store.ingest(ok("r1", t), rules: []) }
        _ = try await store.ingest(ok("r2", 1_500), rules: [])
        let kept = try await store.events(kind: "routine.ok", since: 0)
        #expect(kept.map(\.occurredAt).sorted() == [1_500, 3_000])
        // Nothing in the activity log mentions them.
        let audit = try await store.recentAudit(limit: 100)
        #expect(!audit.contains { $0.action == "event.received" })
    }

    @Test func successRecordIsHiddenAndNeverATrigger() {
        #expect(Store.internalKinds.contains("routine.ok"))
        #expect(MetricExtractor.ignoredKinds.contains("routine.ok"))
        #expect(!TodayTimelineKinds.contains("routine.ok"))
        let e = StoredEvent(id: 1, source: "routine", kind: "routine.ok", app: "x", payload: .object(["routine": .string("r1")]), occurredAt: 1)
        #expect(NotifyCandidate.from(id: 1, kind: e.kind, app: e.app, payload: e.payload, amount: nil, text: "", isSample: false) == nil)
        // It still clears an earlier failure of the same routine.
        let fail = StoredEvent(id: 0, source: "routine", kind: "job.failed", app: "x", payload: .object(["routine": .string("r1")]), occurredAt: 0)
        #expect(JobFailures.stillFailing([fail], states: [:], readAt: 0, successes: [e]).isEmpty)
    }
}

private let TodayTimelineKinds: Set<String> = ["review.new", "mail.reply", "job.failed", "site.down", "disk.low", "crash.spike", "testflight.feedback", "ci.build"]
