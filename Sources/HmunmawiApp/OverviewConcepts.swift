import Charts
import HmunmawiCore
import SwiftUI

/// Developer screen (never shown to users): three Overview concepts on real data, opened with
/// `open Hmunmawi.app --args -HMStyleBoard overview`. Used to pick a direction; kept for future design work.
struct OverviewConcepts: View {
    let model: AppModel

    var body: some View {
        let facts = OverviewFacts(model: model)
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                let only = UserDefaults.standard.string(forKey: "HMConcept")
                if only == nil || only == "A" { concept("A · Hero") { HeroSection(facts: facts) } }
                if only == nil || only == "B" { concept("B · Pulse grid") { PulseConcept(facts: facts) } }
                if only == nil || only == "C" { concept("C · Story") { StoryConcept(facts: facts) } }
            }
            .padding(28)
        }
        .task { await model.load() }
    }

    private func concept<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.weight(.bold))
            content()
        }
    }
}

/// The handful of numbers an Overview leads with, gathered once.
struct OverviewFacts {
    let subscribers: [(Date, Double)]
    let payments: [StoredEvent]
    let allPayments: [StoredEvent]
    let paymentsWeek: Int
    let users: [(Date, Double)]
    let crashFree: Double?
    let crashRates: [(String, Double)]
    let card: TodayCard?
    let attention: Int

    @MainActor
    init(model: AppModel) {
        let histories = model.snapshots("history.series")
        var totals: [Date: Double] = [:]
        for history in histories {
            for (date, value) in TrendChart.points(history.payload, "active") { totals[date, default: 0] += value }
        }
        subscribers = totals.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        let paymentKinds: Set<String> = ["revenue.purchase", "revenue.renewal"]
        let weekAgo = Millis(Date.now.timeIntervalSince1970 * 1000) - 7 * TodayBuilder.day
        let paid = model.events.filter { paymentKinds.contains($0.kind) }
        payments = Array(paid.prefix(6))
        allPayments = paid
        paymentsWeek = paid.filter { $0.occurredAt > weekAgo }.count
        users = model.events.filter { $0.kind == "analytics.daily_users" }
            .sorted { $0.occurredAt < $1.occurredAt }
            .compactMap { e in e.payload[path: "users"]?.number.map { (Date(timeIntervalSince1970: Double(e.occurredAt) / 1000), $0) } }
        // Some senders send 0.996, others 99.6: one scale before picking the lowest.
        let rates = model.snapshots("app.snapshot").compactMap { $0.payload[path: "crash_free"]?.number }.map { $0 <= 1 ? $0 * 100 : $0 }
        crashFree = rates.min()
        crashRates = model.snapshots("app.snapshot").compactMap { s in
            s.payload[path: "crash_free"]?.number.map { (s.app ?? "App", $0 <= 1 ? $0 * 100 : $0) }
        }
        card = model.card
        attention = model.snapshots("attention.items").reduce(0) { $0 + ($1.payload[path: "items"]?.array?.count ?? 0) }
    }
}

struct PaymentRow: View {
    let event: StoredEvent
    @Environment(AppModel.self) private var model: AppModel?

    @State private var open = false

    var body: some View {
        HStack(spacing: 10) {
            AppIcon(app: event.app, size: 32,
                    badge: event.kind == "revenue.renewal" ? "arrow.triangle.2.circlepath" : "bag.fill")
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(EventText.describe(event)).font(.callout.weight(.medium))
                    if let shares = TickerItems.familyShares(event, in: model?.events ?? []) {
                        Label("\(shares)", systemImage: "person.2.fill")
                            .font(.callout).foregroundStyle(.secondary)
                            .help("Shared with \(shares) family members, no extra charge")
                    }
                }
                Text([TickerItems.flag(event), Money.shared.purchaseLine(event)].compactMap { $0 }.joined(separator: " "))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Text(Ago.text(millis: event.occurredAt))
                .font(.callout).foregroundStyle(.secondary)
        }
        .contentShape(.rect)
        .onTapGesture { open = true }
        .popover(isPresented: $open, arrowEdge: .leading) { PurchaseDetail(event: event) }
        .help("Click for the purchase details")
    }
}

// MARK: A · Hero

struct HeroSection: View {
    let facts: OverviewFacts
    @Environment(AppModel.self) private var model: AppModel?

