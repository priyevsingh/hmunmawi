import HmunmawiCore
import SwiftUI

// The cinematic moments. Each plays once, when it happens (first open of the day, first visit to a scene,
// a real sale), using one-shot animations; nothing keeps running afterwards. Reduce Motion skips them.

/// First open of the day: the window starts dark, dawn rises over blue hills (Mizoram), the greeting fades up
/// word by word with the day's line, then the title lifts away and the camera settles on the dashboard.
struct OpeningTitle: View {
    let greeting: String
    let line: String
    let done: () -> Void
    @State private var phase = 0   // 0 dark · 1 dawn · 2 words · 3 leaving

    static let key = "HMOpeningDay"
    static var due: Bool {
        UserDefaults.standard.string(forKey: key) != Date.now.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
    }
    static func markShown() { UserDefaults.standard.set(Date.now.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day()), forKey: key) }

    var body: some View {
        let words = greeting.split(separator: " ").map(String.init)
        ZStack {
            Color.black
            Hills(depth: 0).opacity(phase >= 1 ? 1 : 0)
            VStack(spacing: 14) {
                HStack(spacing: 14) {
                    ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                        Text(w).font(.system(size: 76, weight: .bold)).foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.25), radius: 14, y: 4)
                            .opacity(phase >= 2 ? 1 : 0)
                            .offset(y: phase >= 2 ? 0 : 28)
                            .blur(radius: phase >= 2 ? 0 : 8)
                            .animation(.spring(response: 0.9, dampingFraction: 0.85).delay(Double(i) * 0.18), value: phase)
                    }
                }
                Text(line).font(.title2.weight(.medium)).foregroundStyle(.white.opacity(0.92))
                    .multilineTextAlignment(.center).frame(maxWidth: 760)
                    .opacity(phase >= 2 ? 1 : 0)
                    .animation(.easeOut(duration: 0.9).delay(0.5), value: phase)
            }
            .padding(40)
        }
        .ignoresSafeArea()
        .contentShape(.rect)
        .allowsHitTesting(phase != 3)
        .onTapGesture { finish() }
        .help("Click to skip")
        .task {
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation(.easeOut(duration: 1.4)) { phase = 1 }
            try? await Task.sleep(for: .milliseconds(500))
            phase = 2
            try? await Task.sleep(for: .milliseconds(2300))
            finish()
        }
    }

    private func finish() {
        guard phase != 3 else { return }
        OpeningTitle.markShown()
        phase = 3
        done()
    }
}

/// A real sale while the app is open: the app icon drops in at the centre with its flag, the amount counts
/// up inside a burst of light in the money colour, then everything flies up into the toolbar.
struct SaleMoment: View {
    let event: StoredEvent?
    @State private var shown: StoredEvent?
    @State private var step = 0  // 0 hidden · 1 in · 2 counted · 3 leaving
    @State private var playing: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { g in
            if let e = shown {
                let amount = Money.shared.amount(e)
                let text = amount.map { Money.shared.format($0, from: Money.shared.target, decimals: 0) } ?? ""
                let zero = text.replacingOccurrences(of: "[0-9]", with: "0", options: .regularExpression)
                ZStack {
                    Color.black.opacity(step == 1 || step == 2 ? 0.12 : 0).ignoresSafeArea()
                    ForEach(0..<2, id: \.self) { i in
                        Circle().stroke(Brand.Category.money.opacity(0.5), lineWidth: 3)
                            .frame(width: 160, height: 160)
                            .scaleEffect(step >= 2 ? 3.2 + Double(i) : 0.4)
                            .opacity(step >= 2 ? 0 : (step == 1 ? 0.9 : 0))
                            .animation(.easeOut(duration: 1.1).delay(Double(i) * 0.15), value: step)
                    }
                    VStack(spacing: 12) {
                        AppIcon(app: e.app, size: 96)
                            .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
                            .offset(y: step >= 1 ? 0 : -220)
                        HStack(spacing: 8) {
                            if let flag = TickerItems.flag(e) { Text(flag).font(.title) }
                            Text(e.kind == "revenue.renewal" ? "Renewal · \(e.app ?? "")" : "New sale · \(e.app ?? "")").font(Kit.outcome)
                        }
                        if !text.isEmpty {
                        Text(step >= 2 ? text : zero)
                            .font(.system(size: 56, weight: .bold)).monospacedDigit()
                            .foregroundStyle(Brand.Category.money.gradient)
                            .contentTransition(.numericText())
                        }
                    }
                    .padding(32)
                    .background(Color(nsColor: .windowBackgroundColor), in: .rect(cornerRadius: 28))
                    .shadow(color: .black.opacity(0.2), radius: 30, y: 12)
                    .opacity(step == 0 || step == 3 ? 0 : 1)
                    .scaleEffect(step == 3 ? 0.15 : 1)
                    .offset(y: step == 3 ? -g.size.height / 2 + 20 : 0)
                }
                .frame(width: g.size.width, height: g.size.height)
            }
        }
        .allowsHitTesting(false)
        .onChange(of: event?.id) { _, _ in
            guard !reduceMotion, let e = event, ["revenue.purchase", "revenue.renewal"].contains(e.kind) else { return }
            // Only a sale that just happened is an event; older ones arriving late from the feed stay quiet.
            guard Date.now.timeIntervalSince1970 * 1000 - Double(e.occurredAt) < 15 * 60 * 1000 else { return }
            play(e)
        }
    }

    private func play(_ e: StoredEvent) {
        // A second sale replaces the first one's moment instead of being hidden by its exit.
        playing?.cancel()
        shown = e
        step = 0
        playing = Task { @MainActor in
            withAnimation(.spring(response: 0.55, dampingFraction: 0.7)) { step = 1 }
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
            withAnimation(.smooth(duration: 0.9)) { step = 2 }
            try? await Task.sleep(for: .milliseconds(2000))
            if Task.isCancelled { return }
            withAnimation(.easeIn(duration: 0.55)) { step = 3 }
            try? await Task.sleep(for: .milliseconds(600))
            if Task.isCancelled { return }
            if shown?.id == e.id { shown = nil; step = 0 }
        }
    }
}

