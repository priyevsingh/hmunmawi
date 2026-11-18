import HmunmawiCore
import SwiftUI

/// Rejection Shield for one app's version in progress: what would get it bounced, and for each item a way
/// forward. Three kinds of help: "Fix it for me" (small, reversible changes, previewed first), "Draft it for me"
/// (AI writes, you edit, then it's saved) and "Guide me" (answers only you can give: steps and a direct link).
struct ShieldView: View {
    let app: String
    @Environment(AppModel.self) private var model: AppModel?
    @State private var open = false

    var body: some View {
        if let model, let report = model.snapshots("release.check").first(where: { ComingSoon.shortName($0.app ?? "") == app })?.payload {
            let items = report[path: "items"]?.array ?? []
            let fixed = ShieldMemory.fixedIDs(report)
            let blocking = items.filter { $0[path: "ok"] == .bool(false) && $0[path: "level"]?.string == "block" && !fixed.contains($0[path: "id"]?.string ?? "") }
            let warns = items.filter { $0[path: "ok"] == .bool(false) && $0[path: "level"]?.string == "warn" && !fixed.contains($0[path: "id"]?.string ?? "") }
            VStack(alignment: .leading, spacing: 10) {
                Button { withAnimation(.smooth) { open.toggle() } } label: {
                    HStack(spacing: 8) {
                        Image(systemName: blocking.isEmpty ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                            .foregroundStyle(blocking.isEmpty ? Brand.good : Brand.caution)
                        Text("Rejection Shield").foregroundStyle(.primary)
                        Kit.glow(blocking.isEmpty
                                 ? (warns.isEmpty ? Quips.pick(["Bulletproof. Apple's reviewers will be bored.", "All clear. Nothing to nitpick, not even a comma.", "Spotless. Ship it like you mean it."])
                                    : Quips.pick(["No blockers, just \(warns.count) bit\(warns.count == 1 ? "" : "s") of polish left.", "Shippable. \(warns.count) optional glow-up\(warns.count == 1 ? "" : "s") if you're feeling fancy."]))
                                 : Quips.pick(["\(blocking.count) rejection magnet\(blocking.count == 1 ? "" : "s") spotted. Let's defuse them.",
                                               "\(blocking.count) thing\(blocking.count == 1 ? "" : "s") Apple would bounce this for. Dodge incoming.",
                                               "\(blocking.count) banana peel\(blocking.count == 1 ? "" : "s") on the road to review."]),
                                 tint: blocking.isEmpty ? Brand.good : Brand.caution)
                        Spacer()
                        Image(systemName: "chevron.down").rotationEffect(.degrees(open ? 180 : 0)).foregroundStyle(.secondary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                if open {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        ShieldItem(item: item, report: report, model: model, fixed: fixed.contains(item[path: "id"]?.string ?? ""))
                    }
                    SubmitRow(report: report, model: model, ready: blocking.isEmpty)
                    HStack {
                        if let url = ShieldGuide.link("version", report) {
                            Link(destination: url) { Label("Open in App Store Connect", systemImage: "arrow.up.forward.app") }
                        }
                        Spacer()
                        let at = report[path: "checked_at"]?.number.map { Date(timeIntervalSince1970: $0 / 1000) }
                        Text("Checked \(at.map { Ago.text($0) } ?? "recently"); next check by \(at.map { $0.addingTimeInterval(6 * 3600).formatted(date: .omitted, time: .shortened) } ?? "the next round"). Changes only when you say so.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill((blocking.isEmpty ? Brand.good : Brand.caution).opacity(0.07)))
        }
    }
}

/// Fixes you made since the last check (shown as fixed until the next check confirms), and their undo.
@MainActor enum ShieldMemory {
    private static let key = "HMShieldFixes"     // "versionID|itemID" -> [at: Double, undo: JSON string]
    static func all() -> [String: [String: Any]] { (UserDefaults.standard.dictionary(forKey: key) as? [String: [String: Any]]) ?? [:] }
    static func remember(_ version: String, _ item: String, undo: JSONValue?) {
        var a = all()
        // Running a fix again must not lose the original values: per-language texts keep the oldest value for each
        // language, and any other undo keeps the first one (what was there before Hmunmawi touched it).
        var keep = undo
        // (A submit's undo points at that one review submission, so a new submit always replaces it.)
        if item != "submit", let old = Self.undo(version, item) {
            if case .object(var newTexts)? = undo?[path: "texts"], case .object(let oldTexts)? = old[path: "texts"],
               case .object(var fields)? = undo {
                for (k, v) in oldTexts { newTexts[k] = v }
                fields["texts"] = .object(newTexts)
                keep = .object(fields)
            } else {
                keep = old
            }
        }
        a["\(version)|\(item)"] = ["at": Date.now.timeIntervalSince1970 * 1000,
                                   "undo": keep.flatMap { try? String(decoding: JSONEncoder().encode($0), as: UTF8.self) } ?? ""]
        UserDefaults.standard.set(a, forKey: key)
    }

    /// When a fix was made (ms), if remembered.
    static func at(_ version: String, _ item: String) -> Double? { all()["\(version)|\(item)"]?["at"] as? Double }
    static func forget(_ version: String, _ item: String) { var a = all(); a["\(version)|\(item)"] = nil; UserDefaults.standard.set(a, forKey: key) }
    static func undo(_ version: String, _ item: String) -> JSONValue? {
        guard let s = all()["\(version)|\(item)"]?["undo"] as? String, !s.isEmpty else { return nil }
        return try? JSONValue.parse(s)
    }
    /// Items fixed after this report was made.
    static func fixedIDs(_ report: JSONValue) -> Set<String> {
        let version = report[path: "version_id"]?.string ?? ""
        let checked = report[path: "checked_at"]?.number ?? 0
        return Set(all().compactMap { k, v in
            let parts = k.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0] == version, (v["at"] as? Double ?? 0) > checked else { return nil }
            return parts[1]
        })
    }
}

/// Direct links and plain steps for things only you can answer.
enum ShieldGuide {
    static func link(_ id: String, _ report: JSONValue) -> URL? {
        guard let app = report[path: "app_id"]?.string else { return nil }
        let base = "https://appstoreconnect.apple.com/apps/\(app)"
        let path: String = switch id {
        case "age_rating", "accessibility": "\(base)/distribution/info"
        case "encryption": "\(base)/testflight/ios"
        case "privacy": "\(base)/distribution/privacy"
        case "agreements": "https://appstoreconnect.apple.com/business"
        default: "\(base)/distribution/ios/version/inflight"
        }
        return URL(string: path)
    }

    static func steps(_ id: String) -> String? {
        switch id {
        case "age_rating": "App Information → Age Rating → Edit. Answer every question truthfully; Apple shows the result on your page."
        case "encryption": "TestFlight → this build → Missing Compliance. Most apps using only HTTPS answer \u{201C}standard encryption, exempt\u{201D}, but check Apple's guidance for yours."
        case "accessibility": "App Information → Accessibility. Declare only features you've tested (VoiceOver, Larger Text, Dark Mode and so on) for each device."
        case "privacy": "App Privacy → Edit. Match what the app and its SDKs really collect and send."
        case "agreements": "Business → Agreements. The Paid Apps agreement, tax forms and bank details must all be active."
        case "screenshots": "On the version page, add screenshots for each device size and language that's missing; the list above names them."
        case "uploads": "Wait a few minutes; if one shows an error, delete it and upload it again."
        case "description": "On the version page, fill in the description and keywords for each language named above."
        case "events": "In-App Events → the event → each language: add both the card image (16:9) and the details-page image (9:16)."
        case "build": "Upload a build from Xcode (Product → Archive → Distribute), wait until it's processed, then attach it."
        case "contact", "review_notes": "On the version page, under App Review Information."
        case "unread": "Nothing to do; it tries again on the next check."
        default: nil
        }
    }
}

private struct ShieldItem: View {
    let item: JSONValue
    let report: JSONValue
    let model: AppModel
    let fixed: Bool
    @State private var confirm = false
    @State private var confirmUndo = false
    @State private var busy = false
    @State private var result: String?
    @State private var drafting: Draft?
    @State private var showSteps = false

    private var id: String { item[path: "id"]?.string ?? "" }
    private var versionID: String { report[path: "version_id"]?.string ?? "" }
    private var liveID: String? { report[path: "live_version_id"]?.string }

    var body: some View {
        let ok = item[path: "ok"] == .bool(true) || fixed
        let level = item[path: "level"]?.string ?? "block"
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : level == "manual" ? "hand.raised.circle" : level == "warn" ? "exclamationmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? Brand.good : level == "manual" ? Color.secondary : level == "warn" ? Brand.caution : Brand.bad)
            VStack(alignment: .leading, spacing: 4) {
                Text(item[path: "title"]?.string ?? "")
                if fixed {
                    Text("Fixed just now. The next check will take a victory lap.").font(.callout).foregroundStyle(.secondary)
                } else if let d = item[path: "detail"]?.string, !d.isEmpty {
                    Text(level == "manual" && !ok ? "Check by hand: " + d : d).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if showSteps {
                    if let s = ShieldGuide.steps(id) { Text(s).font(.callout).fixedSize(horizontal: false, vertical: true) }
                    if let url = ShieldGuide.link(id, report) {
                        Link(destination: url) { Label("Open it in App Store Connect", systemImage: "arrow.up.forward.app") }.font(.callout)
                    }
                }
                if let result { Text(result).font(.callout).foregroundStyle(result.hasPrefix("Couldn") ? Brand.bad : Brand.good).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            if fixed, ShieldMemory.undo(versionID, id) != nil {
                Button("Undo") { confirmUndo = true }.disabled(busy)
            } else if !ok {
                actions
            }
        }
        // Undo writes to App Store Connect too, so it asks like every other write.
        .confirmationDialog("Put back what was there before?", isPresented: $confirmUndo) {
            Button("Undo the change") { undo() }
        } message: { Text("Hmunmawi restores the previous value in App Store Connect.") }
        .confirmationDialog(confirmTitle, isPresented: $confirm) {
            Button("Sort it for me: " + confirmButton) { Task { await run(fixParams) } }
        } message: { Text("Undo is one click away, and nothing gets submitted. Apple won't even notice. Yet.") }
        .sheet(item: $drafting) { d in DraftSheet(draft: d) { params in Task { await run(params) } }.buttonStyle(.pill) }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 6) {
            switch id {
            case "build": autopilot(busy ? "Attaching" : "Attach build") { confirm = true }
            case "promo" where liveID != nil: autopilot(busy ? "Copying" : "Copy from live") { confirm = true }
            case "contact" where liveID != nil: autopilot(busy ? "Copying" : "Copy contact") { confirm = true }
            case "whats_new": autopilot("Draft What's New") { drafting = Draft(kind: .whatsNew, item: item, report: report) }
            case "review_notes": autopilot("Draft notes") { drafting = Draft(kind: .reviewNotes, item: item, report: report) }
            default: EmptyView()
            }
            if ShieldGuide.steps(id) != nil || ShieldGuide.link(id, report) != nil, id != "unread" {
                Button { withAnimation { showSteps.toggle() } } label: { Label(showSteps ? "Show me how (hide)" : "Show me how", systemImage: "safari") }
            }
        }
        .buttonStyle(.pill)
    }

    /// "Sort it for me: …": the app does it for you, after your OK. The one word for system-driven actions everywhere.
    private func autopilot(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Label("Sort it for me: \(title)", systemImage: "sparkles") }.disabled(busy)
    }

    private var confirmTitle: String {
        switch id {
        case "build": "Attach the newest processed build to version \(report[path: "version"]?.string ?? "")?"
        case "promo": "Copy promotional text from the live version into the empty languages?"
        default: "Copy the reviewer contact details from your last version?"
        }
    }
    private var confirmButton: String { id == "build" ? "Attach build" : "Copy" }

    private var fixParams: JSONValue {
        var p: [String: JSONValue] = ["version_id": .string(versionID), "app_id": report[path: "app_id"] ?? .null]
        switch id {
        case "build": p["fix"] = .string("attach_build")
        case "promo": p["fix"] = .string("set_texts"); p["field"] = .string("promotionalText"); p["copy_live"] = .bool(true)
            p["only_empty"] = .bool(true); p["live_id"] = liveID.map(JSONValue.string) ?? .null
        default: p["fix"] = .string("set_review"); p["copy_contact_from"] = liveID.map(JSONValue.string) ?? .null
        }
        return .object(p)
    }

    private func run(_ params: JSONValue) async {
        busy = true
        let r = await model.shieldFix(params)
        busy = false
        result = r.ok ? r.message : "Couldn't fix it: \(r.message)"
        if r.ok { ShieldMemory.remember(versionID, id, undo: r.undo) }
    }

    private func undo() {
        guard let u = ShieldMemory.undo(versionID, id) else { return }
        Task {
            busy = true
            let r = await model.shieldFix(u)
            busy = false
            result = r.ok ? "Undone" : "Couldn't undo: \(r.message)"
            if r.ok { ShieldMemory.forget(versionID, id) }
        }
    }
}

struct Draft: Identifiable {
    enum Kind { case whatsNew, reviewNotes }
    let kind: Kind
    let item: JSONValue
    let report: JSONValue
    var id: String { "\(kind)" + (report[path: "version_id"]?.string ?? "") }
}

/// AI drafts, you edit, then save. What's New: one text per missing language from your notes. Reviewer notes:
/// the "NEW IN x.y - HOW TO TEST" block.
private struct DraftSheet: View {
    let draft: Draft
    let save: (JSONValue) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var changes = ""
    @State private var texts: [String: String] = [:]
    @State private var notes = ""
    @State private var busy = false
    @State private var error: String?
    @State private var confirming = false

    private var locales: [String] { draft.item[path: "locales"]?.array?.compactMap(\.string) ?? [] }
    private var version: String { draft.report[path: "version"]?.string ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.kind == .whatsNew ? "Draft What's New" : "Draft notes for the reviewer").font(.title2)
            Text("What changed in \(version)? One line per change, in your own words. The AI writes it up\(draft.kind == .whatsNew ? " and translates it into \(locales.count) language\(locales.count == 1 ? "" : "s")" : "") for you to check.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("e.g. New dark mode for widgets\nFixed a crash when opening history", text: $changes, axis: .vertical)
                .lineLimit(3...6).input(.text(2000), $changes)
            Button(busy ? "Drafting" : "Draft it") { Task { await make() } }.disabled(busy || changes.trimmingCharacters(in: .whitespaces).isEmpty)
            if let error { Text(error).foregroundStyle(Brand.bad).fixedSize(horizontal: false, vertical: true) }
            if draft.kind == .whatsNew, !texts.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(locales, id: \.self) { loc in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(loc).font(.callout.monospaced()).foregroundStyle(.secondary)
                                TextField(loc, text: Binding(get: { texts[loc] ?? "" }, set: { texts[loc] = $0 }), axis: .vertical)
                                    .lineLimit(2...6)
                                    .input(.text(4000), Binding(get: { texts[loc] ?? "" }, set: { texts[loc] = $0 }))
                            }
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
            if draft.kind == .reviewNotes, !notes.isEmpty {
                TextField("Notes", text: $notes, axis: .vertical).lineLimit(6...14).input(.text(4000), $notes)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.pill).keyboardShortcut(.cancelAction)
                Button("Save to App Store Connect") { confirming = true }.buttonStyle(.pillProminent).keyboardShortcut(.defaultAction)
                .buttonStyle(.pillProminent)
                .disabled(draft.kind == .whatsNew ? texts.values.allSatisfy { $0.isEmpty } : notes.isEmpty)
                .confirmationDialog(draft.kind == .whatsNew ? "Save What's New to \(texts.filter { !$0.value.isEmpty }.count) language\(texts.filter { !$0.value.isEmpty }.count == 1 ? "" : "s") in App Store Connect?"
                                    : "Save these notes for Apple's reviewer?", isPresented: $confirming) {
                Button("Save") {
                    let vid = draft.report[path: "version_id"] ?? .null
                    if draft.kind == .whatsNew {
                        save(.object(["fix": .string("set_texts"), "version_id": vid, "field": .string("whatsNew"), "only_empty": .bool(true),
                                      "texts": .object(texts.mapValues { .string($0) })]))
                    } else {
                        save(.object(["fix": .string("set_review"), "version_id": vid, "notes": .string(notes)]))
                    }
                    dismiss()
                }
                } message: { Text(draft.kind == .whatsNew ? "Only empty languages are filled; anything you already wrote stays. You can undo right after."
                                  : "These replace the reviewer notes now in App Store Connect. You can undo right after.") }
            }
        }
        .padding(22).frame(width: 620)
    }

    private func make() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            if draft.kind == .whatsNew {
                let prompt = """
                Write the App Store "What's New" text for version \(version) of an iOS app, from these changes:
                \(changes)
                Friendly, short (under 600 characters), no marketing fluff, no emoji overload. Then translate it.
                Reply with JSON only, no code fence: an object mapping each of these App Store locale codes to the text in that language: \(locales.joined(separator: ", ")).
                """
                let reply = try await AIWriter.draft(prompt)
                guard let open = reply.firstIndex(of: "{"), let close = reply.lastIndex(of: "}"), open < close,
                      let data = String(reply[open...close]).data(using: .utf8),
                      let map = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
                    error = "The AI's reply wasn't in the expected form. Try again."
                    return
                }
                texts = map.filter { locales.contains($0.key) }
                if texts.count < locales.count { error = "Drafted \(texts.count) of \(locales.count) languages; fill in the rest or try again." }
            } else {
                let prompt = """
                Write App Review notes for version \(version) of an iOS app. Start with a block titled "NEW IN \(version) - HOW TO TEST": \
                a few short lines, each saying what changed and exactly where a reviewer finds it in the app. Use current Apple names \
                (Apple Account, not Apple ID). Plain text, under 1,500 characters. Changes:
                \(changes)
                """
                notes = try await AIWriter.draft(prompt).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            self.error = (error as? WireError)?.message ?? "Couldn't draft it: \(error.localizedDescription)"
        }
    }
}

/// Submit for Review, both ways: Sort it for me (the app submits after you confirm; only with zero blockers) or
/// Show me how (open the version in App Store Connect and press Submit there). Never automatic.
private struct SubmitRow: View {
    let report: JSONValue
    let model: AppModel
    let ready: Bool
    @State private var confirm = false
    @State private var pendingPull: JSONValue?
    @State private var busy = false
    @State private var result: String?

    var body: some View {
        let state = report[path: "state"]?.string ?? ""
        let vid = report[path: "version_id"]?.string ?? ""
        // Right after submitting, the last check (up to 6 h old) still says "prepare"; the remembered submit
        // counts as waiting, so Submit doesn't come back and "Pull it back" stays reachable.
        // Only until the next check: after that, its state (approved, rejected, back to prepare) is the truth.
        let submittedSinceCheck = (ShieldMemory.at(vid, "submit") ?? 0) > (report[path: "checked_at"]?.number ?? 0)
        let waiting = ["WAITING_FOR_REVIEW", "READY_FOR_REVIEW", "IN_REVIEW"].contains(state) || submittedSinceCheck
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 8) {
                if waiting {
                    Label("With Apple now. Fingers crossed, toes too.", systemImage: "paperplane.fill").foregroundStyle(.secondary)
                } else {
                    Button { confirm = true } label: { Label(busy ? "Sort it for me: Submitting" : "Sort it for me: Submit for Review", systemImage: "sparkles") }
                        .buttonStyle(.pillProminent).disabled(!ready || busy)
                        .help(ready ? "Hmunmawi submits this version after you confirm" : "Clear the blockers above first")
                }
                if let url = ShieldGuide.link("version", report) {
                    Link(destination: url) { Label("Show me how: submit in App Store Connect", systemImage: "safari") }
                }
                Spacer()
                if let undo = ShieldMemory.undo(vid, "submit"), waiting {
                    Button("Pull it back") { pendingPull = undo }
                        .confirmationDialog("Pull this version back from App Review?", isPresented: Binding(get: { pendingPull != nil }, set: { if !$0 { pendingPull = nil } })) {
                            Button("Pull it back") {
                                guard let undo = pendingPull else { return }
                                Task { busy = true; let r = await model.shieldFix(undo); busy = false
                                    result = r.ok ? r.message : "Couldn't pull it back: \(r.message)"; if r.ok { ShieldMemory.forget(vid, "submit") } }
                            }
                        } message: { Text("It leaves Apple's review queue and goes back to being prepared. You can submit it again later.") }
                }
            }
            if !ready && !waiting {
                Text("\u{201C}Sort it for me\u{201D} unlocks once the blockers are cleared; \u{201C}Show me how\u{201D} works any time.").font(.caption).foregroundStyle(.secondary)
            }
            if let result { Text(result).font(.callout).foregroundStyle(result.hasPrefix("Couldn") ? Brand.bad : Brand.good) }
        }
        .confirmationDialog("Submit \(report[path: "version"]?.string ?? "this version") for App Review?", isPresented: $confirm) {
            Button("Sort it for me: Submit for Review") {
                Task {
                    busy = true
                    var p: [String: JSONValue] = ["fix": .string("submit"), "version_id": report[path: "version_id"] ?? .null, "app_id": report[path: "app_id"] ?? .null]
                    let r = await model.shieldFix(.object(p))
                    busy = false
                    result = r.ok ? "Sent to Apple. You can pull it back while it waits." : "Couldn't submit: \(r.message)"
                    if r.ok { ShieldMemory.remember(vid, "submit", undo: r.undo) }
                }
            }
        } message: { Text("This sends it to Apple's reviewers. You can pull it back while it's waiting for review.") }
    }
}