    var body: some View {
        VStack(spacing: 14) {
            // Apple Health "Highlights": four equal tiles, colour on the header and sparkline, numbers black.
            EqualRowsGrid(minWidth: 280) {
                KPITile(title: "Active subscribers", symbol: "person.2.fill", tint: Brand.Category.money,
                        value: (facts.subscribers.last.map { Int($0.1).formatted() } ?? "Not in yet"), points: facts.subscribers, change: true, detail: subscribersCard)
                KPITile(title: earnedTitle, symbol: "indianrupeesign", tint: Brand.Category.money,
                        value: earnedValue, points: earnings, detail: earnedCard)
                KPITile(title: "Crash-free", symbol: "checkmark.shield.fill", tint: Brand.Category.users,
                        value: facts.crashFree.map { String(format: "%.1f%%", $0) } ?? "", points: crashTrend, detail: crashCard)
                // The portal's first numbers: Money (14 days), lifetime, today live, next Apple payment.
                KPITile(title: "Proceeds, 14 days", symbol: "banknote.fill", tint: Brand.Category.money,
                        value: portal.flatMap { $0[path: "proceeds_usd"]?.number }.map { Money.shared.format($0, from: "USD") } ?? "",
                        note: portal?[path: "change_usd"]?.number.map { "\($0 >= 0 ? "+" : "−")\(Money.shared.format(abs($0), from: "USD", decimals: 0)) vs prior 14 days" },
                        points: [],
                        split: churnSplit, detail: proceedsCard)
                KPITile(title: earnedSoFarTitle, symbol: "building.columns.fill", tint: Brand.Category.money,
                        value: lifetime.flatMap { $0[path: "net"]?.number }.map { Money.shared.format($0, from: "INR", decimals: 0) } ?? "",
                        note: lifetime.flatMap { $0[path: "gross"]?.number }.map { "Your earnings · total \(Money.shared.format($0, from: "INR", decimals: 0))" },
                        points: [], split: lifetimeSplit, detail: lifetimeCard)
                KPITile(title: "Today, live", symbol: "bolt.fill", tint: Brand.good,
                        value: Money.shared.format(liveTotal(daysAgo: 0), from: Money.shared.target, decimals: 0),
                        note: "\(todayCount) payment\(todayCount == 1 ? "" : "s") · \(Money.shared.format(liveTotal(daysAgo: 1), from: Money.shared.target, decimals: 0)) yesterday",
                        points: dailyEarned, detail: todayCard)
                KPITile(title: "Next Apple payment", symbol: "calendar.badge.clock", tint: Brand.Category.money,
                        value: nextPaymentDate, note: nextPaymentNote, points: earnings, detail: paymentCard)
            }
        }
    }

    private var dayStart: Date { Calendar.current.startOfDay(for: .now) }

    // MARK: Detail cards

    private func m(_ v: Double?, _ code: String, _ d: Int? = 0) -> String? { v.map { Money.shared.format($0, from: code, decimals: d) } }

    private var subscribersCard: InfoModel {
        var c = InfoModel(icon: .symbol("person.2.fill"), tint: Brand.Category.money, title: "Active subscribers", subtitle: "All apps")
        let d = Direction(facts.subscribers.map(\.1))
        var facts1 = [c.fact("person.2", "Now", (facts.subscribers.last.map { Int($0.1).formatted() } ?? "Not in yet")),
                      c.fact("arrow.up.right", "Against the 7-day average", d.text)]
        for s in model?.snapshots("history.series") ?? [] {
            if let v = s.payload[path: "active"]?.array?.compactMap(\.number).last { facts1.append(c.fact("app", s.app ?? "", "\(Int(v))")) }
        }
        c.facts = facts1.compactMap { $0 }
        c.points = facts.subscribers
        c.source = "App Store Connect subscription reports, daily"
        return c
    }

    private var earnedCard: InfoModel {
        var c = InfoModel(icon: .symbol("indianrupeesign"), tint: Brand.Category.money, title: earnedTitle, subtitle: "Estimated proceeds")
        c.facts = [c.fact("banknote", "Amount", earnedValue), c.fact("sum", "Estimated so far, all months", Format.usd(money?[path: "total_usd_est"]))].compactMap { $0 }
        c.points = earnings
        c.source = "App Store Connect finance reports"
        return c
    }

    private var crashCard: InfoModel {
        var c = InfoModel(icon: .symbol("checkmark.shield.fill"), tint: Brand.Category.users, title: "Crash-free sessions", subtitle: "Lowest of your apps each day")
        c.facts = ([c.fact("checkmark.shield", "Overall", facts.crashFree.map { String(format: "%.2f%%", $0) })]
                   + facts.crashRates.map { c.fact("app", $0.0, String(format: "%.2f%%", $0.1)) }).compactMap { $0 }
        c.points = crashTrend
        c.source = "Sentry release health"
        return c
    }

