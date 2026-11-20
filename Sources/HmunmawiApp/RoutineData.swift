import HmunmawiCore
import SwiftUI

/// The ready drafts in one bank (banks/<name>.json): add, read and remove them by hand. Agents use hm bank-add.
struct BankEditor: View {
    @Environment(\.dismiss) private var dismiss
    let bank: String
    @State private var items: [BankItem] = []
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bank “\(bank)”").font(.title2.bold())
            let today = Date.now.localDay
            if !items.isEmpty {
                Text("\(Bank.available(items, today: today)) of \(items.count) ready. A used draft is ready again after 14 days.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if items.isEmpty {
                Text("Empty. Add a few ready posts below; the routine uses these before asking any AI.")
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 6)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(items, id: \.id) { i in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(i.text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                    Text([i.used_on.map { "used \($0)" } ?? "not used yet", i.tag].compactMap { $0 }.joined(separator: " · "))
                                        .font(.callout).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(role: .destructive) { change { $0.removeAll { $0.id == i.id } } } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless).help("Remove this draft")
                            }
                            .padding(.vertical, 8)
                            if i.id != items.last?.id { Divider() }
                        }
                    }
                }
                .frame(maxHeight: 360).fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .bottom) {
                TextField("New draft", text: $draft, prompt: Text("A ready post, as you'd post it"), axis: .vertical)
                    .lineLimit(1...4).textFieldStyle(.roundedBorder).input(.text(1000), $draft)
                Button("Add") {
                    let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { return }
                    change { if $0.count < 2000 { $0.append(BankItem(id: String(UUID().uuidString.prefix(8)).lowercased(), text: t)) } }
                    draft = ""
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.pillProminent) }
        }
        .padding(22)
        .frame(width: 560)
        .onAppear { items = Bankfile.read(bank) }
    }

    /// Applies one edit to the bank as it is on disk now (a routine or an agent may have changed it meanwhile).
    private func change(_ edit: (inout [BankItem]) -> Void) {
        var l = Bankfile.read(bank); edit(&l); Bankfile.write(bank, l); items = l
    }
}

/// The outreach list (outreach.json): who you pitched, and the one follow-up per outlet. Agents use hm outreach-….
struct OutreachEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries = Outreachfile.read()
    @State private var outlet = ""
    @State private var app = ""
    @State private var type = "press pitch"
    @State private var followUp = Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now
    @State private var withFollowUp = true
    @State private var page = ""
    @State private var checking = false
    @State private var checkNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Outreach").font(.title2.bold())
            Text("Who you pitched or listed with, and when to follow up (once per outlet). The follow-up routine reminds you on the day.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if entries.isEmpty {
                Text("Nothing yet. Add your first pitch below.").font(.callout).foregroundStyle(.secondary).padding(.vertical, 6)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.offset) { n, e in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(e.outlet) · \(e.app)").font(.body.weight(.medium))
                                    Text(line(e)).font(.callout)
                                        .foregroundStyle(e.due(today: Date.now.localDay) ? Brand.caution : Brand.secondaryText)
                                }
                                Spacer()
                                if e.follow_up != nil, e.followed_up != true {
                                    Button("Followed up") {
                                        change { l in if let i = l.firstIndex(where: { $0.outlet == e.outlet && $0.app == e.app }) { l[i].followed_up = true; l[i].follow_up = nil } }
                                    }
                                }
                                Button(role: .destructive) { change { $0.removeAll { $0.outlet == e.outlet && $0.app == e.app } } } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless).help("Remove \(e.outlet)")
                            }
                            .padding(.vertical, 8)
                            if n != entries.count - 1 { Divider() }
                        }
                    }
                }
                .frame(maxHeight: 340).fixedSize(horizontal: false, vertical: true)
            }
            GroupBox {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        TextField("Outlet", text: $outlet, prompt: Text("Outlet or site")).input(.name, $outlet)
                        TextField("App", text: $app, prompt: Text("App")).input(.name, $app)
                        TextField("Type", text: $type, prompt: Text("press pitch")).input(.name, $type)
                    }
                    GridRow {
                        TextField("Their page", text: $page, prompt: Text("https://… (optional: checked before adding)")).input(.url, $page)
                            .gridCellColumns(2)
                        Button(checking ? "Checking…" : "Check") { Task { await check() } }
                            .disabled(checking || InputCheck.httpsURL(page) == nil)
                            .help("Is the page there, is there an email or contact form, is it paid-only, which language, and is it already on your list?")
                    }
                    if let checkNote {
                        GridRow { Text(checkNote).font(.callout).foregroundStyle(.secondary).gridCellColumns(3).fixedSize(horizontal: false, vertical: true) }
                    }
                    GridRow {
                        Toggle("Follow up on", isOn: $withFollowUp)
                        DatePicker("Follow up on", selection: $followUp, displayedComponents: .date).labelsHidden().disabled(!withFollowUp)
                        Button("Add") { add() }.disabled(outlet.trimmingCharacters(in: .whitespaces).isEmpty || app.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .textFieldStyle(.roundedBorder).padding(4)
            }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.pillProminent) }
        }
        .padding(22)
        .frame(width: 620)
    }

    private func line(_ e: OutreachEntry) -> String {
        let follow = e.followed_up == true ? "followed up" : e.follow_up.map { "follow up \($0)" } ?? "no follow-up"
        return "\(e.type) · \(e.status) \(e.date) · \(follow)"
    }

    private func add() {
        let o = InputRule.name.clean(outlet), a = InputRule.name.clean(app)
        guard !o.isEmpty, !a.isEmpty else { return }
        let t = InputRule.name.clean(type.isEmpty ? "press pitch" : type), when = withFollowUp ? followUp.localDay : nil
        change { l in
            // One entry per outlet and app: adding it again updates its follow-up date.
            if let i = l.firstIndex(where: { $0.outlet == o && $0.app == a }) {
                if let when, l[i].followed_up != true { l[i].follow_up = when }
            } else {
                l.append(OutreachEntry(outlet: o, app: a, type: t, status: "submitted", date: Date.now.localDay, follow_up: when,
                                       url: InputCheck.httpsURL(page)?.absoluteString))
            }
        }
        outlet = ""; page = ""; checkNote = nil
    }

    private func change(_ edit: (inout [OutreachEntry]) -> Void) {
        var l = Outreachfile.read(); edit(&l); Outreachfile.write(l); entries = l
    }

    /// "Check before adding": reads the outlet's page (one request) and compares it with your list.
    private func check() async {
        guard let url = InputCheck.httpsURL(page), !InputCheck.isInternalHost(url.host ?? "") else { return }
        checking = true; defer { checking = false }
        let existing = Outreachfile.read().map { (outlet: $0.outlet, where: [$0.contact, $0.url].compactMap { $0 }.joined(separator: " ")) }
        let got = await Routines.fetch(url, maxBytes: 1_500_000)
        var r = OutreachCheck.check(html: got.body ?? "", status: got.status, finalURL: got.final?.absoluteString, candidateURL: url.absoluteString, existing: existing)
        r.duplicateOf = OutreachCheck.duplicates(url: url.absoluteString, email: r.emails.first, outlet: outlet, existing: existing)
        checkNote = r.summary
    }
}

