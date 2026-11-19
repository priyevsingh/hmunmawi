import HmunmawiCore
import SwiftUI

/// What Hmunmawi is doing right now and what it healed by itself, gathered from the activity log.
struct SystemStatus {
    enum Level { case good, caution, bad }

    struct Connection: Identifiable {
        let name: String
        let healthy: Bool
        let lastSeen: Date?
        var id: String { name }
    }

    struct Heal: Identifiable {
        let id: Int64
        let at: Date
        let text: String
    }

    var level: Level = .good
    var connections: [Connection] = []
    var lastCheck: Date?
    var lastBackup: Date?
    var heals: [Heal] = []

    var headline: String {
        switch level {
        case .good: "Healthy"
        case .caution: "Recovering"
        case .bad: "Needs attention"
        }
    }

    var color: Color {
        switch level {
        case .good: Brand.good
        case .caution: Brand.caution
        case .bad: Brand.bad
        }
    }

    private static func healText(_ action: String, _ name: String) -> String? {
        switch action {
        case "plugin.unresponsive": "\(name) stopped answering and was restarted"
        case "plugin.poll_retry": "\(name) check took too long; stopped it and trying again"
        case "plugin.start_failed": "\(name) failed to start; retrying with a pause"
        case "app.crash_report": "Hmunmawi crashed earlier (Apple's report)"
        case "app.hang_report": "Hmunmawi stopped responding earlier (Apple's report)"
        case "app.freeze": "The window froze briefly"
        case "plugin.flood": "\(name) sent far more data than usual; paused for an hour"
        case "job.retry": "A job failed and is being retried"
        case "job.recovered": "Unfinished jobs resumed after a restart"
        case "heal.restored": "Database restored from a backup"
        case "heal.fresh_start": "A damaged database was set aside; started fresh"
        case "heal.caught_up": "Caught up after the Mac woke from sleep"
        case "backup.saved": "Daily backup saved"
        case "heal.disk.low": "Checked disk space on this Mac"
        case "heal.upgrade_backup": "Database upgraded (a copy was saved first)"
        default: nil
        }
    }

    static let launchedAt = Millis(Date.now.timeIntervalSince1970 * 1000)

    nonisolated static func staleUpdateFailure(_ e: AuditEntry, launchedAt: Millis) -> Bool {
        guard e.at < launchedAt else { return false }
        if e.action == "plugin.changed_on_disk" { return true }
        return e.action == "plugin.poll_failed" && (e.detail[path: "error"]?.string ?? "").contains("changed on disk")
    }

