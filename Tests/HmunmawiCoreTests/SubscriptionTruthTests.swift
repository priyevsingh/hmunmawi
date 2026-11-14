import Foundation
import Testing
@testable import HmunmawiCore

@Suite struct SubscriptionTruthTests {
    var nextID: Int64 = 0
    func ev(_ kind: String, _ app: String, _ day: String, _ fields: [String: JSONValue], at: Millis? = nil) -> StoredEvent {
        var p = fields; p["day"] = .string(day)
        let ms = at ?? Millis(DayNumber.of(day)!) * 86_400_000 + 86_399_999
        return StoredEvent(id: Int64(DayNumber.of(day)!), source: "t", kind: kind, app: app, payload: .object(p), occurredAt: ms)
    }
    func obj(_ m: [String: Int]) -> JSONValue { .object(m.mapValues { .number(Double($0)) }) }
    func day(_ n: Int) -> String { DayNumber.day(n) }

    @Test func dayNumbersRoundTrip() {
        #expect(DayNumber.of("1970-01-01") == 0)
        #expect(DayNumber.of("2026-11-03") == 20_760)
        for n in stride(from: 10_000, to: 30_000, by: 37) { #expect(DayNumber.of(DayNumber.day(n)) == n) }
        #expect(DayNumber.of("2024-02-29").map(DayNumber.day) == "2024-02-29")
        #expect(DayNumber.of("2026-13-01") == nil)
        #expect(DayNumber.of("nonsense") == nil)
    }

    /// 10 weekly subscribers start on one day; 4 renew a week later, 2 are still there 3 weeks on.
    @Test func renewalByPlanFollowsTheCohort() {
        let start = DayNumber.of("2026-08-01")!
        var rows = [ev("subscription.events", "A", day(start), ["new_paid": .number(10), "paid": obj(["weekly|1": 10])])]
        rows.append(ev("subscription.events", "A", day(start + 7), ["renewals": .number(4), "paid": obj(["weekly|2": 4])]))
        rows.append(ev("subscription.events", "A", day(start + 14), ["renewals": .number(3), "paid": obj(["weekly|3": 3])]))
        rows.append(ev("subscription.events", "A", day(start + 21), ["renewals": .number(2), "paid": obj(["weekly|4": 2])]))
        rows.append(ev("subscription.events", "A", day(start + 60), ["cancels": .number(1)]))   // the newest report day
        let t = SubscriptionTruth.make(rows)["A"]!
        let weekly = t.plans.first { $0.name == "weekly" }!
        #expect(weekly.starts == 10)
        #expect(weekly.points.first { $0.after == 1 } == .init(after: 1, kept: 4, of: 10))
        #expect(weekly.points.first { $0.after == 3 } == .init(after: 3, kept: 2, of: 10))
        #expect(weekly.points.first { $0.after == 6 } == .init(after: 6, kept: 0, of: 10))
        // 12 weeks after the start is past the newest day: not shown rather than shown as 0%.
        #expect(weekly.points.first { $0.after == 12 } == nil)
    }

    /// Subscribers who started too recently to have reached a renewal are not counted as having left.
    @Test func recentStartsAreNotCountedAsLost() {
        let last = DayNumber.of("2026-10-31")!
        let rows = [
            ev("subscription.events", "A", day(last - 30), ["new_paid": .number(5), "paid": obj(["weekly|1": 5])]),
            ev("subscription.events", "A", day(last - 23), ["paid": obj(["weekly|2": 5])]),
            ev("subscription.events", "A", day(last - 2), ["new_paid": .number(20), "paid": obj(["weekly|1": 20])]),
        ]
        let p = SubscriptionTruth.make(rows)["A"]!.plans[0].points.first { $0.after == 1 }!
        #expect(p.of == 5 && p.kept == 5)
    }

    @Test func trialsCountOnlyOnceEnded() {
        let last = DayNumber.of("2026-10-31")!
        let rows = [
            ev("subscription.events", "A", day(last - 20), ["trials": .number(3), "trial_lengths": obj(["3": 3])]),
            ev("subscription.events", "A", day(last - 17), ["trial_paid": .number(1), "trial_cancel": .number(1), "paid": obj(["yearly|1": 1])]),
            ev("subscription.events", "A", day(last - 1), ["trials": .number(4), "trial_lengths": obj(["7": 4])]),   // still running
            ev("subscription.events", "A", day(last), ["cancels": .number(2), "cancels_first": .number(1), "billing_trouble": .number(2),
                                                       "recovered": .number(1), "billing_lost": .number(1), "refunds": .number(1),
                                                       "new_paid": .number(3), "paid": obj(["yearly|1": 3])]),
        ]
        let t = SubscriptionTruth.make(rows)["A"]!
        #expect(t.trialsStarted == 7 && t.trialsEnded == 3 && t.trialsPaid == 1 && t.trialsCancelled == 1)
        #expect(t.trialToPaid == 1.0 / 3)
        #expect(t.starts == 4 && t.cancels == 2 && t.billingLost == 1 && t.recovered == 1)
        #expect(t.payments == 4 && t.refundRate == 0.25)
        // Yearly started within the history: no renewal can be due yet, so no points (the view says "too new").
        #expect(t.plans.first?.points.isEmpty == true)
    }

    @Test func windowEndsAtNewestDayAcrossApps() {
        let last = DayNumber.of("2026-10-31")!
        let rows = [
            ev("subscription.events", "A", day(last - 100), ["cancels": .number(9)]),   // outside 90 days
            ev("subscription.events", "A", day(last - 10), ["cancels": .number(1)]),
            ev("subscription.events", "B", day(last), ["new_paid": .number(1)]),
        ]
        let all = SubscriptionTruth.make(rows)
        #expect(all["A"]?.cancels == 1)
        #expect(all["A"]?.toDay == "2026-10-31" && all["B"]?.toDay == "2026-10-31")
        #expect(all["A"]?.historyFrom == day(last - 100))
    }

    @Test func headlineNamesTheBiggestLeak() {
        let last = DayNumber.of("2026-10-31")!
        let weekly = [ev("subscription.events", "A", day(last), ["new_paid": .number(34), "cancels": .number(30), "cancels_first": .number(27),
                                                                 "paid": obj(["weekly|1": 34])])]
        #expect(SubscriptionTruth.make(weekly)["A"]?.headline == "Most who leave turn renewal off in their first week: 27 of 34 who started paying")
        let trials = [ev("subscription.events", "A", day(last - 10), ["trials": .number(3), "trial_lengths": obj(["3": 3]), "trial_cancel": .number(3)]),
                      ev("subscription.events", "B", day(last), ["new_paid": .number(1)])]   // the newest report day
        #expect(SubscriptionTruth.make(trials)["A"]?.headline == "None of the 3 free trials that ended became paid")
        let billing = [ev("subscription.events", "A", day(last), ["new_paid": .number(10), "cancels": .number(1), "cancels_first": .number(0),
                                                                  "billing_lost": .number(3)])]
        #expect(SubscriptionTruth.make(billing)["A"]?.headline == "More subscribers were lost to failed payments (3) than to cancelling (1)")
    }

    @Test func countryFlaggedWhenSubscribersPayFarLessEach() {
        let mrr = [ev("subscription.mrr", "A", "2026-10-31", ["active_paid": .number(20), "mrr_usd": .number(60),
            "countries": .object(["US": .object(["active": .number(10), "mrr_usd": .number(45)]),
                                  "IN": .object(["active": .number(8), "mrr_usd": .number(10)]),
                                  "DE": .object(["active": .number(2), "mrr_usd": .number(5)])])])]
        let flags = CountryValue.flags(mrr: mrr, daily: [], subs: [])
        #expect(flags.count == 1)
        #expect(flags.first?.country == "IN" && flags.first?.active == 8)
        #expect(abs((flags.first?.perSubUSD ?? 0) - 1.25) < 0.001 && abs((flags.first?.appPerSubUSD ?? 0) - 3) < 0.001)
        #expect(flags.first?.conversion == nil)   // no downloads by country yet: no conversion claim
    }

    @Test func countryConversionNeedsFourWeeksOfCountryDownloads() {
        let mrr = [ev("subscription.mrr", "A", "2026-10-31", ["active_paid": .number(20), "mrr_usd": .number(60),
            "countries": .object(["US": .object(["active": .number(12), "mrr_usd": .number(50)]),
                                  "IN": .object(["active": .number(8), "mrr_usd": .number(10)])])])]
        let last = DayNumber.of("2026-10-31")!
        let daily = (0..<28).map { ev("revenue.daily", "A", day(last - $0), ["units": .number(10), "units_by_country": obj(["US": 6, "IN": 4])]) }
        let subs = [ev("subscription.events", "A", day(last - 3), ["new_by_country": obj(["IN": 6, "US": 2])])]
        let f = CountryValue.flags(mrr: mrr, daily: daily, subs: subs).first!
        #expect(f.downloads == 112 && f.newPaid == 6)
        #expect(abs(f.conversion! - 6.0 / 112) < 1e-9 && abs(f.appConversion! - 8.0 / 280) < 1e-9)
        #expect(CountryValue.flags(mrr: mrr, daily: Array(daily.prefix(27)), subs: subs).first?.conversion == nil)
    }

    @Test func releaseReportWaitsForSevenDaysThenJudges() {
        let live = DayNumber.of("2026-10-20")!
        var crash: [StoredEvent] = [], daily: [StoredEvent] = [], subs: [StoredEvent] = []
        for d in (live - 7)..<(live + 7) {
            let after = d >= live
            crash.append(ev("crash.daily", "A", day(d), ["sessions": .number(100), "crashed": .number(after ? 5 : 0)]))
            daily.append(ev("revenue.daily", "A", day(d), ["units": .number(10)]))
            subs.append(ev("subscription.events", "A", day(d), ["new_paid": .number(1)]))
        }
        #expect(ReleaseReport.make(app: "A", version: "2.0", liveDay: day(live), newestDay: day(live + 5),
                                   crash: crash, daily: daily, subs: subs, snapshots: []) == nil)
        let r = ReleaseReport.make(app: "A", version: "2.0", liveDay: day(live), newestDay: day(live + 6),
                                   crash: crash, daily: daily, subs: subs, snapshots: [])!
        #expect(r.verdict == .hurt("Crash-free sessions"))
        #expect(r.measures.first { $0.name == "Crash-free sessions" }?.after == "95.0%")
        #expect(r.measures.first { $0.name == "Downloads that started paying or a trial" }?.call == .same)
        #expect(r.measures.first { $0.name == "Downloads a day" }?.judged == false)
    }

    @Test func releaseReportReadsNewRatingsStars() {
        let live = DayNumber.of("2026-10-20")!
        let snap = { (d: Int, r: Double, n: Double) in
            StoredEvent(id: Int64(d), source: "t", kind: "app.snapshot", app: "A",
                        payload: .object(["rating": .number(r), "ratings_count": .number(n)]), occurredAt: Millis(d) * 86_400_000 + 3_600_000)
        }
        // 4.5 from 20 ratings, then 4 new 1-star ratings: (4.5*20 + 4) / 24 = 3.917.
        let snaps = [snap(live - 7, 4.5, 20), snap(live, 4.5, 20), snap(live + 7, (4.5 * 20 + 4) / 24, 24)]
        let r = ReleaseReport.make(app: "A", version: "2.0", liveDay: day(live), newestDay: day(live + 8),
                                   crash: [], daily: [], subs: [], snapshots: snaps)!
        let stars = r.measures.first { $0.name == "Stars from new ratings" }!
        #expect(stars.after == "1.0★" && stars.call == .worse && stars.note == "4 new ratings")
        #expect(r.verdict == .hurt("Stars from new ratings"))
    }
}
