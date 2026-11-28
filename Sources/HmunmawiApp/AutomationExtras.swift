import HmunmawiCore
import SwiftUI

/// Everything on the automation map beyond today's timed jobs: weekly and switched-off jobs, helpers that are
/// always running (with their real state), safety nets, and what happens when something fails. Two rows show
/// at a glance; the details sit one click deeper, so nothing from the map is left out.
struct AutomationExtras: View {
    let model: AppModel

    struct Item: Identifiable, Hashable {
        let id: String
        let when: String
        let title: String
        let tags: [String]
        let detail: String
        let state: String      // running, ok, failed, missing, off, unknown (always/safety); off/on (weekly)
        let note: String?
        let label: String?
    }
    struct Failure: Identifiable, Hashable { let id: String; let failure: String; let happens: String; let result: String }

    @State private var mac = MacAutomations.shared
    @State private var notes = AutomationNotes.shared
    @State private var lists: [JobLists.Entry] = []

    private func item(_ e: JobLists.Entry) -> Item {
        let when = (e.days.isEmpty ? "" : e.days.joined(separator: ", ") + " ") + (e.at ?? e.every ?? "")
        let state = e.off ? "off" : e.lastStatus == "failed" ? "failed" : e.lastStatus == "ran" ? "ok" : "on"
        return Item(id: e.id, when: when, title: e.title, tags: [e.source], detail: e.detail, state: state, note: nil, label: nil)
    }

    private func item(_ j: MacAutomations.Job) -> Item {
        let n = notes.note(j.label)
        let failed = j.state == "failed" ? j.exitCode.map { "last run stopped with error \($0)" } : nil
        return Item(id: j.label, when: j.when, title: n.title, tags: [], detail: n.detail, state: j.state, note: failed, label: j.label)
    }

