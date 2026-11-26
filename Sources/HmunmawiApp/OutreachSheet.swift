import AppKit
import HmunmawiCore
import SwiftUI

/// Outreach: what the reply watch found (each change waits for your tap), and every pitch or listing with what
/// Hmunmawi keeps for it (notes, do-not-contact, coverage, launch date) and drafts you edit and send yourself.
struct OutreachSheet: View {
    enum Filter: String, CaseIterable {
        case awaiting = "Awaiting reply"
        case replied = "Replied"
        case noReply = "No reply"
        case all = "All"
    }

    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var items: [OItem] = []
    @State private var side = Outreach.Side()
    @State private var filter: Filter = .awaiting
    @Environment(\.openSheet) private var openSheet
    @State private var busy: String?
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Outreach").font(.title2.bold())
                Spacer()
                Button { openSheet?({ AnyView(OutreachSetup().buttonStyle(.pill)) }) } label: { Label("Setup", systemImage: "slider.horizontal.3") }
            }
            Text("Replies, listing decisions, bounces and follow-ups found in your mail. Clear bookkeeping updates automatically with 1-click Undo; uncertain matches and drafts wait for your OK.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            let recentAuto = (side.autoApplied ?? []).filter { $0.undone != true }.suffix(8).reversed()
            if !recentAuto.isEmpty {
                DisclosureGroup("Auto-updated recently (\(recentAuto.count))") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(recentAuto)) { rec in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("\(rec.outlet) · \(rec.kind)").font(.callout.weight(.medium))
                                    Text(rec.why).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Undo") {
                                    Task {
                                        busy = rec.id
                                        let r = await Outreach.undoAutoApplied(rec)
                                        busy = nil
                                        note = r.note
                                        reload()
                                    }
                                }.buttonStyle(.pill).disabled(busy != nil)
                            }
                        }
                    }.padding(.top, 4)
                }
                .font(.callout)
            }
            let open = side.suggestions.filter { $0.state == "new" }
            if !open.isEmpty {
                HStack {
                    Text("To look at (\(open.count))").font(.headline)
                    Spacer()
                    let closes = open.filter { $0.kind == "no reply" }
                    if closes.count > 1 {
                        Button("Close all \(closes.count) as no reply") { Task { for s in closes { await apply(s) } } }.disabled(busy != nil)
                    }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(open.enumerated()), id: \.element.id) { n, s in
                            suggestionRow(s)
                            if n < open.count - 1 { Divider() }
                        }
                    }.padding(.horizontal, 10)
                }
                .frame(maxHeight: 300).fixedSize(horizontal: false, vertical: true)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            }
            if let note { Text(note).font(.callout).foregroundStyle(.secondary) }
            let shown = filteredItems
            HStack {
                Text("\(filter.rawValue) (\(shown.count))").font(.headline)
                Spacer()
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { n, i in
                        Button { let m = model; openSheet?({ AnyView(OutreachDetail(model: m, item: i).buttonStyle(.pill)) }) } label: { itemRow(i) }.buttonStyle(.plain)
                        if n < shown.count - 1 { Divider() }
                    }
                    if shown.isEmpty { Text(items.isEmpty ? "No outreach list yet. Open Setup." : "Nothing in \(filter.rawValue.lowercased()).").foregroundStyle(.secondary).padding(.vertical, 8) }
                }
            }
            .frame(minHeight: 160, maxHeight: 360)
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.pillProminent) }
        }
        .padding(22)
        .frame(minWidth: 560, idealWidth: 760)
        .onAppear(perform: reload)
    }

    private var filteredItems: [OItem] {
        let matches: [OItem] = switch filter {
        case .awaiting:
            items.filter { ["submitted", "pending review"].contains($0.status) }
        case .replied:
            items.filter { ["replied", "approved", "live"].contains($0.status) || side.extras[$0.id]?.coverage?.isEmpty == false }
        case .noReply:
            items.filter { ["no reply", "rejected", "bounced"].contains($0.status) }
        case .all:
            items
        }
        return matches.sorted { ($0.followUp ?? "9999", $1.date) < ($1.followUp ?? "9999", $0.date) }
    }

    private func reload() {
        let loaded = Outreach.items()
        Outreach.purgeSelfAuthoredThreads(items: loaded, mail: Outreach.mail(model.events))
        items = loaded
        side = Outreach.side()
    }

    private static let words: [String: String] = [
        "replied": "answered", "approved": "approved the listing", "live": "listing is live", "rejected": "declined",
        "bounced": "bounced: the address failed", "verify": "wants you to confirm your email", "followed up": "your follow-up went out",
        "auto-reply": "is away (auto-reply)", "no reply": "close as no reply",
        "launch": "follow-up should wait for the launch", "thank": "covered you: say thanks", "repitch": "worth telling about the new version",
        "answer": "is waiting for your answer", "check in": "time for one friendly check-in", "covered": "may have covered you"]

    private static func threadWords(_ s: OSuggestion) -> String {
        switch s.thread ?? "" {
        case "your turn": return "wrote again: your turn, they asked something"
        case "promised": return s.promise == "coverage" ? "wrote again: they may cover it (Hmunmawi watches for it)"
            : s.promise == "testing" ? "wrote again: they're testing it" : "wrote again: they'll get back to you"
        case "scheduled": return "wrote again: a date is set"
        case "passed on": return "wrote again: passed you to someone else"
        case "declined": return "wrote again: not for them"
        case "done": return "wrote again: just thanks, nothing to do"
        default: return "wrote again: read it yourself"
        }
    }

    @ViewBuilder private func suggestionRow(_ s: OSuggestion) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("\(s.outlet) · \(s.app.replacingOccurrences(of: "+", with: " & "))").font(.body.weight(.medium))
                    if !s.sure { Text("maybe").font(.caption.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Brand.caution.opacity(0.18), in: Capsule()).foregroundStyle(Brand.caution) }
                }
                Text(s.kind == "thread" ? Self.threadWords(s) : (Self.words[s.kind] ?? s.kind)).font(.callout)
                if let l = s.link, let u = InputCheck.httpsURL(l) { Link(l, destination: u).font(.callout).lineLimit(1).truncationMode(.middle) }
                Text([s.mailSubject.map { "“\($0)”" }, s.mailFrom, s.why].compactMap { $0 }.joined(separator: " · "))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Not this") { mark(s, "dismissed") }
            Button(applyTitle(s)) { Task { await apply(s) } }.buttonStyle(.pillProminent).disabled(busy != nil)
        }
        .padding(.vertical, 8)
    }

    private func applyTitle(_ s: OSuggestion) -> String {
        if s.kind == "thread" { return "OK" }
        if s.kind == "covered" { return "Add coverage" }
        if let st = s.status { return "Mark \(st)" }
        if let f = s.followUp { return "Follow up \(Outreach.prettyDay(f))" }
        if s.markFollowedUp == true { return "Mark followed up" }
        return "Done"
    }

    private func mark(_ s: OSuggestion, _ state: String) {
        Outreach.changeSide { side in if let i = side.suggestions.firstIndex(where: { $0.id == s.id }) { side.suggestions[i].state = state } }
        reload()
    }

    private func apply(_ s: OSuggestion) async {
        // A conversation's new state: remembered here (and the list's status, if it changes).
        if s.kind == "thread", let st = s.thread {
            let mailID = String(s.id.split(separator: "|").last ?? "")
            Outreach.changeSide { $0.threads = ($0.threads ?? [:]).merging([s.entry: Outreach.Thread(state: st, promise: s.promise, since: s.day, mail: mailID, evidence: s.why)]) { _, b in b } }
            if s.status != nil, let item = items.first(where: { $0.id == s.entry }) {
                let r = await Outreach.apply(item, status: s.status, followUp: nil, markFollowedUp: false)
                if !r.ok { note = r.note; return }
            }
            mark(s, "done"); return
        }
        if s.kind == "covered", let l = s.link {
            Outreach.changeSide { side in
                var x = side.extras[s.entry] ?? OutreachExtra()
                x.coverage = (x.coverage ?? []) + [.init(url: l, date: Date.now.localDay)]
                side.extras[s.entry] = x
            }
            mark(s, "done"); return
        }
        if s.kind == "answer" || s.kind == "check in" {
            Outreach.changeSide { side in if var th = side.threads?[s.entry] { th.checkedIn = true; side.threads?[s.entry] = th } }
            mark(s, "done"); return
        }
        guard s.status != nil || s.followUp != nil || s.markFollowedUp == true else {
            if s.kind == "thank" { Outreach.changeSide { $0.extras[s.entry, default: OutreachExtra()].thankedOn = Date.now.localDay } }
            mark(s, "done"); return
        }
        guard let item = items.first(where: { $0.id == s.entry }) else { note = "That entry isn't in the list any more."; return }
        busy = s.id
        let r = await Outreach.apply(item, status: s.status, followUp: s.followUp, markFollowedUp: s.markFollowedUp == true)
        busy = nil
        note = r.ok ? "\(s.outlet): \(applyTitle(s).lowercased())." : r.note
        if r.ok { mark(s, "done") }
    }

    @ViewBuilder private func itemRow(_ i: OItem) -> some View {
        let x = side.extras[i.id]
        let hasReply = i.status == "replied" || side.threads?[i.id] != nil
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(i.outlet).font(.body.weight(.medium))
                    if x?.dnc == true { Image(systemName: "hand.raised.fill").foregroundStyle(Brand.caution).help("Don't contact again") }
                    if x?.coverage?.isEmpty == false { Image(systemName: "newspaper.fill").foregroundStyle(Brand.good).help("Covered you") }
                }
                Text("\(i.app.replacingOccurrences(of: "+", with: " & ")) · \(i.type) · sent \(Outreach.prettyDay(i.date))").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if i.status == "replied" {
                Text("Replied").font(.callout.weight(.medium)).foregroundStyle(Brand.good)
            } else if i.status == "no reply" {
                Text(i.followedUpOn != nil ? "No reply · followed up" : "No reply received").font(.callout).foregroundStyle(.secondary)
            } else if i.status == "submitted" && i.isEmail && !hasReply {
                Text(i.followedUpOn != nil ? "Followed up · 0 replies" : "Awaiting reply").font(.callout).foregroundStyle(.secondary)
            } else {
                Text(i.status).font(.callout)
            }
            if let f = i.followUp {
                let late = (DayNumber.of(f) ?? 0) < (DayNumber.of(Date.now.localDay) ?? 0)
                Text("follow up \(Outreach.prettyDay(f))").font(.callout).foregroundStyle(late ? Brand.caution : Brand.secondaryText)
            }
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(.vertical, 7).contentShape(Rectangle())
    }
}

