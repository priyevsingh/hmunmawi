import HmunmawiCore
import SwiftUI

/// The Mac's day as a 24-hour heatmap: one cell per hour, brighter the more jobs run in it. Hours already
/// past are solid, the rest are pale; a "now" hand stands in the current hour. Hover or click an hour to see
/// its jobs; the next run's hour is chosen at first. On arrival the hours light up from midnight to now and the
/// hand slides into place, once; after that only the minute moves anything.
struct AutomationDay: View {
    let model: AppModel
    @State private var selected: Int?
    @State private var hovered: Int?
    @State private var swept = false      // the arrival sweep: hours light up one after another
    @State private var handIn = false
    @State private var glow = false       // the next run's hour glows once after the sweep
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    struct Run: Identifiable {
        let minute: Int
        let title: String
        let detail: String
        let bot: Bool
        /// What actually happened today: ran, failed, missed, due, later or untracked (from the Mac's logs).
        var status = "later"
        var statusDetail: String?
        /// Unique source identifier (launchd label or joblist id) so concurrent runs at the same minute stay distinct.
        var sourceID: String = ""
        /// For job controls: the launchd agent (Run now, Pause), its plist, its log, or the bot's routine.
        var label: String?
        var plist: String?
        var log: String?
        var routine: String?
        var paused = false
        var id: String { sourceID.isEmpty ? "\(minute)-\(title)" : "\(minute)-\(sourceID)-\(title)" }
        var problem: Bool { status == "failed" || status == "missed" }
    }

