import Foundation
import Testing
@testable import HmunmawiCore

@Suite struct PlanFreshnessTests {
    static let step = "Planned for Body Vitals 4.1.8, not 4.1.7: show Yearly's weekly cost under its $69.99/year price. Submit ~17 Nov"

    @Test func findsVersionsButNotPricesOrPercentages() {
        #expect(PlanFreshness.versions(in: Self.step) == [[4, 1, 8], [4, 1, 7]])
        #expect(PlanFreshness.versions(in: "Keep Weekly ($2.99) at 99.87% and €1.50").isEmpty)
    }

    @Test func aPlanForAShippedVersionIsDone() {
        #expect(PlanFreshness.alreadyLive(Self.step, liveVersion: "4.1.8"))          // live now: done
        #expect(PlanFreshness.alreadyLive(Self.step, liveVersion: "4.2"))            // a newer one shipped: done
        #expect(!PlanFreshness.alreadyLive(Self.step, liveVersion: "4.1.7"))         // not shipped yet: still open
        #expect(!PlanFreshness.alreadyLive("Keep prices while Yearly is tested ($2.99)", liveVersion: "4.1.8"))   // no version: kept
        #expect(!PlanFreshness.alreadyLive(Self.step, liveVersion: nil))
    }
}

@Suite struct PlanStepsShownTests {
    static func step(_ text: String, ageDays: Double, app: String = "Body Vitals", now: Date) -> StoredEvent {
        StoredEvent(id: 1, source: "script", kind: "plan.step", app: app,
                    payload: .object(["step": .string(text), "page": .string("p")]),
                    occurredAt: Int64((now.timeIntervalSince1970 - ageDays * 86_400) * 1000))
    }

    @Test func shippedAndStaleStepsAreHidden() {
        let now = Date()
        let live = ["Body Vitals": "4.1.8"]
        let list = [Self.step("Planned for Body Vitals 4.1.8: do x", ageDays: 0, now: now),        // version live: done
                    Self.step("Planned for Body Vitals 4.2: do y", ageDays: 0, now: now),           // not live yet: shown
                    Self.step("Keep prices while Yearly is tested ($2.99)", ageDays: 0, now: now), // no version: shown
                    Self.step("Old line a script stopped sending", ageDays: 5, now: now)]           // older than 3 days: hidden
        let shown = PlanFreshness.current(list, liveVersions: live, now: now).map { $0.payload[path: "step"]?.string ?? "" }
        #expect(shown == ["Planned for Body Vitals 4.2: do y", "Keep prices while Yearly is tested ($2.99)"])
    }

    @Test func liveVersionMatchesTheReleaseSnapshotName() {
        #expect(PlanFreshness.live(for: "Body Vitals", in: ["Body Vitals: Health Widgets": "4.1.8"]) == "4.1.8")
    }
}
