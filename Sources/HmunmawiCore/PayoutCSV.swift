import Foundation

/// The accountant export: Apple's payouts by fiscal month, in INR. Pure, so it can be tested.
public enum PayoutCSV {
    public struct Month: Sendable, Equatable {
        public let name: String            // "2026-10", Apple's name for the fiscal month
        public let start: Date, end: Date  // the fiscal month (Sunday to Saturday)
        public let paid: Date              // estimated payment date (33 days after the month ends)
        public let totals: [String: Double] // Apple's finance report, per currency
    }

    /// The fiscal months for Apple's finance-report names, newest first.
    public static func months(_ reports: [String: [String: Double]], calendar: Calendar = Calendar(identifier: .gregorian)) -> [Month] {
        reports.compactMap { name, totals in
            let p = name.split(separator: "-").compactMap { Int($0) }
            guard p.count == 2, let mid = calendar.date(from: DateComponents(year: p[0], month: p[1], day: 15)) else { return nil }
            let m = AppleFiscal.month(containing: mid, calendar: calendar)
            guard let paid = calendar.date(byAdding: .day, value: 33, to: m.end) else { return nil }
            return Month(name: name, start: m.start, end: m.end, paid: paid, totals: totals)
        }.sorted { $0.name > $1.name }
    }

    /// The date whose rate converts a payout: the payment date once it has passed, else today ("not paid yet").
    public static func rateDay(for m: Month, now: Date) -> Date { m.paid <= now ? m.paid : now }

    /// CSV text. `inrPer`: for a rate day ("yyyy-MM-dd"), INR for one unit of each currency (European Central Bank
    /// reference rates); a currency without a rate is left blank and named, never guessed. `bank`: INR that actually
    /// reached your bank, per month, used instead of the estimate when given.
    public static func build(_ months: [Month], bank: [String: Double], inrPer: [String: [String: Double]], now: Date) -> String {
        func day(_ d: Date) -> String {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
        }
        func n(_ v: Double, _ decimals: Int = 2) -> String { String(format: "%.\(decimals)f", v) }
        func cell(_ s: String) -> String { s.contains(where: { ",\"\n".contains($0) }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s }
        var lines = [
            "# Apple App Store payouts by Apple fiscal month, from Apple's finance reports (Hmunmawi).",
            "# INR estimates use European Central Bank reference rates on the estimated payment date (33 days after the fiscal month ends); not-yet-paid months use today's rate.",
            "# Where you entered the INR that reached your bank, that figure is used. Your bank statement is the final figure for tax. Amounts are before any tax Apple withholds.",
            "Fiscal month,Start,End,Estimated payment date,Currency,Amount,INR per unit,INR,Source",
        ]
        for m in months {
            let rd = day(rateDay(for: m, now: now))
            let rates = inrPer[rd] ?? [:]
            var estimate = 0.0, missing: [String] = []
            for (cur, amt) in m.totals.sorted(by: { $0.key < $1.key }) where amt != 0 {
                let r = cur == "INR" ? 1.0 : rates[cur]
                if let r { estimate += amt * r } else { missing.append(cur) }
                lines.append([m.name, day(m.start), day(m.end), day(m.paid), cur, n(amt), r.map { n($0, 4) } ?? "", r.map { n(amt * $0) } ?? "",
                              r == nil ? "no ECB rate for \(cur)" : (m.paid <= now ? "estimate" : "estimate (not paid yet)")].map(cell).joined(separator: ","))
            }
            let total: String, source: String
            if let b = bank[m.name] { total = n(b); source = "from bank" }
            else { total = n(estimate); source = missing.isEmpty ? "estimate" : "estimate without " + missing.joined(separator: ", ") }
            lines.append([m.name, day(m.start), day(m.end), day(m.paid), "TOTAL", "", "", total, source].map(cell).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
