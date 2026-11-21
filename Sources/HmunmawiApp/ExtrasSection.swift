import AppKit
import HmunmawiCore
import SwiftUI

/// Settings → General → Your extras: what your own setup switches on, for everyone. Each row is set here, by an agent
/// (`hm set extras.*`) or by your workspace's `config/hmunmawi-extras.json`. A row an owner settings file sets is
/// shown but can't be changed here.
struct ExtrasSection: View {
    @State private var extras = Extras.current
    @State private var xFile = XFileFeed.shared
    @State private var zoneNote: String?

    var body: some View {
        Section {
            let items = extras.items(xFileSetting: xFile.path)
            ForEach(items, id: \.id) { item in row(item) }
            fileLine
        } header: { Text("Your extras") } footer: {
            Text("Your private workspace can switch these on too: put config/hmunmawi-extras.json in the workspace folder (the Private workspace guide has a sample). A choice made here wins over that file\(extras.owner.isOn ? "; your owner settings file wins over both" : ""). Nothing here is a key, and nothing is read until a feature needs it.")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .hmExtrasChanged)) { _ in extras = Extras.current }
    }

    @ViewBuilder private func row(_ item: ExtraItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Label(item.title, systemImage: item.on ? "checkmark.circle.fill" : "circle")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(item.on ? Color.primary : Color.secondary)
                Spacer()
                control(item)
            }
            Text(caption(item)).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("extras.\(item.id)")
    }

    private func caption(_ item: ExtraItem) -> String {
        var parts: [String] = []
        if let v = item.value { parts.append(v) }
        switch item.source {
        case .owner: parts.append("from your owner settings file")
        case .workspace: parts.append("from your workspace file")
        case .build: parts.append("in this build")
        case .settings, .none: break
        }
        if item.id == "extras.time_zone", let zoneNote { parts.append(zoneNote) }
        parts.append(item.note)
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func control(_ item: ExtraItem) -> some View {
        let locked = item.source == .owner
        switch item.id {
        case "extras.workspace", "extras.key_folder", "extras.repos_folder":
            HStack {
                Button("Choose…") { if let u = Self.chooseFolder() { set(item.id, u.path) } }
                if extras.settingsValue(item.id) != nil { Button("Clear") { set(item.id, nil) } }
            }.disabled(locked)
        case "x.file":
            HStack {
                Button("Choose…") { if let u = Self.chooseFile() { xFile.path = u.path; changed() } }
                if !xFile.path.isEmpty { Button("Clear") { xFile.path = ""; changed() } }
            }
        case "extras.ai_pause_card", "extras.zoho_mail":
            Toggle("", isOn: Binding(get: { item.on }, set: { set(item.id, $0 ? "true" : "false") }))
                .labelsHidden().toggleStyle(.switch).disabled(locked)
        case "extras.time_zone":
            Picker("", selection: Binding(get: { extras.settings.timeZone ?? "" },
                                          set: { set(item.id, $0.isEmpty ? nil : $0) })) {
                Text(extras.file.timeZone.flatMap(TimeZone.init(identifier:)).map { "As the workspace file says (\($0.identifier))" }
                     ?? "This Mac's (\(Extras.macZone.identifier))").tag("")
                ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().frame(maxWidth: 260).disabled(locked)
        default:
            Text(item.on ? "On" : "Not in this build").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var fileLine: some View {
        if let url = extras.workspaceFileURL {
            let short = url.path.replacingOccurrences(of: URL.homeDirectory.path, with: "~")
            switch extras.fileState {
            case .ok: Label("Workspace file read: \(short)", systemImage: "doc.text").font(.footnote).foregroundStyle(.secondary)
            case .unreadable(let why): Label("Workspace file not used (\(why)): \(short)", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(Brand.caution)
            case .missing, .none: Label("No workspace file yet (\(short)); the extras above are set here only.", systemImage: "doc")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func set(_ id: String, _ value: String?) {
        ExtrasStore.set(id, value)
        if id == "extras.time_zone" {
            ExtrasStore.applyZone()
            zoneNote = "applied; a few dates already on screen update after the next start"
        }
        changed()
    }

    private func changed() { NotificationCenter.default.post(name: .hmExtrasChanged, object: nil) }

    static func chooseFolder() -> URL? {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false; p.prompt = "Choose"
        return p.runModal() == .OK ? p.url : nil
    }

    static func chooseFile() -> URL? {
        let p = NSOpenPanel()
        p.canChooseDirectories = false; p.canChooseFiles = true; p.allowsMultipleSelection = false; p.prompt = "Choose"
        p.allowedContentTypes = [.json]
        return p.runModal() == .OK ? p.url : nil
    }
}

extension Notification.Name { static let hmExtrasChanged = Notification.Name("HMExtrasChanged") }

extension Extras {
    /// The value this Mac's settings hold for a row (nil = not set here).
    func settingsValue(_ id: String) -> String? {
        switch id {
        case "extras.workspace": settings.workspace
        case "extras.key_folder": settings.keyFolder
        case "extras.repos_folder": settings.reposFolder
        case "extras.time_zone": settings.timeZone
        case "extras.ai_pause_card": settings.aiPauseCard.map { $0 ? "true" : "false" }
        case "extras.zoho_mail": settings.zohoMail.map { $0 ? "true" : "false" }
        default: nil
        }
    }
}

/// Saving Your extras (Settings and `hm set extras.*` both come here).
@MainActor
enum ExtrasStore {
    nonisolated static func defaultsKey(_ id: String) -> String? {
        switch id {
        case "extras.workspace": Extras.Key.workspace
        case "extras.key_folder": Extras.Key.keyFolder
        case "extras.repos_folder": Extras.Key.reposFolder
        case "extras.ai_pause_card": Extras.Key.aiPauseCard
        case "extras.zoho_mail": Extras.Key.zohoMail
        case "extras.time_zone": Extras.Key.timeZone
        default: nil
        }
    }

    /// Saves one extra (nil clears it, so the workspace file or "off" applies again). Paths are kept with `~`.
    static func set(_ id: String, _ value: String?) {
        guard let key = defaultsKey(id) else { return }
        let d = UserDefaults.standard
        if let value {
            if value == "true" || value == "false", id == "extras.ai_pause_card" || id == "extras.zoho_mail" {
                d.set(value == "true", forKey: key)
            } else {
                d.set(value.replacingOccurrences(of: URL.homeDirectory.path, with: "~", options: .anchored), forKey: key)
            }
        } else {
            d.removeObject(forKey: key)
        }
        Extras.reload()
        if id == "extras.time_zone" { applyZone() }
        NotificationCenter.default.post(name: .hmExtrasChanged, object: nil)
    }

    static func applyZone() {
        Extras.reload()
        Extras.applyProcessZone()
    }
}
