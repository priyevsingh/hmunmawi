import HmunmawiCore
import SwiftUI

/// Everything about how the business is running, in one glance on Pulse: a seal in the middle saying
/// whether all is well, and a pill for each check around it. A pill turns amber or red only when it needs
/// you; click any pill for its detail (the crash history lives there as real bars).
struct HealthCheck: View {
    let model: AppModel

    struct Check: Identifiable {
        /// What a screen shows of it, to tell whether a refresh changed anything (no redraw when it didn't).
        var signature: String { "\(id)|\(title)|\(value)|\(level.rawValue)|\(apps.joined(separator: ","))" }
        let id: String
        let symbol: String
        let title: String
        let value: String
        var apps: [String] = []
        var level: Level = .good
        var detail: InfoModel
        enum Level: Int { case good, caution, bad }
        var tint: Color { level == .good ? Brand.good : level == .caution ? Brand.caution : Brand.bad }
    }

    /// Silent while everything is fine (the greeting and the toolbar's status pill already say so); a banner
    /// only for checks that need you, gone once they're fixed. The full list lives in the status pill.
    var body: some View {
        let problems = Self.checks(model).filter { $0.level != .good }
        if !problems.isEmpty {
            KitCard {
                CardHeader(symbol: "exclamationmark.triangle.fill", title: "Needs you",
                           tint: problems.contains { $0.level == .bad } ? Brand.bad : Brand.caution)
                ForEach(problems) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(c.title): \(c.value)").font(Kit.outcome).foregroundStyle(c.tint)
                        if let line = c.detail.paragraphs.first { Text(line).font(.callout).foregroundStyle(.secondary) }
                    }
                    .clickForDetail(c.detail)
                }
            }
        }
    }

    // MARK: The checks

    private static func latest(_ model: AppModel, _ kind: String, within days: Millis = 2) -> [StoredEvent] {
        let cutoff = Millis(Date.now.timeIntervalSince1970 * 1000) - days * TodayBuilder.day
        let matching = model.events.filter { $0.kind == kind && $0.occurredAt > cutoff }
        return Dictionary(grouping: matching, by: { $0.app ?? "" }).compactMap { $0.value.max { $0.occurredAt < $1.occurredAt } }
            .sorted { ($0.app ?? "") < ($1.app ?? "") }
    }

    /// A job failure counts only while the job is still failing: when launchd now reports its last run as fine
    /// (it recovered on its own), yesterday's error isn't news, and Automations already says "all fine".
    /// A failure newer than launchd's last reading always counts (the reading can't have seen it recover).
    static func stillFailing(_ events: [StoredEvent], successes: [StoredEvent] = []) -> [StoredEvent] {
        let mac = MacAutomations.shared
        if mac.lastRead == nil || Date.now.timeIntervalSince(mac.lastRead!) > 300 { Task { await mac.refresh() } }
        return JobFailures.stillFailing(events, states: macJobStates(), readAt: macReadAt(), successes: successes)
    }

    /// launchd's latest reading of every job (label -> running / ok / failed / off) and when it was taken.
    static func macJobStates() -> [String: String] {
        Dictionary(MacAutomations.shared.jobs.map { ($0.label, $0.state) }, uniquingKeysWith: { a, _ in a })
    }
    static func macReadAt() -> Millis {
        Millis((MacAutomations.shared.lastRead ?? .distantPast).timeIntervalSince1970 * 1000)
    }

    static func crashTrend(_ model: AppModel) -> [(Date, Double)] {
        var byDay: [Date: Double] = [:]
        // The last two weeks only, so "crash-free now" is never weeks old.
        let since = Millis(Date.now.timeIntervalSince1970 * 1000) - 14 * TodayBuilder.day
        for e in model.events where e.kind == "crash.daily" && e.occurredAt > since {
            guard var r = e.payload[path: "crash_free_rate"]?.number else { continue }
            if r <= 1 { r *= 100 }
            let d = e.reportDay
            // Today isn't over: its crash-free figure covers only part of the day, so it waits until tomorrow.
            guard d < Calendar.current.startOfDay(for: .now) else { continue }
            byDay[d] = min(byDay[d] ?? 100, r)
        }
        return byDay.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// App Store Connect lists every cert; the health row should reflect the **newest still-valid cert per type**
    /// (old ones often linger until they expire). Among those per-type bests, the soonest date is when any signing
    /// line would run out. Falls back to `account.snapshot`'s stored field when expiry items aren't loaded yet.
    static func certificateExpiry(for model: AppModel, account: JSONValue?, now: Date = .now) -> JSONValue? {
        let items = model.snapshots("expiry.snapshot").first?.payload[path: "items"]?.array ?? []
        return certificateExpiry(expiryItems: items, account: account, now: now)
    }

    static func certificateExpiry(expiryItems: [JSONValue], account: JSONValue?, now: Date = .now) -> JSONValue? {
        let today = Calendar.current.startOfDay(for: now)
        func parseDay(_ raw: String) -> Date? {
            try? Date(String(raw.prefix(10)) + "T12:00:00Z", strategy: .iso8601)
        }
        func dayISO(_ date: Date) -> String {
            String(date.formatted(.iso8601.year().month().day()))
        }
        var newestByType: [String: Date] = [:]
        for i in expiryItems {
            guard i[path: "kind"]?.string == "Certificate",
                  let expStr = i[path: "expires"]?.string,
                  let exp = parseDay(expStr),
                  exp >= today else { continue }
            let type = (i[path: "type"]?.string ?? "UNKNOWN").uppercased()
            newestByType[type] = max(newestByType[type] ?? .distantPast, exp)
        }
        if !newestByType.isEmpty, let soonest = newestByType.values.min() {
            return .string(dayISO(soonest))
        }
        if let certs = account?[path: "certificates"]?.array {
            for c in certs {
                guard let expStr = c[path: "expires"]?.string,
                      let exp = parseDay(expStr),
                      exp >= today else { continue }
                let type = (c[path: "type"]?.string ?? "UNKNOWN").uppercased()
                newestByType[type] = max(newestByType[type] ?? .distantPast, exp)
            }
            if !newestByType.isEmpty, let soonest = newestByType.values.min() {
                return .string(dayISO(soonest))
            }
        }
        return account?[path: "next_certificate_expiry"]
    }

    private static func dateCheck(_ id: String, _ symbol: String, _ title: String, _ value: JSONValue?, note: String?) -> Check? {
        guard let s = value?.string, let d = try? Date(String(s.prefix(10)) + "T12:00:00Z", strategy: .iso8601) else { return nil }
        let days = Calendar.current.dateComponents([.day], from: .now, to: d).day ?? 999
        var info = InfoModel(icon: .symbol(symbol), tint: Brand.Category.users, title: title, subtitle: d.dayText)
        let when = days < 0 ? ("Expired", "\(-days) \(days == -1 ? "day" : "days") ago") : ("In", "\(days) \(days == 1 ? "day" : "days")")
        info.facts = [info.fact("calendar", "Date", d.dayText), info.fact("hourglass", when.0, when.1), info.fact("info.circle", "Note", note)].compactMap { $0 }
        info.paragraphs = [days < 0 ? "This has expired. Renew it now; until then it can stop things working."
                           : days <= 30 ? "Coming up soon. Renew it before then so nothing stops." : "Chill for now. It turns amber 30 days out."]
        return Check(id: id, symbol: symbol, title: title, value: days < 0 ? "Expired" : days <= 30 ? "due in \(days) \(days == 1 ? "day" : "days") (\(d.formatted(.dateTime.day().month(.abbreviated))))" : d.formatted(.dateTime.day().month(.abbreviated).year()),
                     level: days < 7 ? .bad : days <= 30 ? .caution : .good, detail: info)
    }

    /// Amber when a required Mac permission is off, so the menu bar and Pulse show it before a job is blocked.
    static func permissionsCheck(_ snapshot: MacPermissionSnapshot) -> Check? {
        let missing = snapshot.requiredMissing
        guard !missing.isEmpty else { return nil }
        var info = InfoModel(icon: .symbol("lock.shield"), tint: Brand.caution, title: "Mac permissions")
        info.paragraphs = [
            "Grant these once in Settings → Permissions. Checking the status never asks, and routines wait instead of showing a system box mid-run.",
            missing.map(\.title).joined(separator: ", ")
        ]
        let names = missing.map(\.title).joined(separator: ", ")
        return Check(id: "permissions", symbol: "lock.shield", title: "Mac permissions",
                     value: names, level: .caution, detail: info)
    }

    static func checks(_ model: AppModel, permissions: MacPermissionSnapshot? = nil) -> [Check] {
        let crashes = latest(model, "crash.daily")
        let crashing = crashes.filter { ($0.payload[path: "crashed"]?.number ?? 0) > 0 }
        let failed = stillFailing(latest(model, "job.failed", within: 1), successes: model.events.filter { JobFailures.successKinds.contains($0.kind) })
        let down = latest(model, "site.down", within: 1)
        // A script's "needs a look" (amber): open until a success for the same job arrives.
        let look = JobFailures.needingLook(latest(model, JobFailures.attentionKind, within: 1),
                                           successes: model.events.filter { JobFailures.successKinds.contains($0.kind) })
        let trend = crashTrend(model), worstRate = trend.last?.1
        var out: [Check] = []

        var crash = InfoModel(icon: .symbol("checkmark.shield.fill"), tint: Brand.Category.users, title: "Crash-free sessions",
                              subtitle: "From Sentry sessions, lowest of your apps each day. App Store Connect stays the official release-quality number.")
        crash.facts = crashes.compactMap { e in
            crash.fact("app.fill", e.app ?? "App", e.payload[path: "crashed"]?.number.map { $0 == 0 ? "No crashes" : "\(Int(safe: $0)) crashed sessions" })
        }
        crash.points = trend
        out.append(Check(id: "crash", symbol: crashing.isEmpty ? "checkmark.shield.fill" : "bolt.trianglebadge.exclamationmark.fill",
                         title: "Crash-free",
                         value: worstRate.map { String(format: "%.1f%%", $0) } ?? (crashing.isEmpty ? "All apps" : "\(crashing.count) crashed"),
                         apps: crashes.compactMap(\.app), level: crashing.isEmpty ? .good : .bad, detail: crash))

        var jobs = InfoModel(icon: .symbol("gearshape.2.fill"), tint: Brand.Category.users, title: "Mac jobs")
        jobs.paragraphs = [failed.isEmpty ? "Every watched routine ran fine today." : failed.map { EventText.describe($0) }.joined(separator: "\n")]
        out.append(Check(id: "jobs", symbol: "gearshape.2.fill", title: "Mac jobs",
                         value: failed.isEmpty ? "All ran" : failed.count == 1 ? "\(failed[0].app.map { MacJobRoutine.shortName($0) } ?? "1") failed" : "\(failed.count) failed", level: failed.isEmpty ? .good : .bad, detail: jobs))

        if !look.isEmpty {
            var info = InfoModel(icon: .symbol("exclamationmark.bubble.fill"), tint: Brand.caution, title: "Needs a look")
            info.paragraphs = [look.map { e in
                let detail = e.payload[path: "detail"]?.string ?? e.payload[path: "error"]?.string
                return EventText.describe(e) + (detail.map { ". \($0)" } ?? "")
            }.joined(separator: "\n")]
            out.append(Check(id: "attention", symbol: "exclamationmark.bubble.fill", title: "Needs a look",
                             value: look.count == 1 ? (look[0].app ?? "1 thing") : "\(look.count) things",
                             apps: look.compactMap(\.app), level: .caution, detail: info))
        }

        var site = InfoModel(icon: .symbol("globe"), tint: Brand.Category.users, title: "Website")
        site.paragraphs = [down.isEmpty ? "All pages loading. Checked every few minutes." : (down.first.map { EventText.describe($0) } ?? "")]
        out.append(Check(id: "site", symbol: "globe", title: "Website", value: down.isEmpty ? "Up" : "Down",
                         level: down.isEmpty ? .good : .bad, detail: site))

        let account = model.snapshots("account.snapshot").first?.payload
        if let c = dateCheck("member", "person.crop.circle.badge.checkmark", "Developer membership", account?[path: "renews"], note: account?[path: "fee"]?.string) { out.append(c) }
        if let c = dateCheck("cert", "key.fill", "Certificate", certificateExpiry(for: model, account: account), note: nil) { out.append(c) }
        if let devices = account?[path: "devices"]?.number {
            var info = InfoModel(icon: .symbol("iphone"), tint: Brand.Category.users, title: "Developer account")
            info.facts = [info.fact("iphone", "Devices", "\(Int(devices))"),
                          info.fact("person.2", "Team members", account?[path: "users"]?.number.map { "\(Int(safe: $0))" })].compactMap { $0 }
            out.append(Check(id: "devices", symbol: "iphone", title: "Devices", value: "\(Int(devices))", detail: info))
        }
        if let permissions, let c = permissionsCheck(permissions) { out.append(c) }
        return out
    }
}

/// The six checks as a plain list, for the status pill's popover.
struct HealthList: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your apps").font(.callout).foregroundStyle(.secondary)
            ForEach(model.healthChecks) { c in
                HStack(spacing: 8) {
                    Image(systemName: c.level == .good ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(c.tint)
                    Text(c.title)
                    Spacer()
                    Text(c.value).foregroundStyle(c.level == .good ? Brand.secondaryText : c.tint).monospacedDigit().liveNumber(c.value)
                }
                .font(.callout)
                .help(c.detail.paragraphs.first ?? "")
            }
        }
    }
}