    private var proceedsCard: InfoModel {
        var c = InfoModel(icon: .symbol("banknote.fill"), tint: Brand.Category.money, title: "Proceeds, last 14 days", subtitle: "What Apple estimates you keep")
        var f = [c.fact("banknote", "Proceeds", m(portal?[path: "proceeds_usd"]?.number, "USD", nil)),
                 c.fact("arrow.left.arrow.right", "Against the prior 14 days", portal?[path: "change_usd"]?.number.map { ($0 >= 0 ? "+" : "−") + (m(abs($0), "USD") ?? "") }),
                 c.fact("calendar", "Against last week", portal?[path: "week_delta_usd"]?.number.map { ($0 >= 0 ? "+" : "−") + (m(abs($0), "USD", nil) ?? "") }),
                 c.fact("arrow.triangle.2.circlepath", "Renewed", portal?[path: "renewals"]?.number.map { "\(Int(safe: $0))" }),
                 c.fact("xmark.circle", "Cancelled", portal?[path: "cancels"]?.number.map { "\(Int(safe: $0))" })]
        for s in portal?[path: "shares"]?.array ?? [] { f.append(c.fact("app", s[path: "name"]?.string ?? "", m(s[path: "usd"]?.number, "USD", nil))) }
        c.facts = f.compactMap { $0 }
        c.paragraphs = portal?[path: "meaning"]?.string.map { [$0] } ?? []
        c.source = "Your script feed, Money section"
        return c
    }

    private var lifetimeCard: InfoModel {
        var c = InfoModel(icon: .symbol("building.columns.fill"), tint: Brand.Category.money, title: earnedSoFarTitle,
                          subtitle: lifetime?[path: "range"]?.string)
        c.facts = [c.fact("person.crop.circle", "Your earnings", m(lifetime?[path: "net"]?.number, "INR")),
                   c.fact("storefront", "Apple's cut", m(lifetime?[path: "apple_cut"]?.number, "INR")),
                   c.fact("sum", "Total paid by customers", m(lifetime?[path: "gross"]?.number, "INR"))].compactMap { $0 }
        c.source = "App Store Connect sales reports, all time"
        return c
    }

    private var todayCard: InfoModel {
        var c = InfoModel(icon: .symbol("bolt.fill"), tint: Brand.good, title: "Today, live", subtitle: Date.now.dayText)
        let today = facts.allPayments.filter { Date(timeIntervalSince1970: Double($0.occurredAt) / 1000) >= dayStart }
        c.facts = ([c.fact("bolt", "Earned today", Money.shared.format(liveTotal(daysAgo: 0), from: Money.shared.target, decimals: 0)),
                    c.fact("calendar", "Yesterday", Money.shared.format(liveTotal(daysAgo: 1), from: Money.shared.target, decimals: 0))]
                   + today.map { e in c.fact("bag", [TickerItems.flag(e), e.app].compactMap { $0 }.joined(separator: " "), Money.shared.purchaseLine(e)) })
            .compactMap { $0 }
        c.points = dailyPayments
        c.source = "Live App Store purchase notifications"
        return c
    }

    private var paymentCard: InfoModel {
        var c = InfoModel(icon: .symbol("calendar.badge.clock"), tint: Brand.Category.money, title: "Next Apple payment")
        c.facts = [c.fact("calendar", "Expected", nextPaymentDate), c.fact("doc.text", "For sales in", money?[path: "next_payment_period"]?.string),
                   c.fact("hourglass", "Status", money?[path: "next_payment_status"]?.string?.replacingOccurrences(of: "_", with: " ").capitalized)].compactMap { $0 }
        c.source = "App Store Connect payments"
        return c
    }

    private var portal: JSONValue? { model?.snapshots("money.portal").first?.payload }
    private var lifetime: JSONValue? { model?.snapshots("money.lifetime_inr").first?.payload }

    private var churnSplit: [KPITile.Part] {
        guard let r = portal?[path: "renewals"]?.number, let c = portal?[path: "cancels"]?.number, r + c > 0 else { return [] }
        return [.init(label: "\(Int(r)) renewed", value: r, tint: Brand.good), .init(label: "\(Int(c)) cancelled", value: c, tint: Brand.bad)]
    }

