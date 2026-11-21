import Foundation
import Testing
@testable import HmunmawiCore

/// A script's "needs a look" (`job.attention`, 1.5.7): amber, newest per job, cleared by a later success.
@Suite struct NeedsLookTests {
    static func ev(_ id: Int64, _ kind: String, app: String?, routine: String? = nil, at: Millis) -> StoredEvent {
        var p: [String: JSONValue] = ["title": .string("Nothing new went live")]
        if let routine { p["routine"] = .string(routine) }
        return StoredEvent(id: id, source: "scriptfeed", kind: kind, app: app, payload: .object(p), occurredAt: at)
    }

    @Test func openUntilASuccessForTheSameJob() {
        let look = Self.ev(1, "job.attention", app: "Site content", routine: "content_engine", at: 1_000)
        #expect(JobFailures.needingLook([look]).map(\.id) == [1])
        let okAfter = Self.ev(2, "routine.ok", app: "Site content", routine: "content_engine", at: 2_000)
        #expect(JobFailures.needingLook([look], successes: [okAfter]).isEmpty)                  // the script sent ok
        let okBefore = Self.ev(3, "routine.ok", app: "Site content", routine: "content_engine", at: 500)
        #expect(JobFailures.needingLook([look], successes: [okBefore]).map(\.id) == [1])       // an older ok doesn't clear it
        let otherJob = Self.ev(4, "routine.ok", app: "Other", routine: "other", at: 3_000)
        #expect(JobFailures.needingLook([look], successes: [otherJob]).map(\.id) == [1])
    }

    @Test func newestPerJobAndAppOnlyEventsWork() {
        let a1 = Self.ev(1, "job.attention", app: "Backups", at: 1_000)
        let a2 = Self.ev(2, "job.attention", app: "Backups", at: 2_000)                         // a resend: one item, the newest
        let b = Self.ev(3, "job.attention", app: "Feed", at: 1_500)
        #expect(JobFailures.needingLook([a1, a2, b]).map(\.id) == [2, 3])
        let finished = Self.ev(4, "job.finished", app: "Backups", at: 2_500)                     // cleared by app name too
        #expect(JobFailures.needingLook([a1, a2, b], successes: [finished]).map(\.id) == [3])
        #expect(JobFailures.needingLook([Self.ev(5, "job.failed", app: "X", at: 1)]).isEmpty)   // only job.attention counts
    }

    @Test func describedInPlainWords() {
        let e = Self.ev(1, "job.attention", app: "Site content", at: 1)
        #expect(EventText.describe(e) == "Site content: Nothing new went live")
    }
}
