import Foundation

/// How API credits cover measured spend (Anthropic's cost report: whole UTC days, per workspace). Pure arithmetic,
/// so the figures on the Costs card can be tested.
public enum CreditMath {
    /// One day's spend in one workspace (USD).
    public struct Spend: Sendable, Equatable {
        public let day: Date            // UTC midnight
        public let workspace: String
        public let usd: Double
        public init(day: Date, workspace: String, usd: Double) { self.day = day; self.workspace = workspace; self.usd = usd }
    }

    /// A credit as far as coverage goes.
    public struct Window: Sendable, Equatable {
        public let name: String
        public let amountUSD: Double
        public let start: Date
        public let end: Date?
        public let workspaces: [String]?
        public let excludeWorkspaces: [String]?
        public init(name: String, amountUSD: Double, start: Date, end: Date?, workspaces: [String]? = nil, excludeWorkspaces: [String]? = nil) {
            self.name = name; self.amountUSD = amountUSD; self.start = start; self.end = end
            self.workspaces = workspaces; self.excludeWorkspaces = excludeWorkspaces
        }
        public func covers(_ s: Spend) -> Bool {
            guard s.day >= CreditMath.utcDay(start) else { return false }
            if let end, s.day >= CreditMath.utcDay(end) { return false }
            if let only = workspaces { return only.contains(s.workspace) }
            if let skip = excludeWorkspaces { return !skip.contains(s.workspace) }
            return true
        }
    }

    public struct Breakdown: Sendable, Equatable {
        public let total: Double
        public let covered: [Covered]
        public let paid: Double
        public struct Covered: Sendable, Equatable { public let name: String; public let usd: Double }
    }

    static let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
    public static func utcDay(_ d: Date) -> Date { utc.startOfDay(for: d) }

    /// A monthly credit whose period has ended is the next period's credit (same amount, dates moved on a month at
    /// a time) until its period contains `now`. Others are unchanged.
    public static func currentPeriod(start: Date, end: Date?, monthly: Bool, now: Date) -> (start: Date, end: Date?, rolled: Bool) {
        guard monthly, var e = end, e <= now else { return (start, end, false) }
        var s = start, n = 0
        while e <= now, n < 1200, let next = utc.date(byAdding: .month, value: 1, to: e) { s = e; e = next; n += 1 }
        return (s, e, true)
    }

    /// What this month's API spend will have cost you by the month's end. Each workspace keeps its daily pace for
    /// the days still to come (`daysDone` whole UTC days are counted so far), and those projected days go through
    /// the same credit rules as real ones: each credit only within its own dates and workspaces, oldest first, up
    /// to what it has left; `nextPeriods` are monthly credits' next periods (a renewal mid-month pays too). Never
    /// less than what you've already paid (credits pay first, so the paid part can start at $0 and rise later).
    public static func projectedPaid(month: [Spend], credits: [Window], usedBefore: [Double], nextPeriods: [Window],
                                     monthStart: Date, daysDone: Int, daysInMonth: Int,
                                     pace: [Spend]? = nil, paceDays: Int = 0) -> Double {
        let actual = breakdown(month: month, credits: credits, usedBefore: usedBefore).paid
        // The daily pace: from `pace` (the last `paceDays` whole days, which may reach into last month) when given,
        // so two busy days at a month's start don't set the whole month; else this month's own days.
        let source = (pace != nil && paceDays > 0) ? (pace!, paceDays) : (month, daysDone)
        guard source.1 > 0, daysInMonth > daysDone else { return actual }
        var perDay: [String: Double] = [:]
        for s in source.0 { perDay[s.workspace, default: 0] += s.usd / Double(source.1) }
        var future: [Spend] = []
        for d in daysDone..<daysInMonth {
            guard let day = utc.date(byAdding: .day, value: d, to: utcDay(monthStart)) else { continue }
            for (ws, usd) in perDay where usd > 0 { future.append(Spend(day: day, workspace: ws, usd: usd)) }
        }
        let all = breakdown(month: month + future, credits: credits + nextPeriods,
                            usedBefore: usedBefore + Array(repeating: 0, count: nextPeriods.count))
        return max(actual, all.paid)
    }

    /// Splits this month's spend into what credits covered and what was paid.
    /// - `usedBefore`: for each credit (same order as `credits`), its spend inside its own window before `month`'s
    ///   first day (what already used it up).
    /// Each day's spend is covered at most once: credits are applied oldest first, each only to days inside its own
    /// dates and workspaces, up to what it has left.
    public static func breakdown(month: [Spend], credits: [Window], usedBefore: [Double]) -> Breakdown {
        let total = month.map(\.usd).reduce(0, +)
        var left = month.map(\.usd)
        let order = month.indices.sorted { month[$0].day < month[$1].day }
        var covered: [Breakdown.Covered] = []
        for ci in credits.indices.sorted(by: { credits[$0].start < credits[$1].start }) {
            let c = credits[ci]
            var capacity = max(0, c.amountUSD - (ci < usedBefore.count ? usedBefore[ci] : 0))
            var cov = 0.0
            for i in order where capacity > 0 && left[i] > 0 && c.covers(month[i]) {
                let take = min(left[i], capacity)
                left[i] -= take; capacity -= take; cov += take
            }
            if cov > 0.004 { covered.append(.init(name: c.name, usd: cov)) }
        }
        return Breakdown(total: total, covered: covered, paid: max(0, left.reduce(0, +)))
    }
}