    /// "Earned so far · since Jan 2026" from the lifetime block's own date.
    private var earnedSoFarTitle: String {
        guard let since = lifetime?[path: "since"]?.string, let d = try? Date(since + "-01T12:00:00Z", strategy: .iso8601) else { return "Earned so far" }
        return "Earned so far · since \(d.formatted(.dateTime.month(.abbreviated).year()))"
    }

    private var lifetimeSplit: [KPITile.Part] {
        guard let net = lifetime?[path: "net"]?.number, let cut = lifetime?[path: "apple_cut"]?.number else { return [] }
        return [.init(label: "You \(Money.shared.format(net, from: "INR", decimals: 0))", value: net, tint: Brand.Category.money),
                .init(label: "Apple's cut \(Money.shared.format(cut, from: "INR", decimals: 0))", value: cut, tint: Brand.secondaryText.opacity(0.6))]
    }

    /// Sales and renewals that arrived on a given day, in the chosen currency.
    private func liveTotal(daysAgo: Int) -> Double {
        guard let start = Calendar.current.date(byAdding: .day, value: -daysAgo, to: dayStart),
              let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return 0 }
        return facts.allPayments.filter {
            let d = Date(timeIntervalSince1970: Double($0.occurredAt) / 1000); return d >= start && d < end
        }.compactMap { Money.shared.amount($0) }.reduce(0, +)
    }

    private var nextPaymentDate: String {
        guard let s = money?[path: "next_payment_date"]?.string, let d = try? Date(s + "T12:00:00Z", strategy: .iso8601) else { return "" }
        return d.formatted(.dateTime.day().month(.abbreviated))
    }

    private var nextPaymentNote: String? {
        let period = money?[path: "next_payment_period"]?.string
        let status = money?[path: "next_payment_status"]?.string?.replacingOccurrences(of: "_", with: " ")
        return [period.map { "for \($0)" }, status].compactMap { $0 }.joined(separator: " · ")
    }

    private var todayCount: Int {
        facts.allPayments.filter { Date(timeIntervalSince1970: Double($0.occurredAt) / 1000) >= dayStart }.count
    }

    /// What live purchases brought in each of the last 7 days, in the chosen currency.
    private var dailyEarned: [(Date, Double)] {
        (0..<7).reversed().compactMap { back in
            guard let day = Calendar.current.date(byAdding: .day, value: -back, to: dayStart) else { return nil }
            return (day, liveTotal(daysAgo: back))
        }
    }

    /// Payments per day for the last 7 days.
    private var dailyPayments: [(Date, Double)] {
        (0..<7).reversed().compactMap { back in
            guard let day = Calendar.current.date(byAdding: .day, value: -back, to: dayStart),
                  let next = Calendar.current.date(byAdding: .day, value: 1, to: day) else { return nil }
            let n = facts.allPayments.filter {
                let d = Date(timeIntervalSince1970: Double($0.occurredAt) / 1000); return d >= day && d < next
            }.count
            return (day, Double(n))
        }
    }

    private var money: JSONValue? { model?.snapshots("money.summary").first?.payload }
    private var earnedTitle: String { "Earned, \(money?[path: "latest_month"]?.string ?? "this month")" }
    private var earnedValue: String { Format.usd(money?[path: "latest_month_usd"]) }

    private var earnings: [(Date, Double)] {
        let months = model?.snapshots("earnings.months").first?.payload[path: "months"]?.array ?? []
        // Each month carries its own label ("Aug 2026"); read the date from it.
        let parse = DateFormatter(); parse.locale = Locale(identifier: "en_US_POSIX"); parse.dateFormat = "MMM yyyy"
        return months.compactMap { m in
            guard let v = m[path: "usd"]?.number, let label = m[path: "label"]?.string,
                  let d = parse.date(from: String(label.prefix(8))) else { return nil }
            return (d, v)
        }
    }

    /// The lowest crash-free rate across apps for each of the last days.
    private var crashTrend: [(Date, Double)] {
        var byDay: [Date: Double] = [:]
        for e in model?.events ?? [] where e.kind == "crash.daily" {
            guard var r = e.payload[path: "crash_free_rate"]?.number else { continue }
            if r <= 1 { r *= 100 }
            let d = e.reportDay
            byDay[d] = min(byDay[d] ?? 100, r)
        }
        return byDay.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
}

/// One Health-style highlight: coloured header, black number, a change chip, and a small sparkline.
private struct KPITile: View {
    struct Part { let label: String; let value: Double; let tint: Color }