    private static let india: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current   // launchd runs jobs on this Mac's own clock
        return c
    }()
    private static let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    /// Runs launchd should have counted by `date`: one catch-up for any times before the Mac started,
    /// plus each time since.
    static func needed(_ j: MacAutomations.Job, start: Date, upTo date: Date) -> Int {
        let boot = MacAutomations.bootTime
        let past = j.times.compactMap { t -> Date? in
            let q = t.split(separator: ":").compactMap { Int($0) }
            return q.count == 2 && (0..<24).contains(q[0]) && (0..<60).contains(q[1]) ? start.addingTimeInterval(Double(q[0] * 60 + q[1]) * 60) : nil
        }.filter { $0 <= date }
        return (past.contains { $0 < boot } ? 1 : 0) + past.filter { $0 >= boot }.count
    }

    /// Today's runs (this Mac's time), earliest first, read natively: your Mac's scheduled jobs (launchd) that
    /// belong to your projects or are described in your notes, plus job lists (scripts' own routines, bots).
    /// A run counts as done when any of its logs (output, or the wrapper log beside its launch script) changed
    /// after that time; no change 45 min later = didn't run. Jobs with no log at all show as not tracked.
    private static var memo: (key: Int, runs: [Run])?

    /// Everything the day's runs are worked out from, as one number: it changes when a job, a note, a job list file or
    /// the log changes, and at least every 15 seconds. Drawing the page asks for the runs many times a second; this
    /// makes all but the first ask free (Instruments, Nov 2026: the repeated rebuild was a third of scroll time).
    static func cacheKey(_ model: AppModel) -> Int {
        var h = Hasher()
        h.combine(Int(Date.now.timeIntervalSince1970 / 15))
        for j in MacAutomations.shared.jobs { h.combine(j.label); h.combine(j.state); h.combine(j.lastLog); h.combine(j.times.count) }
        h.combine(AutomationNotes.shared.file.notes.count)
        h.combine((try? FileManager.default.attributesOfItem(atPath: JobLists.folder.path))?[.modificationDate] as? Date)
        h.combine(model.audit.count); h.combine(model.events.count)
        return h.finalize()
    }

    private static var checkedAt = Date.distantPast

    static func runs(_ model: AppModel, on date: Date = .now) -> [Run] {
        guard abs(date.timeIntervalSinceNow) < 60 else { return computeRuns(model, on: date) }   // only "now" is remembered
        // Asked many times per frame while drawing: within one second the answer is simply reused.
        if let m = memo, Date.now.timeIntervalSince(checkedAt) < 1 { return m.runs }
        let key = cacheKey(model)
        checkedAt = .now
        if let m = memo, m.key == key { return m.runs }
        let out = computeRuns(model, on: date)
        memo = (key, out)
        return out
    }

    private static func computeRuns(_ model: AppModel, on date: Date) -> [Run] {
        let today = dayNames[india.component(.weekday, from: date) - 1]
        let start = india.startOfDay(for: date)
        let notes = AutomationNotes.shared
        var out: [Run] = []
        for j in MacAutomations.shared.jobs where !j.times.isEmpty && j.state != "off" {
            guard !notes.note(j.label).hidden,
                  notes.file.notes[j.label] != nil || ProjectStore.shared.belongs(jobLabel: j.label),
                  j.days.isEmpty || j.days.contains(today) else { continue }
            let logDate = j.lastLog
            let n = notes.note(j.label)
            for t in j.times {
                let p = t.split(separator: ":").compactMap { Int($0) }
                guard p.count == 2 else { continue }
                let minute = p[0] * 60 + p[1]
                let at = start.addingTimeInterval(Double(minute) * 60)
                var run = Run(minute: minute, title: n.title, detail: n.detail, bot: false, sourceID: j.label)
                if at > date { run.status = "later" }
                else if let logDate, logDate >= at.addingTimeInterval(-60) {
                    // Same rule as before: only the latest past run can carry the job's last error.
                    let latestPast = j.times.last { t in
                        let q = t.split(separator: ":").compactMap { Int($0) }
                        return q.count == 2 && (0..<24).contains(q[0]) && (0..<60).contains(q[1]) && start.addingTimeInterval(Double(q[0] * 60 + q[1]) * 60) <= date
                    }
                    run.status = (t == latestPast && j.state == "failed") ? "failed" : "ran"
                    run.statusDetail = "log updated \(logDate.formatted(date: .omitted, time: .shortened))"
                }
                else if let n = j.runsSinceBoot, n > 0, n >= Self.needed(j, start: start, upTo: date) {
                    // No log change, but launchd counted the runs. Times before the Mac started are run once
                    // when it starts ("caught up").
                    run.status = j.state == "failed" ? "failed" : "ran"
                    run.statusDetail = at < MacAutomations.bootTime
                        ? "caught up when the Mac started at \(MacAutomations.bootTime.formatted(date: .omitted, time: .shortened))"
                        : "ran \(n) time\(n == 1 ? "" : "s") since the Mac started"
                }
                else if logDate == nil { run.status = "untracked" }
                else if date.timeIntervalSince(at) > 45 * 60 { run.status = "missed"; run.statusDetail = "its log didn't change after this time" }
                else { run.status = "due"; run.statusDetail = "waiting to start" }
                if run.status == "failed", let code = j.exitCode { run.statusDetail = "last run stopped with error \(code)" }
                run.label = j.label
                run.plist = j.plist
                run.log = j.log
                out.append(run)
            }
        }
        for e in JobLists.read() where !e.off {
            guard let at = e.at, e.days.isEmpty || e.days.contains(today) else { continue }
            let times = RoutineSchedule.times(at)
            let slots: [(minute: Int, at: Date)] = times.map { t in
                let minute = t.hour * 60 + t.minute
                let slotAt = india.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: start)
                    ?? start.addingTimeInterval(Double(minute) * 60)
                return (minute, slotAt)
            }
            let latestPast = slots.last { $0.at <= date }?.at
            // One bead per time ("04:00,10:00,16:00,22:00" is four runs a day).
            for s in slots {
                var run = Run(minute: s.minute, title: e.title, detail: e.detail, bot: e.who == "bot", sourceID: e.id)
                run.status = Self.jobListStatus(lastStatus: e.lastStatus, slotAt: s.at, latestPastSlot: latestPast, now: date)
                out.append(run)
            }
        }
        return out.filter { ProjectStore.shared.shows(jobLabel: $0.label) }.sorted { ($0.minute, $0.title) < ($1.minute, $1.title) }
    }

    /// Resolves today's timeline status for one scheduled slot of a `JobLists` entry.
    /// Any future slot today is always "later", never marked ran/failed by an earlier run today.
    static func jobListStatus(lastStatus: String?, slotAt: Date, latestPastSlot: Date?, now date: Date) -> String {
        if slotAt > date { return "later" }
        switch lastStatus {
        case "failed": return latestPastSlot == slotAt ? "failed" : "untracked"
        case "missed": return latestPastSlot == slotAt ? "missed" : "untracked"
        case "ran": return "ran"
        default: return "untracked"
        }
    }

    @State private var picked: String?     // a bead you clicked (run id)
    @State private var scrub: Int?         // the minute under the pointer while it moves along the ribbon
    @State private var hoveredID: String?  // exact bead under the pointer (2D hit-test)
    @State private var stripWidth: CGFloat = 760
    @State private var pillWidth: CGFloat = 70

    var body: some View {
        // Redrawn once a minute (the sun and the ran/later marks); nothing else ticks.
        TimelineView(.everyMinute) { context in
            let now = Self.india.component(.hour, from: context.date) * 60 + Self.india.component(.minute, from: context.date)
            content(runs: Self.runs(model, on: context.date), now: now)
        }
    }

    @ViewBuilder
    private func content(runs: [Run], now: Int) -> some View {
        if !runs.isEmpty {
            let next = runs.first { $0.minute > now }
            let done = runs.filter { $0.minute <= now }.count
            let failed = runs.filter(\.problem).count
            let hoveredRun = hoveredID.flatMap { id in runs.first { $0.id == id } }
            // Hovering a bead previews that exact job; scrubbing empty sky previews the nearest run; a click pins one.
            let near = hoveredRun ?? scrub.flatMap { m in runs.min { abs($0.minute - m) < abs($1.minute - m) }.flatMap { abs($0.minute - m) <= 45 ? $0 : nil } }
            let focus = near ?? runs.first(where: { $0.id == picked }) ?? next ?? runs[runs.count - 1]   // runs is non-empty here
            KitCard {
                CardHeader(symbol: "sun.horizon.fill", title: "Your Mac's day", tint: failed > 0 ? Brand.caution : Brand.Category.web,
                           caption: "\(done) of \(runs.count) due so far" + (failed > 0 ? " · \(failed) didn't run right" : "") + " · " + LocalTime.zoneLabel())
                if let next {
                    Statement(label: "Next", key: "\(next.title) at \(Self.hm(next.minute))", rest: Self.until(next.minute - now))
                } else {
                    Statement(label: "Today", key: "Every routine has run", tint: Brand.good)
                }
                ribbon(runs: runs, now: now, focus: focus)
                    .focusable()
                    .focusEffectDisabled()
                    .onKeyPress(.rightArrow) { step(runs, focus, 1); return .handled }
                    .onKeyPress(.leftArrow) { step(runs, focus, -1); return .handled }
                Divider()
                runRow(focus, now: now, isNext: next?.id == focus.id)
            }
            .onAppear { arrive() }
        }
    }

    // MARK: The sky ribbon

    /// The day as a sky: night blue, dawn, daylight, dusk, night again.
    private static let sky = LinearGradient(stops: [
        .init(color: Color(red: 0.06, green: 0.08, blue: 0.20), location: 0.00),   // midnight
        .init(color: Color(red: 0.11, green: 0.14, blue: 0.33), location: 0.17),
        .init(color: Color(red: 0.36, green: 0.33, blue: 0.58), location: 0.23),   // first light
        .init(color: Color(red: 0.86, green: 0.66, blue: 0.74), location: 0.27),   // rose dawn
        .init(color: Color(red: 0.62, green: 0.78, blue: 0.97), location: 0.33),   // morning
        .init(color: Color(red: 0.55, green: 0.76, blue: 0.99), location: 0.50),   // noon
        .init(color: Color(red: 0.63, green: 0.79, blue: 0.96), location: 0.66),
        .init(color: Color(red: 0.96, green: 0.80, blue: 0.62), location: 0.74),   // golden hour
        .init(color: Color(red: 0.62, green: 0.47, blue: 0.72), location: 0.79),   // dusk
        .init(color: Color(red: 0.20, green: 0.20, blue: 0.43), location: 0.85),
        .init(color: Color(red: 0.07, green: 0.09, blue: 0.22), location: 1.00),
    ], startPoint: .leading, endPoint: .trailing)

    /// How far in from the strip's edges midnight sits (a bead's radius and a little air).
    static let stripInset: CGFloat = 14

    struct BeadLayout {
        let positions: [String: CGPoint]
        let height: CGFloat
    }

    /// Places every scheduled run at a distinct, non-overlapping coordinate along the sky strip.
    /// Up to 7 vertical lanes expand strip height cleanly; denser clusters spill into adjacent columns.
    static func layoutBeads(runs: [Run], width: CGFloat) -> BeadLayout {
        let usableW = max(width, 2 * stripInset + 32)
        let step: CGFloat = 16
        let maxVerticalLanes = 7
        let px: (Int) -> CGFloat = { m in stripInset + CGFloat(m) / 1440 * (usableW - 2 * stripInset) }

        var roughLastX: [CGFloat] = []
        var neededLanes = 1
        for r in runs {
            let x = px(r.minute)
            var lane = 0
            while lane < roughLastX.count && abs(x - roughLastX[lane]) < step { lane += 1 }
            if lane == roughLastX.count { roughLastX.append(x) } else { roughLastX[lane] = x }
            neededLanes = max(neededLanes, lane + 1)
        }

        let lanesCount = min(max(neededLanes, 5), maxVerticalLanes)
        let height: CGFloat = neededLanes <= 5 ? 110 : 30 + CGFloat(lanesCount) * step

        var columnOffsets: [CGFloat] = [0]
        for d in stride(from: step, through: step * 16, by: step) {
            columnOffsets.append(d)
            columnOffsets.append(-d)
        }

        var placed: [CGPoint] = []
        placed.reserveCapacity(runs.count)
        func fits(_ pt: CGPoint) -> Bool {
            placed.allSatisfy { hypot($0.x - pt.x, $0.y - pt.y) >= 15.5 }
        }

        var positions: [String: CGPoint] = [:]
        for r in runs {
            let baseX = px(r.minute)
            var chosen: CGPoint?
            search: for dx in columnOffsets {
                let cx = min(max(baseX + dx, stripInset), usableW - stripInset)
                for lane in 0..<lanesCount {
                    let cy = height - 16 - CGFloat(lane) * step
                    let pt = CGPoint(x: cx, y: cy)
                    if fits(pt) {
                        chosen = pt
                        placed.append(pt)
                        break search
                    }
                }
            }
            if chosen == nil {
                let cx = min(max(baseX, stripInset), usableW - stripInset)
                let pt = CGPoint(x: cx, y: height - 16)
                chosen = pt
                placed.append(pt)
            }
            positions[r.id] = chosen
        }
        return BeadLayout(positions: positions, height: height)
    }

    /// Returns the closest run bead within `maxDistance` of `point` in 2D space.
    static func nearestRun(to point: CGPoint, in positions: [String: CGPoint], runs: [Run], maxDistance: CGFloat = 14) -> Run? {
        var best: Run?
        var bestDist = maxDistance
        for r in runs {
            guard let pt = positions[r.id] else { continue }
            let d = hypot(pt.x - point.x, pt.y - point.y)
            if d <= bestDist {
                bestDist = d
                best = r
            }
        }
        return best
    }

    private func ribbon(runs: [Run], now: Int, focus: Run) -> some View {
        let layout = Self.layoutBeads(runs: runs, width: stripWidth)
        let nextID = runs.first { $0.minute > now }?.id
        return VStack(spacing: 8) {
            GeometryReader { g in
                let w = g.size.width, h = g.size.height
                // One time-to-position rule for everything on the strip (beads, sun, ticks, cursor, labels): midnight and
                // the next midnight sit one bead-radius-plus inside the edges, so a 12 am bead is whole, not cut in half.
                let px: (CGFloat) -> CGFloat = { Self.stripInset + $0 / 1440 * (w - 2 * Self.stripInset) }
                let activeLayout = abs(w - stripWidth) > 0.5 ? Self.layoutBeads(runs: runs, width: w) : layout
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Self.sky)
                        // Horizon light along the bottom, deeper sky at the top.
                        .overlay(LinearGradient(colors: [.black.opacity(0.18), .clear, .white.opacity(0.16)], startPoint: .top, endPoint: .bottom)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous)))
                        // A few still stars in the night hours.
                        .overlay(Canvas { ctx, size in
                            var seed: UInt64 = 7
                            for _ in 0..<46 {
                                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                                let fx = Double(seed >> 33) / Double(1 << 31)
                                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                                let fy = Double(seed >> 33) / Double(1 << 31)
                                guard fx < 0.21 || fx > 0.84 else { continue }
                                let r = fy < 0.3 ? 1.2 : 0.8
                                ctx.fill(Path(ellipseIn: CGRect(x: fx * size.width, y: fy * size.height * 0.75, width: r, height: r)),
                                         with: .color(.white.opacity(0.35 + fy * 0.3)))
                            }
                        }.allowsHitTesting(false))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.22), lineWidth: 1))
                        .allowsHitTesting(false)
                    // The past is lit, the rest of the day is softly veiled.
                    // (Full-width rounded veil, masked from "now" to midnight: clipping an offset rectangle cut
                    // it short at 24h minus now, leaving a hard edge mid-afternoon.)
                    RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.black.opacity(0.18))
                        .mask(HStack(spacing: 0) { Color.clear.frame(width: px(CGFloat(now))); Color.black })
                        .frame(width: w, height: h)
                        .allowsHitTesting(false)
                    // The sun (or moon at night) marks now; it drifts in when the page opens.
                    let sx = px(CGFloat(handIn ? now : 0))
                    let day = (6 * 60...19 * 60).contains(now)
                    ZStack {
                        Circle().fill(RadialGradient(colors: [(day ? Color(red: 1, green: 0.93, blue: 0.70) : .white).opacity(0.55), .clear],
                                                     center: .center, startRadius: 4, endRadius: 46))
                            .frame(width: 92, height: 92)
                        Circle().fill(day ? Color(red: 1, green: 0.95, blue: 0.80) : Color(white: 0.96)).frame(width: 18, height: 18)
                    }
                    .offset(x: sx - 46, y: -28)
                    .opacity(handIn ? 1 : 0)
                    .allowsHitTesting(false)
                    // Faint 3-hour ticks.
                    ForEach(1..<8, id: \.self) { i in
                        Rectangle().fill(.white.opacity(0.14)).frame(width: 1, height: h - 24)
                            .offset(x: px(CGFloat(i) * 180), y: 12)
                            .allowsHitTesting(false)
                    }
                    // The scrub cursor or hovered bead callout.
                    if let hitID = hoveredID,
                       let hit = runs.first(where: { $0.id == hitID }),
                       let hitPos = activeLayout.positions[hit.id] {
                        let hitState = Self.state(hit, now: now, isNext: nextID == hit.id)
                        let pillX: CGFloat = hitPos.x < w * 0.55
                            ? min(hitPos.x + 16, max(6, w - pillWidth - 6))
                            : max(hitPos.x - pillWidth - 16, 6)
                        let pillY: CGFloat = min(max(hitPos.y - 13, 6), max(6, h - 30))
                        Rectangle().fill(.white.opacity(0.45)).frame(width: 1.5, height: h)
                            .offset(x: hitPos.x)
                            .allowsHitTesting(false)
                        Text("\(Self.hm(hit.minute)) · \(hit.title) · \(hitState.text)")
                            .font(.callout.weight(.semibold)).monospacedDigit()
                            .fixedSize()
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(.regularMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1))
                            .shadow(color: .black.opacity(0.28), radius: 6, y: 2)
                            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pillWidth = $0 }
                            .offset(x: pillX, y: pillY)
                            .allowsHitTesting(false)
                    } else if let m = scrub {
                        let x = px(CGFloat(m))
                        Rectangle().fill(.white.opacity(0.75)).frame(width: 1.5, height: h)
                            .offset(x: x)
                            .allowsHitTesting(false)
                        Text(Self.hm(m)).font(.callout.weight(.semibold)).monospacedDigit()
                            .fixedSize()
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.regularMaterial, in: Capsule())
                            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pillWidth = $0 }
                            .offset(x: min(max(x - pillWidth / 2, 6), max(6, w - pillWidth - 6)), y: 6)
                            .allowsHitTesting(false)
                    }
                    ForEach(runs) { r in
                        let pos = activeLayout.positions[r.id] ?? CGPoint(x: px(CGFloat(r.minute)), y: h - 16)
                        bead(r, chosen: r.id == focus.id, now: now, isNext: nextID == r.id)
                            .position(pos)
                            .scaleEffect(swept ? 1 : 0.1)
                            .opacity(swept ? 1 : 0)
                            .animation(reduceMotion ? nil : .spring(response: 0.7, dampingFraction: 0.75).delay(Double(r.minute) / 1440 * 2.4), value: swept)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        if ScrollGate.active { return }
                        if let hit = Self.nearestRun(to: p, in: activeLayout.positions, runs: runs) {
                            hoveredID = hit.id
                            scrub = hit.minute
                        } else {
                            hoveredID = nil
                            scrub = max(0, min(1439, Int((p.x - Self.stripInset) / max(w - 2 * Self.stripInset, 1) * 1440)))
                        }
                    case .ended:
                        hoveredID = nil
                        scrub = nil
                    }
                }
            }
            .frame(height: layout.height)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                if abs($0 - stripWidth) > 0.5 { stripWidth = $0 }
            }
            // Each label centred under its own time on the same scale as the strip (6 am is a quarter of the way along,
            // not wherever equal-width columns happen to put it).
            GeometryReader { g in
                ForEach(Array([("12 am", 0), ("6 am", 360), ("Noon", 720), ("6 pm", 1080), ("12 am", 1440)].enumerated()), id: \.offset) { _, item in
                    Text(item.0).font(.callout).foregroundStyle(.secondary).fixedSize()
                        .position(x: Self.stripInset + CGFloat(item.1) / 1440 * (g.size.width - 2 * Self.stripInset), y: 10)
                }
            }
            .frame(height: 20)
            DotKey()
        }
    }

    private func bead(_ r: Run, chosen: Bool, now: Int, isNext: Bool) -> some View {
        let state = Self.state(r, now: now, isNext: false)
        let later = r.status == "later" || (r.status == "due" && r.minute > now)
        let untracked = r.status == "untracked"
        let delay = Double(r.minute) / 1440 * 2.4
        return ZStack {
            // One soft ring as the bead lands (timed with its arrival).
            Circle().strokeBorder((later ? Color.white : untracked ? Color(white: 0.72) : state.tint).opacity(0.9), lineWidth: 1.5)
                .frame(width: 11, height: 11)
                .scaleEffect(swept ? 3.2 : 1)
                .opacity(swept ? 0 : 0.9)
                .animation(reduceMotion ? nil : .easeOut(duration: 1.6).delay(delay + 0.35), value: swept)
            if later {
                Circle().fill(.black.opacity(0.42))
                    .overlay(Circle().strokeBorder(.white.opacity(0.95), lineWidth: 1.75))
                    .frame(width: 11, height: 11)
                    .shadow(color: .black.opacity(0.4), radius: 2)
            } else if untracked {
                Circle().fill(Color(white: 0.48))
                    .overlay(Circle().strokeBorder(.white.opacity(0.75), lineWidth: 1.25))
                    .frame(width: 11, height: 11)
                    .shadow(color: .black.opacity(0.35), radius: 2)
            } else {
                Circle().fill(state.tint).frame(width: 11, height: 11)
                    .overlay(Circle().strokeBorder(.white.opacity(0.92), lineWidth: 1.5))   // readable on night and day
                    .shadow(color: .black.opacity(0.42), radius: 2)
                    .shadow(color: state.tint.opacity(0.85), radius: 5)
                    .ripple(state.tint, trigger: r.status)
            }
            if chosen { Circle().strokeBorder(.white, lineWidth: 2).frame(width: 18, height: 18).shadow(color: .black.opacity(0.45), radius: 2) }
        }
        // The next run breathes softly (drawn by Core Animation, so the app stays idle).
        .ripple(.white, trigger: isNext, breathes: isNext)
        .frame(width: 18, height: 18)
        .contentShape(Circle())
        .onTapGesture { withAnimation(.smooth(duration: 0.3)) { picked = r.id } }
        .accessibilityElement()
        .accessibilityLabel("\(Self.hm(r.minute)), \(r.title), \(state.text)")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: The chosen run

    private func runRow(_ r: Run, now: Int, isNext: Bool) -> some View {
        let state = Self.state(r, now: now, isNext: isNext)
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(Self.hm(r.minute)).font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(state.tint)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(r.title).font(.body.weight(.semibold))
                    Text(r.bot ? BotName.current : "Mac").font(.callout.weight(.medium))
                        .foregroundStyle(r.bot ? Brand.Category.users : Brand.Category.web)
                        .padding(.horizontal, 7).padding(.vertical, 1)
                        .background((r.bot ? Brand.Category.users : Brand.Category.web).opacity(0.12), in: Capsule())
                }
                Text(r.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Label(state.text, systemImage: state.symbol).font(.callout.weight(.semibold)).foregroundStyle(state.tint)
                if let d = r.statusDetail, r.status != "later", r.status != "untracked" {
                    Text(d).font(.callout).foregroundStyle(.secondary)
                }
            }
            JobMenu(run: r, model: model)
        }
        .id(r.id)
        .transition(.opacity.combined(with: .offset(y: 6)))
        .animation(.smooth(duration: 0.3), value: r.id)
    }

    /// ← / → move through the day's runs.
    private func step(_ runs: [Run], _ current: Run, _ d: Int) {
        guard let i = runs.firstIndex(where: { $0.id == current.id }) else { return }
        let j = min(max(i + d, 0), runs.count - 1)
        withAnimation(.smooth(duration: 0.25)) { picked = runs[j].id; hoveredID = nil; scrub = nil }
    }

    private func arrive() {
        guard !reduceMotion else { swept = true; handIn = true; return }
        swept = false; handIn = false
        // Beads appear across the day from midnight, then the sun drifts to now.
        Task { @MainActor in await Task.yield(); swept = true }
        withAnimation(.smooth(duration: 2.2).delay(0.6)) { handIn = true }
    }

    /// What to show for a run: what happened, or what's coming.
    static func state(_ r: Run, now: Int, isNext: Bool) -> (text: String, symbol: String, tint: Color) {
        switch r.status {
        case "ran": ("Ran", "checkmark.circle.fill", Brand.good)
        case "failed": ("Failed", "xmark.octagon.fill", Brand.bad)
        case "missed": ("Didn't run", "exclamationmark.triangle.fill", Brand.caution)
        case "untracked": (r.bot ? "\(BotName.current) · not tracked here" : "Not tracked here", "eye.slash", Brand.secondaryText)
        default:
            if isNext { ("Next", "arrow.right.circle.fill", Brand.Category.web) }
            else if r.minute <= now { ("Due", "clock", Brand.Category.web) }
            else { ("Later", "clock", Brand.secondaryText) }
        }
    }

    static func hm(_ m: Int) -> String { String(format: "%02d:%02d", m / 60, m % 60) }

    static func hourName(_ h: Int) -> String {
        h == 0 ? "12 am" : h < 12 ? "\(h) am" : h == 12 ? "12 pm" : "\(h - 12) pm"
    }

    static func until(_ m: Int) -> String {
        let h = m / 60, r = m % 60
        if h == 0 { return "in \(r) min" }
        return "in \(h) h" + (r > 0 ? " \(r) min" : "")
    }
}


