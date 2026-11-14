import Foundation
import HmunmawiCore
import SwiftUI

/// A business you run: your apps, or a website like a tour company's. Each one tracks its own sources;
/// the toolbar switcher shows one project or all. Stored as plain JSON (projects.json next to the app's
/// data) so agents and scripts can read and edit it.
struct Project: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable { case apps, website, other }
    var id: String = UUID().uuidString
    var name: String
    var kind: Kind
    /// Names that mark an item as this project's (app, site or channel name; part of the name is enough).
    var members: [String]
    /// Mac jobs whose label starts with one of these belong to this project.
    var jobPrefixes: [String] = []
    /// Also show items that belong to no project (Mac, mail, all-apps totals). On for your main project.
    var includeShared = false

    var symbol: String {
        switch kind { case .apps: "app.badge.fill"; case .website: "globe"; case .other: "square.grid.2x2.fill" }
    }
}

@MainActor @Observable
final class ProjectStore {
    static let shared = ProjectStore()
    private(set) var projects: [Project] = []
    /// nil = all projects.
    var selectedID: String? { didSet { UserDefaults.standard.set(selectedID, forKey: "HMProject"); onChange?() } }
    var onChange: (() -> Void)?
    private var file: URL {
        URL.hmSupport.appending(path: "projects.json")
    }

    init() {
        if let data = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([Project].self, from: data) {
            projects = list
        }
        selectedID = UserDefaults.standard.string(forKey: "HMProject")
    }

    var selected: Project? { projects.first { $0.id == selectedID } }

    func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? enc.encode(projects).write(to: file, options: .atomic)
        onChange?()
    }

    func update(_ p: Project) {
        if let i = projects.firstIndex(where: { $0.id == p.id }) { projects[i] = p } else { projects.append(p) }
        save()
    }

    func remove(_ p: Project) {
        projects.removeAll { $0.id == p.id }
        if selectedID == p.id { selectedID = nil }
        save()
    }

    /// Which project an item (by its app/site name) belongs to; nil when none claims it.
    func owner(of app: String?) -> Project? {
        guard let app, !app.isEmpty else { return nil }
        return projects.first { p in p.members.contains { !$0.isEmpty && app.localizedCaseInsensitiveContains($0) } }
    }

    /// Whether an item shows under the selected project.
    func shows(_ app: String?) -> Bool {
        guard let p = selected else { return true }
        if let o = owner(of: app) { return o.id == p.id }
        return p.includeShared
    }

    /// True when a Mac job belongs to one of your projects (its label matches a project's job prefixes).
    func belongs(jobLabel: String) -> Bool {
        projects.contains { $0.jobPrefixes.contains { jobLabel.hasPrefix($0) } }
    }

    func shows(jobLabel: String?) -> Bool {
        guard let p = selected else { return true }
        guard let label = jobLabel else { return p.includeShared }
        if let o = projects.first(where: { $0.jobPrefixes.contains { label.hasPrefix($0) } }) { return o.id == p.id }
        return p.includeShared
    }

    /// Names that mark text (a routine's title, a log entry) as a project's: its name, its first word when that is
    /// distinctive ("Sunny" for "Sunny Trips"), its members and its job prefixes.
    private func needles(_ q: Project) -> [String] {
        let first = q.name.split(separator: " ").first.map(String.init) ?? ""
        return (q.members + q.jobPrefixes + [q.name, first.count >= 4 ? first : ""]).map { $0.lowercased() }.filter { $0.count >= 3 }
    }

    private func mentions(_ q: Project, _ text: String) -> Bool { needles(q).contains { text.contains($0) } }

    /// Whether a routine, bot job or log entry described by `text` shows under the selected project: it names the
    /// project, or it names no project at all and shared items are included. Everything when no project is picked.
    func shows(text: String) -> Bool {
        guard let p = selected else { return true }
        let t = text.lowercased()
        if mentions(p, t) { return true }
        if projects.contains(where: { $0.id != p.id && mentions($0, t) }) { return false }
        return p.includeShared
    }

    /// The activity log for the selected project (see `shows(text:)`).
    func scopedAudit(_ entries: [AuditEntry]) -> [AuditEntry] {
        guard selected != nil else { return entries }
        return entries.filter { shows(text: ($0.subject ?? "") + " " + $0.action + " " + String(describing: $0.detail)) }
    }

    /// First run: one "My apps" project with every connected app. Websites, Mac job prefixes and other projects
    /// are added by you in Settings → Projects (saved projects are never rebuilt).
    func suggest(from events: [StoredEvent]) {
        guard projects.isEmpty else { return }
        var apps = Project(name: "My apps", kind: .apps, members: [], includeShared: true)
        apps.members = Set(events.filter { $0.kind == "app.snapshot" }.compactMap(\.app)).sorted()
        guard !apps.members.isEmpty else { return }
        projects = [apps]
        save()
    }
}