    let title: String
    let symbol: String
    let tint: Color
    let value: String
    var note: String?
    let points: [(Date, Double)]
    var change = false
    /// A split bar (e.g. you vs Apple, renewed vs cancelled) shown instead of a sparkline.
    var split: [Part] = []
    var detail: InfoModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(tint).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                CountUpText(text: value.isEmpty ? "No data yet" : value)
                    .font(.system(size: value.isEmpty ? 17 : 32, weight: .bold)).monospacedDigit()
                    // Fitness style: the number in its colour, with Apple's subtle top-to-bottom shine.
                    .foregroundStyle(value.isEmpty ? AnyShapeStyle(Brand.secondaryText) : AnyShapeStyle(Kit.vibrant(tint)))
                    .lineLimit(1).minimumScaleFactor(0.7)
                if change, points.count > 1 {
                    let d = Direction(points.map(\.1))
                    Label(d.text, systemImage: d.symbol).font(.callout.weight(.semibold)).foregroundStyle(d.color).fixedSize()
                }
            }
            if let note, !note.isEmpty {
                Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !split.isEmpty {
                let total = max(split.map(\.value).reduce(0, +), 1)
                GeometryReader { g in
                    HStack(spacing: 2) {
                        ForEach(split.indices, id: \.self) { i in
                            Capsule().fill(split[i].tint.gradient).frame(width: max(3, g.size.width * split[i].value / total - 2))
                                .shadow(color: split[i].tint.opacity(0.3), radius: 2)
                        }
                    }
                    .background(Capsule().fill(.quaternary))
                }
                .frame(height: 4)
                .modifier(DrawIn())
                HStack {
                    ForEach(split.indices, id: \.self) { i in
                        Text(split[i].label).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if i < split.count - 1 { Spacer(minLength: 4) }
                    }
                }
            } else if points.count > 1 {
                TrendChart(title: title, points: points, tint: tint, height: 36, showHeader: false)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentCard(cornerRadius: 20)
        .hoverLift()
        .clickForDetail(detail)
    }
}

// MARK: B · Pulse grid

private struct PulseConcept: View {
    let facts: OverviewFacts

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)], spacing: 16) {
            PulseTile(title: "Subscribers", symbol: "person.2.fill", value: facts.subscribers.last?.1, series: facts.subscribers)
            PaymentsTile(facts: facts)
            PulseTile(title: "Daily users", symbol: "figure.walk", value: facts.users.last?.1, series: facts.users)
            CrashTile(rates: facts.crashRates)
        }
    }
}

/// Big number, direction chip, and a chart that bleeds to the card's edges.
private struct PulseTile: View {
    let title: String
    let symbol: String
    let value: Double?
    let series: [(Date, Double)]

    var body: some View {
        let direction = Direction(series.map(\.1))
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: symbol).font(.headline).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(value.map { Int(safe: $0).formatted() } ?? "Not in yet")
                        .font(.system(size: 52, weight: .bold)).monospacedDigit()
                        .contentTransition(.numericText())
                    Label(direction.text, systemImage: direction.symbol)
                        .font(.callout.weight(.semibold)).foregroundStyle(direction.color)
                }
            }
            .padding([.horizontal, .top], 20)
            Spacer(minLength: 8)
            Chart(Array(series.enumerated()), id: \.offset) { index, point in
                AreaMark(x: .value("Day", point.0), y: .value(title, point.1))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [direction.color.opacity(0.28), direction.color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Day", point.0), y: .value(title, point.1))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color(nsColor: .labelColor).opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                if index == series.count - 1 {
                    PointMark(x: .value("Day", point.0), y: .value(title, point.1)).symbolSize(90).foregroundStyle(direction.color)
                }
            }
            .chartXAxis(.hidden).chartYAxis(.hidden)
            .chartYScale(domain: .automatic(includesZero: false))
            .chartPlotStyle { $0.padding(.trailing, 12) }
            .frame(height: 96)
        }
        .frame(maxWidth: .infinity, minHeight: 240, alignment: .topLeading)
        .contentCard(cornerRadius: 28)
    }
}

/// Payments per day for the last 7 days; today emphasised.
private struct PaymentsTile: View {
    let facts: OverviewFacts

