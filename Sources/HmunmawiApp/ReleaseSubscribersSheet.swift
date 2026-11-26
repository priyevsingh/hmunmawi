import AppKit
import HmunmawiCore
import SwiftUI
import UniformTypeIdentifiers

/// Compact per-app release notification summary and quick actions inside `AppsPager`.
struct ReleaseSubscribersSection: View {
    let model: AppModel
    let app: String
    @State private var subscribers = ReleaseSubscribers.shared
    @State private var showSheet = false
    @State private var statusNote: String?
    @State private var drafting = false

    var body: some View {
        let appSubscribers = subscribers.subscribers(forApp: app)
        let activeCount = subscribers.activeCount(forApp: app)
        let inactiveCount = max(0, appSubscribers.count - activeCount)
        let lastNotified = subscribers.book.notifiedVersions[app]

        VStack(alignment: .leading, spacing: 12) {
            Divider()
            CardHeader(
                symbol: "envelope.badge.person.crop",
                title: "Release notifications",
                tint: Brand.Category.users,
                caption: lastNotified.map { "Last notified v\($0)" }
            )

            HStack(alignment: .firstTextBaseline, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(activeCount == 0
                         ? "No active subscribers for \(app)"
                         : "\(activeCount) active subscriber\(activeCount == 1 ? "" : "s")")
                        .font(.callout.weight(.medium))
                    let details = [
                        inactiveCount > 0 ? "\(inactiveCount) unsubscribed or bounced" : nil,
                        lastNotified.map { "Last notified live version: v\($0)" } ?? "No release update drafted yet"
                    ].compactMap { $0 }
                    Text(details.joined(separator: " · "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                HStack(spacing: 8) {
                    Button {
                        showSheet = true
                    } label: {
                        Label("Manage subscribers", systemImage: "person.2")
                    }
                    .buttonStyle(.pill)

                    if activeCount > 0 {
                        Button {
                            drafting = true
                            Task {
                                let result = await subscribers.draftNotification(app: app, model: model)
                                statusNote = result.note
                                drafting = false
                            }
                        } label: {
                            Label(drafting ? "Drafting…" : "Draft update note", systemImage: "square.and.pencil")
                        }
                        .buttonStyle(.pillProminent)
                        .disabled(drafting)
                    }
                }
            }

            if let statusNote, !statusNote.isEmpty {
                Text(statusNote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(isPresented: $showSheet) {
            ReleaseSubscribersSheet(model: model, initialApp: app)
                .buttonStyle(.pill)
        }
    }
}

/// Manages opt-in release subscribers, CSV/paste imports, per-app automation & templates, and mail undo actions.
struct ReleaseSubscribersSheet: View {
    let model: AppModel
    var initialApp: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var subscribers = ReleaseSubscribers.shared
    @State private var selectedApp: String
    @State private var csvInput = ""
    @State private var searchText = ""
    @State private var statusFilter = "active"
    @State private var note: String?
    @State private var drafting = false
    @State private var allowPatchUpdates = false
    @State private var autoDraftOnRelease = true
    @State private var customSubject = ""
    @State private var customTemplate = ""
    @State private var templateExpanded = false

    init(model: AppModel, initialApp: String? = nil) {
        self.model = model
        self.initialApp = initialApp
        let trimmed = initialApp?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self._selectedApp = State(initialValue: trimmed.isEmpty ? "all" : trimmed)
    }

    private var knownApps: [String] {
        var seen = Set<String>()
        var out: [String] = []
        let candidates = model.snapshots("app.snapshot").compactMap(\.app)
            + APPName.known
            + [initialApp].compactMap { $0 }
            + Array(subscribers.book.configs.keys)
            + Array(subscribers.book.notifiedVersions.keys)
        for raw in candidates {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.caseInsensitiveCompare("all") != .orderedSame else { continue }
            if seen.insert(trimmed.lowercased()).inserted {
                out.append(trimmed)
            }
        }
        return out.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var automationTargetApp: String? {
        selectedApp == "all" ? knownApps.first : selectedApp
    }

    private var filteredSubscribers: [ReleaseSubscriber] {
        let base = subscribers.subscribers(forApp: selectedApp == "all" ? nil : selectedApp)
        let statusFiltered = base.filter { sub in
            switch statusFilter {
            case "active": return sub.isActive
            case "inactive": return !sub.isActive
            default: return true
            }
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return statusFiltered }
        return statusFiltered.filter { sub in
            sub.email.localizedCaseInsensitiveContains(query)
                || (sub.name?.localizedCaseInsensitiveContains(query) == true)
                || sub.apps.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var recentMailActions: [ReleaseMailRecord] {
        Array((subscribers.book.mailActions ?? []).filter { $0.undone != true }.suffix(10).reversed())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    addSubscribersCard

                    if let targetApp = automationTargetApp {
                        automationCard(for: targetApp)
                    }

                    if !recentMailActions.isEmpty {
                        recentAutoUpdatesCard
                    }

                    subscribersListCard
                }
                .padding(.vertical, 2)
            }

            if let note, !note.isEmpty {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.pillProminent)
            }
        }
        .padding(22)
        .frame(minWidth: 640, idealWidth: 780, minHeight: 580, idealHeight: 740)
        .onAppear { loadAppConfig() }
        .onChange(of: selectedApp) { _, _ in loadAppConfig() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Customer release notifications")
                    .font(.title2.bold())
                Text("Opt-in list stored locally. Updates always wait for your OK in Log before sending.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Picker("App", selection: $selectedApp) {
                Text("All apps").tag("all")
                ForEach(knownApps, id: \.self) { app in
                    Text(app).tag(app)
                }
            }
            .labelsHidden()
            .frame(width: 190)
        }
    }

    private var addSubscribersCard: some View {
        KitCard {
            CardHeader(
                symbol: "person.badge.plus",
                title: "Add subscribers",
                tint: Brand.Category.users,
                caption: selectedApp == "all" ? "Assigning to all apps" : "Assigning to \(selectedApp)"
            )

            Text("Paste comma-, semicolon-, or newline-separated addresses, or import a CSV export.")
                .font(.callout)
                .foregroundStyle(.secondary)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $csvInput)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 84, maxHeight: 130)
                    .background(
                        Color(nsColor: .textBackgroundColor).opacity(0.65),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
                    )

                if csvInput.isEmpty {
                    Text("alice@example.com, \"Bob Smith\" <bob@example.com>")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
            }

            HStack(spacing: 10) {
                Button {
                    importCSVFile()
                } label: {
                    Label("Import .csv file…", systemImage: "doc.badge.plus")
                }
                .buttonStyle(.pill)

                Spacer()

                Button {
                    addFromInput()
                } label: {
                    Label("Add to list", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.pillProminent)
                .disabled(csvInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func automationCard(for targetApp: String) -> some View {
        let activeCount = subscribers.activeCount(forApp: targetApp)
        let lastNotified = subscribers.book.notifiedVersions[targetApp]
        let lintProblem = liveLintProblem(for: targetApp)

        return KitCard {
            CardHeader(
                symbol: "paperplane.circle.fill",
                title: "Release automation · \(targetApp)",
                tint: Brand.Category.users,
                caption: lastNotified.map { "Last notified v\($0)" }
            )

            VStack(alignment: .leading, spacing: 10) {
                Toggle("Auto-draft release email when new App Store version goes live", isOn: $autoDraftOnRelease)
                    .onChange(of: autoDraftOnRelease) { _, _ in saveToggles(for: targetApp) }

                Toggle("Include patch updates (x.y.z)", isOn: $allowPatchUpdates)
                    .onChange(of: allowPatchUpdates) { _, _ in saveToggles(for: targetApp) }
            }

            DisclosureGroup("Customize email template & anti-spam check", isExpanded: $templateExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Subject")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        TextField(
                            "Subject",
                            text: $customSubject,
                            prompt: Text(ReleaseNotifyTemplate.defaultSubjectPattern)
                        )
                        .textFieldStyle(.roundedBorder)
                        .input(.text(120), $customSubject)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Body template")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)

                        ZStack(alignment: .topLeading) {
                            TextEditor(text: $customTemplate)
                                .font(.body.monospaced())
                                .scrollContentBackground(.hidden)
                                .padding(8)
                                .frame(minHeight: 150, maxHeight: 220)
                                .background(
                                    Color(nsColor: .textBackgroundColor).opacity(0.65),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
                                )

                            if customTemplate.isEmpty {
                                Text(ReleaseNotifyTemplate.defaultBodyPattern)
                                    .font(.body.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 13)
                                    .padding(.vertical, 10)
                                    .allowsHitTesting(false)
                            }
                        }

                        Text("Tokens: {{app}}, {{version}}, {{whats_new_section}}, {{app_store_url}}, {{greeting_name}}")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)

                        Text("Anti-spam reminder: keep it plain text with 1 link, sign off with \(ReleaseNotifyTemplate.signOff), and keep the unsubscribe instruction.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let lintProblem {
                        Label(lintProblem, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(Brand.caution)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Label("Passes anti-spam and wording checks", systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(Brand.good)
                    }

                    HStack(spacing: 8) {
                        Button("Reset to default") {
                            resetTemplate(for: targetApp)
                        }
                        .buttonStyle(.pill)

                        Spacer()

                        Button("Save template") {
                            saveTemplate(for: targetApp)
                        }
                        .buttonStyle(.pillProminent)
                    }
                }
                .padding(.top, 8)
            }
            .font(.callout.weight(.medium))

            Divider()

            HStack(alignment: .center, spacing: 10) {
                Text("Parks an editable draft in Log → Needs your OK.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    drafting = true
                    Task {
                        let result = await subscribers.draftNotification(app: targetApp, model: model)
                        note = result.note
                        drafting = false
                    }
                } label: {
                    Label(drafting ? "Drafting…" : "Draft release update now", systemImage: "square.and.pencil")
                }
                .buttonStyle(.pillProminent)
                .disabled(drafting || activeCount == 0)
            }
        }
    }

    private var recentAutoUpdatesCard: some View {
        KitCard {
            CardHeader(
                symbol: "arrow.uturn.backward.circle",
                title: "Recent auto-updates",
                tint: Brand.caution,
                caption: "\(recentMailActions.count)"
            )

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(recentMailActions.enumerated()), id: \.element.id) { index, rec in
                    if index > 0 { Divider() }
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(rec.email)
                                    .font(.callout.weight(.medium))
                                Text(rec.kind == .bounce ? "Bounced" : "Unsubscribed")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(
                                        (rec.kind == .bounce ? Brand.bad : Brand.caution).opacity(0.16),
                                        in: Capsule()
                                    )
                                    .foregroundStyle(rec.kind == .bounce ? Brand.bad : Brand.caution)
                            }
                            Text("\(rec.day) · \(rec.reason)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button("Undo") {
                            if subscribers.undoMailAction(rec) {
                                note = "Undid \(rec.kind.rawValue) for \(rec.email)."
                            }
                        }
                        .buttonStyle(.pill)
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private var subscribersListCard: some View {
        let rows = filteredSubscribers
        return KitCard {
            CardHeader(
                symbol: "person.2.fill",
                title: "Subscribers",
                tint: Brand.Category.users,
                caption: "\(rows.count)"
            )

            HStack(spacing: 10) {
                TextField("Search email, name, or app", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .input(.text(120), $searchText)

                Picker("Status", selection: $statusFilter) {
                    Text("Active").tag("active")
                    Text("Unsubscribed / Bounced").tag("inactive")
                    Text("All").tag("all")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            if rows.isEmpty {
                Text(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? "No subscribers match this filter."
                     : "No subscribers match “\(searchText.trimmingCharacters(in: .whitespacesAndNewlines))”.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, sub in
                        if index > 0 { Divider() }
                        subscriberRow(sub)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func subscriberRow(_ sub: ReleaseSubscriber) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(sub.email)
                        .font(.body.weight(.medium))
                        .textSelection(.enabled)
                    if let name = sub.name, !name.isEmpty {
                        Text(name)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    ForEach(sub.apps, id: \.self) { appName in
                        Text(appName.caseInsensitiveCompare("all") == .orderedSame ? "All apps" : appName)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .glassCapsule()
                    }
                    statusBadge(for: sub)
                }
            }

            Spacer()

            HStack(spacing: 6) {
                if !sub.isActive {
                    Button("Reactivate") {
                        if subscribers.reactivate(email: sub.email) {
                            note = "Reactivated \(sub.email)."
                        }
                    }
                    .buttonStyle(.pill)
                }

                Button("Remove") {
                    let scope = selectedApp == "all" ? nil : selectedApp
                    if subscribers.remove(email: sub.email, app: scope) {
                        note = scope == nil
                            ? "Removed \(sub.email)."
                            : "Removed \(sub.email) from \(scope!)."
                    }
                }
                .buttonStyle(.pill)
            }
        }
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private func statusBadge(for sub: ReleaseSubscriber) -> some View {
        if sub.isActive {
            Text("Active")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Brand.good.opacity(0.16), in: Capsule())
                .foregroundStyle(Brand.good)
        } else if let bouncedAt = sub.bouncedAt {
            Text(bouncedAt.isEmpty ? "Bounced" : "Bounced \(bouncedAt)")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Brand.bad.opacity(0.16), in: Capsule())
                .foregroundStyle(Brand.bad)
        } else if let unsubscribedAt = sub.unsubscribedAt {
            Text(unsubscribedAt.isEmpty ? "Unsubscribed" : "Unsubscribed \(unsubscribedAt)")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Brand.caution.opacity(0.16), in: Capsule())
                .foregroundStyle(Brand.caution)
        }
    }

    // MARK: - Actions

    private func loadAppConfig() {
        guard let targetApp = automationTargetApp else { return }
        let cfg = subscribers.config(forApp: targetApp)
        allowPatchUpdates = cfg.allowPatchUpdates
        autoDraftOnRelease = cfg.autoDraftOnRelease
        customSubject = cfg.customSubject ?? ""
        customTemplate = cfg.customTemplate ?? ""
    }

    private func saveToggles(for targetApp: String) {
        var cfg = subscribers.config(forApp: targetApp)
        guard cfg.allowPatchUpdates != allowPatchUpdates || cfg.autoDraftOnRelease != autoDraftOnRelease else { return }
        cfg.allowPatchUpdates = allowPatchUpdates
        cfg.autoDraftOnRelease = autoDraftOnRelease
        subscribers.setConfig(cfg, forApp: targetApp)
    }

    private func saveTemplate(for targetApp: String) {
        if let problem = liveLintProblem(for: targetApp) {
            note = "Template not saved: \(problem)"
            return
        }
        let subjectTrimmed = customSubject.trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyTrimmed = customTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        let cfg = ReleaseNotifyAppConfig(
            allowPatchUpdates: allowPatchUpdates,
            autoDraftOnRelease: autoDraftOnRelease,
            customSubject: subjectTrimmed.isEmpty ? nil : subjectTrimmed,
            customTemplate: bodyTrimmed.isEmpty ? nil : bodyTrimmed
        )
        subscribers.setConfig(cfg, forApp: targetApp)
        note = "Saved template for \(targetApp)."
    }

    private func resetTemplate(for targetApp: String) {
        customSubject = ""
        customTemplate = ""
        let cfg = ReleaseNotifyAppConfig(
            allowPatchUpdates: allowPatchUpdates,
            autoDraftOnRelease: autoDraftOnRelease,
            customSubject: nil,
            customTemplate: nil
        )
        subscribers.setConfig(cfg, forApp: targetApp)
        note = "Reset template for \(targetApp) to default."
    }

    private func liveLintProblem(for targetApp: String) -> String? {
        let subjectTrimmed = customSubject.trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyTrimmed = customTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        let previewConfig = ReleaseNotifyAppConfig(
            allowPatchUpdates: allowPatchUpdates,
            autoDraftOnRelease: autoDraftOnRelease,
            customSubject: subjectTrimmed.isEmpty ? nil : subjectTrimmed,
            customTemplate: bodyTrimmed.isEmpty ? nil : bodyTrimmed
        )
        let version = subscribers.liveVersion(app: targetApp, model: model) ?? "1.0"
        let appID = subscribers.resolveAppID(app: targetApp, model: model)
        let appStoreURL = appID.map { "https://apps.apple.com/app/id\($0)" } ?? "https://escapethematrix.app"
        let rendered = ReleaseNotifyTemplate.render(
            app: targetApp,
            version: version,
            whatsNew: "Bug fixes and improvements.",
            appStoreURL: appStoreURL,
            subscriberName: "Alex",
            config: previewConfig
        )
        return ReleaseNotifySpamLint.problem(
            rendered.body,
            subject: rendered.subject,
            wording: Wording.rules
        )
    }

    private func importCSVFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a CSV or text file of subscriber email addresses"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let text = (try? String(contentsOf: url, encoding: .utf8))
            ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else {
            note = "Couldn't read \(url.lastPathComponent)."
            return
        }
        importRawText(text)
    }

    private func addFromInput() {
        let trimmed = csvInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let summary = importRawText(trimmed)
        if summary.added > 0 || summary.updatedApps > 0 || summary.duplicates > 0 || summary.unsubscribedSkipped > 0 {
            csvInput = ""
        }
    }

    @discardableResult
    private func importRawText(_ raw: String) -> ReleaseSubscribersStore.UpsertSummary {
        let targetApps = selectedApp == "all" ? ["all"] : [selectedApp]
        let summary = subscribers.importCSV(raw, defaultApps: targetApps)
        var parts = [
            "Added \(summary.added)",
            "Updated \(summary.updatedApps)",
            "Duplicates \(summary.duplicates)",
            "Skipped unsubscribed \(summary.unsubscribedSkipped)"
        ]
        if !summary.invalid.isEmpty {
            let preview = summary.invalid.prefix(3).joined(separator: ", ")
            let extra = summary.invalid.count > 3 ? " +\(summary.invalid.count - 3) more" : ""
            parts.append("Invalid \(summary.invalid.count) (\(preview)\(extra))")
        }
        note = parts.joined(separator: " · ")
        return summary
    }
}
