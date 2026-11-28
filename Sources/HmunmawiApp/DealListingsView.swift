import AppKit
import HmunmawiCore
import SwiftUI

/// Interactive Deal & Directory Launches sheet: browse matching free directories,
/// run pre-flight checks, copy self-serve fields, queue gated PRs/pitches, and copy Live Listed Links.
struct DealListingsView: View {
    let appName: String
    let appStoreID: String?
    let initialOfferCode: String?
    let initialRedeemURL: String?
    let initialEndDate: String?
    let model: AppModel

    @Environment(\.dismiss) private var dismiss
    @State private var deals = DealListings.shared
    @State private var selectedPlatform: DealPlatform = .ios
    @State private var freeOnly = true
    @State private var selectedDirectoryID: String = DealDirectory.builtIn.first?.id ?? "indie-app-sales"

    // Form fields
    @State private var productURL = ""
    @State private var iconURL = ""
    @State private var shortDescription = ""
    @State private var dealSummary = ""
    @State private var offerCode = ""
    @State private var redeemURL = ""
    @State private var regularPrice = "49.99"
    @State private var salePrice = "39.99"
    @State private var startDate = DealPreflightValidator.todayISO()
    @State private var endDate = ""

    @State private var preflight: DealPreflightResult?
    @State private var checking = false
    @State private var statusNote: String?
    @State private var copiedID: String?
    @State private var liveLinkDraft: [String: String] = [:]

    private var matchingDirectories: [DealDirectory] {
        deals.book.allDirectories.filter { dir in
            dir.supports(platform: selectedPlatform) && (!freeOnly || dir.isFree)
        }
    }

