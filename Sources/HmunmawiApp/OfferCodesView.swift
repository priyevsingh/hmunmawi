import AppKit
import HmunmawiCore
import SwiftUI
import UniformTypeIdentifiers

/// "Offer codes" on an app's card: codes left, Copy next (copies the redeem link and marks it shared),
/// custom codes like FREE4LIFE / REP60 with their share count, and the last few shares with Undo.
struct OfferCodesPart: View {
    let app: String
    let model: AppModel
    @State private var codes = OfferCodes.shared
    @State private var copied: String?
    @State private var found: [URL]?
    @State private var searching = false
    @State private var webImport = false
    @State private var showDeals = false
    @State private var campaign = ""

    /// The App Store id for this app name (from App Store Connect snapshots).
    static func appID(_ app: String, model: AppModel) -> String? {
        // App Store Connect's full name ("My App: Photo Editor") vs the short name on the card ("My App").
        func same(_ full: String?) -> Bool {
            guard let full else { return false }
            return full == app || full.split(separator: ":").first.map(String.init)?.trimmingCharacters(in: .whitespaces) == app
        }
        return model.snapshots("offercodes.snapshot").first { same($0.app) }?.payload[path: "app_id"]?.string
            ?? model.snapshots("icon.snapshot").first { same($0.app) }?.payload[path: "appID"]?.string
    }

