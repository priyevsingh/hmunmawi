import Charts
import HmunmawiCore
import SwiftUI

/// Money, each number in one home: the scene headline holds what you've earned; this card shows where every
/// rupee customers paid went (you / Apple), the month bars hold Apple's monthly estimates, the side tile the
/// next payment.

/// Lifetime: one bar split into what you keep and Apple's share, with what customers paid in total.
struct LifetimeSplit: View {
    let lifetime: JSONValue
    @Environment(\.sceneActive) private var sceneActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var grow = 1.0

    var body: some View {
        let net = lifetime[path: "net"]?.number ?? 0, cut = lifetime[path: "apple_cut"]?.number ?? 0
        let gross = lifetime[path: "gross"]?.number ?? (net + cut)
        let share = gross > 0 ? net / gross : 0
        let inr: (Double) -> String = { Money.shared.format($0, from: "INR", decimals: 0) }
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                CardHeader(symbol: "chart.bar.xaxis", title: "Where every rupee went", tint: Brand.Category.money, caption: rangeText)
            }
            GeometryReader { g in
                HStack(spacing: 3) {
                    Capsule().fill(Brand.Category.money.gradient)
                        .frame(width: max(8, (g.size.width - 3) * share * grow))
                    Capsule().fill(Brand.secondaryText.opacity(0.28))
                }
            }
            .frame(height: 14)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("You keep \(Int((share * 100).rounded()))%").font(.title3.weight(.bold)).foregroundStyle(Brand.Category.money.gradient)
                    Text("after Apple's commission and taxes").font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 24)
                VStack(alignment: .center, spacing: 2) {
                    Text(inr(gross)).font(.title3.weight(.bold)).monospacedDigit()
                    Text("customers paid").font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 24)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(inr(cut)).font(.title3.weight(.bold)).monospacedDigit().foregroundStyle(.secondary)
                    Text("Apple's share · \(gross > 0 ? Int((cut / gross * 100).rounded()) : 0)%").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .contentCard(cornerRadius: 22)
        .onAppear { arrive() }
        .onChange(of: sceneActive) { _, on in if on { arrive() } }
    }

    private var rangeText: String {
        guard let r = lifetime[path: "range"]?.string else { return "" }
        let parts = r.components(separatedBy: " to ")
        func day(_ s: String) -> String {
            let iso = s.count == 7 ? s + "-01" : s
            guard let d = try? Date(iso + "T12:00:00Z", strategy: .iso8601) else { return s }
            return s.count == 7 ? d.formatted(.dateTime.month(.abbreviated).year()) : d.formatted(.dateTime.day().month(.abbreviated).year())
        }
        return parts.count == 2 ? "\(day(parts[0])) – \(day(parts[1]))" : r
    }

    private func arrive() {
        guard !reduceMotion else { grow = 1; return }
        grow = 0
        withAnimation(.spring(response: 0.9, dampingFraction: 0.85).delay(0.2)) { grow = 1 }
    }
}

/// Apple's monthly estimates as real bars (no smoothing), split by app; months Apple hasn't reported yet
/// are marked, never guessed. Hover a month for its numbers.
struct MonthBars: View {
    let model: AppModel
    @Environment(\.sceneActive) private var sceneActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var grow = 1.0
    @State private var selected: String?

    struct Month {
        let label: String; let short: String; let byApp: [(String, Double)]
        /// The month isn't over or Apple's monthly report isn't out: built from Apple's daily sales reports.
        var estimate = false
        var total: Double { byApp.map(\.1).reduce(0, +) }
    }

    /// "My App / other" (a feed's bucket for one app plus the rest) reads "My App & others".
    static func appName(_ key: String) -> String {
        guard key.lowercased().hasSuffix(" / other") else { return APPName.pretty(key) }
        return APPName.pretty(String(key.dropLast(" / other".count))) + " & others"
    }