    private var liveSubmissions: [DealSubmission] {
        deals.liveListedSubmissions(appName: appName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Deal & Directory Launches · \(appName)")
                        .font(.title3.weight(.semibold))
                    Text("Submit yourself with 1-click copy, or let Hmunmawi prepare a gated GitHub PR in Log → Needs your OK.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.pill)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    liveLinksSection
                    Divider()
                    offerDetailsSection
                    Divider()
                    directoriesSection
                }
            }

            if let statusNote {
                Text(statusNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(minWidth: 740, minHeight: 620)
        .onAppear { seedInitialValues() }
    }

    // MARK: - Live Listed Links Section

    private var liveLinksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Live Listed Links", systemImage: "link.badge.plus")
                    .font(.headline)
                Spacer()
                if !liveSubmissions.isEmpty {
                    Button {
                        let text = liveSubmissions.compactMap { sub -> String? in
                            guard let u = sub.liveListingURL, !u.isEmpty else { return nil }
                            let name = deals.book.directory(id: sub.directoryID)?.name ?? sub.directoryID
                            return "\(name): \(u)"
                        }.joined(separator: "\n")
                        copyToPasteboard(text, tag: "all-links")
                    } label: {
                        Label(copiedID == "all-links" ? "Copied all" : "Copy all live links", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.pill)
                }
            }

            if liveSubmissions.isEmpty {
                Text("No live listed links yet for \(appName). Once a PR merges or you save a directory link below, every live URL appears here ready to copy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(liveSubmissions) { sub in
                    let dirName = deals.book.directory(id: sub.directoryID)?.name ?? sub.directoryID
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(dirName).font(.callout.weight(.medium))
                                if let code = sub.offerCode, !code.isEmpty {
                                    Text(code).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                }
                                Text("ends \(sub.endDate)").font(.caption2).foregroundStyle(.secondary)
                            }
                            if let url = sub.liveListingURL {
                                Text(url)
                                    .font(.caption)
                                    .foregroundStyle(Color.accentColor)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        Spacer()
                        if let url = sub.liveListingURL {
                            Button(copiedID == sub.id ? "Copied" : "Copy link") {
                                copyToPasteboard(url, tag: sub.id)
                            }
                            .buttonStyle(.pillProminent)
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.45)))
                }
            }
        }
    }

    // MARK: - Offer Details & Pre-Flight

    private var offerDetailsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Offer Details").font(.headline)
                Spacer()
                Picker("Platform", selection: $selectedPlatform) {
                    ForEach([DealPlatform.ios, .mac, .web], id: \.self) { p in
                        Text(p.label).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 210)
                Toggle("Free only", isOn: $freeOnly).toggleStyle(.checkbox)
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Product URL").font(.caption).foregroundStyle(.secondary)
                    TextField("https://...", text: $productURL).textFieldStyle(.roundedBorder)
                    Text("Icon URL").font(.caption).foregroundStyle(.secondary)
                    TextField("https://.../icon.png", text: $iconURL).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Regular ($)").font(.caption).foregroundStyle(.secondary)
                    TextField("49.99", text: $regularPrice).textFieldStyle(.roundedBorder)
                    Text("Sale ($)").font(.caption).foregroundStyle(.secondary)
                    TextField("39.99", text: $salePrice).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Offer Code").font(.caption).foregroundStyle(.secondary)
                    TextField("OFF60", text: $offerCode).textFieldStyle(.roundedBorder)
                    Text("End Date").font(.caption).foregroundStyle(.secondary)
                    TextField("YYYY-MM-DD", text: $endDate).textFieldStyle(.roundedBorder)
                }
            }
            TextField("One-line description (<= 160 chars)", text: $shortDescription).textFieldStyle(.roundedBorder)
            TextField("Deal summary (e.g. 60% off lifetime with code OFF60)", text: $dealSummary).textFieldStyle(.roundedBorder)

            if let preflight {
                if preflight.ok && preflight.warnings.isEmpty {
                    Label("Pre-flight checks passed", systemImage: "checkmark.seal.fill")
                        .font(.caption).foregroundStyle(Brand.good)
                } else {
                    ForEach(preflight.errors, id: \.self) { err in
                        Label(err, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(Brand.bad)
                    }
                    ForEach(preflight.warnings, id: \.self) { warn in
                        Label(warn, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Brand.caution)
                    }
                }
            }
        }
    }

    // MARK: - Directories List

    private var directoriesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Matching Directories (\(matchingDirectories.count))").font(.headline)
                Spacer()
                Button {
                    Task { await deals.pollOpenPRsIfDue(force: true) }
                } label: {
                    Label("Refresh PRs", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.pill)
            }

            ForEach(matchingDirectories) { dir in
                directoryRow(dir)
            }
        }
    }

    @ViewBuilder
    private func directoryRow(_ dir: DealDirectory) -> some View {
        let existing = deals.book.submissions.first {
            $0.directoryID == dir.id && $0.appName.caseInsensitiveCompare(appName) == .orderedSame
        }
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(dir.name).font(.body.weight(.medium))
                        Text(dir.kind.label).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(.quaternary))
                        if let existing {
                            Text(existing.status.label).font(.caption2.weight(.semibold))
                                .foregroundStyle(existing.status.isLiveListed ? Brand.good : Color.accentColor)
                        }
                    }
                    Text(dir.rulesSummary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(checking ? "Checking…" : "Check") {
                    Task {
                        checking = true
                        let sub = buildDraftSubmission(directoryID: dir.id, existingID: existing?.id)
                        preflight = await deals.runPreflight(for: sub)
                        checking = false
                    }
                }
                .buttonStyle(.pill)
                .disabled(checking)

                Button(copiedID == "copy-\(dir.id)" ? "Copied" : "Copy fields") {
                    let sub = buildDraftSubmission(directoryID: dir.id, existingID: existing?.id)
                    let text: String
                    switch dir.kind {
                    case .githubJSONPR: text = DealFormatters.indieGoodiesJSON(for: sub)
                    case .githubMarkdownPR: text = DealFormatters.markdownTableRow(for: sub, directory: dir)
                    case .webForm, .emailPitch: text = DealFormatters.selfServeCopyBlock(for: sub, directory: dir)
                    }
                    copyToPasteboard(text, tag: "copy-\(dir.id)")
                }
                .buttonStyle(.pill)

                if dir.kind == .githubJSONPR || dir.kind == .githubMarkdownPR {
                    Button("Prepare PR") {
                        Task {
                            let sub = buildDraftSubmission(directoryID: dir.id, existingID: existing?.id)
                            deals.upsert(sub)
                            let res = await deals.preparePRJob(submissionID: sub.id, model: model)
                            statusNote = res.note
                        }
                    }
                    .buttonStyle(.pillProminent)
                } else {
                    Button("Open site") {
                        if let u = URL(string: dir.submitURL) { NSWorkspace.shared.open(u) }
                    }
                    .buttonStyle(.pillProminent)
                }
            }

            HStack(spacing: 8) {
                TextField(
                    "Paste live listing URL (once approved/listed)…",
                    text: Binding(
                        get: { liveLinkDraft[dir.id] ?? existing?.liveListingURL ?? "" },
                        set: { liveLinkDraft[dir.id] = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                Button("Save live URL") {
                    let sub = buildDraftSubmission(directoryID: dir.id, existingID: existing?.id)
                    deals.upsert(sub)
                    let urlStr = liveLinkDraft[dir.id] ?? existing?.liveListingURL ?? dir.websiteURL
                    deals.setLiveURL(id: sub.id, urlString: urlStr)
                    statusNote = "Saved live URL for \(dir.name)."
                }
                .buttonStyle(.pill)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.32)))
    }

    // MARK: - Helpers

    private func seedInitialValues() {
        if offerCode.isEmpty { offerCode = initialOfferCode ?? "" }
        if redeemURL.isEmpty { redeemURL = initialRedeemURL ?? "" }
        if endDate.isEmpty { endDate = initialEndDate ?? "2027-04-29" }
        if dealSummary.isEmpty {
            let reg = Double(regularPrice) ?? 49.99
            let sal = Double(salePrice) ?? 39.99
            let pct = reg > 0 ? Int(((reg - sal) / reg * 100).rounded()) : 20
            dealSummary = offerCode.isEmpty
                ? "\(pct)% off lifetime"
                : "\(pct)% off lifetime with code \(offerCode)"
        }
        if let existing = deals.book.submissions.first(where: { $0.appName.caseInsensitiveCompare(appName) == .orderedSame }) {
            if productURL.isEmpty { productURL = existing.productURL }
            if iconURL.isEmpty { iconURL = existing.iconURL ?? "" }
            if shortDescription.isEmpty { shortDescription = existing.shortDescription }
        }
    }

    private func buildDraftSubmission(directoryID: String, existingID: String?) -> DealSubmission {
        DealSubmission(
            id: existingID ?? UUID().uuidString,
            directoryID: directoryID,
            appName: appName,
            appStoreID: appStoreID,
            platforms: [selectedPlatform],
            productURL: productURL.trimmingCharacters(in: .whitespacesAndNewlines),
            iconURL: iconURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : iconURL.trimmingCharacters(in: .whitespacesAndNewlines),
            shortDescription: shortDescription.trimmingCharacters(in: .whitespacesAndNewlines),
            dealSummary: dealSummary.trimmingCharacters(in: .whitespacesAndNewlines),
            offerCode: offerCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : offerCode.trimmingCharacters(in: .whitespacesAndNewlines),
            redeemURL: redeemURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : redeemURL.trimmingCharacters(in: .whitespacesAndNewlines),
            pricing: .lifetime,
            regularPrice: Double(regularPrice) ?? 0,
            salePrice: Double(salePrice) ?? 0,
            currency: "USD",
            startDate: startDate,
            endDate: endDate
        )
    }

    private func copyToPasteboard(_ text: String, tag: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedID = tag
    }
}
