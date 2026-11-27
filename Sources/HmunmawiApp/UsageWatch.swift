import Foundation
import HmunmawiCore
import SwiftUI

/// AI & subscriptions usage: how much of each plan's limit is used and when it resets, from a chain of sources
/// tried in order (first one that works wins, and the screen says which):
///   1. official API (when a key is set; joins next)
///   2. a usage file a bot writes (~/Library/Application Support/Hmunmawi/usage/*.json, format in docs/AI-AND-COSTS.md)
///   3. other apps' own local files (Grok Bot's weekly-usage cache, when Grok Bot is on this Mac) and per-account
///      Claude usage files a tool of yours writes (folder in HMClaudeUsageFolder, off until set): unofficial, so a
///      change in those files shows as "couldn't read", never as a wrong number
///   4. typed by you (plan, price, renewal) via Costs
/// Read-only; nothing is sent anywhere.
@MainActor @Observable
final class UsageWatch {
    static let shared = UsageWatch()

    struct Reading: Identifiable, Hashable {
        let service: String
        let detail: String?        // plan or account
        let usedPercent: Double?
        let resets: Date?
        let source: String         // "Grok Bot's file", "your usage files", "your bot", "Hmunmawi"
        let read: Date?
        let problem: String?
        var id: String { service + (detail ?? "") }
    }

    private(set) var readings: [Reading] = []
    private(set) var lastRefresh: Date?
    private(set) var refreshing = false
    nonisolated static let botFolder = URL.hmSupport.appending(path: "usage")
    static let offKey = "HMUsageSourcesOff"      // sources you switched off, e.g. ["grok.local"]

