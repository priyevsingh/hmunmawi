import Foundation
import Testing
@testable import HmunmawiCore

@Suite struct JudgeTests {
    func cal() -> Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Kolkata")!; return c }
    func series(_ c: Calendar, from: String, values: [Double]) -> [(day: Date, value: Double)] {
        let f = DateFormatter(); f.calendar = c; f.timeZone = c.timeZone; f.dateFormat = "yyyy-MM-dd"
        let start = f.date(from: from)!
        return values.enumerated().map { (c.date(byAdding: .day, value: $0.offset, to: start)!, $0.element) }
    }

    @Test func keepUndoImprove() {
        let c = cal()
        // 28 days at 10, the change day, then 28 days at 12 (+20%).
        let up = series(c, from: "2026-09-01", values: Array(repeating: 10, count: 28) + [99] + Array(repeating: 12, count: 28))
        let r = Judge.judge(up, changeDay: "2026-09-29", days: 28, betterUp: true, calendar: c)
        #expect(r.verdict == .keep && r.daysBefore == 28 && r.daysAfter == 28 && abs(r.change - 0.2) < 1e-9)
        // The same rise is bad for a "lower is better" number (crashes).
        #expect(Judge.judge(up, changeDay: "2026-09-29", days: 28, betterUp: false, calendar: c).verdict == .undo)
        // +2%: no clear effect.
        let flat = series(c, from: "2026-09-01", values: Array(repeating: 10, count: 28) + [10] + Array(repeating: 10.2, count: 28))
        #expect(Judge.judge(flat, changeDay: "2026-09-29", days: 28, betterUp: true, calendar: c).verdict == .improve)
    }

    @Test func tooLittleDataIsUnclear() {
        let c = cal()
        let short = series(c, from: "2026-09-20", values: Array(repeating: 10, count: 9) + [10] + Array(repeating: 20, count: 28))
        #expect(Judge.judge(short, changeDay: "2026-09-29", days: 28, betterUp: true, calendar: c).verdict == .unclear)
        let zero = series(c, from: "2026-09-01", values: Array(repeating: 0, count: 28) + [0] + Array(repeating: 5, count: 28))
        #expect(Judge.judge(zero, changeDay: "2026-09-29", days: 28, betterUp: true, calendar: c).verdict == .unclear)
    }

    @Test func savedBeforeCoversLostHistory() {
        let c = cal()
        // Only the 28 days after are still in the history; the before average (10 over 28 days) was saved.
        let after = series(c, from: "2026-09-30", values: Array(repeating: 12, count: 28))
        #expect(Judge.judge(after, changeDay: "2026-09-29", days: 28, betterUp: true, calendar: c).verdict == .unclear)
        let r = Judge.judge(after, changeDay: "2026-09-29", days: 28, betterUp: true, calendar: c, saved: (10, 28))
        #expect(r.verdict == .keep && r.daysBefore == 28)
    }

    @Test func dueDay() {
        #expect(WatchedChange(id: "a", what: "x", metric: "m", date: "2026-11-04").dueDay == DayNumber.of("2026-12-03"))
    }
}
