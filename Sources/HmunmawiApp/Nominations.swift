import HmunmawiCore
import SwiftUI

/// Featuring nominations for one app: your drafts and what's been sent, with Sort it for me (AI polishes the text,
/// saves a draft, or submits, each only after you confirm) and Show me how (open it in App Store Connect).
struct NominationsPart: View {
    let app: String
    let model: AppModel
    @State private var polishing: JSONValue?
    @State private var creating = false
    @State private var submitting: JSONValue?
    @State private var result: String?

    var body: some View {
        if let appID = OfferCodesPart.appID(app, model: model),
           let snap = model.snapshots("nominations.snapshot").first?.payload {
            let mine = (snap[path: "items"]?.array ?? []).filter { ($0[path: "app_ids"]?.array ?? []).contains { $0.string == appID || $0.number.map { String(Int(safe: $0)) } == appID } }   // ids as text or number
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                HStack {
                    Label { Text("Featuring nominations").foregroundStyle(.primary) } icon: { Image(systemName: "star.bubble.fill").foregroundStyle(Brand.Category.users) }
                        .font(.headline)
                    Spacer()
                    Button { creating = true } label: { Label("Sort it for me: Draft one", systemImage: "sparkles") }
                    if let url = URL(string: "https://appstoreconnect.apple.com/apps/\(appID)/distribution/nominations") {
                        Link(destination: url) { Label("Show me how", systemImage: "safari") }
                    }
                }
                .buttonStyle(.pill)
                if mine.isEmpty {
                    Text(Quips.pick(["No nominations yet. Apple's editors can't feature what they don't know about.",
                                     "Nothing nominated. Your app is being suspiciously humble."]))
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(Array(mine.enumerated()), id: \.offset) { _, n in
                    let draft = n[path: "state"]?.string == "DRAFT"
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: draft ? "pencil.circle" : "paperplane.circle.fill").foregroundStyle(draft ? Color.secondary : Brand.good)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(n[path: "name"]?.string ?? "Nomination")
                            Text([draft ? "Draft" : "Sent to Apple", Self.type(n[path: "type"]?.string),
                                  n[path: "publish_start"]?.string.map { "for \(String($0.prefix(10)))" }].compactMap { $0 }.joined(separator: " · "))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if draft {
                            Button { polishing = n } label: { Label("Sort it for me: Polish", systemImage: "sparkles") }
                            Button { submitting = n } label: { Label("Sort it for me: Submit", systemImage: "paperplane") }
                        }
                    }
                    .buttonStyle(.pill)
                }
                if let result { Text(result).font(.callout).foregroundStyle(result.hasPrefix("Couldn") ? Brand.bad : Brand.good) }
            }
            .sheet(item: Binding(get: { polishing.map { Wrapped(v: $0) } }, set: { polishing = $0?.v })) { w in
                NominationEditor(app: app, appID: appID, existing: w.v) { params in Task { await run(params) } }
                    .buttonStyle(.pill)
            }
            .sheet(isPresented: $creating) {
                NominationEditor(app: app, appID: appID, existing: nil) { params in Task { await run(params) } }
                    .buttonStyle(.pill)
            }
            .confirmationDialog("Submit \u{201C}\(submitting?[path: "name"]?.string ?? "this nomination")\u{201D} to Apple?",
                                isPresented: Binding(get: { submitting != nil }, set: { if !$0 { submitting = nil } })) {
                Button("Sort it for me: Submit to Apple") {
                    if let id = submitting?[path: "id"] { Task { await run(.object(["fix": .string("nomination_submit"), "nomination_id": id])) } }
                }
            } message: { Text("Apple's editors will see it. You can't unsubmit from here, only in App Store Connect.") }
        }
    }

    static func type(_ t: String?) -> String? {
        switch t { case "APP_LAUNCH": "New app"; case "APP_ENHANCEMENTS": "Big update"; case "NEW_CONTENT": "New content"; default: nil }
    }

    private func run(_ params: JSONValue) async {
        let r = await model.shieldFix(params)
        result = r.ok ? r.message : "Couldn't do it: \(r.message)"
    }

    private struct Wrapped: Identifiable { let v: JSONValue; var id: String { v[path: "id"]?.string ?? "new" } }
}

