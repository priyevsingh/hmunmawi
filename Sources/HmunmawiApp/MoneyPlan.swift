import Foundation
import HmunmawiCore
import SwiftUI

/// Payday & profit: Apple's next payment (estimated: the API has no real payment amount or date), this month's
/// forecast, what you pay for tools and AI, and what's really left. All in your chosen currency.
///
/// Apple pays per fiscal month (its own 5-4-4-week calendar, see AppleFiscal) and payment lands about 33 days
/// after the month ends (Apple promises within 45). Shown as an estimate.
@MainActor enum MoneyPlan {
    /// The fiscal month a day belongs to: (start, end).
    static func fiscalMonth(containing day: Date, cal: Calendar = .init(identifier: .gregorian)) -> (start: Date, end: Date) {
        let m = AppleFiscal.month(containing: day, calendar: cal)
        return (m.start, m.end)
    }

    struct Plan {
        var lastMonthUSD: Double            // proceeds in the last finished fiscal month
        var lastMonthEnd: Date
        var payDate: Date                   // estimated
        var monthSoFarUSD: Double
        var forecastUSD: Double
        var daysIn: Int, daysTotal: Int
        /// Today's day of the fiscal month, as people count it (the 1st is day 1). `daysIn` counts complete days.
        var dayOfMonth: Int { min(daysTotal, completeDays + 1) }
        var missingDays: Int                // days without a sales report (shown, never hidden)
        var lastMissing: Int
        var basedOnLastMonth: Bool          // too early in the month to judge: last month's pace is used
        var lastDays = 28                   // length of the last fiscal month (Apple's are 4 or 5 weeks)
        var payIsThisMonth = false          // last month's payout already went out, so the next one is this month's
        var completeDays = 0                // whole days since the month started (0 on its first day)
        var lastMonthName = ""              // Apple's name for the last finished fiscal month ("2026-10")
        var paidMonthName = ""              // the month before it (already paid out) and when that was paid
        var paidMonthEnd = Date.distantPast
    }

    static func plan(_ daily: [String: Double], now: Date = .now) -> Plan {
        let cal = Calendar(identifier: .gregorian)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd"   // same zone as the days it walks (UTC made every month start a day early in India)
        func sum(_ a: Date, _ b: Date) -> (Double, Int) {
            var total = 0.0, missing = 0, d = a
            while d <= b && d < now.addingTimeInterval(-86_400) {
                if let v = daily[f.string(from: d)] { total += v } else { missing += 1 }
                d = cal.date(byAdding: .day, value: 1, to: d)!
            }
            return (total, missing)
        }
        let current = fiscalMonth(containing: now)
        let previous = fiscalMonth(containing: cal.date(byAdding: .day, value: -1, to: current.start)!)
        let (last, lastMissing) = sum(previous.start, previous.end)
        let (soFar, missing) = sum(current.start, now)
        let total = (cal.dateComponents([.day], from: current.start, to: current.end).day ?? 30) + 1
        let complete = max(0, min(total, (cal.dateComponents([.day], from: current.start, to: now).day ?? 0)))
        let elapsed = max(1, complete)
        var pay = cal.date(byAdding: .day, value: 33, to: previous.end)!
        var payIsThisMonth = false
        if pay < cal.startOfDay(for: now) { pay = cal.date(byAdding: .day, value: 33, to: current.end)!; payIsThisMonth = true }
        let reported = elapsed - missing
        let early = reported < 3
        let lastDays = (cal.dateComponents([.day], from: previous.start, to: previous.end).day ?? 30) + 1
        let forecast = early ? last / Double(max(1, lastDays - lastMissing)) * Double(total)
                             : soFar / Double(max(1, reported)) * Double(total)
        return Plan(lastMonthUSD: last, lastMonthEnd: previous.end, payDate: pay, monthSoFarUSD: soFar,
                    forecastUSD: forecast, daysIn: elapsed, daysTotal: total, missingDays: missing,
                    lastMissing: lastMissing, basedOnLastMonth: early, lastDays: lastDays, payIsThisMonth: payIsThisMonth,
                    completeDays: complete,
                    lastMonthName: AppleFiscal.month(containing: previous.start, calendar: cal).name,
                    paidMonthName: AppleFiscal.month(before: AppleFiscal.month(containing: previous.start, calendar: cal), calendar: cal).name,
                    paidMonthEnd: AppleFiscal.month(before: AppleFiscal.month(containing: previous.start, calendar: cal), calendar: cal).end)
    }
}