    static func make(audit: [AuditEntry], addOns: [AddOnRow], backups: URL, covered: Set<String> = [],
                     launchedAt: Millis = SystemStatus.launchedAt) -> SystemStatus {
        let now = Date.now
        let hourAgo = Millis((now.timeIntervalSince1970 - 3600) * 1000)
        let dayAgo = Millis((now.timeIntervalSince1970 - 86_400) * 1000)
        let failing: Set<String> = ["plugin.unresponsive", "plugin.start_failed", "plugin.poll_failed", "plugin.http_blocked", "plugin.flood", "plugin.delivery_failed", "app.crash_report", "app.hang_report", "app.freeze"]

        var status = SystemStatus()
        status.connections = addOns.filter(\.approved).map { row in
            // "Changed on disk" from before this launch was the previous copy of the app seeing an update or rebuild;
            // this launch trusts the new files, so it isn't a broken connection (it kept the dot red up to 10 minutes).
            let mine = audit.filter { $0.actor == row.id && !(Self.staleUpdateFailure($0, launchedAt: launchedAt)) }
            let recentFailure = mine.first { failing.contains($0.action) && $0.at > hourAgo }
            let lastGood = mine.first { !failing.contains($0.action) }
            let healthy = covered.contains(row.id) || row.missing.isEmpty && (recentFailure == nil || (lastGood?.at ?? 0) > (recentFailure?.at ?? 0))
            return Connection(name: row.manifest.name, healthy: healthy,
                              lastSeen: mine.first.map { Date(timeIntervalSince1970: Double($0.at) / 1000) })
        }
        status.lastCheck = status.connections.compactMap(\.lastSeen).max()
        // Repeats of the same fix become one line: "Checked disk space on this Mac ×8 · Space is fine now".
        var grouped: [String: (heal: Heal, count: Int)] = [:]
        for entry in audit where entry.at > dayAgo {
            let name = addOns.first { $0.id == entry.actor }?.manifest.name ?? entry.actor
            guard let text = healText(entry.action, name) else { continue }
            let key = entry.action + "|" + name
            if let g = grouped[key] { grouped[key] = (g.heal, g.count + 1); continue }
            let detail = entry.action.hasPrefix("heal.") ? (entry.subject.map { " · \($0)" } ?? "") : ""
            grouped[key] = (Heal(id: entry.id, at: Date(timeIntervalSince1970: Double(entry.at) / 1000), text: text + detail), 1)
        }
        status.heals = grouped.values.map { g in
            Heal(id: g.heal.id, at: g.heal.at, text: g.count > 1 ? "\(g.heal.text) (×\(g.count))" : g.heal.text)
        }.sorted { $0.at > $1.at }
        let files = (try? FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        status.lastBackup = files.filter { $0.lastPathComponent.hasPrefix("hmunmawi-") }
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()

        // "Recovering" only while something is still being fixed: a restart or a failed start in the last hour.
        // A fix that finished (backup saved, disk freed, caught up) leaves the app Healthy.
        let stillFixing: Set<String> = ["plugin.unresponsive", "plugin.poll_retry", "plugin.start_failed", "job.retry", "heal.fresh_start"]
        let recentHeal = audit.contains { $0.at > hourAgo && stillFixing.contains($0.action) }
        status.level = status.connections.contains { !$0.healthy } ? .bad : recentHeal ? .caution : .good
        return status
    }
}

/// The toolbar pill: a live dot and one line; click for details.
struct StatusPill: View {
    let status: SystemStatus
    /// The one health answer (same as Today, the menu bar and notifications).
    var truth: HealthTruth
    var flash: StoredEvent?
    @State private var open = false

    static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 10 { return "just now" }
        if seconds < 60 { return "\(seconds / 15 * 15 == 0 ? seconds : seconds / 15 * 15) seconds ago" }
        return Ago.text(date, now: now)
    }

