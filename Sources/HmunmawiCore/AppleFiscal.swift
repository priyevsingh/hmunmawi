import Foundation

/// Apple's fiscal calendar, which its payments and finance reports follow. The year starts on the Sunday after
/// the last Saturday of September; each quarter is a 5-week month and two 4-week months (Oct 5, Nov 4, Dec 4,
/// Jan 5, …); months run Sunday to Saturday, and the last month ends the day before the next year starts (a
/// 53-week year gives September 5 weeks). E.g. October 2025 = 28 Sep – 1 Nov 2025, June 2026 = 31 May – 27 Jun.
public enum AppleFiscal {
    public struct Month: Sendable, Equatable {
        public let start: Date      // first day (a Sunday), start of day
        public let end: Date        // last day (a Saturday), start of day
        public let name: String     // "2025-10": the month Apple names it after
    }

    /// Day 1 of the fiscal year that starts in late September of `year` (the Sunday after September's last Saturday).
    static func yearStart(_ year: Int, _ cal: Calendar) -> Date {
        let lastOfSep = cal.date(from: DateComponents(year: year, month: 9, day: 30))!
        let back = cal.component(.weekday, from: lastOfSep) % 7      // Saturday (7) -> 0 days back
        return cal.date(byAdding: .day, value: 1 - back, to: lastOfSep)!
    }

    /// The fiscal year's 12 months.
    static func months(ofYearStarting year: Int, _ cal: Calendar) -> [Month] {
        let start = yearStart(year, cal), next = yearStart(year + 1, cal)
        var out: [Month] = [], d = start
        for i in 0..<12 {
            let weeks = i % 3 == 0 ? 5 : 4
            let monthEnd = i == 11 ? cal.date(byAdding: .day, value: -1, to: next)!
                                   : cal.date(byAdding: .day, value: weeks * 7 - 1, to: d)!
            let calMonth = (9 + i) % 12 + 1                                  // Oct, Nov, …, Sep
            let calYear = calMonth >= 10 ? year : year + 1
            out.append(Month(start: d, end: monthEnd, name: String(format: "%04d-%02d", calYear, calMonth)))
            d = cal.date(byAdding: .day, value: 1, to: monthEnd)!
        }
        return out
    }

    /// The fiscal month a day belongs to.
    public static func month(containing day: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> Month {
        let d = calendar.startOfDay(for: day)
        let y = calendar.component(.year, from: d)
        let fy = d >= yearStart(y, calendar) ? y : y - 1
        return months(ofYearStarting: fy, calendar).first { d >= $0.start && d <= $0.end }!
    }

    /// The `reportDate` Apple's finance-report API wants for a fiscal month named like `name` ("2026-09" = the
    /// month Apple's payments page calls September 2026). Apple numbers the reports by fiscal period: the year
    /// is the fiscal year (starts in October, so October 2025 is year 2026) and the month is the period, 1 for
    /// October to 12 for September. So September 2026 is "2026-12" and October 2026 is "2027-01". Asking for
    /// "2026-09" returns June 2026's report (the add-on did, until 5 Nov 2026). The add-on holds a copy of this rule.
    public static func reportDate(forName name: String) -> String? {
        let p = name.split(separator: "-")
        guard p.count == 2, let y = Int(p[0]), let m = Int(p[1]), (1...12).contains(m) else { return nil }
        return String(format: "%04d-%02d", m >= 10 ? y + 1 : y, (m + 2) % 12 + 1)
    }

    /// The fiscal month just before `m`.
    public static func month(before m: Month, calendar: Calendar = Calendar(identifier: .gregorian)) -> Month {
        month(containing: calendar.date(byAdding: .day, value: -1, to: m.start)!, calendar: calendar)
    }
}