/// Small one-shot celebrations ("moments"): Apple's monthly report landing, a release approved, the first sale of the
/// day. Each plays once (remembered by key), slides in with a symbol that draws itself, gives a soft haptic, and
/// leaves after a few seconds. With Reduce Motion it simply appears and fades.
struct MomentBanner: View {
    let model: AppModel
    @State private var moment: (key: String, symbol: String, tint: Color, title: String, line: String)?
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            if let m = moment {
                HStack(spacing: 12) {
                    // The symbol draws itself in (SF Symbols' draw-on), then gives one bounce; Reduce Motion: it's just there.
                    ZStack {
                        if shown || reduceMotion {
                            Image(systemName: m.symbol).font(.title2).foregroundStyle(Kit.vibrant(m.tint))
                                .symbolEffect(.bounce, value: shown)
                                .transition(.symbolEffect(.drawOn))   // under Reduce Motion it's always shown, so this never plays
                        }
                    }
                    .frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.title).font(.headline)
                        Text(m.line).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button { withAnimation { moment = nil } } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
                .scaleEffect(shown || reduceMotion ? 1 : 0.94)
                .opacity(shown ? 1 : 0)
                .sensoryFeedback(.success, trigger: shown)
                .transition(.opacity)
            }
        }
        .task(id: model.events.count) { await check() }
    }

    private func check() async {
        // Moments are remembered for good, so sample data must never use one up.
        guard moment == nil, !model.isDemo else { return }
        let seen = Set(UserDefaults.standard.stringArray(forKey: "HMMomentsSeen") ?? [])
        var pick: (String, String, Color, String, String)?
        // Apple's finance report for a new month arrived.
        let months = await model.financeMonths()
        if let m = months.keys.sorted().last, !seen.contains("finance-\(m)") {
            let total = months[m]!.compactMap { Money.shared.convert($0.value, from: $0.key) }.reduce(0, +)
            pick = ("finance-\(m)", "banknote.fill", Brand.Category.money, Quips.pick(["Apple's report is in", "Payday paperwork landed"]),
                    "\(MoneyPlanCard.monthName(m)): \(Money.shared.format(total, from: Money.shared.target, decimals: 0)) on its way to you.")
        }
        // A release approved.
        for r in ComingSoon.releases(model) where pick == nil && r.status.hasPrefix("Approved") && !seen.contains("approved-\(r.app)-\(r.version ?? "")") {
            pick = ("approved-\(r.app)-\(r.version ?? "")", "checkmark.seal.fill", Brand.good, "\(r.app) \(r.version ?? "") approved!",
                    Quips.pick(["Apple said yes. Pop something fizzy.", "Approved. The review gods smiled."]))
        }
        // A sales milestone (counted since Hmunmawi started keeping score).
        if pick == nil, let n = await model.lifetimePurchases(),
           let mark = [10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10_000].last(where: { $0 <= n }), !seen.contains("sales-\(mark)") {
            pick = ("sales-\(mark)", "trophy.fill", Brand.Category.money, "Sale number \(mark.formatted())!",
                    Quips.pick(["Counted since Hmunmawi started keeping score. Treat yourself.",
                                "Somebody frame this one. Counted since Hmunmawi started watching."]))
        }
        // An all-clear day: every health check green and no worries on the board. Once a week at most.
        let week = Calendar.current.component(.weekOfYear, from: .now), year = Calendar.current.component(.yearForWeekOfYear, from: .now)
        let checks = model.healthChecks
        if pick == nil, Calendar.current.component(.hour, from: .now) >= 10, !checks.isEmpty, model.truth.dot == .good,
           checks.allSatisfy({ $0.level == .good }), !model.findings.contains(where: { $0.lane == .worry }),
           !seen.contains("allclear-\(year)-\(week)") {
            pick = ("allclear-\(year)-\(week)", "checkmark.circle.fill", Brand.good, Quips.pick(["All clear", "Nothing on fire"]),
                    Quips.pick(["Every check is green and nothing needs you. Go build something fun.",
                                "No crashes, no failed jobs, no worries. Rare air; enjoy it."]))
        }
        guard let p = pick, seen.count < 500 else { return }
        UserDefaults.standard.set(Array(seen) + [p.0], forKey: "HMMomentsSeen")
        moment = (p.0, p.1, p.2, p.3, p.4)
        withAnimation(reduceMotion ? .easeInOut(duration: 0.3) : .spring(response: 0.5, dampingFraction: 0.75)) { shown = true }
        try? await Task.sleep(for: .seconds(9))
        withAnimation(.easeOut(duration: 0.4)) { shown = false }
        try? await Task.sleep(for: .seconds(0.5))
        moment = nil
    }
}
