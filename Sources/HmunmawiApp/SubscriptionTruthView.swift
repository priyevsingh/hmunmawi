import HmunmawiCore
import SwiftUI

/// "Why people stop paying" on an app's page: free trials and how they ended, people turning renewal off, failed
/// payments and the ones Apple recovered, refunds, and below them renewal by plan. From Apple's Subscription Event
/// report; replaces the script feed's rough churn figures in the same place.
struct StopPayingSection: View {
    let truth: SubscriptionTruth

    var body: some View {
        let figures = figures
        if !figures.isEmpty || !truth.plans.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Divider()
                CardHeader(symbol: "person.2.slash.fill", title: "Why people stop paying", tint: Brand.Category.money,
                           caption: "Last \(truth.windowDays) days · Apple's subscription events")
                if let h = truth.headline { Text(h).font(Kit.outcome).fixedSize(horizontal: false, vertical: true) }
                if !figures.isEmpty {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 24, alignment: .topLeading), count: evenColumns(figures.count)),
                              alignment: .leading, spacing: 12) {
                        ForEach(figures, id: \.label) { KitFigure(value: $0.value, label: $0.label, tint: Brand.Category.money) }
                    }
                }
                if !truth.plans.isEmpty { RenewalByPlan(truth: truth) }
            }
        }
    }

    private struct Figure { let value: String; let label: String }

    private var figures: [Figure] {
        let t = truth
        let word = SubscriptionTruth.periodWord(t.mainPlan?.name)
        var out: [Figure] = []
        if t.trialsStarted > 0 {
            if t.trialsEnded > 0 {
                out.append(Figure(value: "\(min(t.trialsPaid, t.trialsEnded)) of \(t.trialsEnded)",
                                  label: "free trials that ended became paid" + (t.trialsCancelled > 0 ? " · \(t.trialsCancelled) cancelled during the trial" : "")
                                    + (t.trialsFailed > 0 ? " · \(t.trialsFailed) ended with a failed payment" : "")))
            } else {
                out.append(Figure(value: "\(t.trialsStarted)", label: "free trial\(t.trialsStarted == 1 ? "" : "s") started, none ended yet"))
            }
        }
        if t.starts > 0 || t.cancels > 0 {
            out.append(Figure(value: "\(t.cancels)", label: "turned renewal off" + (t.cancels > 0 ? " · \(t.cancelsFirst) in their first \(word)" : "")
                              + " · \(t.starts) started paying"))
        }
        if t.billingTrouble + t.billingLost + t.recovered > 0 {
            // A payment can fail before the window and be recovered inside it, so "recovered" may exceed "failed".
            out.append(Figure(value: "\(t.billingTrouble)", label: "payment\(t.billingTrouble == 1 ? "" : "s") failed · Apple recovered \(t.recovered)"
                              + (t.recovered > t.billingTrouble ? " (some had failed earlier)" : "") + ", \(t.billingLost) lost"
                              + (t.daysRecovered > 0 ? " · \(t.daysRecovered) paid days saved" : "")))
        } else if t.payments > 0 {
            out.append(Figure(value: "None", label: "failed payments"))
        }
        if let r = t.refundRate {
            out.append(Figure(value: r == 0 ? "None" : String(format: r < 0.1 ? "%.1f%%" : "%.0f%%", r * 100),
                              label: (r == 0 ? "refunded out of \(t.payments)" : "refunded · \(t.refunds) of \(t.payments)") + (t.payments == 1 ? " payment" : " payments")))
        }
        return out
    }
}