/// Changes being watched (changes.json): what changed, the number that should show it, and the verdict once judged.
struct ChangesEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var changes = Changesfile.read()
    @State private var metrics: [(key: String, name: String, better: String?)] = []
    @State private var better = "up"
    @State private var loading = true
    @State private var what = ""
    @State private var metric = ""
    @State private var date = Date.now
    @State private var days = 28
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Changes I'm watching").font(.title2.bold())
            Text("Tell it what you changed and which number should move. After the wait, it compares the average day before with the average day after and suggests keep, improve or undo. It never undoes anything itself.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if changes.isEmpty {
                Text("Nothing watched yet.").font(.callout).foregroundStyle(.secondary).padding(.vertical, 6)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(changes) { c in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.what).font(.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                                    Text(status(c)).font(.callout).foregroundStyle(c.verdict == "undo" ? Brand.caution : Brand.secondaryText)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    var l = Changesfile.read(); l.removeAll { $0.id == c.id }; Changesfile.write(l); changes = l
                                } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless).help("Stop watching this change")
                            }
                            .padding(.vertical, 8)
                            if c.id != changes.last?.id { Divider() }
                        }
                    }
                }
                .frame(maxHeight: 320).fixedSize(horizontal: false, vertical: true)
            }
            GroupBox {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("What changed").gridColumnAlignment(.trailing)
                        TextField("What changed", text: $what, prompt: Text("New screenshots for Japan")).labelsHidden().input(.text(200), $what)
                    }
                    GridRow {
                        Text("Number to watch")
                        if loading {
                            ProgressView().controlSize(.small)
                        } else if metrics.isEmpty {
                            Text("No number has 14 days of data yet.").foregroundStyle(.secondary)
                        } else {
                            HStack {
                                Picker("Number to watch", selection: $metric) {
                                    ForEach(metrics, id: \.key) { Text($0.name).tag($0.key) }
                                }.labelsHidden()
                                Picker("Better when it goes", selection: $better) {
                                    Text("better when higher").tag("up")
                                    Text("better when lower").tag("down")
                                }.labelsHidden().fixedSize()
                            }
                        }
                    }
                    GridRow {
                        Text("Went live on")
                        HStack {
                            DatePicker("Went live on", selection: $date, in: (Calendar.current.date(byAdding: .day, value: -60, to: .now) ?? .now)...Date.now,
                                       displayedComponents: .date).labelsHidden()
                            Picker("Judge after", selection: $days) {
                                ForEach([7, 14, 28], id: \.self) { Text("judge after \($0) days").tag($0) }
                            }.labelsHidden().fixedSize()
                            Spacer()
                            Button("Watch") {
                                Task {
                                    let r = await Routines.shared.addChange(what: what, metric: metric, date: date.localDay, days: days, better: better)
                                    message = r.message
                                    if r.ok { what = ""; changes = Changesfile.read() }
                                }
                            }
                            .disabled(what.trimmingCharacters(in: .whitespaces).isEmpty || metric.isEmpty)
                        }
                    }
                }
                .textFieldStyle(.roundedBorder).padding(4)
            }
            if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.pillProminent) }
        }
        .padding(22)
        .frame(width: 640)
        .task {
            metrics = await Routines.shared.judgeableMetrics()
            if metric.isEmpty { metric = metrics.first?.key ?? "" }
            loading = false
        }
        // Each number starts with its own direction (refunds and crashes are better lower); you can change it.
        .onChange(of: metric, initial: true) { _, key in better = metrics.first { $0.key == key }?.better ?? "up" }
    }

    private func status(_ c: WatchedChange) -> String {
        let name = c.metricName ?? c.metric
        guard let v = c.verdict else {
            let left = (c.dueDay ?? 0) - (DayNumber.of(Date.now.localDay) ?? 0)
            return "\(name) · live \(c.date) · verdict \(left <= 0 ? "at the next run" : "in \(left) days")"
        }
        let word = ["keep": "Keep", "improve": "No clear effect", "undo": "Think about undoing", "unclear": "Not enough data"][v] ?? v
        return "\(word) · \(c.note ?? name)"
    }

}
