import AppKit
import HmunmawiCore
import SwiftUI

/// Settings → Publish: your numbers as a portal page as one self-contained web page, written to a folder. You choose the
/// sections, can make it safe to show anyone, keep a week of earlier copies, and can have your own upload command
/// run after each publish. The app stays the source; the page is a copy.
struct PublishForm: View {
    let model: AppModel
    @AppStorage(PortalPublisher.titleKey) private var title = ""
    @AppStorage(PortalPublisher.autoKey) private var auto = false
    @AppStorage(PortalPublisher.publicKey) private var publicSafe = false
    @AppStorage(PortalPublisher.commandKey) private var command = ""
    @AppStorage(PortalPublisher.approvedKey) private var approvedSig = ""
    @State private var note: String?
    @State private var uploadNote = PortalUpload.note
    @State private var folderPath = PortalPublisher.folder.path
    @State private var excluded = PortalPublisher.excluded
    @State private var confirmCommand = false

    private var trimmed: String { command.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Form {
            Section {
                TextField("Portal name", text: $title, prompt: Text("My apps"))
                    .input(.text(60), $title)
                LabeledContent("Folder") {
                    HStack {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(URL(fileURLWithPath: folderPath).lastPathComponent).font(.callout.weight(.medium))
                            Text(PathField.short(URL(fileURLWithPath: folderPath).deletingLastPathComponent().path)).font(.caption).foregroundStyle(.secondary)
                        }
                        .help(folderPath)
                        Button("Choose…") { choose() }
                    }
                }
                Toggle("Publish again after each refresh", isOn: $auto)
            } header: { Text("Your portal") } footer: {
                Text("One self-contained web page of your numbers, written to this folder; open it in any browser, on any device. Sample numbers are never published. A dated copy is kept each day for the last 8 days, linked at the bottom as \u{201C}Earlier copies\u{201D}.")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Section {
                let list = PortalPublisher.available(model)
                if list.isEmpty {
                    Text(model.isDemo ? "Connect App Store Connect to choose sections." : "Nothing to publish yet.").foregroundStyle(.secondary)
                }
                ForEach(list, id: \.id) { s in
                    Toggle(s.title, isOn: Binding(
                        get: { !excluded.contains(s.id) },
                        set: { on in if on { excluded.remove(s.id) } else { excluded.insert(s.id) }; PortalPublisher.excluded = excluded }))
                }
            } header: { Text("Sections") } footer: {
                Text("Only sections with something in them are listed. New sections (for example a new connection) are included until you switch them off.")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Safe to show anyone", isOn: $publicSafe)
            } footer: {
                Text("Leaves out every money amount (earned, MRR, per-app earnings, money trends and details), the latest sales list and the list of problems. Downloads, percentages, counts and the crash-free rate stay. Use it for a public \u{201C}open startup\u{201D} page.")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Section {
                HStack(alignment: .firstTextBaseline) {
                    TextField("Upload command", text: $command, prompt: Text("Pick an example, or type your own"), axis: .vertical)
                        .font(.system(.callout, design: .monospaced))
                        .input(.text(500), $command)
                    Menu("Examples") {
                        ForEach(UploadHost.allCases) { h in Button(h.title) { command = h.command } }
                    }
                    .fixedSize()
                }
                if let host = UploadHost.match(trimmed) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Set up once (\(host.title))").font(.callout.weight(.semibold))
                        ForEach(Array(host.steps.enumerated()), id: \.offset) { i, step in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("\(i + 1).").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                                Text(.init(step)).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                if !trimmed.isEmpty {
                    if !approvedSig.isEmpty, approvedSig == PortalPublisher.signature(trimmed) {
                        Label(PortalUpload.running ? "Uploading…" : (uploadNote ?? "Approved. It runs after your next publish."), systemImage: "checkmark.seal")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        HStack {
                            Label("Not approved yet: it won't run.", systemImage: "hand.raised").font(.callout).foregroundStyle(Brand.caution)
                            Spacer()
                            Button("Approve this command…") { confirmCommand = true }
                        }
                    }
                    if !publicSafe {
                        Label("If this puts the page online, protect it with a login (for example Cloudflare Access, free) or switch on \u{201C}Safe to show anyone\u{201D}: the page holds your sales figures.", systemImage: "lock")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: { Text("After publishing (optional)") } footer: {
                Text("Your own command, run in the portal folder after you publish, to put the page wherever you host it (Cloudflare's wrangler, Netlify's CLI, or any copy command of your own). It runs only once you approve its exact text, gets no Hmunmawi keys (your tool uses its own login), stops after 2 minutes, and runs at most every 2 hours when publishing happens by itself. The folder's path is in $HM_PORTAL_DIR.")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Section {
                HStack {
                    Button("Publish now") { publish(open: false) }.disabled(model.isDemo)
                    Button("Publish and open") { publish(open: true) }.disabled(model.isDemo)
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([PortalPublisher.folder.appending(path: "index.html")])
                    }
                    .disabled(PortalPublisher.lastPublished == nil)
                    Spacer()
                }
                if let note { Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                else if model.isDemo { Text("Connect App Store Connect first; sample numbers aren't published.").font(.callout).foregroundStyle(.secondary) }
                else if let d = PortalPublisher.lastPublished {
                    Text("Last published \(Ago.text(d)).").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Run this command after each publish?", isPresented: $confirmCommand) {
            Button("Approve and let it run") { PortalPublisher.approve(trimmed); approvedSig = UserDefaults.standard.string(forKey: PortalPublisher.approvedKey) ?? "" }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(trimmed)\n\nIt runs as you, in the folder \(PathField.short(folderPath)). Approve only a command you understand. Changing the text needs a new approval.")
        }
    }

    private func choose() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.prompt = "Use this folder"
        p.directoryURL = PortalPublisher.folder
        guard p.runModal() == .OK, let url = p.url else { return }
        UserDefaults.standard.set(url.path, forKey: PortalPublisher.folderKey)
        folderPath = url.path
    }

    private func publish(open: Bool) {
        do {
            let file = try PortalPublisher.publish(model)
            note = "Published to \(PathField.short(file.deletingLastPathComponent().path))."
            if open { NSWorkspace.shared.open(file) }
            PortalUpload.afterPublish(manual: true) { uploadNote = $0 }
        } catch {
            note = "Couldn't publish: \(plainError(error))"
        }
    }
}


/// Ready-made upload commands for common hosts, each with the one-time setup it needs (from each host's own docs:
/// Cloudflare's wrangler Pages commands, Netlify's CLI deploy). "my-portal" is the name the user picks.
enum UploadHost: String, CaseIterable, Identifiable {
    case cloudflare, netlify
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cloudflare: "Cloudflare Pages"
        case .netlify: "Netlify"
        }
    }
    var command: String {
        switch self {
        case .cloudflare: "npx wrangler pages deploy . --project-name my-portal --branch main"
        case .netlify: "npx netlify deploy --prod --no-build --dir . --site-name my-portal"
        }
    }
    static func match(_ cmd: String) -> UploadHost? {
        if cmd.contains("wrangler") { return .cloudflare }
        if cmd.contains("netlify") { return .netlify }
        return nil
    }
    /// Plain steps, done once in Terminal and the host's website. Markdown: `code` shows as code.
    var steps: [String] {
        let node = "Install Node.js from nodejs.org (it brings `npx`). If you installed it another way, put the full path of `npx` in the command (Terminal: `which npx`)."
        switch self {
        case .cloudflare: return [
            node,
            "Sign in once: in Terminal run `npx wrangler login` (it opens Cloudflare in your browser; a free account is enough).",
            "Create the site once, with your own name instead of my-portal: `npx wrangler pages project create my-portal --production-branch main`. Use the same name in the command above.",
            "Keep it private: in the Cloudflare dashboard open Zero Trust → Access and add an application for my-portal.pages.dev that lets in only your email (free). Or switch on \u{201C}Safe to show anyone\u{201D}.",
            "Press Publish now. The note above says whether the upload worked; the page is then at https://my-portal.pages.dev."]
        case .netlify: return [
            node,
            "Sign in once: in Terminal run `npx netlify login` (it opens Netlify in your browser).",
            "Pick a site name and use it in the command above instead of my-portal; the first publish creates the site. If you're in more than one Netlify team, run the command once in Terminal from the portal folder to choose the team.",
            "Netlify's password protection is a paid feature, so on a free account switch on \u{201C}Safe to show anyone\u{201D}.",
            "Press Publish now. The page is then at https://my-portal.netlify.app."]
        }
    }
}