    var body: some View {
        Button { open.toggle() } label: {
            Group {
                if let flash {
                    // A new moment, announced for a few seconds, then the pill returns to its status.
                    HStack(spacing: 8) {
                        AppIcon(app: flash.app, size: 18, badge: TickerItems.symbol(flash.kind).0,
                                badgeTint: TickerItems.symbol(flash.kind).1)
                        if let flag = TickerItems.flag(flash) { Text(flag) }
                        Text(EventText.describe(flash)).fontWeight(.medium).fixedSize()
                    }
                    .transition(.push(from: .bottom))
                } else {
                    statusLine.transition(.push(from: .top))
                }
            }
            .animation(.smooth(duration: 0.4), value: flash?.id)
            .font(.callout)
            .padding(.horizontal, 4)
        }
        .help("System status")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            // Scrolls inside a screen-sized box: a long day used to push the top of the panel off screen.
            ScrollView { StatusDetail(status: status, truth: truth) }
                .frame(width: 400)
                .frame(maxHeight: (NSScreen.main?.visibleFrame.height ?? 900) * 0.8)
        }
    }

    private var statusLine: some View {
            HStack(spacing: 6) {
                Circle().fill(truth.color).frame(width: 8, height: 8)
                    .ripple(truth.color, trigger: truth.headline, breathes: truth.dot == .good)
                Text(truth.headline).fontWeight(.medium)
                if let check = status.lastCheck {
                    // Re-drawn every 15 seconds so "checked … ago" stays true.
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        Text("· checked \(Self.ago(check, now: context.date))").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
    }
}

private struct StatusDetail: View {
    /// "Disk space low on this Mac" -> "Disk space was low on this Mac", so a fixed problem doesn't read as current.
    static func past(_ text: String) -> String {
        for (now, then) in [(" has pages down", " had pages down"), (" low ", " was low "), (" down", " was down"), (" fails", " failed"), (" is ", " was ")] where text.contains(now) {
            return text.replacingOccurrences(of: now, with: then)
        }
        return text
    }

    let status: SystemStatus
    let truth: HealthTruth
    @Environment(AppModel.self) private var model: AppModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(truth.headline, systemImage: truth.symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(truth.color)
            if truth.dot != .good { Text(truth.sentence).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if let model { HealthList(model: model) }
            if UserDefaults.standard.bool(forKey: AscStreamProtocol.streamEnabledKey) {
                let d = UserDefaults.standard
                let state = d.string(forKey: AscStreamProtocol.Telemetry.stateKey) ?? "closed"
                let lastFrame = d.double(forKey: AscStreamProtocol.Telemetry.lastFrameMsKey)
                let lastPong = d.double(forKey: AscStreamProtocol.Telemetry.lastPongMsKey)
                let live = AscStreamProtocol.streamHealthLabel(state: state, lastFrameMs: lastFrame, lastPongMs: lastPong)
                HStack {
                    Circle().fill(live.healthy ? Brand.good : Brand.caution).frame(width: 8, height: 8)
                    Text("Live sales stream")
                    Spacer()
                    Text(live.text).font(.callout).foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Connections").font(.callout).foregroundStyle(.secondary)
                ForEach(status.connections) { c in
                    HStack {
                        Circle().fill(c.healthy ? Brand.good : Brand.bad).frame(width: 8, height: 8)
                        Text(c.name)
                        Spacer()
                        if let seen = c.lastSeen {
                            Text(Ago.text(seen)).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                }
            }
            // What happened on this Mac today (disk, website, jobs, reviews), each with its healing state.
            if let model {
                let moments = TodayTimeline.collapse(model.events.filter {
                    TodayTimeline.kinds.contains($0.kind) && $0.occurredAt > Millis(Date.now.timeIntervalSince1970 * 1000) - TodayBuilder.day
                })
                if !moments.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("On this Mac, last 24 hours").font(.callout).foregroundStyle(.secondary)
                        ForEach(moments.prefix(6)) { m in
                            let kind = m.latest.kind
                            // Fixed if a heal for this kind was logged after the problem (survives restarts).
                            let healed = model.lastHeals[kind].flatMap { $0.at >= m.first ? $0 : nil }
                            let running = model.heals[kind] == .running
                            // Not a problem (a build that passed) or over by now (the job has worked since): no amber dot.
                            let benign = kind == "ci.build" && !EventText.describe(m.latest).contains("failed")
                            let over = kind == "job.failed" && HealthCheck.stillFailing([m.latest], successes: model.events.filter { JobFailures.successKinds.contains($0.kind) }).isEmpty
                            let resolved = benign || over || healed != nil || { if case .done = model.heals[kind] { return true }; return false }()
                            let color = resolved ? Brand.good : Brand.caution
                            HStack(spacing: 10) {
                                Circle().fill(color).frame(width: 8, height: 8)
                                    .ripple(color, trigger: "\(kind)\(resolved)", breathes: !resolved || running)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(resolved && !benign ? Self.past(EventText.describe(m.latest)) : EventText.describe(m.latest))
                                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                                    Text(benign ? "Done" : over ? "Working again"
                                         : resolved ? "Fixed · \(healed?.subject ?? "healed automatically")"
                                                  : running ? "Fixing it now" : (m.count > 1 && kind != "job.failed" ? "\(m.count) times in 24 hours" : "Open"))
                                        .font(.callout).foregroundStyle(resolved ? Brand.good : Brand.secondaryText).fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                Text(Date(timeIntervalSince1970: Double(m.latest.occurredAt) / 1000), format: .dateTime.hour().minute())
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            HStack {
                Image(systemName: "externaldrive.fill.badge.checkmark").foregroundStyle(.secondary)
                Text(status.lastBackup.map { "Backed up \(Ago.text($0))" } ?? "No backup yet")
                    .font(.callout)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Healed automatically, last 24 hours").font(.callout).foregroundStyle(.secondary)
                if status.heals.isEmpty {
                    Text("Nothing broke. Not even a tiny bit. Show-off.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(status.heals.prefix(8)) { heal in
                    HStack(alignment: .firstTextBaseline) {
                        Text(heal.at, format: .dateTime.hour().minute()).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .leading)
                        Text(heal.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(20)
    }
}
