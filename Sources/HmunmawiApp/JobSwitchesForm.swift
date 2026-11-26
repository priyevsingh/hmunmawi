import AppKit
import Combine
import HmunmawiCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Jobs: one-tap on/off switches for the jobs your own scripts run (social channels, warm-up per
/// platform, anything else your workspace puts in its switch file). Hmunmawi only edits the file; your scripts read
/// it on their next run. Pausing a whole scheduled Mac job is on its row in Automations (… → Pause).
struct JobSwitchesForm: View {
    let model: AppModel
    /// A switch file picked here; empty = the one your workspace points to.
    @AppStorage("HMSwitchFile") private var chosen = ""
    @State private var loaded: SwitchFile.Loaded?
    @State private var problem: SwitchFile.Problem?
    @State private var url: URL?
    @State private var note: String?
    private let tick = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    /// Jobs Hmunmawi itself runs that act for you or watch your services, switched on and off here as in Automations.
    @State private var builtIn: [MyRoutine] = []
    /// The kind whose routine form is open (Set up…).
    @State private var settingUp: RoutineKind?
    static let ownJobKinds: [RoutineKind] = [.xUnfollows, .serviceWatch, .heartbeat, .linkCheck, .pythonCheck]

    var body: some View {
        Form {
            Section {
                ForEach(Self.ownJobKinds.filter { k in !builtIn.contains { $0.does == k.rawValue } }, id: \.self) { k in
                    LabeledContent {
                        Button("Set up…") { settingUp = k }
                            .accessibilityIdentifier("jobs.setup.\(k.rawValue)")
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(k.title)
                            Text("Not set up").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(builtIn, id: \.id) { r in
                    Toggle(isOn: Binding(get: { r.off != true }, set: { setOn(r, $0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.title)
                            Text(status(r)).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("switch.routine.\(r.id)")
                }
            } header: { Text("Run by Hmunmawi") } footer: {
                Text("Each is off until you set it up (here, or in Automations → +). X unfollows also stop with the X switch below (or X unfollows (automatic) in your switch file). Nothing here deploys, repairs or posts without your OK.")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let loaded {
                ForEach(SwitchFile.groupOrder, id: \.self) { group in
                    let rows = loaded.switches.filter { $0.group == group }
                    if !rows.isEmpty {
                        Section {
                            ForEach(rows) { s in row(s) }
                        } header: {
                            Text(group)
                        } footer: {
                            if group == SwitchFile.warmupGroup {
                                Text("On means the account is already warmed up: no warm-up steps, only real post ideas.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                Section {
                    if let url, let problem {
                        Label(problem.description, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Brand.caution)
                        Text(url.path).font(.footnote).monospaced().foregroundStyle(.secondary).textSelection(.enabled)
                    } else {
                        Label("No switch file yet", systemImage: "switch.2")
                        Text("Your own scripts can read a small JSON file of on/off values (for example {\"reddit\": true, \"discord\": false}). Choose that file, or put it in your workspace as config/hmunmawi-switches.json, and its switches show here.")
                            .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                } header: { Text("Jobs & channels") }
            }
            Section {
                LabeledContent("Switch file") {
                    HStack {
                        Text(url?.lastPathComponent ?? "None").foregroundStyle(.secondary)
                        if let url { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                        Button("Choose…") { choose() }
                        if !chosen.isEmpty { Button("Use workspace file") { chosen = ""; reload() } }
                    }
                }
                if let note { Label(note, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary) }
            } footer: {
                Text("Hmunmawi changes only the value you flip; the rest of the file stays exactly as it was. Your scripts pick it up on their next run. To stop a whole scheduled Mac job, use … → Pause on its row in Automations.")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: Binding(get: { settingUp != nil }, set: { if !$0 { settingUp = nil } })) {
            if let k = settingUp {
                NewRoutineForm(kind: k) { reload(); note = "\(k.title) is set up; switch it on or off here." }
            }
        }
        .onAppear { reload() }
        .onChange(of: chosen) { reload() }
        .onReceive(tick) { _ in reload() }
    }

    private func row(_ s: SwitchFile.Switch) -> some View {
        Toggle(isOn: Binding(get: { s.value }, set: { flip(s, to: $0) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(s.label)
                Text(s.isSet ? s.help : "\(s.help) Not in the file yet: \(s.value ? "on" : "off") by default.")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .accessibilityIdentifier("switch.\(s.id)")
        .accessibilityLabel(s.label)
    }

    private func status(_ r: MyRoutine) -> String {
        if r.does == RoutineKind.xUnfollows.rawValue { return XUnfollower.shared.status(r) }
        let when = r.every.map { "Every \($0)" } ?? MyRoutines.when(r)
        let last = r.last.map { " · last \($0["status"] ?? "") \($0["date"] ?? "")" } ?? ""
        return when + last
    }

    private func setOn(_ r: MyRoutine, _ on: Bool) {
        var list = MyRoutines.read()
        guard let i = list.firstIndex(where: { $0.id == r.id }) else { return }
        list[i].off = on ? nil : true   // `off` isn't signed: the routine stays approved
        MyRoutines.write(list)
        note = "\(r.title) is now \(on ? "on" : "off")."
        reload()
        Task { await model.recordJobAction("routine: \(r.id) \(on ? "on" : "off")", label: r.title) }
    }

    private func reload() {
        let kinds = Set(Self.ownJobKinds.map(\.rawValue))
        let mine = MyRoutines.read().filter { kinds.contains($0.does ?? "") }
        if mine != builtIn { builtIn = mine }
        let u = SwitchFile.locate(chosen: chosen)
        url = u
        guard let u else { loaded = nil; problem = nil; return }
        switch SwitchFile.load(u) {
        case .success(let l): if l != loaded { loaded = l }; problem = nil
        case .failure(let p): loaded = nil; problem = p
        }
    }

    private func flip(_ s: SwitchFile.Switch, to value: Bool) {
        guard let url else { return }
        switch SwitchFile.set(s.path, to: value, in: url) {
        case .success(let l):
            loaded = l
            note = "\(s.label) is now \(value ? "on" : "off")."
            Task { await model.recordJobAction("switch: \(s.id) \(value ? "on" : "off")", label: url.lastPathComponent) }
        case .failure(let p):
            note = p.description
            reload()
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.message = "Choose the JSON file of on/off switches your scripts read."
        if let url { panel.directoryURL = url.deletingLastPathComponent() }
        if panel.runModal() == .OK, let u = panel.url { chosen = u.path }
    }
}
