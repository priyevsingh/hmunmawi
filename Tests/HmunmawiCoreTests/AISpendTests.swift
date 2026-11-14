import Foundation
import Testing
@testable import HmunmawiCore

@Suite struct AISpendTests {
    let now = ISO8601DateFormatter().date(from: "2026-11-11T09:00:00Z")!   // 10 whole days of November done

    @Test func openAICostsParse() throws {
        let json = #"{"object":"page","data":[{"object":"bucket","start_time":1793491200,"end_time":1793577600,"results":[{"object":"organization.costs.result","amount":{"value":1.25,"currency":"usd"}},{"object":"organization.costs.result","amount":{"value":0.75,"currency":"usd"}}]}],"has_more":true,"next_page":"p2"}"#
        let r = try #require(AISpendMath.openAIDays(Data(json.utf8)))
        #expect(r.days == [.init(day: "2026-11-01", usd: 2.0)] && r.next == "p2")
    }

    @Test func xaiUsageAndPrepaidParse() throws {
        let json = #"{"timeSeries":[{"group":["Chat grok-4"],"dataPoints":[{"timestamp":"2026-11-01T00:00:00Z","values":[0.5]},{"timestamp":"2026-11-02T00:00:00Z","values":[1.5]}]},{"group":["Image"],"dataPoints":[{"timestamp":"2026-11-01T00:00:00Z","values":[0.25]}]}],"limitReached":false}"#
        let d = try #require(AISpendMath.xaiDays(Data(json.utf8)))
        #expect(d == [.init(day: "2026-11-01", usd: 0.75), .init(day: "2026-11-02", usd: 1.5)])
        #expect(AISpendMath.xaiPrepaidLeft(Data(#"{"changes":[],"total":{"val":"-1000"}}"#.utf8)) == 10)
    }

    @Test func openRouterAndDeepSeekParse() throws {
        let o = try #require(AISpendMath.openRouter(Data(#"{"data":{"total_credits":100.5,"total_usage":25.75}}"#.utf8)))
        #expect(o.bought == 100.5 && o.used == 25.75)
        let d = try #require(AISpendMath.deepSeek(Data(#"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"110.00","granted_balance":"10.00","topped_up_balance":"100.00"}]}"#.utf8)))
        #expect(d.currency == "CNY" && d.granted == 10 && d.toppedUp == 100)
        #expect(AISpendMath.openRouter(Data("{}".utf8)) == nil && AISpendMath.deepSeek(Data("nonsense".utf8)) == nil)
    }

    @Test func dailyMonthRangeAndFreeCredits() {
        // $1/day all of October, $3/day for 1-10 Nov: used $30; low = own pace 3 x 30 = $90; high = 28-day pace.
        var days: [AIReading.Day] = (1...31).map { .init(day: String(format: "2026-10-%02d", $0), usd: 1) }
        days += (1...10).map { .init(day: String(format: "2026-11-%02d", $0), usd: 3) }
        let m = AISpendMath.month(days: days, now: now, paying: true)
        #expect(m.used == 30 && m.paid == 30)
        let pace28 = (18.0 * 1 + 10 * 3) / 28          // 14-31 Oct and 1-10 Nov
        #expect(abs(m.low - (30 + pace28 * 20)) < 1e-9 && abs(m.high - 90) < 1e-9)
        // On free credits: used is shown, nothing counts as a cost.
        let free = AISpendMath.month(days: days, now: now, paying: false)
        #expect(free.used == 30 && free.paid == 0 && free.high == 0)
    }

    @Test func balanceMonthFromReadings() throws {
        func r(_ iso: String, granted: Double, topped: Double) -> AIReading {
            var x = AIReading(provider: .deepseek, at: ISO8601DateFormatter().date(from: iso)!); x.granted = granted; x.toppedUp = topped; return x
        }
        // Free balance used first (5 → 0), then $2 of bought balance, then a $10 top-up (a purchase, not spend).
        let list = [r("2026-11-01T00:00:00Z", granted: 5, topped: 10), r("2026-11-05T00:00:00Z", granted: 0, topped: 10),
                    r("2026-11-08T00:00:00Z", granted: 0, topped: 8), r("2026-11-10T00:00:00Z", granted: 0, topped: 18)]
        let m = try #require(AISpendMath.month(readings: list, now: now, paying: true))
        #expect(m.used == 7 && m.paid == 2 && m.since == nil && m.high >= m.low)
        // OpenRouter: the rise in credits used since the month's first reading (started on the 4th).
        var a = AIReading(provider: .openrouter, at: ISO8601DateFormatter().date(from: "2026-11-04T00:00:00Z")!); a.bought = 50; a.used = 10
        var b = a; b.at = now; b.used = 16
        let o = try #require(AISpendMath.month(readings: [a, b], now: now, paying: true))
        #expect(o.used == 6 && o.paid == 6 && o.since == "2026-11-04")
        #expect(AISpendMath.month(readings: [], now: now, paying: true) == nil)
    }

    @Test func keyFormats() {
        #expect(SpendProvider.openai.looksValid("sk-admin-" + String(repeating: "a", count: 30)))
        #expect(!SpendProvider.openai.looksValid("sk-proj-" + String(repeating: "a", count: 30)))
        #expect(!SpendProvider.deepseek.looksValid("sk- with spaces in it 1234567890"))
        #expect(SpendProvider.openrouter.looksValid("sk-or-v1-" + String(repeating: "b", count: 40)))
    }
}
