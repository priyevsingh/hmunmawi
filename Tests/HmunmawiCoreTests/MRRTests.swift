import Foundation
import Testing
@testable import HmunmawiCore

@Suite struct MRRTests {
    /// Days "2026-09-01" … with the given active counts; each subscription worth $5/month.
    private func days(_ actives: [Int]) -> [MRRModel.Point] {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        let start = f.date(from: "2026-09-01")!
        return actives.enumerated().map { i, a in
            MRRModel.Point(day: f.string(from: start.addingTimeInterval(Double(i) * 86_400)), mrr: Double(a) * 5, gross: Double(a) * 5 / 0.7, active: a)
        }
    }

    @Test func needsTwoWeeksOfHistory() {
        #expect(MRRModel.project(days(Array(repeating: 10, count: 13))) == nil)
        #expect(MRRModel.project(days(Array(repeating: 10, count: 14))) != nil)
    }

    @Test func steadyBusinessStaysFlat() throws {
        let p = try #require(MRRModel.project(days(Array(repeating: 20, count: 60))))
        #expect(p.now == 100)
        #expect(p.in30 == 100...100 && p.in90 == 100...100)
        #expect(p.churnRate == 0 && p.rough)
    }

    @Test func growingBusinessGoesUpShrinkingGoesDown() throws {
        let up = try #require(MRRModel.project(days((0..<60).map { 10 + $0 / 3 })))     // +1 every 3 days
        #expect(up.in30.lowerBound > up.now && up.in90.lowerBound > up.in30.lowerBound)
        let down = try #require(MRRModel.project(days((0..<60).map { 40 - $0 / 3 })))   // −1 every 3 days
        #expect(down.in30.upperBound < down.now && down.in90.upperBound < down.in30.upperBound)
        #expect(down.in90.lowerBound >= 0)
        #expect(down.churnRate > 0)
    }

    @Test func totalsCountAMissingAppAsZero() {
        let a = days([1, 2, 3]), b = Array(days([10, 10, 10]).prefix(2))
        #expect(MRRModel.total([a, b]).map(\.active) == [11, 12, 3])   // b had no row on day 3: 0 that day
        let filled = MRRModel.filled(b, days: a.map(\.day))
        #expect(filled.map(\.active) == [10, 10, 0])
    }

    @Test func timeComesFromTheDatesNotTheRowCount() throws {
        // The same growth with every other day missing must project the same as with every day present.
        let full = days((0..<60).map { 10 + $0 / 3 })
        let sparse = full.enumerated().filter { $0.offset % 2 == 0 || $0.offset == 59 }.map(\.element)
        let a = try #require(MRRModel.project(full)), b = try #require(MRRModel.project(sparse))
        #expect(abs(a.in90.upperBound - b.in90.upperBound) / a.in90.upperBound < 0.1)
    }
}

@Suite struct CreditMathTests {
    let day = 86_400.0
    func d(_ s: String) -> Date { ISO8601DateFormatter().date(from: s + "T00:00:00Z")! }
    func spend(_ s: String, _ usd: Double, ws: String = "Default") -> CreditMath.Spend { .init(day: d(s), workspace: ws, usd: usd) }

    @Test func expiredCreditCoversNothingThisMonth() {
        let oct = CreditMath.Window(name: "Oct", amountUSD: 40, start: d("2026-10-01"), end: d("2026-11-01"))
        let b = CreditMath.breakdown(month: [spend("2026-11-01", 30)], credits: [oct], usedBefore: [25])
        #expect(b.covered.isEmpty && b.paid == 30)
    }

    @Test func notYetStartedCreditCoversOnlyFromItsStart() {
        let c = CreditMath.Window(name: "Mid", amountUSD: 100, start: d("2026-11-15"), end: nil)
        let b = CreditMath.breakdown(month: [spend("2026-11-02", 10), spend("2026-11-16", 5)], credits: [c], usedBefore: [0])
        #expect(b.covered.map(\.usd) == [5] && b.paid == 10)
    }

    @Test func overlappingCreditsNeverCoverTheSameDollarTwice() {
        let a = CreditMath.Window(name: "A", amountUSD: 100, start: d("2026-10-01"), end: nil)
        let b2 = CreditMath.Window(name: "B", amountUSD: 100, start: d("2026-10-15"), end: nil)
        let b = CreditMath.breakdown(month: [spend("2026-11-01", 30)], credits: [b2, a], usedBefore: [0, 0])
        #expect(b.covered.map(\.usd).reduce(0, +) == 30 && b.paid == 0)
        #expect(b.covered.first?.name == "A")   // oldest first
    }