/// What you pay to run the business (tools, AI, memberships), monthly. Typed once; usage sources join later.
@MainActor @Observable
final class Costs {
    static let shared = Costs()
    struct Item: Codable, Identifiable, Hashable {
        var id = UUID().uuidString
        var name: String
        var amount: Double
        var currency: String
        var yearly: Bool
        /// Free (a startup program, a promotion): listed, never counted. `ends`: it stops then (cancelled, or the
        /// free period ends), counted until that day only.
        var free: Bool? = nil
        var ends: Date? = nil
        var isFree: Bool { free ?? false }
        var ended: Bool { ends.map { $0 <= .now } ?? false }
        var monthly: Double { isFree || ended ? 0 : (yearly ? amount / 12 : amount) }
    }
    private let url = URL.hmSupport.appending(path: "costs.json")
    /// Whether you top up Anthropic API credits with your own money (off: free/startup credits only).
    static var paysForAPI: Bool {
        // Until you choose: if you've added free credits (startup programs, monthly team credits), you run on those;
        // with none added, the credits you use are ones you bought, so they count.
        get { (UserDefaults.standard.object(forKey: "HMPaysForAPI") as? Bool) ?? Credits.shared.items.isEmpty }
        set { UserDefaults.standard.set(newValue, forKey: "HMPaysForAPI") }
    }
    private(set) var items: [Item] = []
    init() { if let d = try? Data(contentsOf: url), let i = try? JSONDecoder().decode([Item].self, from: d) { items = i } }
    func save(_ list: [Item]) {
        items = list
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(list).write(to: url, options: .atomic)
    }
    enum Pick { case paid, low, high }
    /// Costs this month in the chosen currency: your tools and plans, the Claude API and your other AI accounts as
    /// `pick` says (paid so far, or either end of the month-end range), plus Hmunmawi's own AI on another provider.
    func monthlyTotal(_ pick: Pick = .high) -> Double {
        let api: (Credits.MonthSpend) -> Double = { switch pick { case .paid: $0.paid; case .low: $0.projectedLow; case .high: $0.projectedPaid } }
        let others = AIAccounts.shared.paidUSD { switch pick { case .paid: $0.paid; case .low: $0.low; case .high: $0.high } }
        let othersLocal = Money.shared.convert(others, from: "USD") ?? 0
        let money = Money.shared
        let typed = items.compactMap { money.convert($0.monthly, from: $0.currency) }.reduce(0, +)
        // The AI tally only resets on the next AI call, so last month's figure must not count as this month's.
        let usage = AISettings.shared.usage
        let tally = usage.month == AISettings.monthKey() ? money.convert(usage.usd, from: "USD") ?? 0 : 0
        // Measured Claude API spend you pay (after credits) already includes Hmunmawi's own AI when that runs on
        // Claude (same Anthropic account), so the tally is added only for another provider.
        // Projected to the month's end, like the payday forecast it's taken from (never less than paid so far).
        // Anthropic API credits are prepaid: spend comes off credits and stops when they run out, so it costs you
        // money only if you buy credits yourself (Your costs → "I buy API credits"). Otherwise it's $0 out of pocket.
        if Self.paysForAPI, let b = Credits.shared.monthBreakdown {
            let paid = api(b)
            return typed + othersLocal + (money.convert(paid, from: "USD") ?? 0) + (AISettings.shared.provider == .claude ? 0 : tally)
        }
        // Hmunmawi's own AI on Claude uses the same prepaid credits: a cost only when you buy them.
        return typed + othersLocal + (AISettings.shared.provider == .claude && !Self.paysForAPI ? 0 : tally)
    }
}

struct MoneyPlanCard: View {
    let model: AppModel
    @State private var plan: MoneyPlan.Plan?
    @State private var official: [String: Double]?      // Apple's finance report for the month being paid
    /// Official months as Apple reported them (per currency), oldest first; converted when drawn, so a currency
    /// or rate change never leaves old amounts under a new symbol.
    @State private var rawMonths: [(month: String, byCurrency: [String: Double])] = []
    private var months: [(month: String, total: Double)] {
        rawMonths.map { m in (m.month, m.byCurrency.compactMap { Money.shared.convert($0.value, from: $0.key) }.reduce(0, +)) }
    }
    @State private var aiRead: String?
    @State private var aiBusy = false
    @State private var costs = Costs.shared
    @State private var editing = false
    @State private var exporting = false
    @State private var checks: [ForecastCheck.Row] = []

