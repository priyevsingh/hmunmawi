import Foundation
import HmunmawiCore
import Testing
@testable import HmunmawiApp

@Suite struct TickerAgeTests {
    let now = Date(timeIntervalSince1970: 1_795_000_000)
    let en = Locale(identifier: "en_US")

    func sale(_ secondsAgo: Double, id: Int64 = 1) -> StoredEvent {
        StoredEvent(id: id, source: "live", kind: "revenue.renewal", app: "A", payload: .object([:]),
                    occurredAt: Millis((now.timeIntervalSince1970 - secondsAgo) * 1000))
    }

    /// Yesterday's sale reads its real age, measured from the time passed in, not "1 minute ago".
    @Test func yesterdaysSaleShowsItsRealAge() {
        let e = sale(21 * 3600 + 120)
        #expect(TickerItems.age(e, now: now, locale: en) == "21 hours ago")
        // The same event a minute after it arrived, and a day later: the label follows the clock it is given.
        #expect(TickerItems.age(e, now: now.addingTimeInterval(-(21 * 3600 + 60)), locale: en) == "1 minute ago")
        #expect(TickerItems.age(e, now: now.addingTimeInterval(86_400), locale: en) == "yesterday")
    }

    /// A sender clock slightly ahead never shows a moment as in the future.
    @Test func aMomentFromTheNearFutureReadsAsNow() {
        #expect(TickerItems.age(sale(-5), now: now, locale: en) == "now")
    }

    /// The "last day" window moves with the time passed in.
    @Test func recentWindowFollowsNow() {
        let events = [sale(3600, id: 1), sale(7200, id: 2), sale(10_800, id: 3)]
        #expect(TickerItems.recent(events, now: now).count == 3)
        #expect(TickerItems.recent(events, now: now).first?.id == 1)
    }
}