    @Test func usedUpCreditCoversOnlyWhatIsLeftAndOnlyItsWorkspaces() {
        let c = CreditMath.Window(name: "Hm", amountUSD: 40, start: d("2026-10-20"), end: nil, workspaces: ["Hmunmawi"])
        let b = CreditMath.breakdown(month: [spend("2026-11-01", 10, ws: "Hmunmawi"), spend("2026-11-01", 7)],
                                     credits: [c], usedBefore: [35])
        #expect(b.covered.map(\.usd) == [5])
        #expect(abs(b.paid - 12) < 1e-9 && b.total == 17)
    }

    @Test func monthlyCreditRollsIntoTheCurrentPeriod() {
        let p = CreditMath.currentPeriod(start: d("2026-09-05"), end: d("2026-10-05"), monthly: true, now: d("2026-11-02"))
        #expect(p.rolled && p.start == d("2026-10-05") && p.end == d("2026-11-05"))
        let q = CreditMath.currentPeriod(start: d("2026-10-05"), end: d("2026-11-05"), monthly: true, now: d("2026-11-02"))
        #expect(!q.rolled)
        #expect(!CreditMath.currentPeriod(start: d("2026-09-05"), end: d("2026-10-05"), monthly: false, now: d("2026-11-02")).rolled)
    }
}

@Suite struct AppleFiscalReportDateTests {
    @Test func appleNumbersFinanceReportsByFiscalPeriod() {
        // Apple numbers finance reports by fiscal period (October = 1 ... September = 12): report "2026-09" holds June 2026's
        // proceeds, and September 2026's sales are in report "2026-12".
        let cases = [("2025-10", "2026-01"), ("2025-11", "2026-02"), ("2026-01", "2026-04"), ("2026-05", "2026-08"),
                     ("2026-06", "2026-09"), ("2026-07", "2026-10"), ("2026-09", "2026-12"), ("2026-10", "2027-01"), ("2026-12", "2027-03")]
        for (name, report) in cases { #expect(AppleFiscal.reportDate(forName: name) == report, "\(name)") }
        #expect(AppleFiscal.reportDate(forName: "2026-13") == nil)
        #expect(AppleFiscal.reportDate(forName: "nonsense") == nil)
    }
}

@Suite struct AppleFiscalTests {
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    func d(_ s: String) -> Date { ISO8601DateFormatter().date(from: s + "T12:00:00Z")! }
    func day(_ s: String) -> Date { cal.startOfDay(for: d(s)) }

    @Test func matchesApplesPublishedMonths() {
        // Published: October 2025 = 28 Sep – 1 Nov; November 2025 = 2 – 29 Nov; June 2026 = 31 May – 27 Jun.
        let oct = AppleFiscal.month(containing: d("2025-10-31"), calendar: cal)
        #expect(oct.start == day("2025-09-28") && oct.end == day("2025-11-01") && oct.name == "2025-10")
        let nov = AppleFiscal.month(containing: d("2025-11-02"), calendar: cal)
        #expect(nov.start == day("2025-11-02") && nov.end == day("2025-11-29") && nov.name == "2025-11")
        let jun = AppleFiscal.month(containing: d("2026-06-10"), calendar: cal)
        #expect(jun.start == day("2026-05-31") && jun.end == day("2026-06-27") && jun.name == "2026-06")
        // The case the old "last Saturday" rule got wrong: 1 Nov 2025 belongs to October.
        #expect(AppleFiscal.month(containing: d("2025-11-01"), calendar: cal).name == "2025-10")
        // November 2026 (this month): 1 – 28 Nov; before it, October 2026 = 27 Sep – 31 Oct.
        let now = AppleFiscal.month(containing: d("2026-11-03"), calendar: cal)
        #expect(now.start == day("2026-11-01") && now.end == day("2026-11-28") && now.name == "2026-11")
        let prev = AppleFiscal.month(before: now, calendar: cal)
        #expect(prev.start == day("2026-09-27") && prev.end == day("2026-10-31") && prev.name == "2026-10")
    }

