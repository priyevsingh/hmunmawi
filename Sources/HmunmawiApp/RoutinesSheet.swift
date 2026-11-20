import HmunmawiCore
import SwiftUI

/// Routines you add in the app: jobs the app can't find by itself (a bot's routine, a cloud job, something you
/// do by hand). Stored as a job list (joblists/my-routines.json), so agents can edit the same file (AGENTS.md).
struct MyRoutine: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var title: String = ""
    var who: String = "bot"          // mac, bot, cloud, you
    var at: String = "09:00"
    var days: [String] = []          // empty = every day
    var detail: String = ""
    var proof: String? = nil         // optional file it writes when it runs; {date} = today's date

    // Routines Hmunmawi runs itself (all optional, so lists written before them read exactly as before).
    /// What it does: nil = just listed (a bot's or cloud job); otherwise one of `RoutineKind`.
    var does: String? = nil
    /// Settings for what it does: "text" (remind), "url" (site watch), "days" (offer codes: "30,7,1").
    var params: [String: String]? = nil
    /// Where it tells you: "imessage", "ntfy", or nil for the first connected of those.
    var tell: String? = nil
    /// "hands-on" (prepares, waits for your OK) or "autopilot"; routines that only tell you have nothing to approve.
    var mode: String? = nil
    /// "30 min": every N minutes from midnight instead of a time of day.
    var every: String? = nil
    /// How late a missed run may still start (minutes); later ones are logged as missed.
    var catchUp: Int? = nil
    /// Set when another scheduler already does this job ("Runs in your hub: site_watch.py"): shown, never run.
    var elsewhere: String? = nil
    var off: Bool? = nil
    /// The last run, for the Automations map: {"date": "YYYY-MM-DD", "status": "ran|failed|missed"}.
    var last: [String: String]? = nil
    /// Signed by the app (trust key) when made or changed here; an unsigned or edited routine never runs.
    var sig: String? = nil
}

enum MyRoutines {
    static let url = JobLists.folder.appending(path: "my-routines.json")
    static let source = "Set in Hmunmawi"
    static var whoNames: [String: String] { ["mac": "Mac", "bot": BotName.current, "cloud": "Cloud", "you": "You"] }

    private struct File: Codable { var source = MyRoutines.source; var who = "bot"; var jobs: [MyRoutine] = [] }

    static func read() -> [MyRoutine] {
        guard let d = try? Data(contentsOf: url), d.count < 512_000,
              let f = try? JSONDecoder().decode(File.self, from: d) else { return [] }
        return f.jobs
    }

    static func write(_ jobs: [MyRoutine]) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: JobLists.folder, withIntermediateDirectories: true)
        try? enc.encode(File(jobs: Array(jobs.prefix(200)))).write(to: url, options: .atomic)
        BotSetup.syncFile(jobs)   // the bot's routines.md follows the list (only once the bot folder exists)
    }

    /// "Mon, Thu 07:11", "Every day 08:22", "Mon–Sat 08:27"
    static func when(_ r: MyRoutine) -> String {
        let all = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let days = all.filter(r.days.contains)
        let label = days.isEmpty || days.count == 7 ? "Every day"
            : days == Array(all.prefix(5)) ? "Weekdays"
            : days == Array(all.prefix(6)) ? "Mon–Sat"
            : days.joined(separator: ", ")
        return "\(label) \(r.at.replacingOccurrences(of: ",", with: ", "))"
    }
}

/// Removed routines, kept 30 days so a slip of the bin (yours or an agent's) can be undone. Each is kept exactly as it
/// was, signature included, so a restored routine is still approved. Lives beside the job lists (not in them, so it
/// never shows as a job) and is in the daily state backup.
enum DeletedRoutines {
    static let url = URL.hmSupport.appending(path: "routines-deleted.json")
    static let keepDays = 30
    struct Item: Codable, Identifiable { var routine: MyRoutine; var removedAt: Date; var id: String { routine.id + "@\(removedAt.timeIntervalSince1970)" } }

    static func read() -> [Item] {
        guard let d = try? Data(contentsOf: url), d.count < 1_000_000,
              let items = try? JSONDecoder().decode([Item].self, from: d) else { return [] }
        let cutoff = Date.now.addingTimeInterval(-Double(keepDays) * 86_400)
        return items.filter { $0.removedAt > cutoff }.sorted { $0.removedAt > $1.removedAt }
    }

    private static func write(_ items: [Item]) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? enc.encode(Array(items.prefix(200))).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func add(_ r: MyRoutine) { write([Item(routine: r, removedAt: .now)] + read()) }

    /// Puts it back as it was. Refused when a routine with the same id exists again (it would be replaced).
    @discardableResult
    static func restore(_ item: Item) -> String? {
        var list = MyRoutines.read()
        if list.contains(where: { $0.id == item.routine.id }) { return "A routine with the same id is already in the list." }
        if list.count >= 200 { return "The list is full (200 routines); remove one first." }
        list.append(item.routine)
        MyRoutines.write(list)
        write(read().filter { $0.id != item.id })
        return nil
    }
}