    var body: some View {
        let reported = Self.months(model)
        let pendingLabels = Self.pending(model, after: reported.last?.label)
        // Past 12 bars the same month name comes round again, so each bar then carries its year ("Oct ’25").
        let withYear = reported.count + pendingLabels.count > 12
        let months = reported.map { Month(label: $0.label, short: Self.shortName($0.label, withYear: withYear), byApp: $0.byApp, estimate: $0.estimate) }
        let pending = pendingLabels.map { Self.shortName($0, withYear: withYear) }
        let apps = Self.apps(months)
        let usd: (Double) -> String = { Money.shared.format($0, from: "USD", decimals: 0) }
        let total = months.map(\.total).reduce(0, +)
        let pick = months.first { $0.short == selected }
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                CardHeader(symbol: "calendar", title: "Earned by month", tint: Brand.Category.money)
                Text(pick.map { "\($0.label) · \(usd($0.total))" } ?? "\(usd(total)) estimated, \(months.first?.short ?? "") – \(months.last?.short ?? "")")
                    .font(.callout.weight(.semibold)).monospacedDigit().foregroundStyle(Brand.Category.money)
                    .contentTransition(.numericText())
                    .animation(.smooth(duration: 0.2), value: selected)
            }
            Chart {
                ForEach(months, id: \.label) { m in
                    ForEach(m.byApp, id: \.0) { app, v in
                        BarMark(x: .value("Month", m.short), y: .value("Earned", v * grow), width: .ratio(0.55))
                            .foregroundStyle(by: .value("App", Self.appName(app)))
                            .cornerRadius(6)
                            .opacity((selected == nil || selected == m.short ? 1 : 0.4) * (m.estimate ? 0.55 : 1))
                    }
                }
                // The note once, over the first month Apple hasn't reported (one per month ran into the next one).
                ForEach(pending, id: \.self) { p in
                    BarMark(x: .value("Month", p), y: .value("Earned", 0), width: .ratio(0.55))
                        .annotation(position: .top, alignment: .leading) {
                            if p == pending.first {
                                Text("Apple hasn't reported\nthese months yet").font(.callout).multilineTextAlignment(.leading).foregroundStyle(.secondary)
                                    .fixedSize()
                            }
                        }
                }
            }
            .chartForegroundStyleScale(domain: apps.map(Self.appName),
                                       range: apps.indices.map { Brand.Category.money.opacity([1.0, 0.45, 0.25][min($0, 2)]) })
            .chartLegend(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine().foregroundStyle(Brand.secondaryText.opacity(0.15))
                    AxisValueLabel { if let d = v.as(Double.self) { Text(Money.shared.format(d, from: "USD", decimals: 0)).font(.callout) } }
                }
            }
            .chartXSelection(value: $selected)
            .frame(height: 210)
            // One pill per app: its share of these months. Hovering a month shows that month's split instead.
            HStack(spacing: 10) {
                ForEach(apps, id: \.self) { app in
                    let v = pick.map { m in m.byApp.first { $0.0 == app }?.1 ?? 0 } ?? months.compactMap { m in m.byApp.first { $0.0 == app }?.1 }.reduce(0, +)
                    let base = pick?.total ?? total
                    HStack(spacing: 8) {
                        AppIcon(app: app.lowercased().hasSuffix(" / other") ? APPName.pretty(String(app.dropLast(" / other".count))) : Self.appName(app), size: 22)
                        Text(Self.appName(app)).font(.callout.weight(.semibold))
                        Text(usd(v)).font(.callout.weight(.bold)).monospacedDigit().foregroundStyle(Brand.Category.money)
                        Text(base > 0 ? "\(Int((v / base * 100).rounded()))%" : "").font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Brand.Category.money.opacity(apps.first == app ? 0.14 : 0.07), in: Capsule())
                    .fixedSize()
                }
                Spacer(minLength: 0)
            }
            if let est = months.last(where: \.estimate) {
                Text("\(est.label) is an estimate from Apple's daily sales reports (lighter bar); Apple's monthly report replaces it when it comes out.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !pending.isEmpty {
                Text("Your lifetime total is higher than these bars because Apple hasn't reported \(pending.joined(separator: " and ")) yet.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(minWidth: 520, maxWidth: .infinity, alignment: .leading)
        .contentCard(cornerRadius: 22)
        .onAppear { arrive() }
        .onChange(of: sceneActive) { _, on in if on { arrive() } }
    }

    private func arrive() {
        guard !reduceMotion else { grow = 1; return }
        grow = 0
        withAnimation(.spring(response: 0.8, dampingFraction: 0.82).delay(0.25)) { grow = 1 }
    }

    /// The first day of a month label ("Oct 2026" or "October 2026").
    static func monthStart(_ label: String) -> Date? {
        monthParse.date(from: label) ?? monthParseLong.date(from: label)
    }

    private static let monthParseLong: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "MMMM yyyy"; return f
    }()

    private static let monthParse: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "MMM yyyy"; return f
    }()

    static func months(_ model: AppModel) -> [Month] {
        var list: [Month] = (model.snapshots("earnings.months").first?.payload[path: "months"]?.array ?? []).compactMap { m in
            guard let label = m[path: "label"]?.string else { return nil }
            var byApp: [(String, Double)] = []
            if case .object(let o)? = m[path: "by_app"] { byApp = o.compactMap { k, v in v.number.map { (k, $0) } }.sorted { $0.0 < $1.0 } }
            return Month(label: label, short: String(label.prefix(3)), byApp: byApp)
        }
        // After the last month a feed gave (or from the start when there's no feed): Apple's own monthly finance
        // reports, read by the App Store Connect connection, and for the month that isn't reported yet (usually the
        // current one), Apple's daily sales reports so far.
        let key = DateFormatter(); key.locale = Locale(identifier: "en_US_POSIX"); key.dateFormat = "yyyy-MM"
        var finance: [String: Double] = [:]          // "2026-10" -> US dollars, all apps
        for e in model.events where e.kind == "finance.month" {
            guard let m = e.payload[path: "month"]?.string, case .object(let totals)? = e.payload[path: "totals"] else { continue }
            let usd = totals.compactMap { code, v in v.number.flatMap { Money.shared.usd($0, from: code) } }.reduce(0, +)
            if usd > 0 { finance[m] = usd }
        }
        // "2026-11" -> app -> US dollars; apps that earned nothing that month are left out.
        // Names follow the earlier months: an app the feed grouped as "X / other" goes into that group.
        let known = Set(list.flatMap { $0.byApp.map(\.0) })
        let group = known.first { $0.lowercased().hasSuffix(" / other") }
        func name(_ app: String) -> String {
            if known.isEmpty || known.contains(app) { return app }
            return known.first { $0.lowercased() == app.lowercased() + " / other" } ?? group ?? app
        }
        var daily: [String: [String: Double]] = [:]
        for (m, apps) in model.dailyProceeds { for (a, v) in apps where v > 0.005 { daily[m, default: [:]][name(a), default: 0] += v } }
        let lastKey = list.last.flatMap { monthStart($0.label) }.map { key.string(from: $0) }
        let firstKey = lastKey ?? finance.keys.min() ?? daily.keys.min()
        guard let firstKey, var d = key.date(from: firstKey) else { return list }
        if lastKey != nil, let next = Calendar.current.date(byAdding: .month, value: 1, to: d) { d = next }
        let nowKey = key.string(from: .now)
        while key.string(from: d) <= nowKey, list.count < 36 {
            let k = key.string(from: d), label = monthParse.string(from: d)
            let split = daily[k] ?? [:], splitTotal = split.values.reduce(0, +)
            if let total = finance[k] {
                // Apple's report is the figure; the daily sales say how it splits between apps.
                let byApp = splitTotal > 0 ? split.map { ($0.key, total * $0.value / splitTotal) }.sorted { $0.0 < $1.0 } : [("All apps", total)]
                list.append(Month(label: label, short: String(label.prefix(3)), byApp: byApp))
            } else if splitTotal > 0 {
                list.append(Month(label: label, short: String(label.prefix(3)), byApp: split.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }, estimate: true))
            }
            guard let next = Calendar.current.date(byAdding: .month, value: 1, to: d) else { break }
            d = next
        }
        return list
    }

    /// "Oct 2026" → "Oct", or "Oct ’26" when bars span more than a year.
    static func shortName(_ label: String, withYear: Bool) -> String {
        guard withYear, let d = monthParse.date(from: label) else { return String(label.prefix(3)) }
        return d.formatted(.dateTime.month(.abbreviated)) + " ’" + String(label.suffix(2))
    }

    /// Apps ordered by what they earned, biggest first.
    static func apps(_ months: [Month]) -> [String] {
        var sums: [String: Double] = [:]
        for m in months { for (a, v) in m.byApp { sums[a, default: 0] += v } }
        return sums.sorted { $0.value > $1.value }.map(\.key)
    }

    /// Months after the last reported one, up to the end of the lifetime range (sales Apple hasn't reported).
    static func pending(_ model: AppModel, after last: String?) -> [String] {
        guard let last, var d = monthParse.date(from: last),
              let range = model.snapshots("money.lifetime_inr").first?.payload[path: "range"]?.string,
              let endText = range.components(separatedBy: " to ").last,
              let end = try? Date((endText.count == 7 ? endText + "-28" : String(endText.prefix(10))) + "T12:00:00Z", strategy: .iso8601)
        else { return [] }
        var out: [String] = []
        while let next = Calendar.current.date(byAdding: .month, value: 1, to: d), next <= end, out.count < 6 {
            out.append(monthParse.string(from: next))
            d = next
        }
        return out
    }
}