    var body: some View {
        if let appID = Self.appID(app, model: model),
           !codes.codes(app: appID).isEmpty || !codes.custom(app: appID).isEmpty || !OfferCodes.offers(model, appID: appID).isEmpty
               || model.snapshots("suboffers.snapshot").contains(where: { $0.payload[path: "app_id"]?.string == appID }) {
            let all = codes.codes(app: appID)
            let left = codes.left(app: appID)
            let info = OfferCodes.batchInfo(model, appID: appID)
            let offerName = all.compactMap { $0.batch.flatMap { info[$0]?.name } }.first
            let expiry = all.filter { $0.sharedAt == nil }.compactMap { $0.batch.flatMap { info[$0]?.expires } }.min()
            VStack(alignment: .leading, spacing: 12) {
                Divider()
                Label { Text("Offer codes").foregroundStyle(.primary) } icon: {
                    Image(systemName: "ticket.fill").foregroundStyle(Brand.Category.money)
                }
                .font(.headline)
                HStack(spacing: 8) {
                    Button { pick() } label: { Label("Import CSV", systemImage: "square.and.arrow.down") }
                    Button { find() } label: { Label(searching ? "Finding" : "Find CSV files", systemImage: "magnifyingglass") }
                        .disabled(searching)
                    Button { webImport = true } label: { Label("Import from a web page", systemImage: "safari") }
                    Button { showDeals = true } label: { Label("Deal directories", systemImage: "megaphone") }
                    Text("App Store Connect → your in-app purchase → Offer Codes → export codes (CSV)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.pill)
                .sheet(isPresented: $showDeals) {
                    let firstCustom = codes.custom(app: appID).first
                    let redeem = firstCustom.map { "https://apps.apple.com/redeem?ctx=offercodes&id=\(appID)&code=\($0.code)" }
                    DealListingsView(
                        appName: app,
                        appStoreID: appID,
                        initialOfferCode: firstCustom?.code,
                        initialRedeemURL: redeem,
                        initialEndDate: firstCustom?.expires,
                        model: model
                    )
                }
                if let note = codes.scanNote { Text(note).font(.callout).foregroundStyle(.secondary) }
                if !all.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(left)").font(.system(size: 30, weight: .bold)).monospacedDigit()
                                .foregroundStyle(Kit.vibrant(left < 20 ? Brand.caution : Brand.Category.money))
                            Text("\(offerName ?? "One-time codes") left of \(all.count.formatted())\(expiry.map { " · expire \(Self.day($0))" } ?? "")")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        TextField("For whom or where? (optional)", text: $campaign).frame(width: 220).input(.name, $campaign)
                        Button {
                            let tag = campaign.trimmingCharacters(in: .whitespaces)
                            if let c = codes.copyNext(app: appID, by: "mac", campaign: tag.isEmpty ? nil : tag) {
                                flash("Copied \(c.code)" + (tag.isEmpty ? " · marked shared" : " · for \(tag)")); campaign = ""
                            }
                        } label: { Label("Copy next code", systemImage: "doc.on.doc") }
                        .buttonStyle(.pillProminent)
                        .disabled(left == 0)
                        .help("Copies the next unused redeem link and marks it shared")
                    }
                }
                ForEach(codes.custom(app: appID)) { c in
                    HStack(spacing: 10) {
                        Text(c.code).font(.body.monospaced())
                        Text([c.capacity.map { "\(c.shared.formatted()) of \($0.formatted()) shared" } ?? "\(c.shared.formatted()) shared",
                              c.expires.map { "expires \(Self.day($0))" }].compactMap { $0 }.joined(separator: " · "))
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button { let tag = campaign.trimmingCharacters(in: .whitespaces); codes.copyCustom(c, by: "mac", campaign: tag.isEmpty ? nil : tag); flash("Copied \(c.code) link" + (tag.isEmpty ? "" : " · for \(tag)")); campaign = "" } label: { Label("Copy link", systemImage: "link") }.buttonStyle(.pill)
                    }
                }
                if let copied {
                    Label(copied, systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(Brand.good)
                        .transition(.opacity)
                }
                // Subscription offers, all in one place (from App Store Connect, daily).
                if let subs = model.snapshots("suboffers.snapshot").first(where: { $0.payload[path: "app_id"]?.string == appID })?.payload[path: "subscriptions"]?.array, !subs.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Subscription offers").font(.callout.weight(.semibold))
                        ForEach(Array(subs.enumerated()), id: \.offset) { _, s in
                            let parts: [String] = [
                                s[path: "intro_mode"]?.string.map { mode in
                                    let m = ["FREE_TRIAL": "free trial", "PAY_AS_YOU_GO": "intro price", "PAY_UP_FRONT": "intro pay-up-front"][mode] ?? mode.lowercased()
                                    return (s[path: "intro_duration"]?.string.map { Self.duration($0) + " " } ?? "") + m
                                },
                                (s[path: "promotional"]?.number).flatMap { $0 > 0 ? "\(Int(safe: $0)) promotional" : nil },
                                (s[path: "win_back"]?.number).flatMap { $0 > 0 ? "\(Int(safe: $0)) win-back" : nil },
                                (s[path: "offer_codes"]?.number).flatMap { $0 > 0 ? "\(Int(safe: $0)) offer code\($0 == 1 ? "" : "s")" : nil },
                            ].compactMap { $0 }
                            HStack(alignment: .firstTextBaseline) {
                                Text(s[path: "name"]?.string ?? "Subscription").font(.callout)
                                Text(parts.isEmpty ? "No offers. Leaving money on the table?" : parts.joined(separator: " · "))
                                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                let tags = codes.campaigns(app: appID).filter { $0.name != "No tag" }
                if !tags.isEmpty {
                    Text("Campaigns: " + tags.prefix(6).map { "\($0.name) \($0.count)" }.joined(separator: " · "))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                let recent = codes.recent(app: appID, limit: 3)
                if !recent.isEmpty {
                    DisclosureGroup("Recently shared") {
                        ForEach(recent) { s in
                            HStack {
                                Text(s.code).font(.callout.monospaced())
                                if let tag = s.campaign { Text(tag).font(.callout) }
                                Text(Ago.text(s.at)).font(.callout).foregroundStyle(.secondary)
                                Spacer()
                                Button("Undo") { codes.undo(s) }.buttonStyle(.borderless)
                            }
                        }
                    }
                    .font(.callout)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        if let url, url.pathExtension.lowercased() == "csv" { Task { @MainActor in _ = await codes.importFiles([url]) } }
                    }
                }
                return true
            }
            .sheet(isPresented: $webImport) { WebImportSheet().buttonStyle(.pill) }
            .sheet(item: Binding(get: { found.map { FoundFiles(urls: $0) } }, set: { if $0 == nil { found = nil } })) { f in
                FoundCSVSheet(urls: f.urls) { chosen in found = nil; Task { _ = await codes.importFiles(chosen) } } cancel: { found = nil }
                    .buttonStyle(.pill)
            }
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsMultipleSelection = true
        panel.message = "Choose the codes CSV files you exported from App Store Connect"
        if panel.runModal() == .OK { let urls = panel.urls; Task { _ = await codes.importFiles(urls) } }
    }

    private func find() {
        searching = true
        let known = codes.knownFiles
        Task {
            let list = await Task.detached(priority: .utility) { OfferCodes.findCSVs(skipping: known) }.value
            searching = false
            found = list
        }
    }

    static func duration(_ d: String) -> String {
        ["THREE_DAYS": "3-day", "ONE_WEEK": "1-week", "TWO_WEEKS": "2-week", "ONE_MONTH": "1-month", "TWO_MONTHS": "2-month",
         "THREE_MONTHS": "3-month", "SIX_MONTHS": "6-month", "ONE_YEAR": "1-year"][d] ?? d.lowercased().replacingOccurrences(of: "_", with: " ")
    }

    private func flash(_ text: String) {
        withAnimation { copied = text }
        Task { try? await Task.sleep(for: .seconds(3)); withAnimation { if copied == text { copied = nil } } }
    }

    static func day(_ iso: String) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate]
        guard let d = f.date(from: String(iso.prefix(10))) else { return iso }
        return d.formatted(.dateTime.day().month(.abbreviated).year())
    }
}

private struct FoundFiles: Identifiable { let urls: [URL]; var id: String { urls.map(\.path).joined() } }

/// What "Find CSV files" found: you tick which to import (all ticked by default).
private struct FoundCSVSheet: View {
    let urls: [URL]
    let done: ([URL]) -> Void
    let cancel: () -> Void
    @State private var chosen: Set<URL> = []

    init(urls: [URL], done: @escaping ([URL]) -> Void, cancel: @escaping () -> Void) {
        self.urls = urls; self.done = done; self.cancel = cancel
        _chosen = State(initialValue: Set(urls))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(urls.isEmpty ? "No new code files found" : "Found \(urls.count) code file\(urls.count == 1 ? "" : "s")").font(.title2)
            Text(urls.isEmpty ? "Searched your Mac for App Store Connect exports (files named OfferCodeOneTimeUseCodes, ending in .csv). Use Import CSV to pick a file anywhere."
                 : "Duplicate codes are skipped automatically.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !urls.isEmpty {
                List(urls, id: \.self) { u in
                    Toggle(isOn: Binding(get: { chosen.contains(u) }, set: { if $0 { chosen.insert(u) } else { chosen.remove(u) } })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(u.lastPathComponent).font(.callout)
                            Text(u.deletingLastPathComponent().path.replacingOccurrences(of: URL.homeDirectory.path, with: "~"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(minHeight: 280)
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                if !urls.isEmpty {
                    Button("Import \(chosen.count)") { done(Array(chosen)) }.keyboardShortcut(.defaultAction).buttonStyle(.pillProminent).disabled(chosen.isEmpty)
                }
            }
        }
        .padding(22)
        .frame(width: 560)
    }
}


/// Import marks from a tracker page you're logged into (e.g. an old portal). Explains exactly what happens.
private struct WebImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var result: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import from a web page").font(.title2.bold())
            Text("For a codes tracker behind a login that no key can read. Hmunmawi asks Safari, where you're already logged in, to fetch this one address once, and imports the codes and \u{201C}shared\u{201D} marks it finds. Nothing else is read or sent.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("https://example.com/api/promo/lifetime", text: $address).input(.url, $address)
            if let result { Text(result).font(.callout).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Close") { dismiss() }.buttonStyle(.pill).keyboardShortcut(.cancelAction)
                Button(busy ? "Reading" : "Read using my Safari login") {
                    busy = true
                    Task { result = await OfferCodes.shared.importUsingSafari(address); busy = false }
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.pillProminent).disabled(busy || address.isEmpty)
            }
        }
        .padding(22).frame(width: 540)
    }
}