    var off: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.offKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.offKey) }
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false; lastRefresh = .now }
        let off = self.off
        let isGrok = BotName.current.localizedCaseInsensitiveContains("grok")
        var out = await Task.detached(priority: .utility) { () -> [Reading] in
            var r: [Reading] = []
            if !off.contains("bot.files") { r += Self.botFiles() }
            // Grok Bot's own cache is read only when your bot is Grok Bot (Settings names it), never just because it's installed.
            if !off.contains("grok.local"), isGrok, !r.contains(where: { $0.service == "Grok Bot" }) { r += Self.grokLocal() }
            if !off.contains("claude.local"), !r.contains(where: { $0.service == "Claude" }) { r += Self.claudeLocal() }
            return r
        }.value
        // 1. Official API: Anthropic's cost report (admin key in the Keychain), this month's spend.
        // Taken from Credits' reading (one cost-report read every 30 minutes serves the whole app): a request of
        // its own every 5 minutes used up the organisation's admin rate limit, shared with other tools.
        if !off.contains("anthropic.api"), Credits.shared.hasAdminKey == true {
            await Credits.shared.refreshLive()
            let c = Credits.shared
            var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
            let resets = utc.dateInterval(of: .month, for: .now)?.end
            if let b = c.monthBreakdown {
                out.insert(Reading(service: "Claude API", detail: String(format: "$%.2f spent this month", b.total), usedPercent: nil,
                                   resets: resets, source: "Anthropic API", read: c.paidRead, problem: nil), at: 0)
            } else {
                out.insert(Reading(service: "Claude API", detail: "this month", usedPercent: nil, resets: nil, source: "Anthropic API", read: nil,
                                   problem: "Not read yet: Anthropic is busy (too many requests); trying again within 30 minutes."), at: 0)
            }
        }
        let ai = AISettings.shared
        if ai.hasKey {
            out.append(Reading(service: "Hmunmawi's AI", detail: ai.provider.name,
                               usedPercent: ai.monthlyBudget > 0 ? min(100, ai.usdThisMonth / ai.monthlyBudget * 100) : nil,
                               resets: Calendar.current.dateInterval(of: .month, for: .now)?.end, source: "Hmunmawi", read: .now, problem: nil))
        }
        // Request limits any service reports in its answers (App Store Connect, X, ...): see QuotaLedger.
        for q in QuotaLedger.shared.readings() {
            out.append(Reading(service: q.service, detail: q.detail(), usedPercent: q.usedPercent, resets: q.resetsAt,
                               source: "its response headers", read: q.seen, problem: q.trouble()))
        }
        readings = out
    }

    /// Events for rules: one per service with % used ("usage.status"), at most one per 6-hour block (a rule's own
    /// cooldown decides how often it alerts).
    func statusEvents() -> [Event] {
        // Local date with the local 6-hour block (a UTC date gave two blocks one key around midnight).
        let hour = Date.now.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day()) + "-\(Calendar.current.component(.hour, from: .now) / 6)"
        return readings.compactMap { r in
            guard let p = r.usedPercent, !(r.resets.map { $0 < .now } ?? false) else { return nil }
            return Event(source: "hmunmawi", kind: "usage.status", app: nil,
                         payload: .object(["service": .string(r.service + (r.detail.map { " · \($0)" } ?? "")), "used_percent": .number(p.rounded())]),
                         occurredAt: Millis(Date.now.timeIntervalSince1970 * 1000), dedupeKey: "usage-\(r.id)-\(hour)")
        }
    }

    /// Bot-written files: {"services":[{"name","plan","used_percent","resets","updated"}]}.
    nonisolated static func botFiles() -> [Reading] {
        let files = (try? FileManager.default.contentsOfDirectory(at: botFolder, includingPropertiesForKeys: nil)) ?? []
        var out: [Reading] = []
        for f in files where f.pathExtension == "json" {
            guard let d = try? Data(contentsOf: f), d.count < 256_000,
                  let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let list = root["services"] as? [[String: Any]] else {
                out.append(Reading(service: f.deletingPathExtension().lastPathComponent, detail: nil, usedPercent: nil, resets: nil,
                                   source: "your bot", read: nil, problem: "File isn't in the usage format (see AGENTS.md)"))
                continue
            }
            for s in list.prefix(50) {
                guard let name = (s["name"] as? String).map({ String($0.prefix(60)) }) else { continue }
                out.append(Reading(service: name, detail: (s["plan"] as? String).map { String($0.prefix(60)) },
                                   usedPercent: (s["used_percent"] as? Double).map { min(max($0, 0), 100) },
                                   resets: (s["resets"] as? String).flatMap { try? Date($0, strategy: .iso8601) },
                                   source: "your bot", read: (s["updated"] as? String).flatMap { try? Date($0, strategy: .iso8601) }, problem: nil))
            }
        }
        return out
    }

    /// Grok Bot keeps its last usage reading in a cache file whose name is the base32 of "...weekly-usage.cache".
    nonisolated static func grokLocal() -> [Reading] {
        let dir = URL.applicationSupportDirectory.appending(path: "Grok Bot/sand-client-persistence")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        for f in files where f.hasSuffix(".blob") {
            guard let name = base32(String(f.dropLast(5))), name.hasSuffix("weekly-usage.cache") else { continue }
            guard let d = try? Data(contentsOf: dir.appending(path: f)),
                  let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let reading = (root["value"] as? [String: Any])?["reading"] as? [String: Any],
                  let usage = reading["usage"] as? [String: Any], let used = usage["percentUsed"] as? Double else {
                return [Reading(service: "Grok Bot", detail: nil, usedPercent: nil, resets: nil, source: "Grok Bot's file", read: nil,
                                problem: "Couldn't read Grok Bot's usage file; it may have changed format")]
            }
            return [Reading(service: "Grok Bot", detail: usage["unifiedPlanName"] as? String, usedPercent: used,
                            resets: (usage["nextResetMs"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) },
                            source: "Grok Bot's file", read: (reading["readAtMs"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }, problem: nil)]
        }
        return []
    }

    /// Claude usage per account from files a tool of yours writes: <folder>/<account>.json with "used" (percent),
    /// "resets_at" and "updated" (Unix seconds). The folder is HMClaudeUsageFolder; nothing is read until it's set.
    nonisolated static func claudeLocal() -> [Reading] {
        let folder = UserDefaults.standard.string(forKey: "HMClaudeUsageFolder") ?? ""
        guard !folder.isEmpty else { return [] }
        let dir = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { f in
            guard let d = try? Data(contentsOf: f), let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                return Reading(service: "Claude", detail: f.deletingPathExtension().lastPathComponent, usedPercent: nil, resets: nil,
                               source: "your usage files", read: nil, problem: "Couldn't read this account's usage file")
            }
            return Reading(service: "Claude", detail: f.deletingPathExtension().lastPathComponent.capitalized,
                           usedPercent: (root["used"] as? Double) ?? (root["used"] as? Int).map(Double.init),
                           resets: (root["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) },
                           source: "your usage files", read: (root["updated"] as? Double).map { Date(timeIntervalSince1970: $0) }, problem: nil)
        }
    }

    nonisolated static func base32(_ s: String) -> String? {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        var bits = 0, value = 0
        var bytes: [UInt8] = []
        for c in s.lowercased() {
            guard let i = alphabet.firstIndex(of: c) else { return nil }
            value = (value << 5) | i; bits += 5
            if bits >= 8 { bits -= 8; bytes.append(UInt8((value >> bits) & 0xFF)) }
        }
        return String(bytes: bytes, encoding: .utf8)
    }
}

struct UsageCard: View {
    @State private var watch = UsageWatch.shared

    var body: some View {
        VStack(spacing: 12) {
            content
            // Only where an AI pause policy is used (Your extras or an owner Mac, or once a pause file exists).
            if Extras.current.aiPauseCard.on || FileManager.default.fileExists(atPath: AIPolicyPaths.policyFile.path) {
                AIPolicyPauseCard()
            }
        }.frame(maxWidth: .infinity)
            .task {
                // Fresh on open, then every 5 minutes while the page is open (each source keeps its own clock too).
                while !Task.isCancelled {
                    await watch.refresh()
                    await Credits.shared.refreshLive()
                    await AIAccounts.shared.refreshAll()
                    try? await Task.sleep(for: .seconds(300))
                }
            }
    }

    @ViewBuilder private var content: some View {
        if !watch.readings.isEmpty {
            KitCard {
                // Credits count too: a hot active/monthly credit counts, while spent one-off grants don't stay red forever.
                let hot = watch.readings.filter { ($0.usedPercent ?? 0) >= 80 }.map(\.id)
                    + Credits.shared.current.filter { c in
                        let left = max(0, c.amountUSD - Credits.shared.used(c))
                        return Credits.shared.percent(c) >= 80 && !Credits.isExhaustedGrant(c, left: left)
                    }.map(\.id)
                HStack(spacing: 8) {
                    CardHeader(symbol: "gauge.with.dots.needle.67percent", title: "AI & subscriptions", tint: Brand.Category.users,
                               caption: (hot.isEmpty ? Quips.pick(["Plenty of fuel in every tank.", "All meters chilling below 80%."])
                                   : "\(hot.count) running hot") + (watch.lastRefresh.map { " · checked \(Ago.text($0))" } ?? ""))
                    Button { Task { await watch.refresh() } } label: {
                        Image(systemName: "arrow.clockwise").symbolEffect(.rotate, isActive: watch.refreshing)
                    }
                    .buttonStyle(.borderless).help("Check usage now").disabled(watch.refreshing)
                }
                CreditRows()
                // A reading whose reset passed over 36 hours ago with nothing new is a plan that has ended or a
                // source that stopped: fold it into one quiet line instead of a stale row.
                let gone = watch.readings.filter { ($0.resets ?? .distantFuture) < .now.addingTimeInterval(-36 * 3600) }
                ForEach(watch.readings.filter { r in !gone.contains { $0.id == r.id } }) { r in
                    HStack(spacing: 12) {
                        ServiceIcon(service: r.service)
                        VStack(alignment: .leading, spacing: 2) {
                            Text([r.service, r.detail].compactMap { $0 }.joined(separator: " · "))
                            Text(r.problem ?? ((r.resets.map { $0 < .now } ?? false)
                                ? "Old reading: it was due to reset \(Ago.text(r.resets!)); waiting for a fresh one from \(r.source)"
                                : [r.resets.map { "resets \(Ago.text($0))" },
                                                "from \(r.source)" + (r.read.map { ", \(Ago.text($0))" } ?? "")]
                                               .compactMap { $0 }.joined(separator: " · ")))
                                .font(.caption).foregroundStyle(r.problem == nil && !(r.resets.map { $0 < .now } ?? false) ? Color.secondary : Brand.caution).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if let p = r.usedPercent, !(r.resets.map { $0 < .now } ?? false) {
                            let tint = MeterTint.of(p)
                            ProgressView(value: p, total: 100).tint(tint).frame(width: 140)
                            Text("\(Int(p.rounded()))%").font(.callout.bold().monospacedDigit()).liveNumber(Int(p.rounded())).foregroundStyle(Kit.vibrant(tint)).frame(width: 46, alignment: .trailing)
                        }
                    }
                }
                if !gone.isEmpty {
                    Text("Gone quiet: " + gone.map { [$0.service, $0.detail].compactMap { $0 }.joined(separator: " · ") }.joined(separator: ", ")
                         + ". No fresh reading since its reset; plan ended? It pops back the moment a new one arrives.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// The service's own icon, loaded from its official site (like a browser tab), cached by the system; a neutral
/// symbol when there's no match or no network. Nothing is bundled.
struct ServiceIcon: View {
    let service: String
    static let sources: [(String, String)] = [
        ("Claude", "https://claude.ai/apple-touch-icon.png"), ("Hmunmawi's AI", "https://claude.ai/apple-touch-icon.png"),
        ("Grok", "https://grok.com/images/apple-touch-icon.png"), ("X", "https://x.com/favicon.ico"),
        ("Cursor", "https://cursor.com/apple-touch-icon.png"), ("OpenAI", "https://openai.com/apple-icon.png"),
    ]
    var body: some View {
        let url = Self.sources.first { service.hasPrefix($0.0) }.flatMap { URL(string: $0.1) }
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().interpolation(.high) }
                    else { IconBadge(symbol: "creditcard.fill", tint: Brand.Category.users, size: 28) }
                }
            } else {
                IconBadge(symbol: "creditcard.fill", tint: Brand.Category.users, size: 28)
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5))
    }
}

/// API credits (grants and recurring monthly credits). Anthropic has no API for credit balances, so each credit is
/// typed once (amount, when it started, when the next one comes); what's been used is read live from Anthropic's
/// cost report since the credit started when an admin key is set, else what you typed.
@MainActor @Observable
final class Credits {
    static let shared = Credits()
    struct Credit: Codable, Identifiable, Hashable {
        var id = UUID().uuidString
        var name: String
        var amountUSD: Double
        var start: Date
        var end: Date?              // when this credit stops (e.g. the monthly window ends)
        var monthly: Bool           // renews each month on the end date
        var spentUSD: Double?       // typed fallback
        /// Which workspaces' spend uses this credit: only these names, or everything except these (nil = all).
        var workspaces: [String]? = nil
        var excludeWorkspaces: [String]? = nil
        /// When the next credit of a monthly one actually arrives, if that's before this one ends (Anthropic's Team
        /// credit overlaps by a couple of days). Ignored once it has passed.
        var next: Date? = nil
        /// What this credit is shared between (your own split, e.g. a research job and this app), shown on the Usage card.
        var allocations: [Allocation]? = nil
    }
    struct Allocation: Codable, Hashable {
        var name: String
        var capUSD: Double
        /// "app" = this app's own AI spend is measured here; anything else shares what's left of the credit.
        var source: String? = nil
        var note: String? = nil
    }
    private let url = URL.hmSupport.appending(path: "credits.json")
    private(set) var items: [Credit] = []
    private(set) var live: [String: Double] = [:]   // id -> spent from Anthropic since start
    init() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: url), let i = try? dec.decode([Credit].self, from: d) { items = i }
        // The last good reading, so a restart or a refused read (Anthropic answers "too many requests" when the
        // admin key is read often) shows the real figure instead of none. Only this calendar month's (UTC).
        // Read once at launch (the Keychain isn't touched while drawing); refreshLive keeps it current.
        hasAdminKey = ((try? KeychainSecretStore().secret(plugin: "usage", name: "anthropic-admin")) ?? nil).map { !$0.isEmpty } ?? false
        if let d = try? Data(contentsOf: lastURL), let r = try? dec.decode(LastRead.self, from: d), r.month == Self.monthKey(.now) {
            monthBreakdown = r.spend; live = r.live; paidRead = r.at
        }
    }

    private struct LastRead: Codable { var month: String; var at: Date; var spend: MonthSpend; var live: [String: Double] }
    private let lastURL = URL.hmSupport.appending(path: "credits-last-read.json")
    nonisolated static func monthKey(_ d: Date) -> String {
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let c = utc.dateComponents([.year, .month], from: d); return String(format: "%04d-%02d", c.year!, c.month!)
    }
    private func saveLastRead() {
        guard let spend = monthBreakdown, let at = paidRead else { return }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? enc.encode(LastRead(month: Self.monthKey(at), at: at, spend: spend, live: live)).write(to: lastURL, options: .atomic)
    }
    func save(_ list: [Credit]) {
        items = list
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? enc.encode(list).write(to: url, options: .atomic)
    }

    /// A one-off non-monthly credit grant that has been completely spent is retired rather than permanently "running hot".
    static func isExhaustedGrant(_ c: Credit, left: Double) -> Bool {
        !c.monthly && left <= 0.005
    }

    /// A monthly credit whose period ended counts as the next period's credit (Anthropic renews it), so an old
    /// period never covers this month and this month's renewal isn't missing.
    static func current(_ c: Credit, now: Date = .now) -> Credit {
        let p = CreditMath.currentPeriod(start: c.start, end: c.end, monthly: c.monthly, now: now)
        guard p.rolled else { return c }
        var r = c; r.start = p.start; r.end = p.end; r.spentUSD = nil; r.next = nil   // the typed figure and arrival date were the old period's
        return r
    }
    /// "next $40 arrives 11 Nov · this one expires 13 Nov" (or "next $40 expected ≈ 13 Nov" when no arrival date is known).
    static func nextLine(_ c: Credit, now: Date = .now) -> String? {
        let day = { (d: Date) in d.formatted(.dateTime.day().month(.abbreviated)) }
        if let n = c.next, n > now {
            return "next $\(Int(c.amountUSD)) arrives \(day(n))" + (c.end.map { " · this one expires \(day($0))" } ?? "")
        }
        return c.end.map { "next $\(Int(c.amountUSD)) expected ≈ \(day($0))" }
    }
    /// The credits as they stand today (monthly ones in their current period).
    var current: [Credit] { items.map { Self.current($0) } }

    private var refreshingLive = false
    private var lastAttempt: Date?
    /// Whether an Anthropic admin key is saved (nil until the first read tries). With a key but no reading yet,
    /// costs and profit wait instead of showing a figure without the Claude API in it.
    private(set) var hasAdminKey: Bool?
    var spendPending: Bool { hasAdminKey == true && monthBreakdown == nil }
    /// Spend since each credit started, from Anthropic's cost report (whole UTC days). Called by the app every
    /// 30 minutes (and when the Costs card opens), once at a time.
    func refreshLive() async {
        guard !refreshingLive else { return }
        // The cost report changes once a day (whole UTC days): reading it more than every 30 minutes only uses up
        // the admin key's rate limit, which other tools on the same key share.
        if let last = lastAttempt, Date.now.timeIntervalSince(last) < 1800 { return }
        refreshingLive = true; defer { refreshingLive = false }
        lastAttempt = .now
        guard let key = (try? KeychainSecretStore().secret(plugin: "usage", name: "anthropic-admin")) ?? nil, !key.isEmpty else { hasAdminKey = false; return }
        hasAdminKey = true
        let list = current
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let monthStart = utc.dateInterval(of: .month, for: .now)!.start
        let today = utc.startOfDay(for: .now)
        let paceStart = utc.date(byAdding: .day, value: -Self.paceDays, to: today)!
        // ONE read covers everything: each credit's spend, this month and the 28-day pace (Anthropic allows the
        // organisation about 90 admin requests an hour, shared with every other tool using an admin key).
        let from = ([monthStart, paceStart] + list.map(\.start)).min()!
        guard let rows = await Self.spentRows(key: key, from: from, to: .now) else { return }
        for c in list { live[c.id] = rows.filter { Self.window(c).covers($0) }.map(\.usd).reduce(0, +) }
        // This month's spend per day and workspace, for "Costs a month": only what no credit paid counts as a cost.
        do {
            let month = rows.filter { $0.day >= monthStart }
            let pace = rows.filter { $0.day >= paceStart }
            let windows = list.map(Self.window)
            let before = zip(list, windows).map { c, w in max(0, used(c) - month.filter(w.covers).map(\.usd).reduce(0, +)) }
            let b = CreditMath.breakdown(month: month, credits: windows, usedBefore: before)
            // Projected to the month's end: whole UTC days counted so far (today's spend appears tomorrow), and each
            // monthly credit's next period, which starts paying when this one ends.
            let daysDone = max(0, utc.component(.day, from: .now) - 1)
            let daysInMonth = utc.range(of: .day, in: .month, for: .now)?.count ?? 30
            let next = list.compactMap { c -> CreditMath.Window? in
                guard c.monthly, let e = c.end, let n = utc.date(byAdding: .month, value: 1, to: e) else { return nil }
                return CreditMath.Window(name: c.name, amountUSD: c.amountUSD, start: e, end: n,
                                         workspaces: c.workspaces, excludeWorkspaces: c.excludeWorkspaces)
            }
            let projected = CreditMath.projectedPaid(month: month, credits: windows, usedBefore: before, nextPeriods: next,
                                                     monthStart: monthStart, daysDone: daysDone, daysInMonth: daysInMonth,
                                                     pace: pace, paceDays: Self.paceDays)
            // The other end: this month's own pace. Spend comes in bursts (big jobs on a few days, nothing on most),
            // so neither pace is "the" answer; the card shows the range between them.
            let ownPace = CreditMath.projectedPaid(month: month, credits: windows, usedBefore: before, nextPeriods: next,
                                                   monthStart: monthStart, daysDone: daysDone, daysInMonth: daysInMonth)
            monthBreakdown = MonthSpend(total: b.total, covered: b.covered.map { .init(name: $0.name, usd: $0.usd) }, paid: b.paid, projectedPaid: max(projected, ownPace), projectedLow: min(projected, ownPace),
                                        pacePerDay: pace.map(\.usd).reduce(0, +) / Double(Self.paceDays),
                                        daysDone: daysDone, daysInMonth: daysInMonth)
            paidRead = .now
            saveLastRead()
        }
    }

    /// Days of spend the month-end projection takes its daily pace from (whole UTC days, up to yesterday).
    nonisolated static let paceDays = 28

    nonisolated static func window(_ c: Credit) -> CreditMath.Window {
        CreditMath.Window(name: c.name, amountUSD: c.amountUSD, start: c.start, end: c.end,
                          workspaces: c.workspaces, excludeWorkspaces: c.excludeWorkspaces)
    }

    /// How this month's Claude API spend splits: what each credit covered and what you paid (USD, measured).
    struct MonthSpend: Equatable, Codable {
        struct Covered: Codable { var name: String; var usd: Double }
        var total: Double
        var covered: [Covered]
        var paid: Double
        /// The high end of what you'll have paid by the month's end: the higher of the last 28 days' pace and this
        /// month's own pace (credits applied as for real days).
        var projectedPaid: Double
        /// The low end of the month-end range (the high end is `projectedPaid`).
        var projectedLow: Double = 0
        var pacePerDay: Double = 0          // all workspaces, USD a day over the pace window
        var daysDone = 0                    // whole UTC days of this month counted
        var daysInMonth = 30
        /// The first week: the projection rests mostly on days not yet spent.
        var early: Bool { daysDone < 7 }
        static func == (a: MonthSpend, b: MonthSpend) -> Bool { a.total == b.total && a.paid == b.paid && a.projectedPaid == b.projectedPaid }
    }
    private(set) var monthBreakdown: MonthSpend?
    /// Spend this month that you actually pay (USD), measured; nil until read.
    var paidThisMonthUSD: Double? { monthBreakdown?.paid }
    /// Projected for the whole month (what "Costs a month" and "Really yours" use).
    var projectedPaidThisMonthUSD: Double? { monthBreakdown?.projectedPaid }
    private(set) var paidRead: Date?

    nonisolated static func inScope(_ workspace: String, _ c: Credit) -> Bool {
        if let only = c.workspaces { return only.contains(workspace) }
        if let skip = c.excludeWorkspaces { return !skip.contains(workspace) }
        return true
    }

    /// Spend per UTC day and workspace name (the default workspace is "Default") between two dates; nil when any
    /// part can't be read (workspace names, a page, or more pages than we follow), never a partial total.
    nonisolated static func spentRows(key: String, from: Date, to: Date) async -> [CreditMath.Spend]? {
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let a = utc.startOfDay(for: from), b = utc.startOfDay(for: to)
        guard b > a else { return [] }
        func request(_ u: URL) -> URLRequest {
            var r = URLRequest(url: u, timeoutInterval: 30)
            r.setValue(key, forHTTPHeaderField: "x-api-key"); r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            return r
        }
        var names: [String: String] = [:]
        guard let wu = URL(string: "https://api.anthropic.com/v1/organizations/workspaces?limit=100"),
              let (wd, wr) = try? await URLSession.shared.data(for: request(wu)), (wr as? HTTPURLResponse)?.statusCode == 200,
              let wroot = try? JSONSerialization.jsonObject(with: wd) as? [String: Any] else { return nil }
        for w in (wroot["data"] as? [[String: Any]]) ?? [] { if let id = w["id"] as? String, let n = w["name"] as? String { names[id] = n } }
        var comps = URLComponents(string: "https://api.anthropic.com/v1/organizations/cost_report")!
        let f = ISO8601DateFormatter()
        comps.queryItems = [.init(name: "starting_at", value: f.string(from: a)), .init(name: "ending_at", value: f.string(from: b)),
                            .init(name: "bucket_width", value: "1d"), .init(name: "limit", value: "31"),
                            .init(name: "group_by[]", value: "workspace_id")]
        var rows: [CreditMath.Spend] = [], page: String? = nil, pages = 0
        repeat {
            if let page { comps.queryItems?.removeAll { $0.name == "page" }; comps.queryItems?.append(.init(name: "page", value: page)) }
            guard let (data, resp) = try? await URLSession.shared.data(for: request(comps.url!)), (resp as? HTTPURLResponse)?.statusCode == 200,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            for bucket in (root["data"] as? [[String: Any]]) ?? [] {
                guard let start = (bucket["starting_at"] as? String).flatMap({ f.date(from: $0) }) else { return nil }
                for r in (bucket["results"] as? [[String: Any]]) ?? [] {
                    let ws = (r["workspace_id"] as? String).map { names[$0] ?? $0 } ?? "Default"
                    let cents = (r["amount"] as? String).flatMap(Double.init) ?? (r["amount"] as? Double)
                    if let cents { rows.append(.init(day: utc.startOfDay(for: start), workspace: ws, usd: cents / 100)) }
                }
            }
            page = (root["has_more"] as? Bool) == true ? root["next_page"] as? String : nil
            pages += 1
        } while page != nil && pages < 40
        return page == nil ? rows : nil
    }

    func used(_ c: Credit) -> Double { live[c.id] ?? c.spentUSD ?? 0 }
    /// Share of a credit used, 0–100.
    func percent(_ c: Credit) -> Double { c.amountUSD > 0 ? min(used(c), c.amountUSD) / c.amountUSD * 100 : 0 }
}

/// One colour rule for every meter on the card (credits and plans alike): green, amber from 80%, red from 90%.
enum MeterTint {
    static func of(_ p: Double) -> Color { p >= 90 ? Brand.bad : p >= 80 ? Brand.caution : Brand.good }
}

struct CreditRows: View {
    @State private var credits = Credits.shared
    var body: some View {
        let rows = credits.current.map { c -> (credit: Credits.Credit, raw: Double, left: Double, pct: Double) in
            let raw = credits.used(c)
            let used = min(raw, c.amountUSD)
            let left = max(0, c.amountUSD - used)
            return (c, raw, left, credits.percent(c))
        }
        let active = rows.filter { !Credits.isExhaustedGrant($0.credit, left: $0.left) }
        let finished = rows.filter { Credits.isExhaustedGrant($0.credit, left: $0.left) }

        ForEach(active, id: \.credit.id) { row in
            let c = row.credit
            let over = row.raw - c.amountUSD          // spend past the credit comes from the normal balance; say so
            HStack(spacing: 12) {
                ServiceIcon(service: "Claude")
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(c.name) · \(String(format: "$%.2f", row.left)) left of $\(Int(c.amountUSD).formatted())"
                         + (c.workspaces.map { " · \($0.joined(separator: ", ")) workspace" } ?? ""))
                    if over >= 0.01 {
                        Text("\(String(format: "$%.2f", over)) spent beyond this credit. " + (Costs.paysForAPI
                                ? "Check your Anthropic balance: when it's empty, API calls stop (or auto-reload charges your card)."
                                : "You don't buy credits and no card is used, so nothing is charged: when the credits are empty, API calls stop."))
                            .font(.caption.weight(.semibold)).foregroundStyle(Brand.bad).fixedSize(horizontal: false, vertical: true)
                    }
                    Text([row.left <= 0.005 ? Quips.pick(["All spent. Every cent did its job.", "Tank empty. Well used."]) : nil,
                          c.monthly ? Credits.nextLine(c) : nil,
                          credits.live[c.id] != nil ? "used from Anthropic API" : "used: as you typed it"].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                    if let allocs = c.allocations, !allocs.isEmpty {
                        let appUsed = AISettings.shared.usdThisMonth
                        let others = allocs.filter { $0.source != "app" }
                        let rest = max(0, row.raw - (allocs.contains { $0.source == "app" } ? appUsed : 0))
                        ForEach(allocs, id: \.self) { a in
                            let used: String = a.source == "app" ? String(format: "$%.2f used", appUsed)
                                : (others.count == 1 ? String(format: "$%.2f used", rest) : "shares the rest")
                            Text("↳ \(a.name): \(used) · up to $\(Int(a.capUSD)) a month" + (a.note.map { " · \($0)" } ?? ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                ProgressView(value: row.pct, total: 100).tint(MeterTint.of(row.pct)).frame(width: 140)
                Text("\(Int(row.pct.rounded()))%").font(.callout.bold().monospacedDigit()).foregroundStyle(Kit.vibrant(MeterTint.of(row.pct)))
                    .frame(width: 46, alignment: .trailing)
            }
        }
        if !finished.isEmpty {
            let names = finished.map { "\($0.credit.name) ($\(Int($0.credit.amountUSD).formatted()) used)" }.joined(separator: ", ")
            Text("Finished grants: \(names).")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