/// One outreach entry: what Hmunmawi keeps for it, and drafts you edit and send yourself.
struct OutreachDetail: View {
    let model: AppModel
    let item: OItem
    @Environment(\.dismiss) private var dismiss
    @State private var extra = OutreachExtra()
    @State private var coverageURL = ""
    @State private var hasLaunch = false
    @State private var launch = Date.now
    @State private var draftSubject = ""
    @State private var draft = ""
    @State private var theirMessage = ""
    @State private var withCode = false
    @State private var busy = false
    @State private var confirmSend = false
    @State private var note: String?

    private var appID: String? {
        OfferCodes.shared.appIDs.first { QuickName.of($0, model: model).caseInsensitiveCompare(item.app.split(separator: "+").first.map(String.init) ?? item.app) == .orderedSame }
    }
    private var inReview: Bool {
        model.snapshots("release.check").contains { $0.app?.localizedCaseInsensitiveContains(item.app) == true
            && ($0.payload[path: "state"]?.string ?? "").contains("REVIEW") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.outlet).font(.title2.bold())
            Text("\(item.app.replacingOccurrences(of: "+", with: " & ")) · \(item.type) · \(item.status) · sent \(Outreach.prettyDay(item.date))\(item.followUp.map { " · follow up \(Outreach.prettyDay($0))" } ?? "")")
                .font(.callout).foregroundStyle(.secondary)
            if let th = Outreach.side().threads?[item.id] {
                Label("\(th.state)\(th.promise.map { " (\($0))" } ?? "") since \(Outreach.prettyDay(th.since)): \(th.evidence)", systemImage: "bubble.left.and.bubble.right")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if let f = Outreach.side().feeds?[item.id] {
                Text("Watching \(f.url) for \(item.app) until \(Outreach.prettyDay(f.until))\(f.checked.map { ", last read \(Outreach.prettyDay($0))" } ?? "")")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                if let c = item.contact { GridRow { Text("Went to").gridColumnAlignment(.trailing); Text(c).textSelection(.enabled) } }
                if let s = item.subject { GridRow { Text("Subject"); Text(s).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) } }
                GridRow {
                    Text("Notes")
                    TextField("Notes", text: Binding(get: { extra.notes ?? "" }, set: { extra.notes = $0.isEmpty ? nil : $0 }),
                              prompt: Text("Who they are, what they like, how they prefer to be contacted"), axis: .vertical)
                        .lineLimit(1...3).labelsHidden().input(.text(1000), Binding(get: { extra.notes ?? "" }, set: { extra.notes = $0.isEmpty ? nil : $0 }))
                }
                GridRow {
                    Text("")
                    HStack(spacing: 16) {
                        Toggle("Don't contact again", isOn: Binding(get: { extra.dnc == true }, set: { extra.dnc = $0 ? true : nil }))
                        Toggle("Under embargo", isOn: Binding(get: { extra.embargo == true }, set: { extra.embargo = $0 ? true : nil }))
                        Toggle("About a release on", isOn: $hasLaunch)
                        DatePicker("Release", selection: $launch, displayedComponents: .date).labelsHidden().disabled(!hasLaunch)
                    }
                }
                GridRow {
                    Text("Coverage")
                    HStack {
                        TextField("Coverage", text: $coverageURL, prompt: Text("https://… (their article or episode)")).labelsHidden().input(.url, $coverageURL)
                        Button("Add") {
                            guard InputCheck.httpsURL(coverageURL) != nil else { note = "That isn't a full https:// address."; return }
                            extra.coverage = (extra.coverage ?? []) + [.init(url: coverageURL, date: Date.now.localDay)]; coverageURL = ""
                        }
                    }
                }
                ForEach(extra.coverage ?? [], id: \.self) { c in
                    GridRow { Text(""); Link(c.url, destination: URL(string: c.url) ?? URL(string: "https://apple.com")!).font(.callout) }
                }
                if let appID {
                    GridRow {
                        Text("Link")
                        HStack {
                            let link = Outreach.campaignLink(appID: appID, outlet: item.outlet, app: item.app)
                            Text(link).font(.callout.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                            Button("Copy") { copy(link) }.help("An App Store link that counts the downloads this outlet brings")
                        }
                    }
                }
            }
            if extra.embargo == true, inReview {
                Label("\(item.app) is still in App Review: don't send anything under embargo until it's approved.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(Brand.caution)
            }
            Divider()
            if extra.dnc == true {
                Text("Marked “don't contact again”: no drafts for \(item.outlet).").font(.callout).foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("Draft").font(.headline)
                    Spacer()
                    if item.isEmail {
                        Button("Follow-up") {
                            let side = Outreach.side()
                            let appFirst = String(item.app.split(separator: "+").first ?? Substring(item.app))
                            let hl = side.highlights?[appFirst] ?? side.highlights?.first { appFirst.localizedCaseInsensitiveContains($0.key) || $0.key.localizedCaseInsensitiveContains(appFirst) }?.value
                            setDraft(Outreach.followUpDraft(item, appLink: appID.map { Outreach.campaignLink(appID: $0, outlet: item.outlet, app: item.app) }, highlights: hl))
                        }
                    }
                    if let c = extra.coverage?.last { Button("Thank you") { setDraft(Outreach.thankDraft(item, coverage: c.url)) } }
                }
                DisclosureGroup("Answer their reply with AI") {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Their message", text: $theirMessage, prompt: Text("Paste their reply here"), axis: .vertical)
                            .lineLimit(3...6).textFieldStyle(.roundedBorder).input(.text(4000), $theirMessage)
                        HStack {
                            if appID != nil { Toggle("Include a free code link", isOn: $withCode) }
                            Spacer()
                            Button(busy ? "Writing…" : "Draft with AI") { Task { await aiDraft() } }
                                .disabled(busy || theirMessage.trimmingCharacters(in: .whitespaces).isEmpty || !AISettings.shared.hasKey)
                        }
                        if !AISettings.shared.hasKey { Text("Needs an AI key (Settings → General).").font(.callout).foregroundStyle(.secondary) }
                        else { Text("Their words go to \(AISettings.shared.provider.name), without quoted history, email addresses or phone numbers.").font(.callout).foregroundStyle(.secondary) }
                    }.padding(.top, 4)
                }
                TextField("Subject", text: $draftSubject, prompt: Text("Subject")).textFieldStyle(.roundedBorder).input(.text(300), $draftSubject)
                TextEditor(text: $draft).font(.body).frame(minHeight: 140, maxHeight: 220)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                HStack {
                    Text("Never sent without your confirmation. Check every line first.").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy") { copy(draft) }.disabled(draft.isEmpty)
                    Button("Open in Mail") { openMail() }.disabled(draft.isEmpty || Outreach.pinnedRecipient(for: item) == nil)
                    if MailSender.isConfigured {
                        Button("Send via \(MailSender.modeDescription)") { confirmSend = true }
                            .buttonStyle(.pillProminent)
                            .disabled(busy || draft.isEmpty || draftSubject.trimmingCharacters(in: .whitespaces).isEmpty || Outreach.pinnedRecipient(for: item) == nil)
                    }
                }
            }
            if let note { Text(note).font(.callout).foregroundStyle(.secondary) }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button("Done") { save(); dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.pillProminent) }
        }
        .padding(22)
        .frame(minWidth: 560, idealWidth: 720)
        .onAppear {
            extra = Outreach.side().extras[item.id] ?? OutreachExtra()
            if let l = extra.launch, let n = DayNumber.of(l) { hasLaunch = true; launch = Date(timeIntervalSince1970: Double(n) * 86_400 + 43_200) }
            if theirMessage.isEmpty, let latest = Outreach.latestTheirReply(for: item, in: model.events) {
                theirMessage = latest
                withCode = AppStorePitchExtract.replyWantsPromoCode(latest)
            }
        }
        .confirmationDialog("Send this email to \(Outreach.pinnedRecipient(for: item) ?? item.outlet)?", isPresented: $confirmSend) {
            Button("Send email") { Task { await sendNow() } }
        } message: {
            Text("Sends via \(MailSender.modeDescription) to \(Outreach.pinnedRecipient(for: item) ?? "").")
        }
    }

    private func sendNow() async {
        guard let to = Outreach.pinnedRecipient(for: item) else { note = "No valid stored contact email."; return }
        if let p = Wording.rules.problem(draftSubject + "\n" + draft) {
            note = "Blocked by Words I never use: \(p)"; return
        }
        busy = true; defer { busy = false }
        let r = await MailSender.send(to: to, subject: draftSubject, body: draft)
        note = r.note
    }

    private func setDraft(_ d: (subject: String, body: String)) { draftSubject = d.subject; draft = d.body }

    private func save() {
        var x = extra
        x.launch = hasLaunch ? launch.localDay : nil
        Outreach.changeSide { $0.extras[item.id] = x }
    }

    private func aiDraft() async {
        busy = true; defer { busy = false }
        // The next unused code is only shown here; mark it given in Offer codes once you've sent it.
        let code = withCode ? appID.flatMap { id in OfferCodes.shared.codes(app: id).first { $0.sharedAt == nil }?.url } : nil
        do {
            let text = try await Outreach.aiReply(item, theirMessage: theirMessage, codeLink: code)
            draftSubject = item.subject.map { $0.lowercased().hasPrefix("re:") ? $0 : "Re: \($0)" } ?? "Re: \(item.app)"
            draft = text
            note = code == nil ? "Draft ready. Edit it before you send." : "Draft ready, with the next unused code. After you send it, mark that code given in Offer codes."
        } catch { note = (error as? WireError)?.message ?? "\(error)" }
    }

    private func copy(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string); note = "Copied." }

    private func openMail() {
        var c = URLComponents(); c.scheme = "mailto"; c.path = item.contact ?? ""
        c.queryItems = [URLQueryItem(name: "subject", value: draftSubject), URLQueryItem(name: "body", value: draft)]
        if let u = c.url { NSWorkspace.shared.open(u) }
    }
}