/// What each dot means, said once, the same everywhere.
struct DotKey: View {
    @Environment(\.colorScheme) private var colorScheme
    private static let untrackedColor = Brand.adaptive(light: (0.45, 0.46, 0.50), dark: (0.58, 0.60, 0.65))
    private static let laterRingColor = Brand.adaptive(light: (0.28, 0.29, 0.34), dark: (0.94, 0.94, 0.97))

    var body: some View {
        FlowLayoutRow(spacing: 14) {
            item(Brand.good, "Ran")
            item(Brand.bad, "Failed")
            item(Brand.caution, "Didn't run")
            item(Brand.Category.web, "Due now")
            item(Self.untrackedColor, "Not tracked here")
            Label {
                Text("Later today").fixedSize()
            } icon: {
                Circle()
                    .fill(colorScheme == .dark ? Color.black.opacity(0.45) : Color.clear)
                    .overlay(Circle().strokeBorder(Self.laterRingColor, lineWidth: 1.6))
                    .frame(width: 9, height: 9)
            }
            .fixedSize()
        }
        .font(.callout).foregroundStyle(Brand.secondaryText)
        .accessibilityElement(children: .combine)
    }

    private func item(_ c: Color, _ t: String) -> some View {
        Label { Text(t).fixedSize() } icon: { Circle().fill(c).frame(width: 9, height: 9) }.fixedSize()
    }
}