    @Test func monthsTileTheYearWithoutGaps() {
        var m = AppleFiscal.month(containing: d("2024-01-15"), calendar: cal)
        for _ in 0..<60 {
            let next = AppleFiscal.month(containing: cal.date(byAdding: .day, value: 1, to: m.end)!, calendar: cal)
            #expect(next.start == cal.date(byAdding: .day, value: 1, to: m.end)!)
            #expect(cal.component(.weekday, from: next.start) == 1 && cal.component(.weekday, from: next.end) == 7)   // Sun–Sat
            m = next
        }
    }
}

@Suite struct PayoutCSVTests {
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    @Test func fiscalMonthsRatesAndBankFigures() {
        let now = ISO8601DateFormatter().date(from: "2026-11-20T12:00:00Z")!
        let months = PayoutCSV.months(["2026-09": ["USD": 100, "INR": 500, "AED": 10], "2026-10": ["USD": 50]], calendar: cal)
        #expect(months.map(\.name) == ["2026-10", "2026-09"])
        // September 2026 = 30 Aug – 26 Sep; paid ≈ 29 Oct. October 2026 = 27 Sep – 31 Oct; paid ≈ 3 Dec (after "now").
        #expect(months[1].paid == cal.date(from: DateComponents(year: 2026, month: 10, day: 29)))
        #expect(months[0].paid == cal.date(from: DateComponents(year: 2026, month: 12, day: 3)))
        let rates = ["2026-10-29": ["USD": 88.0], "2026-11-20": ["USD": 89.0]]
        var csv = PayoutCSV.build(months, bank: [:], inrPer: rates, now: now)
        #expect(csv.contains("2026-09,2026-08-30,2026-09-26,2026-10-29,USD,100.00,88.0000,8800.00,estimate"))
        #expect(csv.contains("2026-09,2026-08-30,2026-09-26,2026-10-29,AED,10.00,,,no ECB rate for AED"))
        #expect(csv.contains("2026-09,2026-08-30,2026-09-26,2026-10-29,TOTAL,,,9300.00,estimate without AED"))
        #expect(csv.contains("2026-10,2026-09-27,2026-10-31,2026-12-03,USD,50.00,89.0000,4450.00,estimate (not paid yet)"))
        csv = PayoutCSV.build(months, bank: ["2026-09": 9100], inrPer: rates, now: now)
        #expect(csv.contains("2026-09,2026-08-30,2026-09-26,2026-10-29,TOTAL,,,9100.00,from bank"))
    }
}

@Suite struct ProjectedPaidTests {
    func d(_ s: String) -> Date { ISO8601DateFormatter().date(from: s + "T00:00:00Z")! }
    func days(_ n: Int, _ ws: String, _ usd: Double) -> [CreditMath.Spend] {
        (0..<n).map { CreditMath.Spend(day: Calendar(identifier: .gregorian).date(byAdding: .day, value: $0, to: d("2026-11-01"))!, workspace: ws, usd: usd) }
    }
    let start = ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z")!

    @Test func creditRunsOutLaterInTheMonth() {
        // $1/day for 10 days, a $15 credit: covered so far, $15 more than the credit by day 30.
        let c = CreditMath.Window(name: "C", amountUSD: 15, start: d("2026-10-01"), end: nil)
        let p = CreditMath.projectedPaid(month: days(10, "A", 1), credits: [c], usedBefore: [0], nextPeriods: [],
                                         monthStart: start, daysDone: 10, daysInMonth: 30)
        #expect(abs(p - 15) < 1e-9)
    }

    @Test func creditForAnotherWorkspaceNeverCoversThisOne() {
        let c = CreditMath.Window(name: "H", amountUSD: 1000, start: d("2026-10-01"), end: nil, workspaces: ["Hmunmawi"])
        let p = CreditMath.projectedPaid(month: days(10, "Default", 1), credits: [c], usedBefore: [0], nextPeriods: [],
                                         monthStart: start, daysDone: 10, daysInMonth: 30)
        #expect(abs(p - 30) < 1e-9)
    }

    @Test func monthlyRenewalMidMonthPaysToo() {
        // $2/day; a $20 monthly credit whose period ends 11 Nov (all used), renewing 11 Nov – 11 Dec with $40.
        let now = CreditMath.Window(name: "M", amountUSD: 20, start: d("2026-10-11"), end: d("2026-11-11"))
        let next = CreditMath.Window(name: "M next", amountUSD: 40, start: d("2026-11-11"), end: d("2026-12-11"))
        let p = CreditMath.projectedPaid(month: days(10, "A", 2), credits: [now], usedBefore: [20], nextPeriods: [next],
                                         monthStart: start, daysDone: 10, daysInMonth: 30)
        // Paid: days 1-10 ($20, credit already used up) + 11 Nov is covered by the renewal... 1 Nov-10 Nov = $20 paid,
        // 11-30 Nov = 20 days x $2 = $40, all inside the renewed $40.
        #expect(abs(p - 20) < 1e-9)
    }