/// Where the outreach list lives, your sending address (and whether its mail records are set up), and the
/// provider token for campaign links.
struct OutreachSetup: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Outreach.fileKey) private var file = ""
    @AppStorage(Outreach.toolKey) private var tool = ""
    @AppStorage(Outreach.ownKey) private var own = ""
    @AppStorage(Outreach.providerKey) private var provider = ""
    @AppStorage(Outreach.allowPatchRepitchKey) private var allowPatchRepitch = false
    @AppStorage(MailSender.transportKey) private var sendTransport = MailSendTransport.auto.rawValue
    @AppStorage(MailSender.smtpHostKey) private var smtpHost = ""
    @AppStorage(MailSender.smtpPortKey) private var smtpPort = 465
    @AppStorage(MailSender.smtpUserKey) private var smtpUser = ""
    @AppStorage(MailSender.smtpFromKey) private var smtpFrom = ""
    @State private var smtpPassword = ""
    @State private var smtpNote: String?
    @State private var testingSend = false
    @State private var check: Outreach.MailCheck?
    @State private var checking = false

    private var selfTestAddress: String? {
        for candidate in [own, smtpFrom, smtpUser] {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if SMTPConfig.isSingleEmail(trimmed) { return trimmed }
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Outreach setup").font(.title2.bold())
            Form {
                TextField("Your sending address", text: $own, prompt: Text("you@yourdomain.com")).input(.text(200), $own)
                HStack {
                    if let check {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("SPF \(check.spf ? "✓ \(check.spfAll ?? "")" : "missing") · DKIM \(check.dkim.map { "✓ (\($0))" } ?? "not found") · DMARC \(check.dmarc ? "✓ \(check.dmarcPolicy ?? "")" : "missing")\(check.dmarc ? (check.dmarcReports ? ", reports on" : ", no reports") : "")")
                                .font(.callout).foregroundStyle(check.advice.isEmpty ? Brand.good : Brand.caution)
                            ForEach(check.advice, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                        }
                    } else { Text("Checks your domain's mail records, so pitches land in inboxes.").font(.callout).foregroundStyle(.secondary) }
                    Spacer()
                    Button(checking ? "Checking…" : "Check") {
                        guard let d = ReplyMatch.domain(own) else { return }
                        checking = true
                        Task { check = await Outreach.mailCheck(domain: d); checking = false }
                    }.disabled(checking || ReplyMatch.domain(own) == nil)
                }
                Section("Outbound sending (on your OK in Log → Waiting)") {
                    Picker("Send via", selection: $sendTransport) {
                        ForEach(MailSendTransport.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    if sendTransport == MailSendTransport.auto.rawValue || sendTransport == MailSendTransport.smtp.rawValue {
                        HStack {
                            TextField("SMTP server", text: $smtpHost, prompt: Text("smtp.zoho.in or smtp.gmail.com")).input(.identifier, $smtpHost)
                            if !UserDefaults.standard.string(forKey: MailWatch.hostKey).isNilOrEmpty {
                                Button("Fill from IMAP") {
                                    let imap = UserDefaults.standard.string(forKey: MailWatch.hostKey) ?? ""
                                    smtpHost = imap.replacingOccurrences(of: "imappro.", with: "smtp.").replacingOccurrences(of: "imap.", with: "smtp.")
                                    if smtpUser.isEmpty { smtpUser = UserDefaults.standard.string(forKey: MailWatch.userKey) ?? "" }
                                    if smtpFrom.isEmpty { smtpFrom = own.isEmpty ? smtpUser : own }
                                }
                            }
                        }
                        Picker("SMTP port", selection: $smtpPort) {
                            Text("465 (SMTPS)").tag(465)
                            Text("587 (STARTTLS)").tag(587)
                        }.pickerStyle(.segmented)
                        TextField("SMTP username", text: $smtpUser, prompt: Text("you@yourdomain.com")).input(.text(254), $smtpUser)
                        TextField("From address (optional)", text: $smtpFrom, prompt: Text("Same as sending address")).input(.text(254), $smtpFrom)
                        HStack {
                            SecureField("SMTP app password", text: $smtpPassword).input(.secret, $smtpPassword)
                            Button("Save password") {
                                do { try MailSender.setSMTPPassword(smtpPassword); smtpNote = "SMTP password saved in Keychain." }
                                catch { smtpNote = "Couldn't save password: \(error.localizedDescription)" }
                            }
                        }
                        if let p = MailSender.smtpConfig.problem, !smtpHost.isEmpty {
                            Text(p).font(.callout).foregroundStyle(Brand.caution)
                        }
                    }
                    HStack {
                        Button(testingSend ? "Sending test…" : "Send test to my address") {
                            Task { await sendTestToSelf() }
                        }
                        .disabled(testingSend || selfTestAddress == nil || sendTransport == MailSendTransport.mailto.rawValue)
                        .help("Sends one short verification email to your own configured address only")
                        Spacer()
                        Text(MailSender.modeDescription).font(.caption).foregroundStyle(.secondary)
                    }
                    if let smtpNote { Text(smtpNote).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                Section("List & rules") {
                    Toggle("Repitch contacts on patch releases (x.y.z)", isOn: $allowPatchRepitch)
                    TextField("Outreach list kept by another tool (optional)", text: $file, prompt: Text("~/tools/outreach_log.json")).input(.path, $file)
                    TextField("Its command to change an entry", text: $tool, prompt: Text("/path/to/python /path/to/outreach_add.py")).input(.text(500), $tool)
                    Text("Empty: Hmunmawi keeps the list itself. With a file: Hmunmawi reads it and changes it only through that command, one tap at a time.")
                        .font(.callout).foregroundStyle(.secondary)
                    TextField("Provider token for campaign links", text: $provider, prompt: Text("App Store Connect → Analytics → Campaign links")).input(.short, $provider)
                }
            }
            .formStyle(.grouped)
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.pillProminent) }
        }
        .padding(22).frame(width: 640)
        .onAppear {
            MailWatch.syncOwnEmailIfEmpty()
            own = UserDefaults.standard.string(forKey: Outreach.ownKey) ?? own
            smtpPassword = MailSender.smtpPassword()
        }
    }

    private func sendTestToSelf() async {
        guard let to = selfTestAddress else {
            smtpNote = "Enter a valid sending address first."
            return
        }
        testingSend = true; defer { testingSend = false }
        if !smtpPassword.isEmpty {
            do { try MailSender.setSMTPPassword(smtpPassword) }
            catch { smtpNote = "Couldn't save SMTP password: \(error.localizedDescription)"; return }
        }
        let res = await MailSender.send(
            to: to,
            subject: "Hmunmawi outreach mail test",
            body: "This test confirmed Hmunmawi can send approved outreach messages via \(MailSender.modeDescription)."
        )
        smtpNote = "Test to \(to): \(res.note)"
    }
}

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool { self?.isEmpty ?? true }
}
