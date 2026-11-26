import AppKit
import HmunmawiCore
import ServiceManagement
import UniformTypeIdentifiers
import SwiftUI

/// The Settings panes, in sidebar order. One list for the sidebar, `hm set settings.tab` and the tests.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, menubar, connections, projects, jobs, rules, permissions, publish, backups, about

    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"; case .menubar: "Menu bar"; case .connections: "Connections"; case .projects: "Projects"
        case .jobs: "Jobs"; case .rules: "Rules"; case .permissions: "Permissions"; case .publish: "Publish"
        case .backups: "Backups"; case .about: "About"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"; case .menubar: "menubar.rectangle"; case .connections: "point.3.connected.trianglepath.dotted"
        case .projects: "square.stack.3d.up"; case .jobs: "switch.2"; case .rules: "bolt.badge.automatic"
        case .permissions: "lock.shield"; case .publish: "globe"; case .backups: "clock.arrow.circlepath"; case .about: "info.circle"
        }
    }
    /// The sidebar's groups, in order, the way System Settings separates them (no headings, just a gap):
    /// the app itself, where numbers come from, what agents and routines may do, sharing and keeping, About.
    static let groups: [[SettingsPane]] = [[.general, .menubar], [.connections, .projects, .jobs], [.rules, .permissions], [.publish, .backups], [.about]]
    /// Unknown or old values (a remembered tab from another version) open General.
    static func from(_ raw: String) -> SettingsPane { SettingsPane(rawValue: raw) ?? .general }
}

/// Settings the way current Mac apps do it (System Settings): a sidebar of panes, each a grouped form with
/// system controls and short footnotes. A sidebar fits every pane at any window size, so none hides behind
/// a toolbar's ">>" overflow menu (10 toolbar tabs did not fit at the old width).
struct SettingsView: View {
    let model: AppModel
    /// Remembered pane; agents can open one with `hm set settings.tab projects`.
    @AppStorage("HMSettingsTab") private var tab = "general"
    /// Sidebar width and the narrowest a pane may get; the window's minimum is the two together.
    static let sidebarWidth: CGFloat = 200
    static let paneMinWidth: CGFloat = 860