    var body: some View {
        let visible = mac.jobs.filter { !notes.note($0.label).hidden && (notes.file.notes[$0.label] != nil || ProjectStore.shared.belongs(jobLabel: $0.label)) && ProjectStore.shared.shows(jobLabel: $0.label) }
        // Jobs on 5+ days live on the day ribbon; This week keeps the 1-4-day ones so it stays easy to scan.
        let weekly = visible.filter { $0.kind == .weekly && $0.days.count < 5 }.map(item)
            + lists.filter { ((!$0.days.isEmpty && $0.days.count < 5) || $0.off) && ProjectStore.shared.shows(text: $0.title + " " + $0.detail + " " + $0.source) }.map(item)
        let always = visible.filter { [.interval, .always, .login, .watch].contains($0.kind) && !notes.note($0.label).safetyNet }.map(item)
        let safety = visible.filter { notes.note($0.label).safetyNet }.map(item)
            + notes.file.notes.filter { $0.key.hasPrefix("note:") && $0.value.safetyNet && !$0.value.hidden }
                .sorted { $0.key < $1.key }
                .map { Item(id: $0.key, when: $0.value.when ?? "", title: $0.value.title, tags: [], detail: $0.value.detail,
                            state: $0.value.check == "live" ? Self.liveState() : AutomationNotes.run(check: $0.value.check), note: nil, label: nil) }
        let failures = notes.file.failures.map { Failure(id: $0.id, failure: $0.failure, happens: $0.happens, result: $0.result) }
        VStack(alignment: .leading, spacing: 26) {
            ThisWeek(items: weekly) { lists = JobLists.read() }
            ExpiryCard(model: model)
            if !always.isEmpty || !safety.isEmpty || !failures.isEmpty {
                AlwaysOn(items: always, safety: safety, failures: failures, model: model)
            }
        }
        .task {
            // Re-read the Mac's jobs while this page is open (cheap: one launchctl call a minute).
            while !Task.isCancelled {
                await mac.refresh()
                lists = JobLists.read()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    static func tint(_ state: String) -> Color {
        switch state {
        case "running", "ok", "on": Brand.good
        case "failed": Brand.bad
        case "missing": Brand.caution
        default: Color.secondary
        }
    }

    /// Check "live": the live-sales outbox answered within the last 15 minutes.
    static func liveState() -> String {
        let live = LivePurchases.shared
        guard live.deployed else { return "unknown" }
        if live.status?.hasPrefix("Couldn't reach") == true { return "failed" }
        guard let last = live.lastCheck else { return "unknown" }
        return Date.now.timeIntervalSince(last) < 900 ? "ok" : "failed"
    }

    static func words(_ state: String, note: String?) -> String {
        let base = switch state {
        case "running": "Running now"
        case "ok": "Working (last run fine)"
        case "failed": "Stopped with an error"
        case "missing": "Not loaded on this Mac"
        case "off": "Switched off"
        case "on": "On"
        default: "Not tracked by a Mac job"
        }
        return note.map { "\(base) · \($0)" } ?? base
    }
}

// MARK: This week

private struct ThisWeek: View {
    let items: [AutomationExtras.Item]
    var onChange: () -> Void
    @State private var open: AutomationExtras.Item?
    @State private var showRoutines = false
    private let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    var body: some View {
        let today = days[(Calendar(identifier: .iso8601).component(.weekday, from: .now) + 5) % 7]
        let dated = items.filter { i in i.state != "off" && days.contains { i.when.contains($0) } }
        let other = items.filter { i in i.state != "off" && !days.contains { i.when.contains($0) } }
        let off = items.filter { $0.state == "off" }
        KitCard {
            HStack(spacing: 10) {
                CardHeader(symbol: "calendar", title: "This week", tint: Brand.Category.web,
                           caption: "\(dated.count + other.count) weekly · \(off.count) switched off")
                Button { showRoutines = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).font(.body.weight(.semibold))
                    .help("Add or change routines the app can't find by itself")
                    .accessibilityLabel("Your routines")
            }
            HStack(alignment: .top, spacing: 8) {
                ForEach(days, id: \.self) { d in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(d).font(.caption.weight(.semibold))
                            .foregroundStyle(d == today ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary))
                        ForEach(dated.filter { $0.when.contains(d) }.sorted { Self.timeOnly($0.when) < Self.timeOnly($1.when) }) { i in chip(i) }
                        // An empty day says so, instead of an unexplained blank column.
                        if !dated.contains(where: { $0.when.contains(d) }) {
                            Text("Nothing weekly").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(d == today ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.04)))
                }
            }
            if !other.isEmpty || !off.isEmpty {
                FlowLayoutRow(spacing: 6) {
                    ForEach(other + off) { i in
                        Button { open = i } label: {
                            Label(i.title, systemImage: i.state == "off" ? "pause.circle" : "repeat")
                                .font(.caption.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                                .foregroundStyle(i.state == "off" ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .background(Capsule().fill(Color.secondary.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                        .help(i.state == "off" ? "Switched off · \(i.when)" : i.when)
                    }
                }
            }
        }
        .popover(item: $open) { i in ItemDetail(item: i, model: nil) }
        .sheetFlow(isPresented: $showRoutines) { AnyView(RoutinesSheet(onChange: onChange).buttonStyle(.pill)) }
    }

    /// "Mon, Thu 05:50" -> "05:50" (the column already says the day).
    static func timeOnly(_ when: String) -> String {
        let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let words = when.replacingOccurrences(of: ",", with: " ").split(separator: " ").filter { !days.contains(String($0)) }
        return words.joined(separator: " ")
    }

    /// "Morning digest (Sunday 09:30)" -> "Morning digest": the chip already shows the day and time.
    static func plainTitle(_ title: String) -> String {
        title.replacingOccurrences(of: #"\s*\((Mon|Tue|Wed|Thu|Fri|Sat|Sun)[a-z]*\.?\s*[0-9:]*\)"#, with: "", options: .regularExpression)
    }

    private func chip(_ i: AutomationExtras.Item) -> some View {
        Button { open = i } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.timeOnly(i.when))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                // Non-breaking hyphens: narrow day columns wrap whole words ("sign‑in"), never "sign- / in".
                Text(Self.plainTitle(i.title).replacingOccurrences(of: "-", with: "\u{2011}")).font(.callout).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8).fill(.background.opacity(0.7)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(i.title), \(i.when)")
    }

    private func row(_ i: AutomationExtras.Item, lead: String) -> some View {
        Button { open = i } label: {
            HStack(spacing: 8) {
                Image(systemName: lead).foregroundStyle(i.state == "off" ? Color.secondary : Brand.Category.web)
                Text(i.title).font(.callout.weight(.medium)).foregroundStyle(i.state == "off" ? .secondary : .primary)
                Text(i.when).font(.callout).foregroundStyle(.secondary)
                Spacer()
                if i.state == "off" { Text("Switched off").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: Always on

private struct AlwaysOn: View {
    let items: [AutomationExtras.Item]
    let safety: [AutomationExtras.Item]
    let failures: [AutomationExtras.Failure]
    let model: AppModel
    @State private var open: AutomationExtras.Item?
    @State private var showSafety = false
    @State private var showFailures = false

    var body: some View {
        let live = items.filter { $0.state == "running" || $0.state == "ok" }
        let bad = items.filter { $0.state == "failed" || $0.state == "missing" }
        KitCard {
            CardHeader(symbol: "waveform.path.ecg", title: "Always on", tint: bad.isEmpty ? Brand.good : Brand.bad,
                       caption: bad.isEmpty ? "\(live.count) helpers checked · all fine" : "\(bad.count) need a look")
            FlowLayoutRow(spacing: 8) {
                ForEach(items) { i in
                    Button { open = i } label: {
                        HStack(spacing: 6) {
                            StateDot(state: i.state)
                                .ripple(AutomationExtras.tint(i.state), trigger: i.state, breathes: i.state == "running" || i.state == "failed")
                            Text(i.title).font(.callout.weight(.medium)).foregroundStyle(i.state == "off" ? .secondary : .primary)
                            Text(i.when).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(Color.secondary.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(i.title): \(AutomationExtras.words(i.state, note: i.note))")
                }
            }
            HStack(spacing: 16) {
                if !safety.isEmpty {
                    Button { showSafety.toggle() } label: {
                        Label("Safety nets (\(safety.count))", systemImage: showSafety ? "chevron.down" : "chevron.right")
                    }
                }
                if !failures.isEmpty {
                    Button { showFailures.toggle() } label: {
                        Label("If something fails (\(failures.count))", systemImage: showFailures ? "chevron.down" : "chevron.right")
                    }
                }
                Spacer()
                HStack(spacing: 10) {
                    ForEach([("running", "Running"), ("failed", "Error"), ("off", "Off"), ("unknown", "Not checked")], id: \.0) { s, t in
                        HStack(spacing: 4) { StateDot(state: s, size: 6); Text(t) }
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless).font(.callout.weight(.semibold))
            if showSafety {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 8)], alignment: .leading, spacing: 10) {
                    ForEach(safety) { s in
                        Button { open = s } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    if s.state != "unknown" { Circle().fill(AutomationExtras.tint(s.state)).frame(width: 6, height: 6) }
                                    Text(s.title).font(.callout.weight(.semibold))
                                    Spacer()
                                    Text(s.when).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(10).frame(maxWidth: .infinity, alignment: .topLeading)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .transition(.opacity)
            }
            if showFailures {
                FlowLayoutRow(spacing: 6) {
                    ForEach(failures) { f in
                        let tint = f.result.contains("late") ? Brand.caution : Brand.good
                        HStack(spacing: 6) {
                            Text(f.failure).font(.caption.weight(.medium))
                            Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                            Text(f.result).font(.caption.weight(.semibold)).foregroundStyle(tint)
                        }
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(Capsule().fill(tint.opacity(0.1)))
                        .help(f.happens)
                        .accessibilityLabel("\(f.failure): \(f.happens). \(f.result)")
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.3), value: showSafety)
        .animation(.smooth(duration: 0.3), value: showFailures)
        .popover(item: $open) { i in ItemDetail(item: i, model: model) }
    }
}

/// One helper, safety net or weekly job: everything the map says about it, its real state and controls.
private struct ItemDetail: View {
    let item: AutomationExtras.Item
    let model: AppModel?
    @State private var result: String?
    @State private var confirmRun = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(AutomationExtras.tint(item.state)).frame(width: 8, height: 8)
                Text(item.title).font(.headline)
                ForEach(item.tags, id: \.self) { Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
            }
            Text(item.when).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Text(item.detail).font(.callout).fixedSize(horizontal: false, vertical: true)
            Label(AutomationExtras.words(item.state, note: item.note), systemImage: "info.circle")
                .font(.callout.weight(.medium)).foregroundStyle(AutomationExtras.tint(item.state))
            if let label = item.label, let model {
                Divider()
                Text(label).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    Button("Run now") { confirmRun = true }
                    if let result { Text(result).font(.caption).foregroundStyle(.secondary) }
                }
                .confirmationDialog("Run \(item.title) now?", isPresented: $confirmRun) {
                    Button("Run now") {
                        result = JobControl.runNow(label)
                        Task { await model.recordJobAction("run", label: label) }
                    }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 300, idealWidth: 360, maxWidth: .infinity, alignment: .leading)
    }
}

/// Wraps controls or capsules onto as many lines as needed.
struct FlowLayoutRow: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let limit = proposal.width ?? 800
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, maxLineWidth: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > limit { x = 0; y += line + spacing; line = 0 }
            maxLineWidth = max(maxLineWidth, x + size.width)
            x += size.width + spacing; line = max(line, size.height)
        }
        return CGSize(width: proposal.width ?? maxLineWidth, height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; line = max(line, size.height)
        }
    }
}


/// Filled for checked states, hollow when the app can't check it (like "Later" on the sky ribbon).
private struct StateDot: View {
    let state: String
    var size: CGFloat = 7
    var body: some View {
        Group {
            if state == "unknown" { Circle().strokeBorder(Color.secondary, lineWidth: 1.2) }
            else { Circle().fill(AutomationExtras.tint(state)) }
        }
        .frame(width: size, height: size)
    }
}