/// AI drafts or polishes the pitch; you edit; confirm saves it as a draft (never submits).
private struct NominationEditor: View {
    let app: String
    let appID: String
    let existing: JSONValue?
    let save: (JSONValue) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var type = "APP_ENHANCEMENTS"
    @State private var text = ""
    @State private var hints = ""
    @State private var busy = false
    @State private var error: String?
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(existing == nil ? "Draft a featuring nomination" : "Polish this nomination").font(.title2)
            if existing == nil {
                TextField("Name, e.g. \(app) 5.0 widgets", text: $name).input(.name, $name)
                Picker("What's it for", selection: $type) {
                    Text("Big update").tag("APP_ENHANCEMENTS"); Text("New app").tag("APP_LAUNCH"); Text("New content").tag("NEW_CONTENT")
                }
            }
            TextField("What's special? A few words for the AI (optional)", text: $hints, axis: .vertical).lineLimit(2...4).input(.text(1000), $hints)
            Button(busy ? "Drafting" : "Sort it for me: Write it") { Task { await draft() } }.disabled(busy)
            TextField("The pitch Apple's editors read", text: $text, axis: .vertical).lineLimit(6...14).input(.text(4000), $text)
            if let error { Text(error).foregroundStyle(Brand.bad).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.pill).keyboardShortcut(.cancelAction)
                Button("Save draft") { confirming = true }.buttonStyle(.pillProminent).keyboardShortcut(.defaultAction)
                    .buttonStyle(.pillProminent).disabled(text.isEmpty || (existing == nil && name.isEmpty))
            }
        }
        .padding(22).frame(minWidth: 560, idealWidth: 640, maxWidth: 900)
        .onAppear { text = existing?[path: "description"]?.string ?? "" }
        .confirmationDialog("Save this as a draft in App Store Connect?", isPresented: $confirming) {
            Button("Save draft") {
                if let id = existing?[path: "id"] {
                    save(.object(["fix": .string("nomination_update"), "nomination_id": id, "description": .string(text)]))
                } else {
                    save(.object(["fix": .string("nomination_create"), "app_id": .string(appID), "name": .string(name),
                                  "type": .string(type), "description": .string(text)]))
                }
                dismiss()
            }
        } message: { Text("It stays a draft; nothing goes to Apple until you press Submit.") }
    }

    private func draft() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            text = try await AIWriter.draft("""
            Write a featuring nomination pitch for Apple's App Store editors about the iOS app "\(app)".
            \(existing.map { "Current draft to improve:\n\($0[path: "description"]?.string ?? "")" } ?? "")
            Notes from the developer: \(hints)
            Under 1,200 characters. Concrete: what's new, who it helps, what makes it special, any Apple tech it uses well.
            No hype words like "revolutionary". Plain text.
            """).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            self.error = (error as? WireError)?.message ?? "Couldn't draft it."
        }
    }
}

/// Product page tests (A/B) and custom product pages for one app, read from App Store Connect.
struct PageTestsPart: View {
    let app: String
    let model: AppModel

    var body: some View {
        if let appID = OfferCodesPart.appID(app, model: model),
           let p = model.snapshots("pagetests.snapshot").first(where: { $0.payload[path: "app_id"]?.string == appID })?.payload {
            let tests = p[path: "tests"]?.array ?? [], pages = p[path: "pages"]?.array ?? []
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                HStack {
                    Label { Text("Product page tests").foregroundStyle(.primary) } icon: { Image(systemName: "rectangle.split.2x1.fill").foregroundStyle(Brand.Category.web) }
                        .font(.headline)
                    Spacer()
                    if let url = URL(string: "https://appstoreconnect.apple.com/apps/\(appID)/distribution/ios/product-page-optimization") {
                        Link(destination: url) { Label("Show me how", systemImage: "safari") }.buttonStyle(.pill)
                    }
                }
                if tests.isEmpty {
                    Text(Quips.pick(["No A/B tests running. Your screenshots are winging it.", "No page tests yet. One test could tell you which screenshots sell."]))
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(Array(tests.enumerated()), id: \.offset) { _, t in
                    Text([t[path: "name"]?.string ?? "Test", (t[path: "state"]?.string ?? "").replacingOccurrences(of: "_", with: " ").lowercased(),
                          t[path: "traffic"]?.number.map { "\(Int(safe: $0))% of visitors" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.callout)
                }
                if !pages.isEmpty {
                    Text("\(pages.count) custom product page\(pages.count == 1 ? "" : "s"): " + pages.prefix(4).compactMap { $0[path: "name"]?.string }.joined(separator: ", "))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