    var body: some View {
        let pane = SettingsPane.from(tab)
        NavigationSplitView {
            List(selection: Binding(get: { pane }, set: { if let p = $0 { tab = p.rawValue } })) {
                ForEach(SettingsPane.groups.indices, id: \.self) { g in
                    Section {
                        ForEach(SettingsPane.groups[g]) { p in
                            Label(p.title, systemImage: p.symbol)
                                .tag(p)
                                .accessibilityIdentifier("settings.tab.\(p.rawValue)")
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: Self.sidebarWidth, ideal: Self.sidebarWidth, max: Self.sidebarWidth + 40)
            .toolbar(removing: .sidebarToggle)   // the panes are the only way around, so the sidebar always shows
        } detail: {
            detail(pane)
                .frame(minWidth: Self.paneMinWidth, maxWidth: .infinity, minHeight: 420, idealHeight: 620, maxHeight: .infinity)
                .navigationTitle(pane.title)
        }
        .navigationSplitViewStyle(.balanced)
        .buttonStyle(.pill)   // same button look as the main window (rows that need another style set their own)
        .task { await model.load() }
    }

    @ViewBuilder private func detail(_ pane: SettingsPane) -> some View {
        switch pane {
        case .general: GeneralSettings(model: model)
        case .menubar: MenuBarSettingsForm(model: model)
        case .connections: ConnectionsForm(model: model)
        case .projects: ProjectsForm()
        case .jobs: JobSwitchesForm(model: model)
        case .rules: RulesEditor(model: model)
        case .permissions: PermissionsForm(permissions: Permissions.shared)
        case .publish: PublishForm(model: model)
        case .backups: BackupsForm(model: model)
        case .about: AboutPane()
        }
    }
}

/// Choices that apply to the whole app.
private struct GeneralSettings: View {
    let model: AppModel
    @State private var money = Money.shared

    var body: some View {
        Form {
            OwnerExtrasSection()
            ExtrasSection()
            Section {
                Picker("Appearance", selection: $appearance) {
                    Text("Same as Mac").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Light or dark for Hmunmawi only. Your Mac's own setting stays as it is.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Picker("Show money in", selection: Binding(
                    get: { money.target },
                    set: { model.setDisplayCurrency($0 == (Locale.current.currency?.identifier ?? "USD") ? nil : $0) })) {
                    ForEach(money.choices, id: \.self) { code in
                        Text("\(Locale.current.localizedString(forCurrencyCode: code) ?? code) (\(code))").tag(code)
                    }
                }
            } footer: {
                Text(money.ratesDate.map { "European Central Bank rates of \($0). Original prices are always kept beside converted ones." }
                     ?? "Rates load from the European Central Bank once a day.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent {
                    TextField("", value: $adCost, format: .number.precision(.fractionLength(2)))
                        .multilineTextAlignment(.trailing).frame(width: 90)
                        .accessibilityLabel("Cost per download you'd expect to pay for ads, in US dollars").clamp($adCost, 0...1000)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ad cost per download (USD)")
                        Text("Ads are suggested only above 1.5× this").font(.callout).foregroundStyle(.secondary)
                    }
                }
            } header: { Label("Next steps", systemImage: "lightbulb") }
            KeepAwakeSection()
            WordingSection()
            AlertsAndSafetySection(model: model)
            ExportSection(model: model)
            AISection()
            WebDashboardSection()
            LiveSalesSection(model: model)
            XSourceSection()
        }
        .formStyle(.grouped)
        .onChange(of: adCost) { _, v in UserDefaults.standard.set(v, forKey: "HMAdCostPerDownload") }
        .onChange(of: appearance) { _, v in AppDelegate.applyAppearance(v) }
    }

    @AppStorage(AppDelegate.appearanceKey) private var appearance = "system"

    @State private var adCost: Double = Playbook.adCostPerDownload
}

/// Keep this Mac awake so routines run on time (off by default).
private struct KeepAwakeSection: View {
    @State private var mode = KeepAwake.shared.mode
    var body: some View {
        Section {
            Picker("Keep this Mac awake for routines", selection: $mode) {
                Text("Off").tag(KeepAwake.Mode.off)
                Text("While plugged in").tag(KeepAwake.Mode.pluggedIn)
                Text("Always").tag(KeepAwake.Mode.always)
            }
            .accessibilityIdentifier("settings.keepAwake")
        } footer: {
            Text("Stops this Mac from going to sleep on its own while Hmunmawi runs, so routines and Mac jobs run at their times. The screen still sleeps, and closing a laptop's lid still sleeps the Mac. \"Always\" uses more battery.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .onChange(of: mode) { _, v in KeepAwake.shared.mode = v }
    }
}

/// "Words I never use": claims you can't back up, wording a store forbids, names you mustn't mention yet.
private struct WordingSection: View {
    @State private var text = Wording.lines(Wording.rules.rules)
    @State private var problems = Wording.rules.problems
    @State private var saved = false
    var body: some View {
        Section {
            TextEditor(text: $text)
                .font(.callout.monospaced()).frame(minHeight: 70, maxHeight: 140)
                .accessibilityLabel("Words I never use, one per line")
                .accessibilityIdentifier("settings.wording")
            HStack {
                ForEach(problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Brand.caution).font(.callout) }
                Spacer()
                if saved { Text("Saved").font(.callout).foregroundStyle(.secondary) }
                Button("Save") { problems = Wording.save(Wording.parseLines(text)); saved = true }
            }
        } header: { Label("Words I never use", systemImage: "text.badge.xmark") } footer: {
            Text("One per line: a word or phrase, then | and why (optional); re: starts a pattern. Post drafts and reply ideas that use one are skipped, the drafting AI is told to avoid them, and your scripts and agents check any text with hm lint-text. Saved as wording-rules.json in Hmunmawi's folder.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .onChange(of: text) { _, _ in saved = false }
    }
}

/// Quiet hours for alerts, and the sandbox connections run in.
private struct AlertsAndSafetySection: View {
    let model: AppModel
    @State private var q = QuietHours.standard
    @State private var sandbox = true
    @AppStorage("HMDigestWeekday") private var digestDay = 2
    @AppStorage("HMDigestHour") private var digestHour = 9
    @AppStorage("HMRatingDropOn") private var ratingDropOn = true
    @AppStorage("HMQuotaWarnAt") private var quotaWarnAt = 80
    @AppStorage(PublicRatings.onKey) private var publicRatings = true
    @AppStorage("HMRatingDropBy") private var ratingDropBy = 0.2
    private func hour(_ h: Int) -> String {
        Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: .now)!.formatted(date: .omitted, time: .shortened)
    }

    var body: some View {
        Section {
            Toggle(isOn: $ratingDropOn) {
                Text("Tell me when a rating drops")
                Text("Compares each app's star rating with a week ago. It shows on Today, and you can build an alert rule on \u{201C}rating.drop\u{201D}. Needs at least 2 new ratings, so one stray rating on a small count stays quiet.")
            }
            if ratingDropOn {
                Stepper(value: $ratingDropBy, in: 0.1...1.0, step: 0.1) {
                    Text("Report a fall of \(String(format: "%.1f", ratingDropBy)) stars or more")
                }
            }
            Toggle(isOn: $publicRatings) {
                Text("Read star ratings from the public App Store page")
                Text("Gives each app its rating, rating count and country ratings when you have no script feed. Sends only the app's id and country codes to Apple's public listing, about once a day.")
            }
            Stepper(value: $quotaWarnAt, in: 50...95, step: 5) {
                Text("Warn me when a service's request limit is \(quotaWarnAt)% used")
                Text("Hmunmawi reads each service's own limit from its answers (App Store Connect, X and others). 0 requests left makes the service refuse for a while.")
            }
            Toggle(isOn: $q.enabled) {
                Text("Quiet hours")
                Text("Alerts that arrive in these hours wait until they end, then come as one message. Urgent rules (priority 1) still go out.")
            }
            if q.enabled {
                Picker("From", selection: $q.startHour) { ForEach(0..<24, id: \.self) { Text(hour($0)).tag($0) } }
                Picker("Until", selection: $q.endHour) { ForEach(0..<24, id: \.self) { Text(hour($0)).tag($0) } }
            }
            LabeledContent {
                HStack {
                    Picker("Day", selection: $digestDay) {
                        ForEach(1...7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0 - 1]).tag($0) }
                    }.labelsHidden().fixedSize()
                    Picker("Time", selection: $digestHour) { ForEach(0..<24, id: \.self) { Text(hour($0)).tag($0) } }
                        .labelsHidden().fixedSize()
                }
            } label: {
                Text("Weekly digest")
                Text("Money, MRR, downloads, the top win and worry, sent by the \u{201C}weekly digest\u{201D} rule (switch it off in Rules).")
            }
            Toggle(isOn: $sandbox) {
                Text("Run connections in a sandbox")
                Text("Connections can't reach the internet themselves, start other programs or read your files and keys; their web calls go through Hmunmawi, to the sites they declared. Applies from each one's next start.")
            }
            let waiting = model.healScriptsWaiting
            if !waiting.isEmpty {
                LabeledContent {
                    Button("Allow") { model.allowHealScripts() }
                } label: {
                    Text("Fix scripts waiting for your OK")
                    Text(waiting.sorted { $0.key < $1.key }.map { "When \($0.key == "disk.low" ? "disk space runs low" : $0.key == "site.down" ? "the website is down" : $0.key): run \(($0.value as NSString).lastPathComponent)" }.joined(separator: "\n")
                         + "\nAdded outside the app, so they don't run until you allow them here.")
                }
            }
            SelfHealingRows(model: model)
        } header: { Label("Alerts and safety", systemImage: "moon.zzz") } footer: {
            Text("Several alerts for one channel are always sent together, and a channel sends at most \(Store.alertsPerChannelPerHour) messages an hour.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .onAppear { q = model.quietHours; sandbox = model.sandboxAddOns }
        .onChange(of: q) { _, v in model.setQuietHours(v) }
        .onChange(of: sandbox) { _, v in model.setSandboxAddOns(v) }
    }
}

/// Self-healing: one fix script per kind of problem, picked here (so it's yours and runs without asking again).
private struct SelfHealingRows: View {
    let model: AppModel
    static let kinds: [(id: String, name: String)] = [("disk.low", "Disk space runs low"), ("site.down", "The website is down"),
                                                       ("job.failed", "A Mac job fails"), ("crash.spike", "Crashes jump")]
    var body: some View {
        let active = model.healScriptsActive
        ForEach(Self.kinds, id: \.id) { k in
            LabeledContent {
                if let path = active[k.id] {
                    Button("Remove") { model.setHealScript(k.id, nil) }
                    Text((path as NSString).lastPathComponent).foregroundStyle(.secondary)
                } else {
                    Button("Choose script…") { pick(k.id) }
                }
            } label: {
                Text("Fix when: \(k.name)")
                Text(active[k.id] == nil ? "Optional. Hmunmawi runs your script once for each new problem of this kind, then logs the result."
                     : "Runs on its own once for each new problem of this kind; the result shows under Healed automatically.")
            }
        }
    }
    private func pick(_ kind: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Choose a shell script to run when this problem appears."
        if panel.runModal() == .OK, let url = panel.url { model.setHealScript(kind, url.path) }
    }
}

/// Bring your own AI key: off by default; says exactly what is sent before you switch it on.
private struct AISection: View {
    @State private var ai = AISettings.shared
    @State private var newKey = ""
    @State private var testResult: String?
    @State private var testing = false

    /// "This month: 4 rewrites · about $0.02 of $1.00" (or tokens when the price isn't known).
    private var usageLine: String {
        let u = ai.usage
        guard u.month == AISettings.monthKey(), u.calls > 0 else {
            return "Stops calling the AI when reached. Nothing used this month."
        }
        let spend = ai.prices != nil ? "about $\(String(format: "%.2f", u.usd)) of $\(String(format: "%.2f", ai.monthlyBudget))"
                                     : "\(u.input + u.output) tokens (add prices to track dollars)"
        return "This month: \(u.calls) \(u.calls == 1 ? "call" : "calls") · \(spend)"
    }

    var body: some View {
        Section {
            Picker("Provider", selection: Binding(get: { ai.provider }, set: { ai.switchProvider($0); testResult = nil })) {
                ForEach(AIProvider.allCases) { Text($0.name).tag($0) }
            }
            if ai.provider == .custom {
                TextField("Address", text: $ai.customURL, prompt: Text("https://…/v1"))
                    .accessibilityLabel("Provider address, OpenAI-compatible, https only").input(.url, $ai.customURL)
            }
            if ai.models.isEmpty {
                TextField("Model", text: $ai.model, prompt: Text(ai.provider == .claude ? "claude-opus-5-5" : "Model name from your provider"))
                    .accessibilityLabel("Model name").input(.identifier, $ai.model)
            } else {
                // Filled from the provider right after the key is saved.
                Picker("Model", selection: $ai.model) {
                    ForEach(ai.models, id: \.self) { Text($0).tag($0) }
                }
            }
            if ai.provider.needsKey {
                LabeledContent {
                    HStack {
                        SecureField("", text: $newKey, prompt: Text(ai.hasKey ? "Saved in Keychain" : "Paste your key"))
                            .accessibilityLabel("\(ai.provider.name) API key").input(.secret, $newKey)
                        FindKeyButton(addOn: "ai", field: ai.provider.rawValue, label: "\(ai.provider.name) API key",
                                      onSource: { SecretSourceCatalog(url: URL.hmSupport.appending(path: SecretSourceCatalog.fileName)).record(plugin: "ai", name: ai.provider.rawValue, ref: $0) }) {
                            ai.saveKey($0); newKey = ""
                        }
                        if !newKey.isEmpty { Button("Save") { ai.saveKey(newKey); newKey = "" }.buttonStyle(.pillProminent) }
                        if ai.hasKey && newKey.isEmpty { ConfirmButton(title: "Remove key", question: "Remove your AI key?", detail: "AI features stop until you paste a key again.") { ai.removeKey(); ai.enabled = false } }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("API key")
                        Text(ai.provider.whereToGetKey).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            if ai.provider != .claude && ai.provider != .ollama {
                LabeledContent {
                    HStack {
                        TextField("In", value: $ai.priceIn, format: .number).frame(width: 60).accessibilityLabel("Price per million input tokens").clamp($ai.priceIn, 0...10_000)
                        Text("/")
                        TextField("Out", value: $ai.priceOut, format: .number).frame(width: 60).accessibilityLabel("Price per million output tokens").clamp($ai.priceOut, 0...10_000)
                    }
                    .multilineTextAlignment(.trailing)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Price per million tokens, USD")
                        Text(ai.prices != nil && ai.priceIn == 0 && ai.priceOut == 0
                             ? "Built-in estimate active for \(ai.model); enter 0 / 0 to keep it, or your own prices"
                             : "In / out, from your provider's pricing page; used to keep within your budget")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                if ai.prices == nil || ai.allowUnpricedModels {
                    Toggle(isOn: $ai.allowUnpricedModels) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Allow unpriced models without USD cap")
                            Text("Lets AI drafts run when this model has no known token price (monthly dollar cap won't stop it)")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            // Two layers so spending is never a mystery: a hard limit at the provider, and this app's own budget.
            VStack(alignment: .leading, spacing: 6) {
                Label("Keep Hmunmawi's AI spending separate", systemImage: "creditcard.and.123")
                    .font(.body.weight(.semibold))
                Text(ai.provider.dedicatedCreditHelp).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let url = ai.provider.limitsURL {
                    Link("Open \(ai.provider.name) limits", destination: url).font(.callout)
                }
            }
            LabeledContent {
                TextField("", value: $ai.monthlyBudget, format: .number.precision(.fractionLength(2)))
                    .multilineTextAlignment(.trailing).frame(width: 80).accessibilityLabel("Monthly AI budget in US dollars").clamp($ai.monthlyBudget, 0...100_000)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hmunmawi's monthly budget, USD")
                    Text(usageLine).font(.callout).foregroundStyle(.secondary)
                    if ai.prices != nil && ai.monthlyBudget > 0 {
                        ProgressView(value: min(ai.usage.month == AISettings.monthKey() ? ai.usage.usd : 0, ai.monthlyBudget),
                                     total: ai.monthlyBudget)
                            .tint(ai.budgetLeft ? Brand.Category.web : Brand.caution)
                            .frame(maxWidth: 260)
                            .accessibilityLabel("AI spending this month against the budget")
                    }
                }
            }
            HStack {
                if testing || ai.checking { ProgressView().controlSize(.small) }
                if !ai.models.isEmpty && testResult == nil {
                    Label("Key works · \(ai.models.count) models", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
                }
                if let testResult { Text(testResult).font(.callout).foregroundStyle(.secondary) }
                Spacer()
                Button("Check key") { Task { testing = true; testResult = await AIWriter.test(); testing = false } }
                    .disabled(!(ai.hasKey && !ai.model.isEmpty))
            }
            Toggle(isOn: $ai.enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Word Next steps with AI")
                    Text("Sends the data each AI feature needs to \(ai.provider.name), only when you use it").font(.callout).foregroundStyle(.secondary)
                }
            }
            .disabled(!(ai.hasKey && !ai.model.isEmpty && ai.endpoint != nil))
            .accessibilityLabel("Word Next steps with AI")
            Toggle(isOn: $ai.polishWeeklyDigest) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Polish weekly digest with AI")
                    Text("Rewrites Sunday's weekly digest with AI before sending (checked against Words I never use)").font(.callout).foregroundStyle(.secondary)
                }
            }
            .disabled(!(ai.hasKey && !ai.model.isEmpty && ai.endpoint != nil))
            .accessibilityLabel("Polish weekly digest with AI")
            if let error = ai.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Brand.caution)
            }
        } header: {
            Label("AI wording · your own key", systemImage: "sparkles")
        } footer: {
            HStack(spacing: 6) {
                Text("Off by default. Next steps work without it.").font(.footnote).foregroundStyle(.secondary)
                InfoTip("Your key stays in this Mac's Keychain and goes only to the provider you pick, over HTTPS (Ollama runs on this Mac). Each AI feature sends only what it works on (for example your weekly numbers, a review you answer, or a reply you paste), and nothing is sent without a key and within your budget. The provider's privacy terms apply to what it receives.")
            }
        }
        .task { await ai.checkKey() }
    }
}

/// Each data source or alert channel as a form section: what it reads, its fields, and Save / Check.
private struct ConnectionsForm: View {
    @MainActor static var lastAddOnsRead = Date.distantPast
    let model: AppModel

    var body: some View {
        Form {
            if model.addOns.isEmpty {
                ContentUnavailableView("No Connections", systemImage: "puzzlepiece.extension")
            }
            // Grouped by what they're for, so a new user finds the right one quickly.
            ForEach(Self.groups, id: \.title) { group in
                let rows = model.addOns.filter { group.ids.contains($0.id) || (group.ids.isEmpty && !Self.known.contains($0.id)) }
                if !rows.isEmpty {
                    Section {} header: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.title).font(.title3.weight(.semibold)).foregroundStyle(.primary)
                            Text(group.why).font(.callout).foregroundStyle(.secondary)
                        }
                        .padding(.top, 8)
                    }
                    ForEach(rows) { row in AddOnSection(row: row, model: model) }
                }
            }
            MailSourceSection(permissions: Permissions.shared, model: model)
            Section {} footer: {
                Label("Keys are stored in your Keychain. Add-ons never see them.", systemImage: "lock.fill")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // Reads each key's state from the Keychain; once per half minute is plenty when flipping between tabs.
        .task {
            if Date.now.timeIntervalSince(Self.lastAddOnsRead) > 30 { Self.lastAddOnsRead = .now; await model.refreshAddOns() }
        }
    }
}

extension ConnectionsForm {
    struct Group { let title: String; let why: String; let ids: [String] }
    static let groups: [Group] = [
        Group(title: "Your apps", why: "Sales, subscriptions, crashes and reviews.",
              ids: ["appstoreconnect", "revenuecat", "sentry", "posthog"]),
        Group(title: "Getting found", why: "Search, video, social and your website.",
              ids: ["searchconsole", "bing", "youtube", "x", "cloudflare", "vercel"]),
        Group(title: "Alerts", why: "Where Hmunmawi tells you about sales and problems.", ids: ["imessage", "ntfy"]),
        Group(title: "Your Mac", why: "Scheduled jobs and your own scripts.", ids: ["macjobs", "scriptfeed"]),
        Group(title: "Other add-ons", why: "Added by you.", ids: []),
    ]
    static let known = Set(groups.flatMap(\.ids))
}

struct AddOnSection: View {
    let row: AddOnRow
    let model: AppModel
    @State private var values: [String: String] = [:]
    /// What is saved now, so Save is only on after a change, and says "Saved" when it's done.
    @State private var saved: [String: String] = [:]
    @State private var justSaved = false
    @State private var busy = false

    private var changed: Bool {
        row.manifest.settings.contains { s in
            let v = values[s.key] ?? ""
            return s.type.hasPrefix("secret") ? !v.isEmpty : v != (saved[s.key] ?? "")
        }
    }

    private var rowDisplay: ConnectionAudit.RowDisplay {
        return ConnectionAudit.display(audit: model.audit, actor: row.id, approved: row.approved, missing: !row.missing.isEmpty)
    }

  private func statusColor(_ tone: ConnectionAudit.RowDisplay.Tone) -> Color {
        switch tone {
        case .good: Brand.good
        case .caution: Brand.caution
        case .bad: Brand.bad
        }
    }

    var body: some View {
        let status = (rowDisplay.label, statusColor(rowDisplay.tone))
        Section {
            if !row.approved {
                if model.changedAddOns.contains(row.manifest.name) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Changed since you last allowed it").font(.callout.weight(.semibold))
                        ForEach(PermissionDiff.lines(old: AppModel.approvedPermissions(row.id), new: ApprovedPermissions(row.manifest)), id: \.self) {
                            Label($0, systemImage: "exclamationmark.triangle.fill").font(.callout)
                        }
                    }.foregroundStyle(Brand.caution).padding(.vertical, 2)
                }
                ForEach(permissionLines, id: \.0) { Label($0.0, systemImage: $0.1) }
                HStack {
                    if AppModel.keptOff.contains(row.id) {
                        Text("Kept off: it won't ask again until you allow it.").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.changedAddOns.contains(row.manifest.name) {
                        Button("Keep off") { Task { await model.keepOff(row.id) } }.buttonStyle(.pill)
                            .help("Leave \(row.manifest.name) off and stop asking; Allow still works any time")
                    }
                    Button("Allow \(row.manifest.name)") { Task { await model.allow(row.id) } }
                        .buttonStyle(.pillProminent)
                }
            } else {
                ForEach(row.manifest.settings, id: \.key) { field($0) }
                HStack {
                    if busy { ProgressView().controlSize(.small) }
                    if justSaved {
                        Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            .transition(.opacity)
                    }
                    Spacer()
                    if row.id == "vercel" {
                        Button("Detect from repo…") { detectVercelRepo() }
                            .buttonStyle(.pill)
                            .help("Read project and team IDs from .vercel/project.json and GitHub repo/branch from .git/config")
                    }
                    // Removes this connection's saved keys from the Keychain (it asks for them again).
                    if row.manifest.settings.contains(where: { $0.type.hasPrefix("secret") }) {
                        ConfirmButton(title: "Disconnect", question: "Disconnect \(row.manifest.name)?",
                                      detail: "Its saved keys are deleted from your Keychain. Its numbers stop updating until you add a key again.") {
                            Task { busy = true; await model.forget(row); busy = false }
                        }
                    }
                    if row.manifest.actions.contains("notify"), row.manifest.poll != nil {
                        // Only asks the server whether it answers: nothing is sent to your phone.
                        Button("Check Now") { Task { busy = true; await model.check(row); busy = false } }
                            .buttonStyle(.pill).disabled(!row.missing.isEmpty)
                            .help("Checks that the alert service answers, without sending you anything")
                    }
                    Button(row.manifest.actions.contains("notify") ? "Send Test" : "Check Now") {
                        Task { busy = true; await model.test(row); busy = false }
                    }
                    .buttonStyle(.pill)
                    .disabled(!row.missing.isEmpty)
                    Button("Save") {
                        Task {
                            busy = true
                            await model.save(values, for: row)
                            for s in row.manifest.settings {
                                // Show what was stored: secrets go blank, other fields lose stray spaces.
                                values[s.key] = s.type.hasPrefix("secret") ? "" : (values[s.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                            saved = values
                            busy = false
                            withAnimation { justSaved = true }
                            try? await Task.sleep(for: .seconds(2.5))
                            withAnimation { justSaved = false }
                        }
                    }
                    .buttonStyle(.pillProminent)
                    .disabled(!changed || busy)
                    .keyboardShortcut(changed ? .defaultAction : nil)
                }
            }
        } header: {
            HStack {
                Label(row.manifest.name, systemImage: AddOnStyle.symbol(row.id))
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(status.1).frame(width: 7, height: 7)
                        .ripple(status.1, trigger: status.0)
                    Text(status.0)
                    // When it last ran, so "Connected" is backed by something you can see.
                    if row.approved, let last = model.audit.first(where: { $0.actor == row.id }) {
                        TimelineView(.periodic(from: .now, by: 30)) { _ in
                            Text("· checked \(Ago.text(millis: last.at))")
                        }
                    }
                }
                .font(.callout).foregroundStyle(.secondary)
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if row.id == "x" {
                    // One description only (the add-on's summary below says what it reads).
                    if XFileFeed.shared.effectivePath.isEmpty && model.value("file", for: "x").isEmpty {
                        Label("Needs an X file: a small JSON file your own bot or script writes (the format is in docs/X-FILE.md). Set it under General → X. Without one, X stays off.",
                              systemImage: "doc.badge.gearshape")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else if !XFileFeed.planLine.isEmpty {
                        Text(XFileFeed.planLine).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if row.approved, rowDisplay.tone != .good, let problem = rowDisplay.detail {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Brand.bad)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let summary = row.manifest.summary { Text(summary).font(.footnote).foregroundStyle(.secondary) }
                if row.id == "ntfy", let sent = model.audit.first(where: { $0.actor == "ntfy" && $0.action == "plugin.delivered" }) {
                    let at = sent.detail[path: "sent_at"]?.string.flatMap { ISO8601DateFormatter().date(from: $0) }
                        ?? Date(timeIntervalSince1970: Double(sent.at) / 1000)
                    Text("Last alert delivered \(at.formatted(date: .abbreviated, time: .shortened))" + (sent.detail[path: "via"]?.string.map { " (sent by \($0))" } ?? ""))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if row.id == "ntfy" {
                    // ntfy.sh is public: anyone who knows (or guesses) the topic name can read the alerts sent to it.
                    Label("ntfy.sh topics are public: anyone who knows the name can read what's sent there. Use a long, random topic name (like hm-7f3k9q2xv8), not your app's name.",
                          systemImage: "lock.trianglebadge.exclamationmark")
                        .font(.footnote).foregroundStyle(Brand.caution).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear {
            for s in row.manifest.settings where !s.type.hasPrefix("secret") { values[s.key] = model.value(s.key, for: row.id) }
            saved = values
        }
    }

    private var permissionLines: [(String, String)] {
        var lines: [(String, String)] = []
        let p = row.manifest.permissions
        if !p.hosts.isEmpty {
            let why = ["api.frankfurter.dev": "exchange rates", "api.appstoreconnect.apple.com": "your App Store data"]
            lines.append(("Contacts " + p.hosts.map { h in why[h].map { "\(h) (\($0))" } ?? h }.joined(separator: ", "), "network"))
        }
        if !p.secrets.isEmpty { lines.append(("Uses the keys you enter here, without seeing them", "key")) }
        if p.mac.contains("messages.send") { lines.append(("Sends iMessages to the number you choose", "message")) }
        if p.mac.contains("xfile.read") { lines.append(("Reads only your X numbers file on this Mac (free, no network, no key)", "doc.text")) }
        let emits = row.manifest.emits
        if emits.contains("*") { lines.append(("May report any kind of event", "bolt")) }
        else if !emits.isEmpty {
            // Event codes ("ci.build") in words people read ("builds"), each once.
            let words: [String: String] = ["revenue": "sales", "review": "reviews", "reviews": "reviews", "ci": "builds",
                                           "asc": "App Store status", "expiry": "expiry dates", "finance": "payouts",
                                           "icon": "app icons", "growth": "followers and search", "crash": "crashes",
                                           "analytics": "visitors", "section": "summary cards", "flow": "your journey",
                                           "offer": "offer codes", "offercodes": "offer codes", "rating": "ratings", "ratings": "ratings",
                                           "money": "sales", "nominations": "featuring nominations", "pagetests": "product page tests",
                                           "perf": "app performance", "release": "releases", "versions": "releases",
                                           "suboffers": "subscription offers", "subscription": "subscribers",
                                           "testflight": "TestFlight feedback", "x": "followers and search", "search": "followers and search"]
            var seen: [String] = []
            for k in emits {
                let w = words[String(k.split(separator: ".").first ?? "")] ?? "other updates"
                if !seen.contains(w) { seen.append(w) }
            }
            if let o = seen.firstIndex(of: "other updates") { seen.append(seen.remove(at: o)) }
            lines.append(("Adds " + ListFormatter.localizedString(byJoining: seen), "bolt"))
        }
        if let poll = row.manifest.poll { lines.append(("Checks every \(poll.everySeconds / 60) minutes", "clock")) }
        return lines
    }

    @ViewBuilder
    private func field(_ setting: PluginManifest.Setting) -> some View {
        let binding = Binding(get: { values[setting.key] ?? "" }, set: { values[setting.key] = $0 })
        let saved = row.savedSecrets.contains(setting.key)
        switch setting.type {
        case "secret-file":
            LabeledContent {
                HStack {
                    Text(values[setting.key]?.isEmpty == false ? "Chosen" : saved ? "Saved in Keychain" : "Not set").foregroundStyle(.secondary)
                    Button("Choose…") { values[setting.key] = chooseFile() ?? values[setting.key] ?? "" }
                        .buttonStyle(.pill)
                        .accessibilityLabel("Choose file for \(setting.label)")
                    FindKeyButton(addOn: row.id, field: setting.key, label: setting.label, wantsFile: true,
                                  onSource: { model.recordSecretSource(plugin: row.id, name: setting.key, ref: $0) }) { values[setting.key] = $0 }
                }
            } label: { fieldLabel(setting.label) }
        case "secret":
            HStack {
                SecureField(text: binding, prompt: Text(saved ? "Saved in Keychain" : (setting.required == true ? "Required" : "Optional"))) { fieldLabel(setting.label) }
                    .input(InputRule.forSetting(key: setting.key, type: setting.type), binding)
                    .accessibilityLabel(setting.label)   // VoiceOver reads which key this field wants
                FindKeyButton(addOn: row.id, field: setting.key, label: setting.label,
                              onSource: { model.recordSecretSource(plugin: row.id, name: setting.key, ref: $0) }) { values[setting.key] = $0 }
            }
        case "toggle":
            Toggle(isOn: Binding(get: { values[setting.key] == "true" }, set: { values[setting.key] = $0 ? "true" : "false" })) {
                fieldLabel(setting.label)
            }
        default:
            TextField(text: binding, prompt: Text(setting.required == true ? "Required" : "Optional")) { fieldLabel(setting.label) }
                .input(InputRule.forSetting(key: setting.key, type: setting.type), binding)
                .accessibilityLabel(setting.label)
        }
    }

    /// "API key from Bing Webmaster Tools → Settings → API access" reads as a short name with the
    /// where-to-find-it part underneath in small grey text, so fields don't wrap to four lines.
    private func fieldLabel(_ full: String) -> some View {
        let cut = [" (", " from ", " — ", ": ", ". "].compactMap { full.range(of: $0)?.lowerBound }.min()
        let name = cut.map { String(full[..<$0]) } ?? full
        var hint = cut.map { String(full[$0...]).trimmingCharacters(in: CharacterSet(charactersIn: " (:—.")) } ?? ""
        if hint.hasSuffix(")") && !hint.contains("(") { hint.removeLast() }
        if hint.hasPrefix("from ") { hint = "From " + hint.dropFirst(5) }
        return VStack(alignment: .leading, spacing: 2) {
            Text(name)
            if !hint.isEmpty { Text(hint).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private func detectVercelRepo() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.message = "Pick one or more local website repository folders (containing .vercel or .git)"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        values = VercelDetector.merge(values: values, detected: panel.urls.map { VercelDetector.detect(in: $0) })
    }

    private func chooseFile() -> String? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "p8") ?? .data, .json]   // .p8 keys, Google service-account JSON
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

/// What Hmunmawi may use on this Mac, with the system's own controls.
private struct PermissionsForm: View {
    let permissions: Permissions

    var body: some View {
        ScrollView {
            PermissionsList(permissions: permissions)
                .padding(20)
        }
    }
}

/// About, like a Mac app's About pane: icon, name, version, one line, and the story.
enum SupportLinks {
    static let sponsorURL = URL(string: "https://github.com/sponsors/priyevsingh")
}

private struct AboutPane: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
            Text("Hmunmawi").font(.largeTitle.weight(.semibold))
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                .font(.callout).foregroundStyle(.secondary)
            VStack(spacing: 6) {
                Text("hmoon-MAH-wee").font(.body.italic()).foregroundStyle(.secondary)
                Text("Mizo for \(Text("\u{201C}beautiful place\u{201D}").foregroundStyle(Kit.vibrant(Brand.Category.web)))")
                    .font(.title3).foregroundStyle(.primary)
                Text("The ops co-founder you can't afford yet.")
                    .font(.title3.weight(.semibold)).foregroundStyle(.primary).multilineTextAlignment(.center)
                    .padding(.top, 4)
                Text("For indie developers on Apple's platforms with a million-dollar idea and a ramen budget. Every morning it tells you what you won, what to fix and what to do next, flags trouble the moment it shows up, and runs the chores while you ship. Free and open source.")
                    .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .padding(.top, 6)
            .frame(maxWidth: 460)
            HStack(spacing: 10) {
                Button("Watch the Story") { openWindow(id: "about") }
                    .buttonStyle(.pillProminent)
                if let sponsorURL = SupportLinks.sponsorURL {
                    Link(destination: sponsorURL) {
                        Label("Sponsor on GitHub", systemImage: "heart")
                    }
                    .buttonStyle(.pill)
                    .help("Open Hmunmawi's GitHub Sponsors page in your browser")
                }
            }
            .padding(.top, 8)
            WallOfAppsBox().frame(maxWidth: 460).padding(.top, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


/// How sales reach the app: Apple's daily report (always), Apple's notification history (minutes, no server),
/// or a worker in your own Cloudflare account (seconds, even while the Mac sleeps).
private struct LiveSalesSection: View {
    let model: AppModel
    @State private var history = AppleHistory.shared
    @State private var live = LivePurchases.shared
    @State private var mode = UserDefaults.standard.string(forKey: "HMLiveMode") ?? "daily"
    @State private var key = ""
    @State private var cfToken = ""
    @State private var existingURL = ""
    @State private var existingKey = ""

    var body: some View {
        Section {
            Picker("Sales arrive", selection: $mode) {
                Text("Next morning (Apple's daily report)").tag("daily")
                Text("Within minutes (Apple history, no server)").tag("history")
                Text("Within seconds (your own Cloudflare)").tag("cloudflare")
            }
            .onChange(of: mode) { _, v in UserDefaults.standard.set(v, forKey: "HMLiveMode") }
            if mode == "history" {
                TextField("In-App Purchase key ID", text: $history.keyID).accessibilityLabel("In-App Purchase key ID").input(.identifier, $history.keyID)
                TextField("Issuer ID", text: $history.issuerID).accessibilityLabel("Issuer ID").input(.identifier, $history.issuerID)
                TextField("Bundle IDs, comma separated", text: $history.bundleIDs).accessibilityLabel("Bundle IDs").input(.list, $history.bundleIDs)
                HStack {
                    SecureField("", text: $key, prompt: Text(history.hasKey ? "Saved in Keychain" : "Paste the .p8 key"))
                        .accessibilityLabel("In-App Purchase private key").input(.pem, $key)
                    if !key.isEmpty { Button("Save") { history.saveKey(key); key = "" }.buttonStyle(.pillProminent) }
                }
                HStack(spacing: 6) {
                    Text("Key from App Store Connect → Integrations → In-App Purchase").font(.callout).foregroundStyle(.secondary)
                    InfoTip("Also set any address under App → App Information → App Store Server Notifications. Apple keeps the history even if nothing answers there; the app reads it every 5 minutes.")
                }
                if let s = history.status { Label(s, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Brand.caution) }
                else if let t = history.lastCheck { Label("Checked \(Ago.text(t))", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green) }
            }
            if mode == "cloudflare" {
                if let url = live.url {
                    if !live.ownWorker {
                        LabeledContent("Reading from") { Text(url).textSelection(.enabled).font(.callout.monospaced()) }
                    }
                    if let apple = live.appleAddress {
                        LabeledContent("Address for App Store Connect") {
                            Text(apple).textSelection(.enabled).font(.callout.monospaced())
                        }
                    }
                    if let hook = live.ascWebhookAddress {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Instant App Store Connect updates (optional)").font(.body.weight(.semibold))
                            Text("Apple calls this address when a version's review state or a TestFlight build changes, so you hear in minutes instead of within the hour. Creating the webhook is a change in your App Store Connect, so you do it: copy the request below and send it with your App Store Connect API key. Hmunmawi never creates it.")
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            LabeledContent("Webhook address") { Text(hook).textSelection(.enabled).font(.callout.monospaced()) }
                            HStack {
                                Button("Copy secret") { copyToClipboard(live.ascWebhookSecret()) }
                                Menu("Copy request for…") {
                                    ForEach(WebhookApps.list(model), id: \.id) { app in
                                        Button(app.name) { if let b = live.ascWebhookRequestBody(appID: app.id) { copyToClipboard(b) } }
                                    }
                                }
                            }
                            if live.hasHookWorker {
                                HStack {
                                    if live.canUpdateHooksWorker && !live.hookTokenRefused {
                                        Button("Update worker") { Task { await live.updateHooksWorkerWithSavedToken() } }
                                            .disabled(live.busy)
                                            .help("Puts this version's worker code on Cloudflare; its address and keys stay the same. It also happens by itself when a new version brings worker changes.")
                                    }
                                    ConfirmButton(title: "Remove webhook worker from Cloudflare", question: "Remove the webhook worker?", detail: "App Store Connect updates stop arriving until you set it up again.") { Task { await live.removeHooks() } }
                                        .disabled(live.busy)
                                }
                                if live.hookTokenRefused {
                                    Label("Cloudflare refused the saved token. Paste one with Workers Scripts: Edit and Workers KV Storage: Edit for this account.", systemImage: "exclamationmark.triangle.fill")
                                        .font(.callout).foregroundStyle(Brand.caution).fixedSize(horizontal: false, vertical: true)
                                }
                                if !live.canUpdateHooksWorker || live.hookTokenRefused {
                                    HStack {
                                        SecureField("", text: $cfToken, prompt: Text("Cloudflare API token, to update the webhook worker"))
                                            .accessibilityLabel("Cloudflare API token to update the webhook worker").input(.secret, $cfToken)
                                        Button("Update worker") { Task { await live.updateHooksWorker(token: cfToken); cfToken = "" } }.disabled(cfToken.isEmpty || live.busy)
                                    }
                                }
                            } else {
                                HStack {
                                    SecureField("", text: $cfToken, prompt: Text("Cloudflare API token, only to add webhook support to a worker set up earlier"))
                                        .accessibilityLabel("Cloudflare API token to update the worker").input(.secret, $cfToken)
                                    Button("Update worker") { Task { await live.deploy(token: cfToken); cfToken = "" } }.disabled(cfToken.isEmpty || live.busy)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    } else {
                        // Sales already arrive through a relay of your own: a separate small worker takes the webhooks, and
                        // where purchases are read from stays exactly as it is.
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Instant App Store Connect updates (optional)").font(.body.weight(.semibold))
                            Text("Your sales already arrive through the outbox above, and that stays as it is. For review and TestFlight changes within minutes, Hmunmawi can add a separate small worker to your Cloudflare account that only receives Apple's webhooks. Creating the webhook itself is a change in your App Store Connect, so you do it (or tell Hmunmawi to).")
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            HStack {
                                SecureField("", text: $cfToken, prompt: Text("Cloudflare API token (Workers Scripts and Workers KV: Edit)"))
                                    .accessibilityLabel("Cloudflare API token for the webhook worker").input(.secret, $cfToken)
                                Button("Set up webhook worker") { Task { await live.deployHooks(token: cfToken); cfToken = "" } }.disabled(cfToken.isEmpty || live.busy)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    if let t = live.lastTestAt { Label("Apple's test notification arrived \(Ago.text(t))", systemImage: "checkmark.seal.fill").foregroundStyle(.green) }
                    if live.canUpdatePurchaseWorker {
                        Button("Update purchase worker") { Task { await live.updatePurchaseWorker() } }
                            .disabled(live.busy)
                            .help("Puts this version's worker code on Cloudflare with the token you saved; your app names must be filled in.")
                    }
                    ConfirmButton(title: live.ownWorker ? "Remove from Cloudflare" : "Disconnect", question: live.ownWorker ? "Remove live updates from Cloudflare?" : "Disconnect live updates?", detail: "New purchases stop showing up live until you connect again.") { Task { await live.remove() } }
                } else {
                    HStack {
                        SecureField("", text: $cfToken, prompt: Text("Cloudflare API token"))
                            .accessibilityLabel("Cloudflare API token").input(.secret, $cfToken)
                        Button("Set up") { Task { await live.deploy(token: cfToken); cfToken = "" } }
                            .buttonStyle(.pillProminent).disabled(cfToken.isEmpty || live.busy)
                    }
                    HStack(spacing: 6) {
                        Text("Token with Workers Scripts and Workers KV: Edit").font(.callout).foregroundStyle(.secondary)
                        InfoTip("Free Cloudflare account → My Profile → API Tokens → Create Token. The app creates a small worker in your account: only Apple-signed notifications are kept, for 7 days, and only this Mac can read them. Remove deletes it all.")
                    }
                    Text("Already run one? Connect it").font(.body.weight(.semibold)).padding(.top, 4)
                    Group {
                        TextField("Outbox address", text: $existingURL, prompt: Text("https://…/outbox")).accessibilityLabel("Existing outbox address").input(.url, $existingURL)
                        HStack {
                            SecureField("", text: $existingKey, prompt: Text("Relay key")).accessibilityLabel("Existing outbox relay key").input(.secret, $existingKey)
                            Button("Connect outbox") { Task { await live.connect(outbox: existingURL, key: existingKey); existingKey = "" } }
                                .disabled(existingURL.isEmpty || existingKey.isEmpty)
                        }
                    }
                }
                TextField("App names: bundle.id=Name, comma separated", text: $live.appNames).accessibilityLabel("App names for bundle IDs").input(.list, $live.appNames)
                if live.busy { ProgressView().controlSize(.small) }
                if let s = live.status { Text(s).font(.callout).foregroundStyle(.secondary) }
            }
        } header: { Label("Live sales", systemImage: "bolt.horizontal") }
        .task(id: live.busy) { live.refreshSavedTokens() }
    }
}

/// Where X numbers come from (always free): a file a bot or Mac job already writes. The X connection reads it.
private struct XSourceSection: View {
    @State private var feed = XFileFeed.shared
    @State private var plan = XPlan.shared
    @State private var reader = XSafariReader.shared
    @State private var copied = false
    @State private var glanceCopied = false
    @AppStorage("HMXGlanceFile") private var glanceFile = ""

    /// What to paste to Grok Bot once so it writes the X glance file (docs/X-FILE.md, `glance`).
    static func glanceRequest(file: String) -> String {
        let path = file.isEmpty ? "x_glance.json in a folder Hmunmawi can read" : file
        return """
        Each morning, read my own X account (no posting, no likes, nothing sent) and save this JSON as \(path):
        {"updated": "<ISO 8601 time>",
         "pinned": {"title": "<pinned post or article title>", "kind": "post or article", "url": "https://x.com/<me>/status/<id>", "views": 0, "likes": 0, "replies": 0},
         "latest_article": {"title": "<my newest X Article>", "url": "https://x.com/<me>/status/<id>", "views": 0, "likes": 0},
         "taking_off": <one of my posts from the last 7 days with at least 3x my average views, same fields as pinned, or null>,
         "taking_off_reason": "<one short sentence why, or why nothing is>",
         "top_replies": [{"to": "@<who I replied to>", "url": "https://x.com/<me>/status/<id>", "views": 0}]}
        top_replies: my two most-viewed replies of the last 7 days. Leave out anything you can't read; never guess a number.
        """
    }

    var body: some View {
        Section {
            Toggle(isOn: $reader.enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Read via your Safari login")
                    Text("Every 6 hours your own X profile opens in a background Safari tab where you're signed in; your numbers are read and the tab closes. Free, no X API, nothing is posted.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if reader.enabled {
                HStack {
                    TextField("Your X handle", text: $reader.handle, prompt: Text("e.g. yourname")).accessibilityLabel("Your X handle")
                        .input(.identifier, $reader.handle)
                    Button(reader.busy ? "Reading…" : "Read now") { Task { await reader.readIfDue(force: true) } }
                        .disabled(reader.busy || XNative.validHandle(reader.handle) == nil)
                }
                if let n = reader.note { Text(n).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                Text("Once in Safari: Settings → Advanced → Show features for web developers, then Develop → Allow JavaScript from Apple Events.")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            PathField(label: "X numbers file (from Grok Bot or a Safari read)", prompt: "Choose the file", text: $feed.path, folders: false)
            if let t = feed.lastRead {
                Label("File updated \(Ago.text(t))", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
            } else {
                HStack(spacing: 6) {
                    Text("Free, no key needed").font(.callout).foregroundStyle(.secondary)
                    InfoTip("Point this at the file Grok Bot or a Safari read of your own X page writes. The X connection reads your numbers from it for free.")
                }
            }
            PathField(label: "X glance file from Grok Bot (optional)", prompt: "Choose the file", text: $glanceFile, folders: false)
            HStack(spacing: 8) {
                Text("Pinned post, latest article, a post taking off and your top replies. The Safari read fills these in too; the newer one is shown.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(glanceCopied ? "Copied" : "Copy request for Grok Bot") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.glanceRequest(file: glanceFile), forType: .string)
                    glanceCopied = true
                }
                .controlSize(.small)
            }
            Picker("Your X plan from", selection: $plan.source) {
                Text("The X file").tag("bot")
                Text("A receipt").tag("receipt")
                Text("I'll type it").tag("typed")
            }
            if plan.source == "receipt" { ReceiptDrop(plan: plan) }
            if plan.source == "typed" {
                TextField("Plan", text: $plan.name, prompt: Text("e.g. Premium")).accessibilityLabel("X plan name").input(.name, $plan.name)
                TextField("Price", text: $plan.price, prompt: Text("e.g. $30 a month")).accessibilityLabel("X plan price").input(.short, $plan.price)
                DatePicker("Renews", selection: Binding(get: { plan.renews ?? .now }, set: { plan.renews = $0 }), displayedComponents: .date)
            }
            if plan.source == "bot", plan.missingInFile {
                HStack(spacing: 8) {
                    Text("Your X file has no plan details yet.").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button(copied ? "Copied" : "Copy request for Grok Bot") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(XPlan.botRequest(file: feed.path), forType: .string)
                        copied = true
                    }
                    Button("Type it instead") { plan.source = "typed" }
                }
                .controlSize(.small)
            }
            if let s = plan.summary {
                VStack(alignment: .leading, spacing: 2) {
                    Label(s, systemImage: "checkmark.seal.fill").font(.callout).foregroundStyle(.green)
                    Text(plan.origin(fileDate: feed.lastRead)).font(.footnote).foregroundStyle(.secondary)
                }
            } else if let n = plan.note {
                Text(n).font(.callout).foregroundStyle(.secondary)
            }
        } header: { Label("X numbers", systemImage: "bubble.left.and.text.bubble.right") }
    }
}


/// A small ⓘ that shows the longer explanation on click, so forms stay short.
struct InfoTip: View {
    let text: String
    @State private var shown = false
    init(_ text: String) { self.text = text }

    var body: some View {
        Button { shown.toggle() } label: { Image(systemName: "info.circle") }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            .accessibilityLabel("More information")
            .help(text)
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true).frame(width: 300).padding(14)
            }
    }
}


/// SwiftUI makes the Settings window fixed-size; this lets you drag it larger (as macOS apps with long
/// settings do), keeping a sensible minimum.
struct ResizableWindow: NSViewRepresentable {
    let minSize: CGSize
    func makeNSView(context: Context) -> NSView { let v = NSView(); apply(v); return v }
    func updateNSView(_ v: NSView, context: Context) { apply(v) }

    /// SwiftUI sets the Settings window's style after its content appears (and again on tab switches),
    /// so the resizable flag is applied a moment later as well.
    private func apply(_ v: NSView) {
        for delay in [0.0, 0.3, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let windows = [v.window].compactMap { $0 } + NSApp.windows.filter { $0.identifier?.rawValue.contains("Settings") == true }
                for w in windows {
                    w.styleMask.insert(.resizable)
                    w.contentMinSize = minSize
                    w.contentMaxSize = CGSize(width: 10_000, height: 10_000)
                }
            }
        }
    }
}


/// Your dashboard on the web: a page you already publish (for example on Cloudflare Pages behind Cloudflare
/// Access), linked here so it opens from the app.
private struct WebDashboardSection: View {
    @State private var url = UserDefaults.standard.string(forKey: "HMWebDashboard") ?? ""
    @State private var reachable: Bool?

    var body: some View {
        Section {
            HStack {
                TextField("Address", text: $url, prompt: Text("https://…")).accessibilityLabel("Web dashboard address").input(.url, $url)
                    .onSubmit { UserDefaults.standard.set(url, forKey: "HMWebDashboard"); check() }
                if let u = URL(string: url), url.hasPrefix("https://") {
                    Link("Open", destination: u)
                }
            }
            if let reachable {
                Label(reachable ? "Online, behind your login" : "Couldn't reach it", systemImage: reachable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(reachable ? .green : Brand.caution)
            }
            HStack(spacing: 6) {
                Text("Link a dashboard page you already publish, to open it from here")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } header: { Label("Web dashboard", systemImage: "safari") }
        .task { check() }
    }

    /// A page behind Cloudflare Access answers with a redirect to its login; that counts as online.
    private func check() {
        guard let u = URL(string: url), url.hasPrefix("https://") else { reachable = nil; return }
        Task {
            var req = URLRequest(url: u, timeoutInterval: 10); req.httpMethod = "HEAD"
            let code = ((try? await URLSession(configuration: .ephemeral).data(for: req))?.1 as? HTTPURLResponse)?.statusCode ?? 0
            reachable = (200..<400).contains(code)
        }
    }
}


/// Drop a receipt (screenshot, photo, PDF or email), paste a screenshot, or choose a file.
private struct ReceiptDrop: View {
    let plan: XPlan
    @State private var over = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.text.viewfinder").font(.title2).foregroundStyle(over ? Color.accentColor : .secondary)
            Text("Drop your X receipt here").font(.callout.weight(.semibold))
            Text("Screenshot, photo, PDF or email · read on this Mac").font(.footnote).foregroundStyle(.secondary)
            HStack {
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.image, .pdf, .emailMessage, .plainText]
                    if panel.runModal() == .OK, let url = panel.url { plan.readReceipt(url) }
                }
                .buttonStyle(.pill)
                Button("Paste") {
                    if let img = NSImage(pasteboard: .general) { plan.readReceipt(image: img) }
                }
                .buttonStyle(.pill)
                .disabled(!NSImage.canInit(with: .general))
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity).padding(14)
        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .foregroundStyle(over ? Color.accentColor : Color.secondary.opacity(0.4)))
        .onDrop(of: [.fileURL], isTargeted: $over) { items in
            _ = items.first?.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in plan.readReceipt(url) } }
            }
            return true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drop your X receipt")
    }
}


/// Settings → Connections: where the outreach reply watch reads your mail from (see MailWatch).
private struct MailSourceSection: View {
    let permissions: Permissions
    let model: AppModel
    @AppStorage(MailWatch.kindKey) private var kindRaw = MailSourceKind.off.rawValue
    @AppStorage(MailWatch.hostKey) private var host = ""
    @AppStorage(MailWatch.zohoHostKey) private var zohoHost = "mail.zoho.com"
    @AppStorage(MailWatch.portKey) private var port = 993
    @AppStorage(MailWatch.userKey) private var user = ""
    @State private var password = ""
    @State private var note = MailWatch.note
    @State private var busy = false

    private var kind: MailSourceKind { MailSourceKind(rawValue: kindRaw) ?? .off }
    private var config: IMAPConfig { IMAPConfig(host: host, port: port, username: user, password: password) }

    var body: some View {
        Section {
            Picker("Read replies from", selection: $kindRaw) {
                ForEach(MailSourceKind.offered(current: kind)) { Text($0.title).tag($0.rawValue) }
            }
            if kind == .appleMail {
                HStack {
                    Label(permissions.mail == .granted ? "Hmunmawi may read Apple Mail" : "Needs your one-time OK for Apple Mail",
                          systemImage: permissions.mail == .granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(permissions.mail == .granted ? Brand.good : Brand.caution)
                    Spacer()
                    if permissions.mail != .granted { Button("Allow") { Task { await permissions.askMail() } } }
                }
            }
            if kind == .zohoSafari {
                Picker("Zoho address you sign in at", selection: $zohoHost) {
                    ForEach(ZohoSafariReader.hosts, id: \.self) { Text($0).tag($0) }
                }
                HStack {
                    Label(permissions.safari == .granted ? "Hmunmawi may read Safari" : "Needs your one-time OK for Safari",
                          systemImage: permissions.safari == .granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(permissions.safari == .granted ? Brand.good : Brand.caution)
                    Spacer()
                    if permissions.safari != .granted { Button("Allow") { Task { await permissions.askSafari() } } }
                }
                Text("For Zoho's free plan (no IMAP). Hmunmawi opens Zoho's page in a background Safari tab, with the login Safari already has, reads senders and subjects, and reads message text only for threads matching your outreach list (leaving unread status untouched). It never sees your password, and sends only when you explicitly approve an email in Log → Waiting. In Safari, turn on Develop → Allow JavaScript from Apple Events. Zoho doesn't publish this page's layout, so a Zoho redesign can stop it working; the note below tells you if so.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if kind == .imap {
                Menu("Fill in the server for…") {
                    Button("Gmail") { host = "imap.gmail.com"; port = 993 }
                    Button("iCloud Mail") { host = "imap.mail.me.com"; port = 993 }
                    Button("Outlook.com") { host = "outlook.office365.com"; port = 993 }
                    Button("Fastmail") { host = "imap.fastmail.com"; port = 993 }
                    Menu("Zoho Mail") {
                        Button("Your own domain (global)") { host = "imappro.zoho.com"; port = 993 }
                        Button("Your own domain (India)") { host = "imappro.zoho.in"; port = 993 }
                        Button("zoho.com address") { host = "imap.zoho.com"; port = 993 }
                    }
                }
                if host.contains("zoho") { Text("Zoho's free plan has no IMAP: this needs a paid Zoho plan and an app-specific password from Zoho. On the free plan, replies can still reach Hmunmawi through a script that reads your signed-in Zoho page in Safari and feeds them in (Connections → Script feed). Zoho's data centres use different servers (.com, .in, .eu): use the one you sign in at.")
                    .font(.footnote).foregroundStyle(.secondary) }
                TextField("Server", text: $host, prompt: Text("imap.example.com")).input(.identifier, $host)
                TextField("Port", value: $port, format: .number.grouping(.never)).clamp($port, 1...65535)
                TextField("Address or username", text: $user).input(.text(254), $user)
                SecureField("App password", text: $password).input(.secret, $password)
                if let problem = config.problem, !(host.isEmpty && user.isEmpty && password.isEmpty) {
                    Text(problem).font(.callout).foregroundStyle(Brand.caution)
                }
            }
            if kind != .off {
                HStack {
                    Button(busy ? "Reading" : "Save and read now") { Task { await save() } }
                        .disabled(busy || (kind == .imap && config.problem != nil))
                    if !note.isEmpty { Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
            }
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Outreach replies").font(.title3.weight(.semibold)).foregroundStyle(.primary)
                Text("Where Hmunmawi looks for answers to your pitches and follow-ups.").font(.callout).foregroundStyle(.secondary)
            }.padding(.top, 8)
        } footer: {
            Label("Inbox scan reads sender, subject and dates only; message bodies are read read-only strictly for matched outreach threads (unread untouched). Outbound mail sends only when you explicitly approve an item in Log → Waiting. Passwords stay in your Keychain.", systemImage: "lock.fill")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .task { password = MailWatch.password(); await permissions.refreshIfStale(olderThan: 30) }
    }

    private func save() async {
        busy = true; defer { busy = false }
        if kind == .imap { do { try MailWatch.setPassword(password) } catch { note = "Couldn't save the password: \(error.localizedDescription)"; return } }
        note = await MailWatch.refresh(model: model, force: true)
    }
}


/// The apps (name and App Store Connect id) that Hmunmawi knows, for "Copy request for…".
@MainActor
enum WebhookApps {
    struct App { let id: String, name: String }
    static func list(_ model: AppModel) -> [App] {
        model.snapshots("icon.snapshot").compactMap { e in
            guard let id = e.payload[path: "appID"]?.string, let name = e.app else { return nil }
            return App(id: id, name: ComingSoon.shortName(name))
        }
    }
}

@MainActor private func copyToClipboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}


/// Settings → General: save your data as a spreadsheet or JSON file, wherever you choose. Nothing leaves the Mac.
private struct ExportSection: View {
    let model: AppModel
    @State private var dataset = DataExport.Dataset.reviews
    @State private var days = 90
    @State private var asJSON = false
    @State private var note: String?
    @State private var busy = false

    var body: some View {
        Section {
            Picker("What", selection: $dataset) { ForEach(DataExport.Dataset.allCases, id: \.self) { Text($0.title).tag($0) } }
            Picker("How far back", selection: $days) {
                Text("30 days").tag(30); Text("90 days").tag(90); Text("1 year").tag(365); Text("Everything").tag(0)
            }
            Picker("Format", selection: $asJSON) { Text("Spreadsheet (CSV)").tag(false); Text("JSON").tag(true) }
            HStack {
                Button(busy ? "Preparing" : "Export…") { Task { await export() } }.disabled(busy)
                if let note { Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        } header: {
            Text("Export your data")
        } footer: {
            Text("Saved where you choose; nothing is sent anywhere. Review texts come from people, so a spreadsheet may show them with a leading apostrophe when they start with = + - or @, to keep them from running as formulas.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func export() async {
        guard let store = model.liveStore else { note = "The app isn't ready yet."; return }
        busy = true; defer { busy = false }
        let since = days == 0 ? 0 : Millis(Date.now.addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970 * 1000)
        let kinds = dataset.kinds
        let events: [StoredEvent]
        do {
            if let kinds {
                var all: [StoredEvent] = []
                for k in kinds.sorted() { all += try await store.events(kind: k, since: since) }
                events = all
            }
            else { events = try await store.events(since: since) }
        } catch { note = "Couldn't read your data: \(error.localizedDescription)"; return }
        let table = DataExport.table(dataset, events: events)
        let text = asJSON ? DataExport.json(table) : DataExport.csv(table)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = DataExport.filename(dataset, json: asJSON)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { note = nil; return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            note = "Saved \(table.rows.count) row\(table.rows.count == 1 ? "" : "s") to \(url.lastPathComponent)."
        } catch { note = "Couldn't save the file: \(error.localizedDescription)" }
    }
}


/// Settings → About → Wall of Apps: put your app on the project's public wall, by pull request from your GitHub.
private struct WallOfAppsBox: View {
    @State private var community = WallCommunity.shared
    @AppStorage(WallCommunity.showKey) private var showCommunity = false
    @State private var input = ""
    @State private var entry: WallOfApps.Entry?
    @State private var note: String?
    @State private var busy = false
    @State private var confirm = false
    @State private var plan = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Wall of Apps").font(.headline)
            Text("Apps whose developers use Hmunmawi, on the project's GitHub page. Add yours with a pull request from your own GitHub account (needs the GitHub CLI, gh).")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("App Store ID or link", text: $input).input(.text(200), $input)
                Button(busy ? "Looking…" : "Look up") {
                    Task { busy = true; entry = nil; note = nil
                        switch await WallSubmit.lookup(input) { case .success(let e): entry = e; case .failure(let f): note = f.text }
                        busy = false }
                }.disabled(busy || input.isEmpty)
            }
            if let e = entry {
                HStack(spacing: 10) {
                    AsyncImage(url: URL(string: e.icon)) { $0.resizable() } placeholder: { Color.secondary.opacity(0.15) }
                        .frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading) { Text(e.app).font(.callout.weight(.medium)); Text("App Store").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Add to the wall…") {
                        Task { busy = true
                            switch await WallSubmit.submit(e, dryRun: true) { case .success(let p): plan = p; confirm = true; case .failure(let f): note = f.text }
                            busy = false }
                    }.disabled(busy)
                }
            }
            if let note { Text(note).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            // Your app made it: share it from your own X account (you press post).
            ForEach(community.mine, id: \.link) { e in
                HStack(spacing: 10) {
                    AsyncImage(url: URL(string: e.icon)) { $0.resizable() } placeholder: { Color.secondary.opacity(0.15) }
                        .frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 7))
                    Text("\(e.app) is on the Wall of Apps 🎉").font(.callout.weight(.medium))
                    Spacer()
                    Button("Share on X") { community.share(e) }.buttonStyle(.pillProminent)
                    Button("Not now") { community.finishShare(e) }.buttonStyle(.pill)
                }
                .padding(10).background(Brand.good.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            }
            Divider().padding(.vertical, 2)
            Toggle(isOn: $showCommunity) {
                Text("Show the community's apps")
                Text("Reads the public list from the project's GitHub about twice a day. Nothing about you is sent.")
            }
            if showCommunity {
                if let status = community.status { Text(status).font(.callout).foregroundStyle(.secondary) }
                if community.apps.isEmpty, community.status == nil {
                    Text("No apps on the wall yet. Be the first.").font(.callout).foregroundStyle(.secondary)
                } else if !community.apps.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44, maximum: 52), spacing: 10)], alignment: .leading, spacing: 10) {
                        ForEach(community.apps.prefix(60), id: \.link) { e in
                            Link(destination: URL(string: e.link) ?? URL(string: "https://apps.apple.com")!) {
                                AsyncImage(url: URL(string: e.icon)) { $0.resizable() } placeholder: { Color.secondary.opacity(0.15) }
                                    .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .help([e.app, e.developer].compactMap { $0 }.joined(separator: " · "))
                        }
                    }
                    Text("\(community.apps.count) app\(community.apps.count == 1 ? "" : "s") on the wall").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .task(id: showCommunity) { await community.refreshIfDue(force: showCommunity && community.apps.isEmpty) }
        .confirmationDialog("Open a pull request?", isPresented: $confirm) {
            Button("Open pull request") {
                guard let e = entry else { return }
                Task { busy = true
                    switch await WallSubmit.submit(e, dryRun: false) {
                    case .success(let url):
                        note = "Pull request opened: \(url). Once it's merged, your app appears on the wall and you can share it."
                        community.markSubmitted(e)
                    case .failure(let f): note = f.text
                    }
                    busy = false }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text(plan) }
    }
}
