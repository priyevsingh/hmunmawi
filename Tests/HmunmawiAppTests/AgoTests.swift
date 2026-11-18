import Foundation
import Observation
import Testing
@testable import HmunmawiApp

@Suite struct AgoTests {
    let now = Date(timeIntervalSince1970: 1_795_000_000)
    let en = Locale(identifier: "en_US")

    @Test func pastAndFutureAges() {
        #expect(Ago.text(now.addingTimeInterval(-21 * 3600 - 120), now: now, locale: en) == "21 hours ago")
        #expect(Ago.text(now.addingTimeInterval(-45 * 3600), now: now, locale: en) == "yesterday")
        // A real future date (a reset) keeps its direction; only clamped moments read as now.
        #expect(Ago.text(now.addingTimeInterval(3 * 3600), now: now, locale: en) == "in 3 hours")
        #expect(Ago.text(now.addingTimeInterval(5), now: now, clampFuture: true, locale: en) == "now")
    }

    /// The label is measured from the moment it's asked for, never a time captured earlier.
    @Test func measuredFromTheCurrentTime() {
        let twoHoursAgo = Date.now.addingTimeInterval(-2 * 3600 - 30)
        #expect(Ago.text(twoHoursAgo).contains("2"))
        #expect(!Ago.text(millis: Int64(twoHoursAgo.timeIntervalSince1970 * 1000)).contains("minute"))
    }

    /// Reading an age inside a view's body ties the view to the minute clock, so each tick redraws it.
    @Test func aTickRedrawsWhatReadAnAge() {
        final class Flag: @unchecked Sendable { var fired = false }
        let flag = Flag()
        withObservationTracking {
            _ = Ago.text(Date.now.addingTimeInterval(-60))
        } onChange: { flag.fired = true }
        MinuteClock.shared.tick()
        #expect(flag.fired)
    }

    @Test func statusPillUsesTheTimeItIsGiven() {
        #expect(StatusPill.ago(now.addingTimeInterval(-5), now: now) == "just now")
        #expect(StatusPill.ago(now.addingTimeInterval(-3 * 3600), now: now).contains("3 hours"))
    }
}