    @Test func neverBelowPaidAndFirstDay() {
        let p = CreditMath.projectedPaid(month: [], credits: [], usedBefore: [], nextPeriods: [], monthStart: start, daysDone: 0, daysInMonth: 30)
        #expect(p == 0)
        let q = CreditMath.projectedPaid(month: days(10, "A", 1), credits: [], usedBefore: [], nextPeriods: [], monthStart: start, daysDone: 10, daysInMonth: 30)
        #expect(abs(q - 30) < 1e-9)
    }

    @Test func twoBusyDaysDontSetTheMonth() {
        // $5/day on 1-2 Nov, but the last 28 days averaged $1/day: 10 so far + 28 x $1 = $38, not 30 x $5 = $150.
        let p = CreditMath.projectedPaid(month: days(2, "A", 5), credits: [], usedBefore: [], nextPeriods: [],
                                         monthStart: start, daysDone: 2, daysInMonth: 30,
                                         pace: Array(repeating: CreditMath.Spend(day: d("2026-10-20"), workspace: "A", usd: 1), count: 28), paceDays: 28)
        #expect(abs(p - 38) < 1e-9)
        // First day of the month (nothing counted yet): still projected from the pace.
        let first = CreditMath.projectedPaid(month: [], credits: [], usedBefore: [], nextPeriods: [], monthStart: start, daysDone: 0, daysInMonth: 30,
                                             pace: [CreditMath.Spend(day: d("2026-10-20"), workspace: "A", usd: 28)], paceDays: 28)
        #expect(abs(first - 30) < 1e-9)
    }
}

@Suite struct ForecastCheckTests {
    @Test func comparesOnlyMonthsWithBoth() {
        let r = ForecastCheck.rows(forecasts: ["2026-09": 210, "2026-10": 190, "2026-11": 200], apple: ["2026-09": 200, "2026-10": 200, "2026-08": 150])
        #expect(r.map(\.month) == ["2026-10", "2026-09"])
        #expect(abs(r[0].error - -0.05) < 1e-9 && abs(r[1].error - 0.05) < 1e-9)
        #expect(abs((ForecastCheck.averageMiss(r) ?? 0) - 0.05) < 1e-9)
        #expect(ForecastCheck.averageMiss([]) == nil)
        #expect(ForecastCheck.rows(forecasts: ["2026-10": 5], apple: ["2026-10": 0]).isEmpty)
    }
}

@Suite struct WeeklyStatsTests {
    func row(_ day: String, _ app: String, units: Double, usd: Double) -> StoredEvent {
        StoredEvent(id: Int64(day.hashValue & 0xffff) + Int64(app.count), source: "t", kind: "revenue.daily", app: app,
                    payload: .object(["day": .string(day), "units": .number(units), "proceeds_usd": .number(usd)]), occurredAt: 0)
    }
    @Test func weekVsWeekBeforeAndBestApp() {
        var rows: [StoredEvent] = []
        for d in 1...14 {
            let day = String(format: "2026-10-%02d", d)
            rows.append(row(day, "A", units: d > 7 ? 3 : 2, usd: d > 7 ? 2 : 1))
            rows.append(row(day, "B", units: 1, usd: 0))
        }
        let mrr = (1...14).map { MRRModel.Point(day: String(format: "2026-10-%02d", $0), mrr: Double(100 + $0), gross: 0, active: 10 + $0 / 7) }
        let s = WeeklyStats.make(daily: rows, mrr: mrr)!
        #expect(s.days.first == "2026-10-08" && s.days.last == "2026-10-14")
        #expect(s.downloads == 28 && s.downloadsBefore == 21)
        #expect(abs((s.downloadsChange ?? 0) - 1.0 / 3.0) < 1e-9)
        #expect(s.earnedUSD == 14 && s.earnedBeforeUSD == 7)
        #expect(s.dailyDownloads == Array(repeating: 4, count: 7))
        #expect(s.best?.name == "A" && s.best?.downloads == 21)
        #expect(s.mrrUSD == 114 && s.mrrWeekAgoUSD == 107 && s.paying == 12)
        // The week before.
        let w1 = WeeklyStats.make(daily: rows, mrr: mrr, weeksBack: 1)!
        #expect(w1.days.last == "2026-10-07" && w1.downloadsChange == nil)
        #expect(WeeklyStats.make(daily: rows, mrr: mrr, weeksBack: 2) == nil)
        #expect(WeeklyStats.make(daily: [], mrr: []) == nil)
    }
}

@Suite struct PeriodStatsTests {
    func rows(from: String, days: Int) -> [StoredEvent] {
        let start = MRRModel.date(from)!
        return (0..<days).map { i in
            let d = Calendar(identifier: .gregorian).date(byAdding: .day, value: i, to: start)!
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
            return StoredEvent(id: Int64(i), source: "t", kind: "revenue.daily", app: "A",
                               payload: .object(["day": .string(f.string(from: d)), "units": .number(1), "proceeds_usd": .number(2)]), occurredAt: 0)
        }
    }
    @Test func onlyCoveredPeriodsAndRightRanges() {
        // 23 Aug – 1 Nov 2026 (like the real history): week and month (October) yes; quarter (Q3 needs 1 Jul) and year no.
        let r = rows(from: "2026-08-23", days: 71)
        #expect(PeriodStats.available(daily: r) == [.week, .month])
        let m = PeriodStats.make(.month, daily: r, mrr: [])!
        #expect(m.title == "October" && m.span.0 == "2026-10-01" && m.span.1 == "2026-10-31")
        #expect(m.downloads == 31 && m.downloadsBefore == 30 && m.buckets.count == 31)
        let w = PeriodStats.make(.week, daily: r, mrr: [])!
        #expect(w.span.0 == "2026-10-26" && w.span.1 == "2026-11-01" && w.buckets.count == 7 && w.downloadsChange == 0)
        #expect(PeriodStats.make(.quarter, daily: r, mrr: []) == nil)
        // A full year of history: Q3 2026 (with Q2 to compare) and 2026 so far, no comparison for last year.
        let y = rows(from: "2025-11-01", days: 366)
        #expect(PeriodStats.available(daily: y) == [.week, .month, .quarter, .year])
        let q = PeriodStats.make(.quarter, daily: y, mrr: [])!
        #expect(q.title == "Q3 2026" && q.span.0 == "2026-07-01" && q.span.1 == "2026-09-30" && q.downloadsBefore == 91)
        // 92 days in 13 weekly bars: the leftover day joins the last week (no one-day sliver), nothing is lost.
        #expect(q.buckets.count == 13 && q.buckets.map(\.downloads).reduce(0, +) == q.downloads && q.buckets.last!.downloads == 8)
        let yr = PeriodStats.make(.year, daily: y, mrr: [])!
        #expect(yr.title == "2026 so far" && yr.downloadsBefore == nil && yr.buckets.count == 11)
    }