/// The next payment from Apple and the months around it, each with where it stands: paid (the amount your bank
/// received, from Settings → Money), due (Apple pays a month's sales within 45 days after it ends), or this month so far.
struct NextPayment: View {
    let model: AppModel

    struct Row { let label: String; let usd: Double; let state: String; let bankINR: Double?; let due: Date? }

    /// Apple's fiscal months are close to calendar months; payment comes within 45 days after a month ends.
    static func rows(_ model: AppModel, now: Date = .now) -> [Row] {
        let key = DateFormatter(); key.locale = Locale(identifier: "en_US_POSIX"); key.dateFormat = "yyyy-MM"
        let cal = Calendar.current
        return MonthBars.months(model).suffix(4).reversed().compactMap { m in
            guard let start = MonthBars.monthStart(m.label), let end = cal.date(byAdding: .month, value: 1, to: start) else { return nil }
            let paid = PayoutBook.shared.bank[key.string(from: start)]
            let due = cal.date(byAdding: .day, value: 45, to: end)
            let state = paid != nil ? "paid" : end > now ? "so far" : (due.map { $0 < now } ?? false) ? "should have arrived" : "due"
            return Row(label: m.label, usd: m.total, state: state, bankINR: paid, due: due)
        }
    }

    var body: some View {
        let rows = Self.rows(model)
        let next = rows.last { $0.state == "due" || $0.state == "should have arrived" }
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(symbol: "building.columns.fill", title: "Next payment", tint: Brand.Category.money)
            if let next, let due = next.due {
                Text("by " + due.formatted(.dateTime.day().month(.abbreviated)))
                    .font(.system(size: 30, weight: .bold)).foregroundStyle(Brand.Category.money.gradient)
                Text("For \(next.label) sales · about \(Money.shared.format(next.usd, from: "USD", decimals: 0))")
                    .font(.callout.weight(.medium))
                if next.state == "should have arrived" {
                    Label("Later than Apple's usual 45 days; check App Store Connect → Payments", systemImage: "clock.badge.exclamationmark.fill")
                        .font(.callout).foregroundStyle(Brand.caution).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Nothing waiting").font(.callout.weight(.medium))
            }
            if !rows.isEmpty {
                Divider().padding(.vertical, 4)
                ForEach(rows, id: \.label) { r in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(r.label) sales").font(.callout)
                            Text(r.state == "paid" ? "Paid to your bank" : r.state == "so far" ? "This month so far"
                                 : r.state == "due" ? "Due by \(r.due?.formatted(.dateTime.day().month(.abbreviated)) ?? "")" : "Overdue")
                                .font(.callout).foregroundStyle(r.state == "should have arrived" ? Brand.caution : Brand.secondaryText)
                        }
                        Spacer()
                        Text(r.bankINR.map { Money.text($0, "INR", decimals: 0) } ?? Money.shared.format(r.usd, from: "USD", decimals: 0))
                            .font(.callout.weight(.semibold)).monospacedDigit().foregroundStyle(Brand.Category.money)
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contentCard(cornerRadius: 22)
    }
}

/// Startup programs: credits approved and in review. Click for the full list as a zoom card (no new screen).
struct ProgramsCard: View {
    let model: AppModel
    @Environment(DetailPresenter.self) private var presenter: DetailPresenter?
    @State private var box = FrameBox()

    var body: some View {
        if let p = model.snapshots("growth.programs").first?.payload {
            KitCard {
                CardHeader(symbol: "gift.fill", title: "Startup programs", tint: Brand.Category.money, caption: "Click for every program")
                // Each program on its own, in its own terms: credits only work for their service, so one big total
                // (mostly one provider's) would read like money you have.
                let approved = (p[path: "items"]?.array ?? []).filter { $0[path: "status"]?.string == "approved" }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(approved.enumerated()), id: \.offset) { _, i in
                        HStack(alignment: .firstTextBaseline) {
                            Text(i[path: "name"]?.string ?? "Program").font(.body.weight(.medium))
                            Text(i[path: "value_label"]?.string ?? "").foregroundStyle(Brand.Category.money)
                            Spacer()
                            if let e = i[path: "expires"]?.string { Text("until \(e)").font(.callout).foregroundStyle(.secondary) }
                        }
                    }
                }
                HStack(alignment: .top, spacing: 40) {
                    KitFigure(value: Format.number(p[path: "approved"]), label: "programs approved", tint: Brand.Category.money)
                    KitFigure(value: Format.number(p[path: "in_review"]), label: "in review", tint: Brand.Category.money)
                    Spacer(minLength: 0)
                }
                if let next = p[path: "next"]?.array?.compactMap(\.string), !next.isEmpty {
                    Text("Next to apply: " + next.joined(separator: ", ")).font(.callout).foregroundStyle(.secondary)
                }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { box.rect = $0 }
            .onTapGesture { presenter?.show(view: AnyView(ProgramsDetail(payload: p)), from: box.rect, width: 640) }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Startup programs, click for every program")
            .accessibilityAddTraits(.isButton)
        }
    }
}
