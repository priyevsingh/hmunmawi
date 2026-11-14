import Foundation
import Testing
@testable import HmunmawiCore

@Suite struct InsightTests {
    func metric(_ values: [Double], count: Bool = false, better: Metric.Better? = .up) -> Metric {
        let today = Calendar.current.startOfDay(for: .now)
        let pts = values.enumerated().map { i, v in
            (Calendar.current.date(byAdding: .day, value: i - values.count + 1, to: today)!, v)
        }
        return Metric(key: "m", name: "Sales", app: "App", better: better, isCount: count, isMoney: false, points: pts)
    }

    @Test func smallCountNoiseIsNotFlagged() {
        // 0-2 sales a day, today 2: ordinary for an indie app.
        let m = metric([0, 1, 0, 2, 1, 0, 1, 0, 1, 2, 0, 1, 2], count: true)
        #expect(InsightEngine.unusual(m) == nil)
    }

    @Test func realSpikeInCountsIsAWin() {
        let m = metric([0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 9], count: true)
        let f = InsightEngine.unusual(m)
        #expect(f?.lane == .win)
    }

    @Test func dropInGoodMetricIsAWorry() {
        let m = metric([50, 52, 49, 51, 50, 53, 48, 50, 51, 49, 52, 50, 20])
        #expect(InsightEngine.unusual(m)?.lane == .worry)
    }

    @Test func undeclaredDirectionStaysNeutral() {
        let m = metric([50, 52, 49, 51, 50, 53, 48, 50, 51, 49, 52, 50, 20], better: nil)
        #expect(InsightEngine.unusual(m)?.lane == .change)
    }

    @Test func newLevelIsFound() {
        let m = metric([10, 11, 9, 10, 10, 11, 9, 10, 20, 21, 19, 20, 21, 20, 19, 21])
        #expect(InsightEngine.newLevel(m)?.lane == .win)
    }

    @Test func steadyTrendIsFound() {
        let m = metric((0..<20).map { Double($0) + (($0 % 3 == 0) ? 0.5 : 0) })
        #expect(InsightEngine.trend(m)?.lane == .win)
    }

    @Test func extractorReadsSeriesWithDeclaredDirection() {
        let days = (1...10).map { String(format: "2026-10-%02d", $0) }
        let payload: JSONValue = .object([
            "days": .array(days.map { .string($0) }),
            "downloads": .array((1...10).map { .number(Double($0)) }),
            "better": .object(["downloads": .string("up")]),
        ])
        let e = StoredEvent(id: 1, source: "t", kind: "history.series", app: "App", payload: payload, occurredAt: 0)
        let m = MetricExtractor.extract([e]).first { $0.key.hasSuffix("downloads") }
        // "downloads" is the script feed's running total: 10 days become 9 day-to-day rises of 1, not a "climbing" 1…10.
        #expect(m?.better == .up && m?.points.count == 9)
        #expect(m?.points.allSatisfy { $0.value == 1 } == true)
    }

    @Test func runningTotalNeverMakesATrendFinding() {
        let days = (1...28).map { String(format: "2026-10-%02d", $0) }
        let total = (1...28).reduce(into: [Double]()) { a, i in a.append((a.last ?? 90) + Double([3, 5, 2, 4][i % 4])) }
        let e = StoredEvent(id: 1, source: "t", kind: "history.series", app: "App",
                            payload: .object(["days": .array(days.map { .string($0) }), "downloads": .array(total.map { .number($0) }),
                                              "better": .object(["downloads": .string("up")])]), occurredAt: 0)
        let m = MetricExtractor.extract([e], now: ISO8601DateFormatter().date(from: "2026-10-29T12:00:00Z")!).first { $0.key.hasSuffix("downloads") }!
        #expect(InsightEngine.trend(m) == nil)   // steady 2-5 a day isn't "climbing week after week"
    }