/// The list behind the + on This week: every routine you added, with Add, Edit and Remove.
struct RoutinesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var routines = MyRoutines.read()
    @Environment(\.openSheet) private var openSheet
    var onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your routines").font(.title2.bold())
            Text("Routines Hmunmawi runs for you, and ones it can't find by itself (a bot's, a cloud or a manual routine).")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if routines.isEmpty {
                Text("Crickets. Tap + to add your first routine").font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                ScrollView {
                  VStack(spacing: 0) {
                    ForEach(routines) { r in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.title).font(.body.weight(.medium))
                                Text(subtitle(r)).font(.callout).foregroundStyle(stateColor(r))
                                    .fixedSize(horizontal: false, vertical: true)
                                if let note = runNotes[r.id] { Text(note).font(.callout).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if r.does != nil {
                                if Routines.shared.state(r) == .changedOutside {
                                    Button("Approve…") { approving = r }.help("Changed outside the app; approve it to let it run")
                                } else if case .on = Routines.shared.state(r), !(RoutineKind(rawValue: r.does ?? "")?.builtIn ?? true) {
                                    Button("Run now") { Task { runNotes[r.id] = await Routines.shared.runNow(r.id, by: .you); routines = MyRoutines.read(); onChange() } }
                                }
                                // A job another scheduler runs is switched on or off there, not here.
                                // (and one changed outside the app is approved first: switching it on mustn't run the edit).
                                if case .elsewhere = Routines.shared.state(r) {} else if Routines.shared.state(r) != .changedOutside {
                                    Toggle("On", isOn: Binding(get: { r.off != true }, set: { on in setOn(r, on) }))
                                        .labelsHidden().toggleStyle(.switch).help(r.off == true ? "Switch on" : "Switch off")
                                }
                            } else if Routines.shared.state(r) == .changedOutside {
                                // A bot's or cloud job's entry edited outside the app: approved the same way.
                                Button("Approve…") { approving = r }.help("Changed outside the app; approve it to let it run")
                            }
                            Button("Edit") { edit(r) }
                            if !(RoutineKind(rawValue: r.does ?? "")?.builtIn ?? false) {
                                Button(role: .destructive) { remove(r) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless).help("Remove \(r.title)")
                            }
                        }
                        .padding(.vertical, 8)
                        if r.id != routines.last?.id { Divider() }
                    }
                  }
                }
                // As tall as the rows (no empty space), up to a point; then it scrolls.
                .frame(maxHeight: 560).fixedSize(horizontal: false, vertical: true)
            }
            if let r = justRemoved {
                HStack {
                    Label("Removed “\(r.title)”.", systemImage: "trash").font(.callout)
                    Spacer()
                    Button("Undo") { undoRemove(r) }.keyboardShortcut("z", modifiers: .command)
                }
                .padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
            if !deleted.isEmpty {
                Button { showDeleted.toggle() } label: {
                    Label("Recently deleted (\(deleted.count))", systemImage: showDeleted ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.borderless).font(.callout)
                if showDeleted {
                    VStack(spacing: 0) {
                        ForEach(deleted) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.routine.title).font(.body.weight(.medium))
                                    Text("Removed \(item.removedAt.formatted(date: .abbreviated, time: .shortened)) · kept until \(item.removedAt.addingTimeInterval(Double(DeletedRoutines.keepDays) * 86_400).formatted(date: .abbreviated, time: .omitted))")
                                        .font(.callout).foregroundStyle(.secondary)
                                    if let note = restoreNotes[item.id] { Text(note).font(.callout).foregroundStyle(Brand.caution) }
                                }
                                Spacer()
                                Button("Restore") { restore(item) }
                            }
                            .padding(.vertical, 6)
                        }
                    }
                    .padding(.leading, 18)
                }
            }
            if BotSetup.needsUpdate {
                Label("Your bot's routines changed. Copy the updated message and paste it into \(BotName.inSentence).", systemImage: "arrow.triangle.2.circlepath")
                    .font(.callout).foregroundStyle(Brand.caution).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button { edit(MyRoutine()) } label: { Label("Add routine", systemImage: "plus") }
                Button { openSheet?({ AnyView(BotSetupSheet().buttonStyle(.pill)) }) } label: { Label("Set up your bot", systemImage: "message") }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.pillProminent)
            }
        }
        .padding(22)
        .frame(minWidth: 600, idealWidth: 640)
        .confirmationDialog("Switch on “\(consenting?.title ?? "")”?", isPresented: Binding(get: { consenting != nil }, set: { if !$0 { consenting = nil } }),
                            titleVisibility: .visible, presenting: consenting) { r in
            Button("Switch on and allow") {
                UserDefaults.standard.set(true, forKey: Self.consentKey(r))
                change { list in if let i = list.firstIndex(where: { $0.id == r.id }) { list[i].off = nil } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { r in
            Text("It sends \(Self.aiData(r) ?? "data") to \(AISettings.shared.provider.name) with your key when it runs, within its monthly cap. \(Self.providerTerms()) Switch it off any time here.")
        }
        .confirmationDialog("Approve “\(approving?.title ?? "")”?", isPresented: Binding(get: { approving != nil }, set: { if !$0 { approving = nil } }),
                            titleVisibility: .visible, presenting: approving) { r in
            Button("Approve and let it run") { approve(r) }
            Button("Cancel", role: .cancel) {}
        } message: { r in
            Text("It was changed outside the app. Approve only if you made this change:\n\n" + Self.describe(r))
        }
    }

    /// The editor replaces this sheet (one sheet at a time) and brings it back, refreshed, when it closes.
    private func edit(_ r: MyRoutine) {
        let onChange = onChange
        let draft = RoutineDraft(r)
        openSheet?({
            AnyView(RoutineForm(draft: draft) { saved in
                // Written straight to disk: this sheet isn't on screen while the editor is, so it can't hold the change.
                var list = MyRoutines.read()
                if let i = list.firstIndex(where: { $0.id == saved.id }) { list[i] = saved } else { list.append(saved) }
                MyRoutines.write(list)
                onChange()
            }.buttonStyle(.pill))
        })
    }

    @State private var runNotes: [String: String] = [:]
    @State private var deleted = DeletedRoutines.read()
    @State private var showDeleted = false
    @State private var justRemoved: MyRoutine?
    @State private var restoreNotes: [String: String] = [:]

    /// Removed, but kept 30 days in Recently deleted; Undo stays on screen for 10 seconds.
    private func remove(_ r: MyRoutine) {
        DeletedRoutines.add(r)
        change { $0.removeAll { $0.id == r.id } }
        deleted = DeletedRoutines.read()
        justRemoved = r
        Task { try? await Task.sleep(for: .seconds(10)); if justRemoved?.id == r.id { justRemoved = nil } }
    }

    private func undoRemove(_ r: MyRoutine) {
        if let item = DeletedRoutines.read().first(where: { $0.routine.id == r.id }) { restore(item) }
        justRemoved = nil
    }

    private func restore(_ item: DeletedRoutines.Item) {
        if let why = DeletedRoutines.restore(item) { restoreNotes[item.id] = why } else { restoreNotes[item.id] = nil }
        routines = MyRoutines.read()
        deleted = DeletedRoutines.read()
        onChange()
    }

    @State private var approving: MyRoutine?

    /// Applies one edit to the list as it is on disk now: an agent or the clock may have changed it while this was open.
    private func change(_ edit: (inout [MyRoutine]) -> Void) {
        var list = MyRoutines.read()
        edit(&list)
        MyRoutines.write(list)
        routines = MyRoutines.read()
        onChange()
    }

    /// On or off isn't signed, so switching never approves anything.
    private func setOn(_ r: MyRoutine, _ on: Bool) {
        // An AI routine sends your data to your AI provider: the first time, say exactly what, and wait for an OK.
        if on, Self.aiData(r) != nil, !UserDefaults.standard.bool(forKey: Self.consentKey(r)) { consenting = r; return }
        change { list in
            guard let i = list.firstIndex(where: { $0.id == r.id }) else { return }
            let wasTrusted = Routines.isTrusted(list[i], key: AppModel.trustKey(KeychainSecretStore())) && Routines.isListedJob(list[i])
            list[i].off = on ? nil : true
            if wasTrusted { list[i] = Routines.shared.signed(list[i]) }   // switching a trusted bot job keeps it trusted
        }
    }

    @State private var consenting: MyRoutine?

    /// Consent is per routine and provider: switching to another provider asks again (their data terms differ).
    static func consentKey(_ r: MyRoutine) -> String { "HMAIConsent-\(r.id)-\(AISettings.shared.provider.rawValue)" }

    /// The provider's own data terms in one line (from their published policies, Nov 2026).
    static func providerTerms() -> String {
        switch AISettings.shared.provider {
        case .claude: "Anthropic says API data isn't used for training and is deleted within 30 days."
        case .openai: "OpenAI says API data isn't used for training; Hmunmawi asks it not to store the exchange."
        case .gemini: "If your Gemini key is on Google's free tier, Google may use and human-review this data; a paid key isn't used for training."
        case .openrouter: "Hmunmawi asks OpenRouter to route only to providers that don't collect prompts."
        case .ollama: "Ollama runs on this Mac: nothing leaves it."
        default: "Check this provider's data terms; Hmunmawi can't tell how it handles data."
        }
    }

    /// What an AI routine sends to the provider, in plain words (nil: it sends nothing).
    static func aiData(_ r: MyRoutine) -> String? {
        switch r.does {
        case RoutineKind.aiBrief.rawValue:
            switch r.params?["input"] ?? "numbers" {
            case "search": return "your Google Search Console figures (searches, pages, clicks)"
            case "crashes": return "your apps' crash counts per day"
            default: return "your weekly numbers, including downloads, revenue and subscriptions"
            }
        case RoutineKind.postDrafts.rawValue: return "your weekly numbers (when the bank runs low and it writes new drafts)"
        default: return nil
        }
    }

    /// Signs exactly what you were shown; if the file changed again meanwhile, nothing is approved.
    private func approve(_ shown: MyRoutine) {
        change { list in
            guard let i = list.firstIndex(where: { $0.id == shown.id }),
                  Routines.canonical(list[i]) == Routines.canonical(shown),
                  Routines.listedCanonical(list[i]) == Routines.listedCanonical(shown) else { return }
            list[i] = Routines.shared.signed(list[i])
        }
    }

    /// What a routine will do, in full, for the approval question.
    /// "Runs in your hub: X post drafts (x_drop_notify.sh, 3 a day from the post bank)" → "Runs in your hub for now:
    /// X post drafts". Script names, paths and old counts in brackets stay out of sight.
    nonisolated static func elsewhereText(_ e: String) -> String {
        var t = e.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s*\S+\.(py|sh|json)\b"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        // A built-in routine you don't need: one of your own jobs already does this work.
        if t.hasSuffix(":") || t.isEmpty { return "Not used: one of your own jobs does this" }
        if t.hasPrefix("Runs in your hub:") { return t.replacingOccurrences(of: "Runs in your hub:", with: "Not used: your own job does this:") }
        return t.hasPrefix("Runs ") ? t : "Runs elsewhere: \(t.contains("/") ? PathField.short(t) : t)"
    }

    static func describe(_ r: MyRoutine) -> String {
        var lines = ["Does: \(RoutineKind(rawValue: r.does ?? "")?.title ?? r.does ?? "")",
                     "When: \(r.every.map { "every \($0)" } ?? MyRoutines.when(r))"]
        let p = r.params ?? [:]
        if r.does == RoutineKind.script.rawValue {
            let cmd = URL(fileURLWithPath: ((p["command"] ?? "") as NSString).expandingTildeInPath)
            lines.append("Runs: \(cmd.lastPathComponent) \(p["args"] ?? "")  (\(PathField.short(cmd.deletingLastPathComponent().path)))")
            if let f = p["folder"], !f.isEmpty { lines.append("In: \(PathField.short(f))") }
            if let f = p["env"], !f.isEmpty { lines.append("Settings file: \(PathField.short(f))") }
            lines.append(p["try"] == "1" ? "Try out first: yes (records what would happen, changes nothing)" : "Try out first: no (runs for real)")
        } else if r.does == RoutineKind.macJob.rawValue {
            lines.append("Starts: \(p["label"] ?? "?")")
            lines.append(p["takeover"] == "1" ? "Takes over its own timer (the job's file is backed up first)" : "Its own timer stays as it is")
        } else {
            for (k, v) in p.sorted(by: { $0.key < $1.key }) where !v.isEmpty { lines.append("\(k): \(v.prefix(200))") }
        }
        if let t = r.tell { lines.append("Tells you by: \(t)") }
        return lines.joined(separator: "\n")
    }

    /// "On · every 30 min · last ran today", "Runs in your hub: site_watch.py", "Needs a website address"…
    private func subtitle(_ r: MyRoutine) -> String {
        let when = r.every.map { "every \($0)" } ?? MyRoutines.when(r)
        guard let kindRaw = r.does else {
            let file = r.proof == nil ? "" : BotSetup.lateSince(r) != nil ? " · today's file is late"
                : JobLists.proofRan(InputRule.path.clean(r.proof ?? ""), today: Date.now.localDay) ? " · today's file arrived"
                : r.params?["late"] != nil ? " · watches its file" : " · checks a file"
            return "\(MyRoutines.whoNames[r.who] ?? r.who) · \(MyRoutines.when(r))\(file)"
        }
        let kind = RoutineKind(rawValue: kindRaw)
        let what = kind?.builtIn == true ? (kind == .weeklyDigest ? "day and hour in Settings → General" : "once a day after 8 am") : when
        let last = r.last.flatMap { l in l["date"] == Date.now.localDay ? " · \(l["status"] == "failed" ? "failed" : "ran") today" : nil } ?? ""
        switch Routines.shared.state(r) {
        case .on: return "On · \(what)\(last)"
        case .off: return "Off · \(what)"
        case .elsewhere(let e): return Self.elsewhereText(e)
        case .needs(let n): return "Needs \(n) (Edit)"
        case .changedOutside: return "Changed outside the app: approve it to let it run"
        case .listed: return "\(MyRoutines.whoNames[r.who] ?? r.who) · \(MyRoutines.when(r))"
        }
    }

    private func stateColor(_ r: MyRoutine) -> Color {
        switch Routines.shared.state(r) {
        case .needs, .changedOutside: Brand.caution
        case .listed where BotSetup.lateSince(r) != nil: Brand.caution
        default: Brand.secondaryText
        }
    }
}

/// What the routine form held when it stepped aside for another sheet, so it comes back as it was left.
final class RoutineDraft {
    var routine: MyRoutine; var time: Date?; var proof: String?
    init(_ r: MyRoutine) { routine = r }
}

private struct RoutineForm: View {
    @Environment(\.dismiss) private var dismiss
    @State var routine: MyRoutine
    @State private var time = Date.now
    @State private var proof = ""
    @Environment(\.openSheet) private var openSheet
    let onSave: (MyRoutine) -> Void
    let draft: RoutineDraft
    private let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    /// The bank this routine posts from ("posts" unless it names another).
    private var bankName: String {
        let b = InputRule.identifier.clean(routine.params?["bank"] ?? "")
        return b.isEmpty ? "posts" : b
    }
    private var builtIn: RoutineKind? { RoutineKind(rawValue: routine.does ?? "").flatMap { $0.builtIn ? $0 : nil } }

    /// Who reads X for the X routines: Grok Bot or Hmunmawi through your Safari login.
    /// New routines start with your bot when one is named in Settings, otherwise with Safari.
    private var source: String {
        routine.params?["source"] ?? (UserDefaults.standard.string(forKey: "HMBotName")?.isEmpty == false ? "bot" : "safari")
    }
    private var sourcePicker: some View {
        Picker("Who reads X", selection: Binding(get: { source }, set: { var p = routine.params ?? [:]; p["source"] = $0; routine.params = p })) {
            Text("Grok Bot").tag("bot")
            Text("Hmunmawi, via my Safari login").tag("safari")
        }
        .onAppear { if routine.params?["source"] == nil { var p = routine.params ?? [:]; p["source"] = source; routine.params = p } }
    }

    @State private var xBusy = false
    @State private var xNote: String?
    private func xRun(_ work: @escaping @MainActor () async -> String) {
        xBusy = true; xNote = nil
        Task { @MainActor in xNote = await work(); xBusy = false }
    }

    private func param(_ key: String) -> Binding<String> {
        Binding(get: { routine.params?[key] ?? "" }, set: { var p = routine.params ?? [:]; p[key] = $0; routine.params = p })
    }

    @State private var alsoAt = ""
    /// An on/off parameter that is on unless set to "0".
    private func flag(_ key: String) -> Binding<Bool> {
        Binding(get: { routine.params?[key] != "0" }, set: { on in var p = routine.params ?? [:]; p[key] = on ? nil : "0"; routine.params = p.isEmpty ? nil : p })
    }
    init(draft: RoutineDraft, onSave: @escaping (MyRoutine) -> Void) {
        let routine = draft.routine
        _routine = State(initialValue: routine)
        _proof = State(initialValue: draft.proof ?? routine.proof ?? "")
        // "04:00,10:00,16:00": the first time goes in the picker, the rest in "Also at".
        let times = routine.at.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        _alsoAt = State(initialValue: times.dropFirst().joined(separator: ", "))
        let p = (times.first ?? "09:00").split(separator: ":").compactMap { Int($0) }
        _time = State(initialValue: draft.time ?? Calendar.current.date(bySettingHour: p.first ?? 9, minute: p.last ?? 0, second: 0, of: .now) ?? .now)
        self.onSave = onSave
        self.draft = draft
    }

    var body: some View {
        Form {
            TextField("Name", text: $routine.title).input(.name, $routine.title)
            Picker("What it does", selection: Binding(get: { routine.does ?? "" }, set: { v in
                routine.does = v.isEmpty ? nil : v
                if !v.isEmpty { routine.who = "mac"; if v == RoutineKind.siteWatch.rawValue, routine.every == nil { routine.every = "30 min" } }
                if v == RoutineKind.postDrafts.rawValue || v == RoutineKind.keyWatch.rawValue { routine.every = "60 min"; routine.catchUp = 60 }
                else if v == RoutineKind.xUnfollows.rawValue { routine.every = "5 min"; routine.catchUp = 5 }
                else if v == RoutineKind.serviceWatch.rawValue || v == RoutineKind.heartbeat.rawValue { routine.every = "15 min"; routine.catchUp = 15 }
                else if v == RoutineKind.linkCheck.rawValue { routine.every = nil; if routine.days.isEmpty { routine.days = ["Mon"] } }
                else if v != RoutineKind.siteWatch.rawValue && v != RoutineKind.linkCheck.rawValue { routine.every = nil }
                if v == RoutineKind.keyWatch.rawValue, routine.params?["long"] == nil { var p = routine.params ?? [:]; p["long"] = "1"; routine.params = p }
            })) {
                Text("Just list it (a bot's, cloud or manual routine)").tag("")
                ForEach(RoutineKind.allCases.filter { !$0.builtIn }) { Text($0.title).tag($0.rawValue) }
                if let k = builtIn { Text(k.title).tag(k.rawValue) }
            }
            .disabled(builtIn != nil)
            if routine.does == nil {
                Picker("Runs on", selection: $routine.who) {
                    ForEach(["mac", "bot", "cloud", "you"], id: \.self) { Text(MyRoutines.whoNames[$0] ?? $0).tag($0) }
                }
            }
            switch RoutineKind(rawValue: routine.does ?? "") {
            case .remind?:
                TextField("Message", text: param("text"), axis: .vertical).lineLimit(1...4).input(.text(900), param("text"))
            case .siteWatch?:
                TextField("Website address", text: param("url"), prompt: Text("https://mysite.com")).input(.url, param("url"))
                Picker("Check every", selection: Binding(get: { routine.every ?? "30 min" }, set: { routine.every = $0; routine.catchUp = Int($0.prefix { $0.isNumber }) })) {
                    ForEach(["1 min", "5 min", "15 min", "30 min", "60 min"], id: \.self) { Text($0).tag($0) }
                }
            case .aiBrief?:
                TextField("Ask the AI", text: param("brief"), axis: .vertical).lineLimit(2...5).input(.text(1500), param("brief"))
                Picker("About", selection: Binding(get: { routine.params?["input"] ?? "numbers" }, set: { var p = routine.params ?? [:]; p["input"] = $0; routine.params = p })) {
                    Text("My week's numbers").tag("numbers")
                    Text("What people search for").tag("search")
                    Text("Crashes this week").tag("crashes")
                }
                TextField("Most it may spend a month (USD)", text: param("cap"), prompt: Text("2")).input(.number, param("cap"))
                Text("Uses your AI key. When there's nothing new it doesn't ask the AI at all, so it costs nothing.")
                    .font(.callout).foregroundStyle(.secondary)
            case .postDrafts?:
                TextField("Bank", text: param("bank"), prompt: Text("posts")).input(.identifier, param("bank"))
                TextField("Drafts a day", text: param("per_day"), prompt: Text("3")).input(.number, param("per_day"))
                TextField("Hours between drafts", text: param("gap"), prompt: Text("3")).input(.number, param("gap"))
                Toggle("Send at my best hours", isOn: Binding(get: { (routine.params?["best_hours"] ?? "1") != "0" },
                                                              set: { var p = routine.params ?? [:]; p["best_hours"] = $0 ? "1" : "0"; routine.params = p }))
                Toggle("Follow X's algorithm", isOn: Binding(get: { (routine.params?["follow_x"] ?? "1") != "0" },
                                                              set: { var p = routine.params ?? [:]; p["follow_x"] = $0 ? "1" : "0"; routine.params = p }))
                Text("Ready drafts come from the bank first, the best one first; weak ones are skipped. Once a week it checks X's published ranking code and re-ranks when X changes what it rewards. When the bank runs low and an AI key is set, the AI writes 5 more from your numbers. You post them yourself.")
                    .font(.callout).foregroundStyle(.secondary)
                TextField("Stay on these topics (optional)", text: param("topics"), prompt: Text("e.g. SwiftUI, indie apps")).input(.list, param("topics"))
                TextField("Never about (optional)", text: param("avoid"), prompt: Text("e.g. crypto, politics")).input(.list, param("avoid"))
                Button("Edit the bank") { let b = bankName; openSheet?({ AnyView(BankEditor(bank: b).buttonStyle(.pill)) }) }
            case .replyIdeas?:
                sourcePicker
                TextField("Your topics", text: param("topics"), prompt: Text("e.g. HealthKit, SwiftUI, indie apps")).input(.list, param("topics"))
                TextField("Never about (optional)", text: param("avoid"), prompt: Text("e.g. crypto, politics")).input(.list, param("avoid"))
                TextField("Replies a day", text: param("per_day"), prompt: Text("4")).input(.number, param("per_day"))
                if source == "safari" {
                    TextField("What you work on", text: param("about"), prompt: Text("e.g. a sleep tracking app for iPhone")).input(.short, param("about"))
                    Picker("Drafts by", selection: Binding(get: { routine.params?["drafts"] ?? "auto" }, set: { var p = routine.params ?? [:]; p["drafts"] = $0; routine.params = p })) {
                        Text("Auto (free first)").tag("auto")
                        Text("Apple's on-device AI (free)").tag("ondevice")
                        Text("My AI key").tag("ai")
                        Text("No drafts, I write them").tag("none")
                    }
                    if let why = OnDeviceAI.status.reason, ["auto", "ondevice"].contains(routine.params?["drafts"] ?? "auto") {
                        Label("On-device drafts: \(why)", systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                    }
                    Text("Once a day Hmunmawi searches X for your topics through your Safari login (read-only) and keeps fresh posts with real conversation. Auto drafts each reply with Apple's on-device AI when this Mac has it (free, nothing leaves the Mac), else with your AI key; with neither you get the post to reply to yourself. One reply at each time above. You post it yourself.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                PathField(label: "Grok Bot's reply-targets folder", prompt: "Optional (Hmunmawi's own reply-targets folder)", text: param("folder"), folders: true)
                Text("Grok Bot finds the posts and drafts the replies (its X search is free), one file a day. Hmunmawi checks each one (fresh, on your topics, no link, no outdated version) and hands you one at each time above. You post it yourself.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Copy request for Grok Bot") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ReplyIdeas.botRequest(folder: (routine.params?["folder"]).flatMap { $0.isEmpty ? nil : $0 } ?? URL.hmSupport.appending(path: "reply-targets").path), forType: .string)
                }
                }
            case .unfollowList?:
                sourcePicker
                if source != "safari" {
                    PathField(label: "Grok Bot's list", prompt: "Optional (Hmunmawi's unfollow-queue.json)", text: param("file"), folders: false)
                }
                TextField("Accounts a day", text: param("per_day"), prompt: Text("10")).input(.number, param("per_day"))
                TextField("Always keep", text: param("keep"), prompt: Text("handles, comma separated")).input(.list, param("keep"))
                Text(source == "safari"
                     ? "Once a day Hmunmawi reads your Following page through your Safari login (read-only) and sends you a short list of accounts that don't follow back, to unfollow by hand. Accounts with 50,000+ followers are kept. This list never unfollows anyone; for that, add X unfollows (automatic) instead."
                     : "Once a day you get a short list of accounts that don't follow you back, to unfollow by hand. Grok Bot makes the list; this routine never unfollows anyone. For automatic unfollows, add X unfollows (automatic) instead.")
                    .font(.callout).foregroundStyle(.secondary)
            case .xUnfollows?:
                sourcePicker
                if source != "safari" {
                    PathField(label: "Grok Bot's list", prompt: "Optional (Hmunmawi's unfollow-queue.json)", text: param("file"), folders: false)
                }
                TextField("Unfollows a day (at most \(XUnfollow.maxPerDay))", text: param("per_day"), prompt: Text("\(XUnfollow.defaultPerDay)")).input(.number, param("per_day"))
                TextField("Only between", text: param("window"), prompt: Text(XUnfollow.defaultWindow)).input(.text(20), param("window"))
                TextField("Always keep", text: param("keep"), prompt: Text("handles, comma separated")).input(.list, param("keep"))
                Text("Unfollows accounts that don't follow you back, for you, through your own Safari login: one tab per account, checked (right person, signed in as you, says Following, no \"Follows you\"), Following → Unfollow, checked again, tab closed. At least 10 minutes apart, spread through the window. The list is made once (from \(source == "safari" ? "your Following page" : "Grok Bot's file")) and never grows by itself; mutuals, your keeps and accounts with 50,000+ followers are never on it. Anything odd on X (login page, challenge, rate limit, an error, the wrong account) stops it for the day and tells you once. Automated actions can get an X account limited; keep the number low.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                let saved = MyRoutines.read().contains { $0.id == routine.id }
                if saved { Text(XUnfollower.shared.status(routine)).font(.callout.monospacedDigit()).foregroundStyle(.secondary).textSelection(.enabled) }
                HStack {
                    Button("Try 3 (no unfollow)") { xRun { await XUnfollower.shared.tryOut(routine, count: 3) } }
                        .accessibilityIdentifier("xunfollow.try")
                    if saved {
                        Button("Rebuild list") { xRun { await XUnfollower.shared.rebuild(routine) } }
                        Button("Resume") { XUnfollower.shared.resume(routine); xNote = "Resumed: it carries on at its next time." }
                    }
                    if xBusy { ProgressView().controlSize(.small) }
                }
                .disabled(xBusy)
                if let xNote { Text(xNote).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("xunfollow.note") }
            case .followUps?:
                Text("Reads your outreach list (agents add to it with hm outreach-add). One follow-up per outlet.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Edit the outreach list") { openSheet?({ AnyView(OutreachEditor().buttonStyle(.pill)) }) }
            case .morningStory?:
                Toggle("Add one line from your AI", isOn: Binding(get: { routine.params?["ai"] == "1" }, set: { on in
                    var p = routine.params ?? [:]; p["ai"] = on ? "1" : nil; routine.params = p.isEmpty ? nil : p
                }))
                if routine.params?["ai"] == "1" {
                    TextField("Most it may spend a month (USD)", text: param("cap"), prompt: Text("1")).input(.number, param("cap"))
                }
                Text("The story itself never needs AI. With this on, your AI adds one sentence from your numbers; only you see it.")
                    .font(.callout).foregroundStyle(.secondary)
            case .offerExpiry?:
                TextField("Warn this many days before", text: param("days"), prompt: Text("30,7,1")).input(.numberList, param("days"))
            case .macJob?:
                Picker("Mac job", selection: param("label")) {
                    Text("Choose one").tag("")
                    ForEach(MacAutomations.shared.jobs.map(\.label).sorted(), id: \.self) { Text($0).tag($0) }
                }
                Toggle("Take over its own timer", isOn: Binding(get: { routine.params?["takeover"] == "1" }, set: { on in
                    var p = routine.params ?? [:]; p["takeover"] = on ? "1" : nil; routine.params = p
                }))
                Text("macOS still runs the job exactly as its file says (command, logs, check-ins); Hmunmawi starts it on this schedule. Taking over its own timer backs up the job's file and removes its schedule so it never runs twice; switch this off or delete the routine to put the original back. While Hmunmawi is quit, a taken-over job waits until Hmunmawi opens again.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Picker("Every", selection: Binding(get: { routine.every ?? "" }, set: { routine.every = $0.isEmpty ? nil : $0; routine.catchUp = $0.isEmpty ? 120 : Int($0.prefix { $0.isNumber }) })) {
                    Text("At times of day").tag("")
                    ForEach(["1 min", "5 min", "15 min", "30 min", "60 min"], id: \.self) { Text($0).tag($0) }
                }
            case .script?:
                PathField(label: "Script", prompt: "Choose the program or script", text: param("command"), folders: false)
                TextField("Extra options (optional)", text: param("args"), prompt: Text("scripts/job.py --weekly")).input(.text(500), param("args"))
                PathField(label: "Run in folder", prompt: "Optional", text: param("folder"), folders: true)
                PathField(label: "Settings file", prompt: "Optional: KEY=VALUE lines the script gets", text: param("env"), folders: false)
                Toggle("Try out first (records what would happen, changes nothing)", isOn: Binding(get: { routine.params?["try"] == "1" }, set: { on in
                    var p = routine.params ?? [:]; p["try"] = on ? "1" : nil; routine.params = p
                }))
                if routine.params?["try"] == "1" {
                    TextField("Try-out switch (the word your script uses for a practice run)", text: param("try_arg"), prompt: Text("--dry-run")).input(.text(100), param("try_arg"))
                }
                Picker("Every", selection: Binding(get: { routine.every ?? "" }, set: { routine.every = $0.isEmpty ? nil : $0; routine.catchUp = $0.isEmpty ? 120 : Int($0.prefix { $0.isNumber }) })) {
                    Text("At a time of day").tag("")
                    ForEach(["1 min", "5 min", "15 min", "30 min", "60 min"], id: \.self) { Text($0).tag($0) }
                }
                Picker("Time limit", selection: Binding(get: { routine.params?["limit_min"] ?? "10" }, set: { v in
                    var p = routine.params ?? [:]; p["limit_min"] = v == "10" ? nil : v; routine.params = p
                })) {
                    ForEach(["10", "30", "60"], id: \.self) { Text("\($0) minutes").tag($0) }
                }
                Text("Runs the file directly (no shell), up to its time limit, and keeps its output. Exit 0 (or 75, \"not due\") is fine; anything else counts as failed. Your script sends its own messages.")
                    .font(.callout).foregroundStyle(.secondary)
                if FileManager.default.fileExists(atPath: ScriptRunner.logURL(routine.id).path) {
                    Button("Show output") { NSWorkspace.shared.open(ScriptRunner.logURL(routine.id)) }
                }
            case .judge?:
                Text("Each morning it looks at the changes you asked it to watch; any that have had their time get a verdict.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Changes I'm watching") { openSheet?({ AnyView(ChangesEditor().buttonStyle(.pill)) }) }
            case .outreachReplies?:
                Text("Every 30 minutes it reads your mail list (every folder) and matches it to your outreach: answers, listing decisions, bounces, auto-replies and follow-ups you sent. Each one waits in Log → Outreach for your tap; nothing is sent.")
                    .font(.callout).foregroundStyle(.secondary)
            case .keyWatch?:
                Toggle("Also tell me when a connection hasn't worked for a day", isOn: Binding(get: { routine.params?["long"] == "1" }, set: { on in
                    var p = routine.params ?? [:]; p["long"] = on ? "1" : nil; routine.params = p.isEmpty ? nil : p
                }))
                Text("Checks every hour. When a connection fails twice in a row because its key or login was refused, expired or revoked, it tells you once; and again when it works. With the switch on, a connection that has failed for 24 hours for any other reason is told once too.")
                    .font(.callout).foregroundStyle(.secondary)
            case .serviceWatch?:
                Toggle("Sentry problems (crashes, website down, late jobs)", isOn: flag("issues"))
                Toggle("Website deploys (Vercel)", isOn: flag("deploys"))
                TextField("Minutes a new commit may wait for a deploy", text: param("behind"), prompt: Text("10")).input(.number, param("behind"))
                Text("Every 15 minutes it reads what your Sentry and Vercel connections found: each new open Sentry problem once in plain words (a new crash, a website Sentry Uptime saw down, a job Sentry Crons saw late), and again when it closes. When production doesn't run your branch's newest commit (no deploy started, or the build failed), it tells you and puts a Redeploy in Log → Waiting: nothing deploys until you approve it. Sentry needs the event:read scope for problems.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .heartbeat?:
                TextField("Sentry DSN", text: param("dsn"), prompt: Text("https://…@o….ingest.sentry.io/…")).input(.url, param("dsn"))
                TextField("Monitor name", text: param("slug"), prompt: Text("hmunmawi-mac")).input(.identifier, param("slug"))
                Picker("Check in every", selection: Binding(get: { routine.every ?? "15 min" }, set: { routine.every = $0; routine.catchUp = Int($0.prefix { $0.isNumber }) })) {
                    ForEach(["5 min", "15 min", "30 min", "60 min"], id: \.self) { Text($0).tag($0) }
                }
                Toggle("Report a problem when a Mac job I watch is failing", isOn: Binding(get: { routine.params?["jobs"] == "1" }, set: { on in
                    var p = routine.params ?? [:]; p["jobs"] = on ? "1" : nil; routine.params = p.isEmpty ? nil : p
                }))
                Text("Sends a check-in to a Sentry Crons monitor (Sentry makes the monitor itself on the first one). When check-ins stop because this Mac is asleep, off or Hmunmawi isn't running, Sentry tells you by its own email or app, the one problem Hmunmawi can't tell you itself. The DSN is in Sentry → Settings → Projects → your project → Client Keys. Sentry's free plan includes one cron monitor.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .linkCheck?:
                TextField("Website or sitemap address", text: param("url"), prompt: Text("https://mysite.com")).input(.url, param("url"))
                TextField("Pages to read (up to \(LinkCheck.maxPages))", text: param("pages"), prompt: Text("50")).input(.number, param("pages"))
                Text("Reads your sitemap (or the page you give), collects every link to another website and checks it, four at a time. A link is called dead only when two runs in a row found it gone (404, 410 or no such site); sites that block checkers or are briefly down never count. App Store links are checked with Apple's public lookup. It tells you new dead links once and never edits your site.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let st = try? JSONDecoder().decode(LinkCheck.State.self, from: Data(contentsOf: Routines.linkStateURL(routine.id))) {
                    Text("Last run \(st.lastRun ?? "-"): \(st.pages ?? 0) pages, \(st.checked ?? 0) links, \(st.dead.count) dead, \(st.suspects.count) to check again.")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary).textSelection(.enabled)
                }
            case .pythonCheck?:
                TextField("Also check these venv folders (optional)", text: param("folders"), prompt: Text("~/work/.venv")).input(.text(800), param("folders"))
                Picker("When one is broken", selection: Binding(get: { routine.params?["repair"] ?? "ask" }, set: { var p = routine.params ?? [:]; p["repair"] = $0 == "ask" ? nil : $0; routine.params = p.isEmpty ? nil : p })) {
                    Text("Tell me, I repair it").tag("ask")
                    Text("Repair it at once").tag("auto")
                }
                Text("Finds the Python environments (venvs) your script routines and Mac jobs run with. When one breaks (usually after Homebrew upgrades Python), it tells you once with the fix. A repair keeps the old folder beside it (.broken-<date>), makes a fresh one with this Mac's python3 and puts back the packages it noted while the venv still worked.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                PythonVenvList(extra: routine.params?["folders"])
            default: EmptyView()
            }
            if let kind = RoutineKind(rawValue: routine.does ?? ""), !kind.builtIn {
                Picker("Tell me by", selection: Binding(get: { routine.tell ?? "" }, set: { routine.tell = $0.isEmpty ? nil : $0 })) {
                    Text("iMessage, else ntfy").tag("")
                    Text("iMessage").tag("imessage")
                    Text("ntfy").tag("ntfy")
                }
                Toggle("Also tell me each time it runs", isOn: Binding(get: { routine.params?["done"] == "1" }, set: { on in
                    var p = routine.params ?? [:]; p["done"] = on ? "1" : nil; routine.params = p.isEmpty ? nil : p
                }))
                Toggle("Also put it in my Calendar", isOn: Binding(get: { routine.params?["calendar"] == "1" }, set: { on in
                    var p = routine.params ?? [:]; p["calendar"] = on ? "1" : nil; routine.params = p.isEmpty ? nil : p
                    if on { Task { await Permissions.shared.askCalendar() } }
                }))
            }
            if routine.every == nil && builtIn == nil {
            DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
            TextField("Also at (optional)", text: $alsoAt, prompt: Text("10:00, 16:00"))
                .input(.text(120), $alsoAt)
            LabeledContent("Days") {
                HStack(spacing: 4) {
                    ForEach(days, id: \.self) { d in
                        Toggle(d, isOn: Binding(
                            get: { routine.days.isEmpty || routine.days.contains(d) },
                            set: { on in
                                var set = Set(routine.days.isEmpty ? days : routine.days)
                                if on { set.insert(d) } else if set.count > 1 { set.remove(d) }
                                routine.days = set.count == 7 ? [] : days.filter(set.contains)
                            }))
                        .toggleStyle(.button)
                    }
                }
            }
            }
            TextField("Notes", text: $routine.detail, axis: .vertical).lineLimit(2...4).input(.text(600), $routine.detail)
            if routine.does == nil {
                PathField(label: "File it leaves each day (optional; {date} = the day)", prompt: "Optional", text: $proof, folders: false)
                Text("A file it writes when it runs. If it's there today, the dot turns green. {date} becomes today's date.")
                    .font(.callout).foregroundStyle(.secondary)
                if !proof.isEmpty {
                    Picker("Tell me if it's late", selection: Binding(get: { routine.params?["late"] ?? "" }, set: { v in
                        var p = routine.params ?? [:]; p["late"] = v.isEmpty ? nil : v; routine.params = p.isEmpty ? nil : p
                    })) {
                        Text("Don't").tag("")
                        ForEach(BotSetup.lateOptions, id: \.self) { Text("\(BotSetup.lateText($0)) after its time").tag(String($0)) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 600, idealWidth: 640)
        .onChange(of: routine) { _, v in draft.routine = v }
        .onChange(of: time) { _, v in draft.time = v }
        .onChange(of: proof) { _, v in draft.proof = v }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    let c = Calendar.current.dateComponents([.hour, .minute], from: time)
                    let first = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
                    // Only valid times are kept ("25:00" or words are dropped), sorted, each once.
                    routine.at = RoutineSchedule.times(([first] + alsoAt.split(separator: ",").map(String.init)).joined(separator: ","))
                        .map { String(format: "%02d:%02d", $0.hour, $0.minute) }.joined(separator: ",")
                    if routine.at.isEmpty { routine.at = first }
                    routine.proof = proof.isEmpty || routine.does != nil ? nil : proof
                    if routine.proof == nil, routine.params?["late"] != nil {   // no file, nothing to be late
                        routine.params?["late"] = nil
                        if routine.params?.isEmpty == true { routine.params = nil }
                    }
                    if routine.id.isEmpty || routine.id.count > 64 { routine.id = UUID().uuidString }
                    // A routine Hmunmawi runs is signed when you save it here; one edited elsewhere waits for your OK.
                    if routine.does != nil {
                        if routine.mode == nil { routine.mode = "hands-on" }
                        if routine.catchUp == nil { routine.catchUp = routine.every.flatMap { Int($0.prefix { $0.isNumber }) } ?? 120 }
                    }
                    routine = Routines.shared.signed(routine)   // a bot's or cloud job too: its text goes to that bot
                    onSave(routine)
                    dismiss()
                }
                .disabled(routine.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}


/// A file or folder chosen with Choose…: shows its name and a short "~/…/parent" line (full path on hover) instead
/// of a long raw path; Edit reveals the text field for typing or pasting a path.
struct PathField: View {
    let label: String
    let prompt: String
    @Binding var text: String
    let folders: Bool
    @State private var editing = false

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                if editing || text.isEmpty {
                    TextField(label, text: $text, prompt: Text(prompt)).labelsHidden().input(.path, $text)
                        .onSubmit { editing = false }
                } else {
                    let url = URL(fileURLWithPath: (text as NSString).expandingTildeInPath)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(url.lastPathComponent).font(.callout.weight(.medium))
                        Text(Self.short(url.deletingLastPathComponent().path))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    .help(text)
                    Button("Edit") { editing = true }.buttonStyle(.borderless)
                }
                Button(text.isEmpty ? "Choose…" : "Change…") {
                    let panel = NSOpenPanel(); panel.canChooseFiles = !folders; panel.canChooseDirectories = folders
                    if panel.runModal() == .OK, let u = panel.url { text = u.path; editing = false }
                }
            }
        }
    }

    /// "/Users/me/Documents/repos/hub/.venv/bin" → "~/…/hub/.venv/bin" (home as ~, at most the last 3 folders).
    nonisolated static func short(_ path: String) -> String {
        let home = NSHomeDirectory()
        let p = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        let parts = p.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count > 4 else { return p.isEmpty ? "/" : p }
        let lead = p.hasPrefix("~") ? "~/…/" : "/…/"
        return lead + parts.suffix(3).joined(separator: "/")
    }
}