    var body: some View {
        let calendar = Calendar.current
        let days = (0..<7).map { calendar.date(byAdding: .day, value: $0 - 6, to: calendar.startOfDay(for: .now))! }
        let counts = days.map { day in
            facts.allPayments.filter { calendar.isDate(Date(timeIntervalSince1970: Double($0.occurredAt) / 1000), inSameDayAs: day) }.count
        }
        let peak = max(counts.max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 6) {
            Label("Payments, 7 days", systemImage: "creditcard.fill").font(.headline).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(facts.paymentsWeek)").font(.system(size: 52, weight: .bold)).monospacedDigit()
                Text("\(counts.last ?? 0) today").font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(Array(counts.enumerated()), id: \.offset) { index, count in
                    VStack(spacing: 4) {
                        ZStack(alignment: .bottom) {
                            Capsule().fill(.quaternary.opacity(0.5))
                            Capsule().fill(index == 6 ? AnyShapeStyle(Brand.good.gradient) : AnyShapeStyle(Brand.data.opacity(0.7)))
                                .frame(height: count == 0 ? 6 : max(10, 70 * CGFloat(count) / CGFloat(peak)))
                        }
                        .frame(height: 70)
                        Text(days[index].formatted(.dateTime.weekday(.narrow))).font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 240, alignment: .topLeading)
        .contentCard(cornerRadius: 28)
    }
}

/// The lowest crash-free rate as a large ring, with each app's rate beside it.
private struct CrashTile: View {
    let rates: [(String, Double)]

    var body: some View {
        let worst = rates.map(\.1).min() ?? 100
        VStack(alignment: .leading, spacing: 12) {
            Label("Crash-free sessions", systemImage: "checkmark.shield.fill").font(.headline).foregroundStyle(.secondary)
            HStack(spacing: 20) {
                Gauge(value: worst, in: 0...100) { EmptyView() } currentValueLabel: {
                    Text(String(format: "%.1f%%", worst)).font(.system(.caption, weight: .bold))
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(Labels.health("crash_free", worst))
                .scaleEffect(1.6)
                .frame(width: 96, height: 96)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(rates, id: \.0) { app, rate in
                        HStack {
                            Circle().fill(Labels.health("crash_free", rate)).frame(width: 8, height: 8)
                            Text(app).font(.callout).fixedSize()
                            Spacer()
                            Text(String(format: "%.2f%%", rate)).font(.callout.weight(.semibold)).monospacedDigit().fixedSize()
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 240, alignment: .topLeading)
        .contentCard(cornerRadius: 28)
    }
}

// MARK: C · Story

private struct StoryConcept: View {
    let facts: OverviewFacts

    var body: some View {
        let d = Direction(facts.subscribers.map(\.1))
        let day = Date.now.formatted(.dateTime.weekday(.wide))
        VStack(alignment: .leading, spacing: 18) {
            Text("A \(facts.paymentsWeek >= StorySentence.busyWeek ? "busy" : "quiet") \(day). \(facts.payments.count) recent payments, \(facts.crashFree.map { $0 >= 99.5 ? "no crash worries" : "watch crashes" } ?? "no crash data"), subscribers \(d.text) vs their recent average.")
                .font(.system(size: 30, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(facts.payments.enumerated()), id: \.offset) { index, event in
                    HStack(alignment: .top, spacing: 14) {
                        VStack(spacing: 0) {
                            Circle().fill(Brand.good).frame(width: 10, height: 10)
                            if index < facts.payments.count - 1 {
                                Rectangle().fill(.quaternary).frame(width: 2).frame(maxHeight: .infinity)
                            }
                        }
                        .frame(width: 10)
                        PaymentRow(event: event).padding(.bottom, 14)
                    }
                }
            }
            .padding(22)
            .contentCard(cornerRadius: 28)
        }
    }
}

/// A whole number ("16", "3,031") counts up from zero when its scene arrives; other values simply rise in.
struct CountUpText: View {
    let text: String
    @Environment(\.sceneActive) private var sceneActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress = 1.0

    var body: some View {
        let digits = text.filter(\.isNumber)
        let isWhole = !digits.isEmpty && text.allSatisfy { $0.isNumber || $0 == "," }
        Group {
            if isWhole, let target = Double(digits) {
                Text("")
                    .modifier(CountUp(value: target * progress))
            } else {
                Text(text)
            }
        }
        .onChange(of: sceneActive) { _, on in
            guard on, !reduceMotion else { return }
            progress = 0
            withAnimation(.easeOut(duration: 1.0).delay(0.15)) { progress = 1 }
        }
    }
}

private struct CountUp: ViewModifier, Animatable {
    var value: Double
    nonisolated var animatableData: Double { get { value } set { value = newValue } }
    func body(content: Content) -> some View { Text(Int(value.rounded()).formatted()) }
}