    @Test func totalNamesTheAppThatDroveIt() {
        let a = metric([10, 11, 9, 10, 10, 11, 9, 10, 10, 11, 9, 10, 30, 31, 29, 30, 31, 30, 29])
        let b = metric([5, 5, 6, 5, 5, 6, 5, 5, 6, 5, 5, 6, 5, 6, 5, 5, 6, 5, 5])
        let total = zip(a.points, b.points).map { ($0.0.day, $0.0.value + $0.1.value) }
        var m = Metric(key: "total|x", name: "Downloads", app: nil, better: .up, isCount: false, isMoney: false, points: total)
        m.breakdowns["app"] = ["My App": a.points, "Other App": b.points]
        #expect(InsightEngine.driver(m, .newLevel)?.contains("My App") == true)
    }

    @Test func fieldNamesAndMoney() {
        #expect(MetricExtractor.readable("mrr_gross_usd") == "MRR before Apple's cut" && MetricExtractor.readable("active_paid") == "Paying subscribers")
        #expect(MetricExtractor.readable("some_new_field") == "Some new field")
        #expect(MetricExtractor.isMoney("mrr_gross_usd") && MetricExtractor.isMoney("proceeds_usd") && !MetricExtractor.isMoney("units"))
        #expect(MetricExtractor.echoFields.contains("mrr_gross_usd"))
    }

    @Test func levelThatStayedSaysSince() throws {
        // $14.74 for 10 readings, then $0 on 3 readings: the change is dated at the run's start.
        let cal = Calendar.current, start = cal.date(from: DateComponents(year: 2026, month: 10, day: 1))!
        let vals: [Double] = Array(repeating: 14.74, count: 10) + [0, 0, 0]
        let pts = vals.enumerated().map { (cal.date(byAdding: .day, value: $0.offset, to: start)!, $0.element) }
        let m = Metric(key: "subscription.mrr|P|mrr_usd", name: "MRR", app: "P", better: .up, isCount: false, isMoney: true, points: pts)
        let f = try #require(InsightEngine.unusual(m))
        // The date follows the Mac's region ("11 Oct" or "Oct 11"), so expect it in this machine's own format.
        let day11 = cal.date(byAdding: .day, value: 10, to: start)!.formatted(.dateTime.day().month(.abbreviated))
        #expect(f.title.contains(" dropped to ") && f.title.contains("0.00 since \(day11), from a usual ") && f.title.contains("14.74"),
                "title was: \(f.title)")
    }

    @Test func rollingWindowNamesItsWindowNotTheReadingDay() throws {
        // Search Console's 7-day impressions (1–7 Nov) read on 9 and 10 Nov: the sentence names 1–7 Nov, never "since 9 Nov".
        let cal = Calendar.current, start = cal.date(from: DateComponents(year: 2026, month: 10, day: 20))!
        let vals: [Double] = [2600, 2650, 2700, 2640, 2610, 2680, 2647, 2660, 2630, 2655, 2620, 2039, 2039]
        let days = vals.indices.map { i -> JSONValue in
            .string(ISO8601DateFormatter.string(from: cal.date(byAdding: .day, value: i, to: start)!, timeZone: .current, formatOptions: [.withFullDate]))
        }
        let e = StoredEvent(id: 1, source: "t", kind: "growth.series", app: "All channels",
                            payload: .object(["days": .array(days), "site_impressions": .array(vals.map { .number($0) }),
                                              "labels": .object(["site_impressions": .string("Hill Trails seen on Google, 7 days")]),
                                              "periods": .object(["site_impressions": .string("1–7 Nov")]),
                                              "better": .object(["site_impressions": .string("up")])]), occurredAt: 0)
        let m = try #require(MetricExtractor.extract([e]).first { $0.key.hasSuffix("site_impressions") })
        #expect(m.period == "1–7 Nov")
        let f = try #require(InsightEngine.unusual(m))
        #expect(f.title.contains("dropped to 2,039 for 1–7 Nov, from a usual") && !f.title.contains("since"))
        // Without a period the old wording stays.
        var plain = m; plain.period = nil
        #expect(InsightEngine.unusual(plain)?.title.contains("since") == true)
    }
}