/// Of the people who started paying, how many were still paying 1, 3, 6 and 12 periods later, per plan.
struct RenewalByPlan: View {
    let truth: SubscriptionTruth
    /// A share of fewer people than this reads like a trend but isn't one ("100%" of 2), so it isn't shown as one.
    static let minCohort = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Still paying, by plan").font(.callout).foregroundStyle(.secondary)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 24, verticalSpacing: 10) {
                ForEach(truth.plans, id: \.name) { plan in
                    GridRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(plan.name.prefix(1).uppercased() + plan.name.dropFirst()).font(.body.weight(.semibold))
                            Text("\(plan.starts) started").font(.callout).foregroundStyle(.secondary)
                        }
                        if plan.points.isEmpty {
                            Text(waiting(plan)).font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .gridCellColumns(SubscriptionTruth.steps.count)
                        } else {
                            ForEach(SubscriptionTruth.steps, id: \.self) { k in
                                if let p = plan.points.first(where: { $0.after == k }), p.of >= Self.minCohort {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(Int((Double(p.kept) / Double(p.of) * 100).rounded()))%")
                                            .font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(Kit.vibrant(Brand.Category.money))
                                        Text("after \(k) \(SubscriptionTruth.periodWord(plan.name))\(k == 1 ? "" : "s") · \(p.kept) of \(p.of)")
                                            .font(.callout).foregroundStyle(.secondary).fixedSize()
                                    }
                                } else {
                                    let p = plan.points.first(where: { $0.after == k })
                                    Text("after \(k) \(SubscriptionTruth.periodWord(plan.name))\(k == 1 ? "" : "s"): " + (p.map { "too few yet (\($0.of) started early enough)" } ?? "needs more history"))
                                        .font(.callout).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func waiting(_ plan: SubscriptionTruth.Plan) -> String {
        let word = SubscriptionTruth.periodWord(plan.name)
        return "Too new to tell: a \(word) has to pass after people start before the first renewal shows (Apple's reports here go back to \(Self.nice(truth.historyFrom)))."
    }

    static func nice(_ day: String) -> String {
        guard let n = DayNumber.of(day) else { return day }
        let date = Date(timeIntervalSince1970: Double(n) * 86_400)
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let sameYear = utc.component(.year, from: date) == utc.component(.year, from: .now)
        return sameYear ? date.formatted(.dateTime.day().month(.abbreviated)) : date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}

extension AppModel {
    /// The script feed's "Renewals" section repeats what Apple's own subscription events show on the app's page, so it's
    /// left out for apps that have them (one place per piece of information).
    func replacedByApp(_ section: CustomSection) -> Bool {
        section.key == "retention" && subTruth[ComingSoon.shortName(section.app)] != nil
    }
}

// MARK: Release report card

/// When each of your apps' live versions went live, from Apple's public lookup (one request a day for all apps).
@MainActor @Observable
final class ReleaseDates {
    static let shared = ReleaseDates()
    struct Live: Codable, Equatable { let version: String; let day: String }
    private(set) var live: [String: Live] = [:]       // short app name -> live version
    private var lastRun: Date?
    private let key = "HMReleaseDates"

    init() {
        if let d = UserDefaults.standard.data(forKey: key), let saved = try? JSONDecoder().decode([String: Live].self, from: d) { live = saved }
    }

    /// Parses an ISO8601 timestamp (e.g. App Store Lookup's UTC `currentVersionReleaseDate`) into a local calendar `yyyy-MM-dd` day.
    static func dayString(fromISO raw: String, timeZone: TimeZone = .current) -> String? {
        let iso = ISO8601DateFormatter()
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = iso.date(from: raw) ?? isoFrac.date(from: raw) else {
            return raw.count >= 10 ? String(raw.prefix(10)) : nil
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day], from: date)
        guard let y = c.year, let m = c.month, let d = c.day else { return nil }
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    func refresh(_ model: AppModel) async {
        if let last = lastRun, Calendar.current.isDateInToday(last) { return }
        var ids: [String: String] = [:]          // App Store id -> short name
        for e in model.snapshots("icon.snapshot") {
            if let id = e.payload[path: "appID"]?.string, id.allSatisfy(\.isNumber), let app = e.app { ids[id] = ComingSoon.shortName(app) }
        }
        guard !ids.isEmpty, let url = URL(string: "https://itunes.apple.com/lookup?id=\(ids.keys.sorted().joined(separator: ","))") else { return }
        lastRun = .now
        guard let (data, resp) = try? await URLSession.shared.data(from: url), (resp as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { lastRun = nil; return }
        for r in (root["results"] as? [[String: Any]]) ?? [] {
            guard let id = (r["trackId"] as? Int).map(String.init), let name = ids[id],
                  let version = r["version"] as? String, let date = r["currentVersionReleaseDate"] as? String,
                  let day = Self.dayString(fromISO: date) else { continue }
            live[name] = Live(version: version, day: day)
        }
        if let d = try? JSONEncoder().encode(live) { UserDefaults.standard.set(d, forKey: key) }
    }
}

/// On an app's page under its header: 7 days after a version goes live, did it help or hurt? Shown for four
/// weeks after that; during the first week, one line says when the report comes.
struct ReleaseReportPart: View {
    let app: String
    let model: AppModel
    @State private var dates = ReleaseDates.shared
    @State private var report: ReleaseReport?

    var body: some View {
        let short = ComingSoon.shortName(app)
        // An invisible anchor: with nothing to show yet the view would be empty, and an empty view never starts its task.
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(width: 0, height: 0)
            if let live = dates.live[short], let day = DayNumber.of(live.day) {
                let today = DayNumber.of(millis: Int64(Date.now.timeIntervalSince1970 * 1000))
                if let report, today <= day + 35 {
                    VStack(alignment: .leading, spacing: 14) {
                        Divider()
                        CardHeader(symbol: "shippingbox.and.arrow.backward.fill", title: "How v\(live.version) did", tint: Brand.Category.users,
                                   caption: "7 days after going live on \(RenewalByPlan.nice(live.day)) against the 7 before")
                        verdict(report).font(Kit.outcome).fixedSize(horizontal: false, vertical: true)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 24, alignment: .topLeading), count: evenColumns(report.measures.count)),
                                  alignment: .leading, spacing: 12) {
                            ForEach(report.measures, id: \.name) { m in
                                KitFigure(value: "\(m.before) → \(m.after)", label: "\(m.name) · \(m.note)", tint: tint(m.call))
                            }
                        }
                    }
                } else if report == nil, today - day < 9 {
                    Label("v\(live.version) went live on \(RenewalByPlan.nice(live.day)). Its report card comes once Apple has 7 days of numbers, about \(RenewalByPlan.nice(DayNumber.day(day + 9))).",
                          systemImage: "shippingbox.and.arrow.backward")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task(id: "\(short)|\(dates.live[short]?.version ?? "")|\(model.windowLastID)") {
            await dates.refresh(model)
            await load(short)
        }
    }

    private func load(_ short: String) async {
        guard let live = dates.live[short], let day = DayNumber.of(live.day), let store = model.liveStore else { report = nil; return }
        let since = Int64(day - 9) * 86_400_000
        async let crash = store.events(kind: "crash.daily", since: since)
        async let daily = store.events(kind: "revenue.daily", since: since)
        async let subs = store.events(kind: "subscription.events", since: since)
        async let snaps = store.events(kind: "app.snapshot", since: since - 2 * 86_400_000)
        let d = AppModel.oneSourcePerDay((try? await daily) ?? []).filter { ComingSoon.shortName($0.app ?? "") == short }
        let newest = d.compactMap { $0.payload[path: "day"]?.string }.max()
        func mine(_ l: [StoredEvent]) -> [StoredEvent] { l.filter { ComingSoon.shortName($0.app ?? "") == short } }
        report = ReleaseReport.make(app: short, version: live.version, liveDay: live.day, newestDay: newest,
                                    crash: mine((try? await crash) ?? []), daily: d,
                                    subs: mine((try? await subs) ?? []), snapshots: mine((try? await snaps) ?? []))
    }

    private func verdict(_ r: ReleaseReport) -> some View {
        let better = r.measures.filter { $0.judged && $0.call == .better }.map { $0.name.lowercased() }
        return switch r.verdict {
        case .helped: Text("v\(r.version) helped: \(better.joined(separator: " and ")) went up").foregroundStyle(Brand.good)
        case .hurt(let what): Text("v\(r.version) hurt \(what.lowercased()); worth a look").foregroundStyle(Brand.bad)
        case .noChange: Text("No clear change from v\(r.version)")
        case .tooFew: Text("Too few people in 7 days to judge v\(r.version)").foregroundStyle(.secondary)
        }
    }

    private func tint(_ c: ReleaseReport.Call) -> Color {
        switch c { case .better: Brand.good; case .worse: Brand.bad; default: Brand.Category.users }
    }
}

// MARK: Download retention (App Store Connect's App Sessions report, from files already on this Mac)

/// Reads App Sessions report files that your own scripts already download from App Store Connect (no request to
/// Apple from here) and works out Day 1 / 7 / 28 retention per app. Scans again only when the newest file changes.
/// Off until you set the folder: `defaults write <app> HMRetentionFolder <path>` (layout below).
@MainActor @Observable
final class RetentionFiles {
    static let shared = RetentionFiles()
    var folder: String { UserDefaults.standard.string(forKey: "HMRetentionFolder") ?? "" }
    private(set) var byApp: [String: DownloadRetention] = [:]
    private var newest: Date?
    private var scanning = false

    func refresh() async {
        guard !scanning else { return }
        scanning = true; defer { scanning = false }
        let folder = self.folder, known = newest
        guard !folder.isEmpty else { return }
        let result = await Task.detached(priority: .utility) { () -> (Date, [String: DownloadRetention])? in
            // <folder>/<app>/analytics/ongoing/app-sessions-standard/daily/<date>/<segment>.csv.gz (weekly and monthly
            // files repeat the same days, so only daily ones are read).
            let fm = FileManager.default
            var files: [(URL, Date)] = []
            for app in (try? fm.contentsOfDirectory(atPath: folder)) ?? [] {
                let daily = URL(fileURLWithPath: folder).appending(path: "\(app)/analytics/ongoing/app-sessions-standard/daily")
                for day in (try? fm.contentsOfDirectory(atPath: daily.path)) ?? [] {
                    let dir = daily.appending(path: day)
                    for f in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasSuffix(".gz") || f.hasSuffix(".csv") || f.hasSuffix(".tsv") {
                        let url = dir.appending(path: f)
                        let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                        files.append((url, m))
                    }
                }
            }
            guard let latest = files.map(\.1).max(), latest != known else { return nil }
            var rows: [[String: String]] = []
            for (url, _) in files {
                guard let data = try? Data(contentsOf: url) else { continue }
                let raw = url.pathExtension == "gz" ? DownloadRetention.gunzip(data) : data
                if let raw { rows += DownloadRetention.parseTSV(String(decoding: raw, as: UTF8.self)) }
            }
            return (latest, DownloadRetention.make(rows) { String($0.split(separator: ":", maxSplits: 1).first ?? Substring($0)).trimmingCharacters(in: .whitespaces) })
        }.value
        if let (date, apps) = result { newest = date; byApp = apps }
    }
}

/// "Still opening the app": Day 1 / 7 / 28 from App Store Connect's sessions sample, on the app's page.
struct DownloadRetentionRow: View {
    let app: String
    @State private var files = RetentionFiles.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Color.clear.frame(width: 0, height: 0)   // keeps the view alive (and its task running) before data arrives
            if let r = files.byApp[ComingSoon.shortName(app)] {
                Divider()
                CardHeader(symbol: "arrow.uturn.backward.circle.fill", title: "Still opening \(ComingSoon.shortName(app))", tint: Brand.Category.users,
                           caption: "Downloads \(RenewalByPlan.nice(r.fromDay)) to \(RenewalByPlan.nice(r.toDay)) · App Store Connect")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 24, alignment: .topLeading), count: evenColumns(r.points.count)),
                          alignment: .leading, spacing: 12) {
                    ForEach(r.points, id: \.day) { p in
                        KitFigure(value: "\(Int((p.share * 100).rounded()))%",
                                  label: "came back on day \(p.day) · \(p.kept) of \(p.of)", tint: Brand.Category.users)
                    }
                }
                Text("From the people who share analytics with developers (Apple's own sample), counted per device.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await files.refresh() }
    }
}