    var body: some View {
        let money = Money.shared
        KitCard {
            HStack {
                CardHeader(symbol: "banknote.fill", title: "Payday & profit", tint: Brand.Category.money,
                           caption: official != nil ? "Apple's finance report + forecasts" : "Forecasts from Apple's daily sales reports")
                Button { exporting = true } label: { Image(systemName: "square.and.arrow.up") }.buttonStyle(.borderless)
                    .help("Export for accountant: Apple's payouts by fiscal month in INR (CSV)")
                Button { editing = true } label: { Image(systemName: "slider.horizontal.3") }.buttonStyle(.borderless).help("Your costs")
            }
            // Without exchange rates (first launch offline; they're kept once loaded) any figure mixing currencies
            // would be partly ₹0: say so plainly instead of showing wrong numbers.
            if plan != nil, money.convert(1, from: "USD") == nil {
                Label("Exchange rates are loading. Payday, forecast and profit appear once they're in (it needs the internet once).",
                      systemImage: "arrow.triangle.2.circlepath")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if let p = plan {
                let lastPay = official.map { $0.compactMap { money.convert($0.value, from: $0.key) }.reduce(0, +) } ?? money.convert(p.lastMonthUSD, from: "USD") ?? 0
                // Early in a month the pace comes from last month: Apple's official figure when it's out, scaled to
                // this month's length (fiscal months are 4 or 5 weeks).
                let forecast = (p.basedOnLastMonth && official != nil) ? lastPay / Double(max(1, p.lastDays)) * Double(p.daysTotal)
                    : money.convert(p.forecastUSD, from: "USD") ?? 0
                // Once last month's money has gone out, the next payday is this month's: its amount is the forecast.
                let pay = p.payIsThisMonth ? forecast : lastPay
                // Facts first: costs paid so far are measured; the month's end is a range (spend comes in bursts).
                let costSoFar = costs.monthlyTotal(.paid)
                let costLow = costs.monthlyTotal(.low), costHigh = costs.monthlyTotal(.high)
                let monthly = costHigh                       // the cautious end, for the AI's read
                let profitLow = forecast - costHigh, profitHigh = forecast - costLow
                let profit = profitLow
                let fmt = { (v: Double) in money.format(v, from: money.target, decimals: 0) }
                let span = { (lo: Double, hi: Double) in abs(hi - lo) < 1 ? fmt(lo) : "\(fmt(lo)) to \(fmt(hi))" }
                let dm = { (d: Date) in d.formatted(.dateTime.day().month(.abbreviated)) }
                let curStart = Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: p.lastMonthEnd)!
                let curEnd = Calendar(identifier: .gregorian).date(byAdding: .day, value: p.daysTotal - 1, to: curStart)!
                let curName = Self.monthName(AppleFiscal.month(containing: curStart).name)
                // "October (Apple's month 28 Sep – 1 Nov)": Apple's months are 4 or 5 weeks, not calendar months.
                let lastSpan = "\(Self.monthName(p.lastMonthName)) (Apple's month to \(dm(p.lastMonthEnd)))"
                let curSpan = "\(curName) (Apple's month \(dm(curStart)) – \(dm(curEnd)))"
                // Four across when there's room, fewer rows of equal height when narrow (never off the card's edge).
                EqualRowsGrid(minWidth: 210, spacing: 28) {
                    figure(money.format(pay, from: money.target, decimals: 0), "Next Apple payday",
                           p.payIsThisMonth ? "\(curSpan), forecast · paid ≈ \(dm(p.payDate)) (Apple's payment calendar)"
                               : official != nil ? "\(lastSpan), Apple's finance report · paid ≈ \(dm(p.payDate)) (Apple's payment calendar)"
                                   + Self.unconverted(official)
                               : p.lastMissing > 7 ? "\(lastSpan). Partial: only \(max(0, p.lastDays - p.lastMissing)) days of reports so far; the real payday will be higher"
                               : "\(lastSpan), forecast from daily sales · paid ≈ \(dm(p.payDate))", Brand.Category.money, usd: money.usdNote(pay, from: money.target))
                    figure(money.format(forecast, from: money.target, decimals: 0), "This month, if it keeps up",
                           p.basedOnLastMonth ? "\(curSpan) · day \(p.dayOfMonth) of \(p.daysTotal): too early to tell, so this uses last month's pace"
                               : "\(curSpan) · \(money.format(money.convert(p.monthSoFarUSD, from: "USD") ?? 0, from: money.target, decimals: 0)) so far, day \(p.dayOfMonth) of \(p.daysTotal)", Brand.Category.users, usd: money.usdNote(forecast, from: money.target))
                    if Credits.shared.spendPending {
                        // A key is saved but Anthropic hasn't answered yet: no figure beats a figure missing the API.
                        figure("…", "Costs paid so far", "Reading your Claude API spend from Anthropic. If it's busy (too many requests), Hmunmawi tries again within 30 minutes.", Brand.caution)
                        figure("…", "Really yours, this month", "\(curName) forecast − costs, once your Claude API spend is in.", Brand.good)
                    } else {
                    figure(fmt(costSoFar), "Costs paid so far",
                           Self.costsLine(costs).replacingOccurrences(of: " Click for details.", with: "")
                               + (abs(costHigh - costLow) >= 1 || costHigh - costSoFar >= 1 ? " By month end: likely \(span(costLow, costHigh))." : "") + " Click for details.",
                           Brand.caution, usd: money.usdNote(costSoFar, from: money.target))
                        .clickForDetail(Self.costsDetail(costs))
                    figure(span(profitLow, profitHigh), "Really yours, this month",
                           "\(curName) forecast \(fmt(forecast)) − costs \(abs(costHigh - costLow) >= 1 ? "by month end (\(span(costLow, costHigh)))" : fmt(costHigh)), before tax. " +
                           (profit >= 0 ? Quips.pick(["Ramen fund: growing.", "Profit! Tiny, but it counts.", "In the black. Somebody frame this."])
                               : Quips.pick(["Costs are winning this round.", "Spending more than earning. Plot twist pending."])),
                           profit >= 0 ? Brand.good : Brand.bad, usd: money.usdNote(profit, from: money.target))
                    }
                }
                // The payout that's already been made: the official month before the one being paid next.
                let paidMonth = p.paidMonthName
                if let last = months.first(where: { $0.month == paidMonth }) {
                    let paidOn = Calendar.current.date(byAdding: .day, value: 33, to: p.paidMonthEnd)!
                    // One flowing line that wraps at narrow widths instead of being cut with "…".
                    let trend = months.count >= 2 ? " · trend: " + months.suffix(3).map { "\(Self.monthName($0.month).prefix(3)) \(money.format($0.total, from: money.target, decimals: 0))" }.joined(separator: " → ") : ""
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(Brand.good)
                        (Text("Last payout \(money.format(last.total, from: money.target, decimals: 0))").font(.body.weight(.semibold))
                         + Text(" · Apple's \(Self.monthName(paidMonth)) report · paid ≈ \(paidOn.formatted(.dateTime.day().month(.abbreviated))) by Apple's calendar\(trend)")
                            .font(.callout).foregroundStyle(.secondary))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let last = checks.first {
                    // How close the forecast came, once Apple's report for a forecast month is in.
                    let pct = { (e: Double) in "\(e >= 0 ? "+" : "−")\(Int((abs(e) * 100).rounded()))%" }
                    Label {
                        Text("Forecast check: \(PayoutsSheet.title(last.month)) forecast \(money.format(money.convert(last.forecastUSD, from: "USD") ?? last.forecastUSD, from: money.target, decimals: 0)), Apple's report \(money.format(money.convert(last.appleUSD, from: "USD") ?? last.appleUSD, from: money.target, decimals: 0)) (\(pct(last.error)))"
                             + (checks.count > 1 ? " · off by \(Int(((ForecastCheck.averageMiss(checks) ?? 0) * 100).rounded()))% on average over \(checks.count) months" : ""))
                    } icon: { Image(systemName: "scope").foregroundStyle(Brand.Category.money) }
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let aiRead {
                        Label { Text((try? AttributedString(markdown: aiRead)) ?? AttributedString(aiRead)) } icon: { Image(systemName: "sparkles") }
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Want the AI's read on where this month lands?").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { Task { await askAI(p, forecast: forecast, pay: pay) } } label: {
                        Label(aiBusy ? "Sort it for me: Thinking" : (aiRead == nil ? "Sort it for me: Predict" : "Sort it for me: Predict again"), systemImage: "sparkles")
                    }
                    .buttonStyle(.pill).disabled(aiBusy)
                }
                if p.lastMissing > 0 && p.lastMissing <= 7 {
                    Text("\(p.lastMissing) day\(p.lastMissing == 1 ? "" : "s") of last month had no sales report here, so payday may be a bit higher.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if p.missingDays > 0 && !p.basedOnLastMonth {
                    Text("\(p.missingDays) day\(p.missingDays == 1 ? "" : "s") this month \(p.missingDays == 1 ? "has" : "have") no sales report yet; Apple publishes each day about a day late.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(official != nil
                     ? "Payday amount is Apple's official finance report, converted at today's rate. Apple's API doesn't give the payment date, so it comes from Apple's payment calendar (about 33 days after its month ends). This month and profit are forecasts."
                     : "Apple hasn't published last month's finance report yet, so payday is a forecast from daily sales; Apple's figure replaces it when it's out (about a week after the month ends).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Adding up Apple's sales reports").foregroundStyle(.secondary)
            }
        }
        // Again whenever any new row is stored (late reports for older days too), the currency or its rates
        // change, or the day turns (new fiscal month, "day X of Y").
        .task(id: "\(model.windowLastID)|\(Money.shared.target)|\(Money.shared.ratesDate ?? "")|\(Date.now.localDay)") {
            let since = Calendar.current.date(byAdding: .day, value: -75, to: .now)!
            let computed = MoneyPlan.plan(await model.dailyProceeds(since: since))
            plan = computed
            // Apple's own name for the fiscal month (a 5-week October can end on 1 November).
            let all = await model.financeMonths()
            official = all[computed.lastMonthName]
            rawMonths = all.keys.sorted().map { m in (m, all[m] ?? [:]) }
            // Forecast check: record this month's forecast from day 15; compare past ones with Apple's reports (USD).
            if computed.dayOfMonth >= 15, !computed.basedOnLastMonth {
                await model.recordForecast(month: AppleFiscal.month(containing: .now).name, usd: computed.forecastUSD)
            }
            let longAll = await model.financeMonths(days: 3650)
            let appleUSD = longAll.compactMapValues { t -> Double? in
                let parts = t.map { Money.shared.usd($0.value, from: $0.key) }
                return parts.contains(nil) ? nil : parts.compactMap { $0 }.reduce(0, +)   // a currency without a rate: skip that month
            }
            checks = ForecastCheck.rows(forecasts: await model.recordedForecasts(), apple: appleUSD)
            aiRead = UserDefaults.standard.string(forKey: "HMForecastAI-" + Date.now.localDay)
        }
        .sheet(isPresented: $editing) { CostsEditor().buttonStyle(.pill) }
        .sheet(isPresented: $exporting) { PayoutsSheet(model: model).buttonStyle(.pill) }
    }

    nonisolated private static let ymFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM"; return f
    }()
    nonisolated static func monthName(_ ym: String) -> String {
        let f = ymFormatter
        return f.date(from: ym).map { $0.formatted(.dateTime.month(.wide)) } ?? ym
    }

    /// The AI's read: range, drivers and risks, from official months, the daily pace and the trend. Read-only;
    /// saved for the day.
    private func askAI(_ p: MoneyPlan.Plan, forecast: Double, pay: Double) async {
        aiBusy = true
        defer { aiBusy = false }
        let money = Money.shared
        let history = months.map { "\($0.month): \(money.format($0.total, from: money.target, decimals: 0))" }.joined(separator: ", ")
        let prompt = """
        An indie iOS developer's Apple App Store proceeds, in \(money.target). Official monthly finance reports: \(history).
        Next payout (month to \(p.lastMonthEnd.formatted(date: .abbreviated, time: .omitted))): \(money.format(pay, from: money.target, decimals: 0)).
        This fiscal month: day \(p.dayOfMonth) of \(p.daysTotal), \(money.format(money.convert(p.monthSoFarUSD, from: "USD") ?? 0, from: money.target, decimals: 0)) so far; simple forecast \(money.format(forecast, from: money.target, decimals: 0)).
        In 2 short sentences: a likely range for this month and the main reason (trend, seasonality, subscriptions renewing). Use the currency symbol. No hedging boilerplate.
        """
        do {
            let text = try await AIWriter.draft(prompt).trimmingCharacters(in: .whitespacesAndNewlines)
            aiRead = String(text.prefix(400))
            UserDefaults.standard.set(aiRead, forKey: "HMForecastAI-" + Date.now.localDay)
        } catch {
            aiRead = "Couldn't ask the AI: " + ((error as? WireError)?.message ?? "\(error)")
        }
    }

    /// One line under "Costs a month" that says how it's reached.
    static func costsLine(_ costs: Costs) -> String {
        let n = costs.items.count, free = costs.items.filter(\.isFree).count, ended = costs.items.filter { !$0.isFree && $0.ended }.count
        let notes = [free > 0 ? "\(free) free" : nil, ended > 0 ? "\(ended) ended" : nil].compactMap { $0 }
        let tools = (n == 0 ? "No tools added" : (n == 1 ? "1 plan or tool" : "\(n) plans and tools") + (notes.isEmpty ? "" : " (\(notes.joined(separator: ", ")))")) + otherAccountsLine()
        guard let b = Credits.shared.monthBreakdown else {
            return tools + " + Hmunmawi's AI this month" + (costs.items.isEmpty ? "; add yours" : "") + ". Click for details."
        }
        let usd = { (v: Double) in String(format: "$%.2f", v) }
        let cov = b.covered.map(\.usd).reduce(0, +)
        if !Costs.paysForAPI {
            return "\(tools). Claude API runs on prepaid credits, not your card (\(usd(b.total)) used in \(Date.now.formatted(.dateTime.month(.wide)))): "
                + creditsLeft() + ". Click for details."
        }
        return "\(tools) + Claude API in \(Date.now.formatted(.dateTime.month(.wide))), measured by Anthropic: \(usd(b.total)) used, \(usd(cov)) covered by credits, \(usd(b.paid)) paid"
            + (Credits.shared.paidRead.map { Date.now.timeIntervalSince($0) > 3600 ? " (read \(Ago.text($0)))" : "" } ?? "") + ". Click for details."
    }

    /// " · OpenAI $4.10 paid · DeepSeek $3.20 left": each connected account, or why it couldn't be read.
    static func otherAccountsLine() -> String {
        let a = AIAccounts.shared
        let parts = SpendProvider.allCases.filter { a.connected.contains($0) }.map { p -> String in
            guard let s = a.status(p) else { return "\(p.name): first read pending" }
            if s.month == nil, s.problem != nil { return "\(p.name): \(a.shortProblems[p] ?? "couldn't read")" }
            let sym = s.currency == "USD" ? "$" : s.currency + " "
            var bits: [String] = []
            if let m = s.month { bits.append(a.paying(p) ? String(format: "%@%.2f paid", sym, m.paid) + (m.since.flatMap(AISpendMath.date).map { " since \($0.formatted(Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).day().month(.abbreviated)))" } ?? "")
                                                         : String(format: "%@%.2f used on free credits", sym, m.used)) }
            if let left = s.left { bits.append(String(format: "%@%.2f left", sym, left)) }
            return "\(p.name) " + (bits.isEmpty ? "connected" : bits.joined(separator: ", "))
        }
        return parts.isEmpty ? "" : " · " + parts.joined(separator: " · ")
    }

    /// "Startup credit used up · monthly credit $X of $Y left (renews 13 Nov)".
    static func creditsLeft() -> String {
        let c = Credits.shared
        let parts = c.current.map { cr -> String in
            let left = max(0, cr.amountUSD - c.used(cr))
            let renew = cr.monthly ? (cr.next.flatMap { n -> String? in
                n > .now ? " (next $\(Int(cr.amountUSD)) on \(n.formatted(.dateTime.day().month(.abbreviated))))" : nil
            } ?? cr.end.map { " (renews \($0.formatted(.dateTime.day().month(.abbreviated))))" } ?? "") : ""
            // A one-off credit past its end date can't pay for anything, whatever was left on it.
            if !cr.monthly, let e = cr.end, e <= .now { return "\(cr.name) expired \(e.formatted(.dateTime.day().month(.abbreviated)))" }
            return left < 0.005 ? "\(cr.name) used up" + renew : String(format: "%@ $%.2f of $%.0f left", cr.name, left, cr.amountUSD) + renew
        }
        return parts.isEmpty ? "no credits added" : parts.joined(separator: " · ")
    }

    /// The full working behind "Costs a month": each part with where it comes from.
    static func costsDetail(_ costs: Costs) -> InfoModel {
        let money = Money.shared
        // Both currencies: yours first, dollars beside it (what Anthropic actually bills).
        let local = { (usd: Double) in money.format(usd, from: "USD", decimals: 2)
            + (money.target == "USD" ? "" : " (" + Money.text(usd, "USD", decimals: 2) + ")") }
        var m = InfoModel(icon: .symbol("creditcard"), tint: Brand.caution, title: "Costs paid so far",
                          subtitle: "What running the business costs this month, and how it's worked out")
        var tools: [InfoModel.Fact] = costs.items.compactMap { item in
            item.isFree ? m.fact("gift", item.name, "free" + (item.ends.map { " until \($0.formatted(.dateTime.day().month(.abbreviated).year()))" } ?? "") + ", not counted")
            : item.ended ? m.fact("calendar.badge.minus", item.name, "ended \(item.ends!.formatted(.dateTime.day().month(.abbreviated))), not counted")
            : m.fact("wrench.and.screwdriver", item.name + (item.yearly ? " (yearly ÷ 12)" : ""),
                   money.format(item.monthly, from: item.currency, decimals: 0)
                   + (money.usdNote(item.monthly, from: item.currency).map { " (\($0))" } ?? "")
                   + (item.ends.map { " · ends \($0.formatted(.dateTime.day().month(.abbreviated)))" } ?? ""))
        }
        if tools.isEmpty, let f = m.fact("plus.circle", "Your tools", "none added yet (the slider button on this card)") { tools = [f] }
        m.groups.append((title: "Tools and plans you added", facts: tools))
        // Other AI accounts read by key.
        let acc = AIAccounts.shared
        var other: [InfoModel.Fact] = []
        for p in SpendProvider.allCases where acc.connected.contains(p) {
            guard let s = acc.status(p) else { if let f = m.fact("hourglass", p.name, "first read pending") { other.append(f) }; continue }
            let cur = s.currency
            let fmt = { (v: Double) in cur == "USD" ? local(v) : String(format: "%@ %.2f", cur, v) }
            if let mo = s.month {
                if let f = m.fact("sparkles", "\(p.name) used this month" + (mo.since.map { " (since \($0))" } ?? ""), fmt(mo.used)) { other.append(f) }
                if let f = m.fact("creditcard", "\(p.name) counted as your cost", acc.paying(p) ? fmt(mo.paid) + (abs(mo.high - mo.low) > 0.005 ? " · by month end " + fmt(mo.low) + " – " + fmt(mo.high) : "") : "none: marked as free credits") { other.append(f) }
            }
            if let left = s.left, let f = m.fact("gift", "\(p.name) balance left", fmt(left)) { other.append(f) }
            if let problem = s.problem, let f = m.fact("exclamationmark.triangle", "\(p.name) last read", problem) { other.append(f) }
        }
        if !other.isEmpty { m.groups.append((title: "Other AI accounts (measured)", facts: other)) }
        if let b = Credits.shared.monthBreakdown {
            var api: [InfoModel.Fact?] = [m.fact("sparkles", "Claude API used this month", local(b.total))]
            for c in b.covered { api.append(m.fact("gift", "Covered by \(c.name)", "− " + local(c.usd))) }
            if Costs.paysForAPI {
                api.append(m.fact("creditcard", "You paid so far", local(b.paid)))
                api.append(m.fact("speedometer", "Pace (last 28 days)", local(b.pacePerDay) + " a day"))
                api.append(m.fact("chart.line.uptrend.xyaxis", "By month end, likely", local(b.projectedLow) + " – " + local(b.projectedPaid)))
            } else {
                // Spend no known credit covers: with prepaid credits it can't have reached a card, so a credit
                // Hmunmawi doesn't know about (or a slightly different figure in Anthropic's own books) paid it.
                if b.paid >= 0.01 {
                    api.append(m.fact("questionmark.circle", "Not matched to a credit you added", local(b.paid)))
                }
                api.append(m.fact("creditcard", "Counted as your cost", "none: prepaid credits, not your card"))
                let c = Credits.shared
                for cr in c.current {
                    api.append(m.fact("gift", "\(cr.name) left", local(max(0, cr.amountUSD - c.used(cr))) + " of " + Money.text(cr.amountUSD, "USD", decimals: 0)))
                }
            }
            m.groups.append((title: "Claude API (measured)", facts: api.compactMap { $0 }))
            let usage = AISettings.shared.usage
            let tally = usage.month == AISettings.monthKey() ? usage.usd : 0
            let onClaude = AISettings.shared.provider == .claude
            if !onClaude, tally > 0, let f = m.fact("sparkles", "Hmunmawi's AI (another provider)", local(tally)) {
                m.groups.append((title: "Hmunmawi's AI", facts: [f]))
            }
            m.paragraphs = Costs.paysForAPI ? [] : [
                "Anthropic API credits are prepaid: what you use comes off your credits, and requests stop when they run out unless you buy more. So the Claude API isn't counted as money you paid. If you top up credits yourself, turn on \"I buy Anthropic API credits myself\" in Your costs (the slider button).",
                "Your Claude plan (Team, Pro) is a separate subscription: add it under Your costs if you pay for it.",
                "Claude API spend is read from Anthropic's cost report (whole UTC days, so today's spend appears tomorrow).",
            ]
            if !Costs.paysForAPI, b.paid >= 0.01 {
                m.paragraphs.insert("Spend not matched to a credit you added was paid by credit Hmunmawi doesn't know about, or Anthropic counted a credit slightly differently. Add any missing credit under Usage so it's matched.", at: 2)
            }
            if Costs.paysForAPI { m.paragraphs = [
                "Claude API spend is read from Anthropic's cost report (whole UTC days, so today's spend appears tomorrow).",
                "A credit pays only for spend in its own workspaces and between its own dates (a monthly credit starts again each month); each day's spend is paid by one credit at most, oldest credit first. What no credit could pay is yours, and only that part counts as a cost.",
                onClaude ? "Hmunmawi's own AI runs on the same Anthropic account, so it's already inside this figure and isn't added again."
                    : "Hmunmawi's own AI uses another provider, so its cost is added on top.",
                "The big number is what you've paid so far this month, as Anthropic measured it. The month-end range runs from this month's own daily pace to the last 28 days' pace, because API spend comes in bursts (big jobs on a few days, little on most). Each projection keeps each workspace's pace, and the projected days go through the same credit rules (a monthly credit's next period included), so it matches the full-month payday forecast. It's never less than what you've already paid; early in the month it moves more.",
                "Apple's months are its fiscal months and Anthropic bills by calendar month; they overlap by 25 days or more, close enough for this comparison.",
            ] }
            m.source = "Anthropic cost report" + (Credits.shared.paidRead.map { " · read " + Ago.text($0) } ?? "")
        } else {
            let usage = AISettings.shared.usage
            let ai = usage.month == AISettings.monthKey() ? usage.usd : 0
            m.groups.append((title: "Hmunmawi's AI", facts: [m.fact("sparkles", "This month", local(ai)),
                                                             m.fact("number", "Calls", "\(usage.month == AISettings.monthKey() ? usage.calls : 0)")].compactMap { $0 }))
            m.paragraphs = ["Hmunmawi's AI cost is counted from the tokens each call used and the model's price.",
                            "Add an Anthropic admin key in Settings to count your whole Claude API spend (after credits) instead."]
        }
        return m
    }

    /// Currencies in Apple's report that can't be converted are left out of the total; say which, never hide it.
    static func unconverted(_ totals: [String: Double]?) -> String {
        let left = (totals ?? [:]).filter { $0.value != 0 && Money.shared.convert($0.value, from: $0.key) == nil }.keys.sorted()
        return left.isEmpty ? "" : " · not counted (no exchange rate): " + left.joined(separator: ", ")
    }

    private func figure(_ value: String, _ label: String, _ note: String, _ tint: Color, usd: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.system(size: 30, weight: .bold)).monospacedDigit().liveNumber(value).foregroundStyle(Kit.vibrant(tint)).lineLimit(1).minimumScaleFactor(0.6)
            // The same amount in dollars, for context (Apple and Anthropic both bill in dollars).
            if let usd, value.contains(where: { ("1"..."9").contains($0) }) { Text(usd).font(.callout.weight(.medium).monospacedDigit()).foregroundStyle(.secondary) }
            Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CostsEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var list = Costs.shared.items
    @State private var name = ""
    @State private var amount = ""
    @State private var currency = Money.shared.target
    @State private var yearly = false
    @State private var free = false
    @State private var hasEnd = false
    @State private var ends = Calendar.current.date(byAdding: .month, value: 1, to: .now) ?? .now
    @State private var addNote: String?
    @State private var adminKey = ""
    @State private var paysForAPI = Costs.paysForAPI
    @State private var keyNote: String?
    @State private var confirmKeyRemove = false
    @State private var provider: SpendProvider = .openai
    @State private var providerKey = ""
    @State private var team = ""
    @State private var providerFree = false
    @State private var connecting = false
    @State private var accountNote: String?
    private var accounts: AIAccounts { AIAccounts.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What you pay to run it").font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    toolsSection
                    Divider()
                    anthropicSection
                    Divider()
                    accountsSection
                }
                .padding(.trailing, 6)
            }
            .frame(maxHeight: 720)   // the whole form on a normal screen; scrolls on small ones
            HStack { Spacer(); Button("Cancel") { dismiss() }.buttonStyle(.pill).keyboardShortcut(.cancelAction)
                Button("Save") { Costs.shared.save(list); Costs.paysForAPI = paysForAPI; dismiss() }.buttonStyle(.pillProminent).keyboardShortcut(.defaultAction) }
        }
        .padding(22).frame(width: 680)
    }