/// Settings → Projects: add, rename and shape each project.
struct ProjectsForm: View {
    @State private var store = ProjectStore.shared

    var body: some View {
        Form {
            ForEach(store.projects) { p in ProjectSection(project: p) }
            Section {
                Menu("New project") {
                    ForEach(Project.Kind.allCases, id: \.self) { kind in
                        Button(kind == .apps ? "Apps" : kind == .website ? "Website or blog" : "Other") {
                            store.update(Project(name: kind == .website ? "New website" : "New project", kind: kind, members: []))
                        }
                    }
                }
                .fixedSize()
            } footer: {
                HStack(spacing: 6) {
                    Text("Pick a project in the toolbar to see only its numbers.").font(.footnote).foregroundStyle(.secondary)
                    InfoTip("A project collects the apps, websites, channels and Mac jobs of one business. Items match by name (part of the name is enough); Mac jobs by the start of their label. Shared items (Mac, mail, totals) show in the project with “Include shared”. Saved as projects.json for agents and scripts.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ProjectSection: View {
    @State var project: Project
    @State private var store = ProjectStore.shared

    var body: some View {
        Section {
            TextField("Name", text: $project.name).accessibilityLabel("Project name").input(.name, $project.name)
            Picker("Type", selection: $project.kind) {
                Text("Apps").tag(Project.Kind.apps)
                Text("Website or blog").tag(Project.Kind.website)
                Text("Other").tag(Project.Kind.other)
            }
            CommaListField(title: "Apps, sites or channels", prompt: "e.g. My App, mysite.com",
                           label: "Apps, sites or channels in this project", items: $project.members)
            CommaListField(title: "Mac jobs starting with", prompt: "e.g. com.mycompany.",
                           label: "Mac job label prefixes for this project", items: $project.jobPrefixes)
            Toggle("Include shared items", isOn: $project.includeShared)
            HStack {
                Button("Remove project", role: .destructive) { store.remove(project) }
                Spacer()
                Button("Save") { store.update(project) }.buttonStyle(.pillProminent)
            }
        } header: {
            Label(project.name, systemImage: project.symbol)
        }
    }
}

/// The toolbar switcher: All, or one project.
struct ProjectSwitcher: View {
    var detail: DetailPresenter
    @State private var store = ProjectStore.shared

    var body: some View {
        if !store.projects.isEmpty {
            // A toolbar menu like Apple's own (icon + name + chevron), crisp label text, no boxed pop-up look.
            let current = store.projects.first { $0.id == store.selectedID }
            Menu {
                Picker("Project", selection: Binding(get: { store.selectedID ?? "" }, set: { newID in
                    detail.closeAll()
                    store.selectedID = newID.isEmpty ? nil : newID
                })) {
                    Label("All projects", systemImage: "square.grid.2x2").tag("")
                    Divider()
                    ForEach(store.projects) { Label($0.name, systemImage: $0.symbol).tag($0.id) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(current?.name ?? "All projects", systemImage: current?.symbol ?? "square.grid.2x2")
                    .labelStyle(.titleAndIcon)
                    .font(.body.weight(.semibold))
            }
            .menuIndicator(.visible)
            .fixedSize()
            .help("Show one project's numbers, or all")
            .accessibilityLabel("Project: \(current?.name ?? "All projects")")
        }
    }
}

/// A comma-separated list typed as free text: the list updates as you type, but the text you type is kept as is
/// (spaces and a trailing comma survive), and it is tidied only when you leave the field.
struct CommaListField: View {
    let title: String, prompt: String, label: String
    @Binding var items: [String]
    @State private var text = ""
    @FocusState private var focused: Bool

    nonisolated static func parse(_ s: String) -> [String] {
        s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var body: some View {
        TextField(title, text: $text, prompt: Text(prompt))
            .accessibilityLabel(label)
            .input(.list, $text)
            .focused($focused)
            .onAppear { text = items.joined(separator: ", ") }
            .onChange(of: text) { _, new in items = Self.parse(new) }
            .onChange(of: focused) { _, now in if !now { text = items.joined(separator: ", ") } }
            .onSubmit { text = items.joined(separator: ", ") }
    }
}