    @Test func newAppOnlyOffersWhatItsHistoryCovers() {
        // The account reports 23 Aug – 1 Nov; app B first sold on 15 Oct: week only, ending on the account's last day.
        let account = rows(from: "2026-08-23", days: 71)
        let lo = MRRModel.date("2026-08-23")!, hi = MRRModel.date("2026-11-01")!
        let b = rows(from: "2026-10-15", days: 10)   // B's sales stop on 24 Oct
        #expect(PeriodStats.available(daily: b, bounds: (lo, hi)) == [.week])
        let w = PeriodStats.make(.week, daily: b, mrr: [], bounds: (lo, hi))!
        #expect(w.span.1 == "2026-11-01" && w.isEmpty)      // nothing that week: the sheet greys it out
        #expect(PeriodStats.available(daily: account, bounds: (lo, hi)) == [.week, .month])
    }
    @Test func peakIsTheBusiestBucket() {
        var r = rows(from: "2026-10-26", days: 7)
        r[2] = StoredEvent(id: 99, source: "t", kind: "revenue.daily", app: "A",
                           payload: .object(["day": .string("2026-10-28"), "units": .number(9), "proceeds_usd": .number(0)]), occurredAt: 0)
        let w = PeriodStats.make(.week, daily: r, mrr: [])!
        #expect(PeriodStats.day(w.peak!.start) == "2026-10-28" && w.peak!.downloads == 9)
    }
}