    // MARK: Tools and plans

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tools and plans").font(.headline)
            Text("Monthly or yearly, in any currency. Mark a plan free (a startup program, a promotion) or give it an end date (cancelled): it's listed but not counted after that.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if list.isEmpty {
                Label("Nothing added yet, like a domain, an AI plan or a developer membership.", systemImage: "tray")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(list) { i in
                        HStack {
                            Text(i.name).lineLimit(1)
                            Spacer()
                            Text(rowDetail(i)).foregroundStyle(.secondary).lineLimit(1)
                            Button(role: .destructive) { list.removeAll { $0.id == i.id } } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).help("Remove \(i.name)")
                        }
                        .padding(.vertical, 6)
                        if i.id != list.last?.id { Divider() }
                    }
                }
            }
            HStack(spacing: 8) {
                Menu("AI plan") { ForEach(AIPlanPresets.names, id: \.self) { n in Button(n) { name = n } } }
                    .fixedSize().help("Fill the name from a common AI plan; type what you pay")
                TextField("Name, e.g. Cursor", text: $name).input(.name, $name)
                TextField("Amount", text: $amount).frame(width: 90).input(.short, $amount).disabled(free)
                TextField("Currency", text: $currency).frame(width: 64).input(.identifier, $currency).disabled(free)
                Picker("", selection: $yearly) { Text("a month").tag(false); Text("a year").tag(true) }.labelsHidden().frame(width: 100).disabled(free)
            }
            HStack(spacing: 14) {
                Toggle("Free", isOn: $free)
                Toggle("Ends on", isOn: $hasEnd)
                if hasEnd { DatePicker("", selection: $ends, displayedComponents: .date).labelsHidden().fixedSize() }
                Spacer()
                Button("Add") { add() }.buttonStyle(.pill).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let addNote { Text(addNote).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func rowDetail(_ i: Costs.Item) -> String {
        let d = { (x: Date) in x.formatted(.dateTime.day().month(.abbreviated).year()) }
        if i.isFree { return "free" + (i.ends.map { " until \(d($0))" } ?? "") }
        let price = "\(i.amount.formatted()) \(i.currency) / \(i.yearly ? "year" : "month")"
        if let e = i.ends { return price + (i.ended ? " · ended \(d(e))" : " · ends \(d(e))") }
        return price
    }

    private func add() {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n.count <= 80 else { addNote = "Give it a name (up to 80 characters)."; return }
        let a = free ? 0 : Money.number(amount.trimmingCharacters(in: .whitespaces))
        guard let a, a >= 0, a < 1_000_000 else { addNote = "Type the amount you pay, like 20 or 19.99."; return }
        let c = currency.trimmingCharacters(in: .whitespaces).uppercased()
        guard free || (c.count == 3 && c.allSatisfy(\.isLetter)) else { addNote = "Currency is a 3-letter code, like USD or INR."; return }
        list.append(.init(name: n, amount: a, currency: free ? "USD" : c, yearly: yearly, free: free ? true : nil, ends: hasEnd ? ends : nil))
        name = ""; amount = ""; free = false; hasEnd = false; addNote = nil
    }

    // MARK: Anthropic

    private var anthropicSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Claude API (Anthropic)").font(.headline)
            Text("An Admin key (console.anthropic.com → Settings → Admin keys) lets Hmunmawi read what your Claude API keys spent. Read-only; kept in your Keychain. Your credits are under Usage.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                SecureField("sk-ant-admin…", text: $adminKey).input(.secret, $adminKey)
                Button("Save key") {
                    do { try KeychainSecretStore().setSecret(adminKey.trimmingCharacters(in: .whitespacesAndNewlines), plugin: "usage", name: "anthropic-admin")
                         adminKey = ""; keyNote = "Saved. It's read within 30 minutes." } catch { keyNote = "Couldn't save: \(error)" }
                }.disabled(!adminKey.hasPrefix("sk-ant-admin"))
                Button("Remove", role: .destructive) { confirmKeyRemove = true }
                    .confirmationDialog("Remove the Anthropic admin key?", isPresented: $confirmKeyRemove) {
                        Button("Remove key", role: .destructive) { KeychainSecretStore().deleteSecret(plugin: "usage", name: "anthropic-admin"); keyNote = "Removed." }
                        Button("Cancel", role: .cancel) {}
                    } message: { Text("API spend will no longer be read from Anthropic. You can paste the key again later.") }
            }
            if let keyNote { Text(keyNote).font(.caption).foregroundStyle(.secondary) }
            else if Credits.shared.hasAdminKey == true {
                Label(Credits.shared.paidRead.map { "Key saved · read \(Ago.text($0))" } ?? "Key saved · first read pending",
                      systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("I buy Anthropic API credits myself (card or auto-reload)", isOn: $paysForAPI)
            Text(paysForAPI ? "Claude API spend that no free credit covers counts as your cost, with a month-end range."
                 : "Off: the Claude API runs on free or promotional credits (for example your monthly Team credit), so it isn't counted as your cost. The card shows what's left instead.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Other AI accounts

    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Other AI accounts").font(.headline)
            Text("Read-only keys let Hmunmawi read what each account spent (OpenAI, xAI) or has left (OpenRouter, DeepSeek), once every 30 minutes at most. Keys stay in your Keychain. Google's Gemini API has no simple way to read this: add it under Tools and plans.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(SpendProvider.allCases.filter { accounts.connected.contains($0) }) { p in
                HStack {
                    Image(systemName: accounts.status(p)?.problem == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(accounts.status(p)?.problem == nil ? Brand.good : Brand.caution)
                    Text(p.name)
                    Spacer()
                    Toggle("Free credits only", isOn: Binding(get: { !accounts.paying(p) }, set: { accounts.setPaying(p, !$0) }))
                        .help("On: this account's spend isn't your money, so it isn't counted as a cost")
                    Button("Remove", role: .destructive) { accounts.disconnect(p) }.buttonStyle(.borderless)
                }
            }
            HStack(spacing: 8) {
                Picker("", selection: $provider) { ForEach(SpendProvider.allCases) { Text($0.name).tag($0) } }.labelsHidden().fixedSize()
                SecureField(provider.placeholder, text: $providerKey).input(.secret, $providerKey)
                if provider.needsTeamID { TextField("Team ID", text: $team).frame(width: 150).input(.identifier, $team) }
                Button(connecting ? "Checking…" : "Connect") {
                    connecting = true
                    Task {
                        accountNote = await accounts.connect(provider, key: providerKey, team: team)
                        accounts.setPaying(provider, !providerFree)
                        if accounts.connected.contains(provider) { providerKey = "" }
                        connecting = false
                    }
                }
                .buttonStyle(.pill).disabled(connecting || providerKey.isEmpty)
            }
            Text(provider.keyHint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("This account runs on free credits only", isOn: $providerFree).font(.callout)
            if let accountNote { Text(accountNote).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}