/// TestFlight tidy-up: expire every older build, keeping the newest and any build attached to a version.
/// Sort it for me lists exactly which builds first and asks; Show me how opens TestFlight. Apple can't un-expire a build.
struct TestFlightTidy: View {
    let app: String
    let model: AppModel
    @State private var list: [JSONValue]?
    @State private var keep: String?
    @State private var busy = false
    @State private var confirm = false
    @State private var result: String?

    private var appID: String? { OfferCodesPart.appID(app, model: model) }

    var body: some View {
        if let appID {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Label("TestFlight tidy-up", systemImage: "airplane.departure").foregroundStyle(.primary)
                    Spacer()
                    Button { Task { await load(appID) } } label: { Label(busy ? "Sort it for me: Looking" : "Sort it for me: Expire old builds", systemImage: "sparkles") }
                        .disabled(busy)
                    if let url = URL(string: "https://appstoreconnect.apple.com/apps/\(appID)/testflight/ios") {
                        Link(destination: url) { Label("Show me how", systemImage: "safari") }
                    }
                }
                .buttonStyle(.pill)
                if let result { Text(result).font(.callout).foregroundStyle(result.hasPrefix("Couldn") ? Brand.bad : .secondary).fixedSize(horizontal: false, vertical: true) }
            }
            .confirmationDialog("Expire \(list?.count ?? 0) old TestFlight build\(list?.count == 1 ? "" : "s") for \(app)?", isPresented: $confirm) {
                Button("Sort it for me: Expire \(list?.count ?? 0)", role: .destructive) { Task { await expire(appID) } }
            } message: {
                Text("Keeps build \(keep ?? "the newest") and any build attached to a version. Builds: \((list ?? []).compactMap { $0[path: "build"]?.string }.prefix(12).joined(separator: ", "))\((list?.count ?? 0) > 12 ? " and more" : ""). Apple can't un-expire a build.")
            }
        }
    }

    private func load(_ appID: String) async {
        busy = true; result = nil
        let r = await model.shieldFixRaw(.object(["fix": .string("list_old_builds"), "app_id": .string(appID)]))
        busy = false
        switch r {
        case .success(let v):
            list = v[path: "builds"]?.array ?? []
            keep = v[path: "keep_build"]?.string
            if list?.isEmpty == true { result = Quips.pick(["Already tidy. Only the newest build is flying.", "Nothing to expire. Marie Kondo would approve."]) }
            else { confirm = true }
        case .failure(let e): result = "Couldn't list builds: \(e.message)"
        }
    }

    private func expire(_ appID: String) async {
        busy = true
        let ids = (list ?? []).compactMap { $0[path: "id"] }
        let r = await model.shieldFix(.object(["fix": .string("expire_old_builds"), "app_id": .string(appID), "ids": .array(ids)]))
        busy = false
        result = r.ok ? r.message : "Couldn't expire them: \(r.message)"
    }
}
