import HmunmawiCore
import SwiftUI

/// Recent reviews for one app, beside Stability: stars, the words, and a reply. "Sort it for me: Draft reply"
/// writes one with AI that you edit; sending always asks first. "Show me how" opens the review in App Store Connect.
struct ReviewsGlance: View {
    let app: String
    let model: AppModel
    @State private var replying: StoredEvent?

    var body: some View {
        let mine = model.events.filter { $0.kind == "review.new" && ComingSoon.shortName($0.app ?? "") == app }
            .sorted { $0.occurredAt > $1.occurredAt }
        VStack(alignment: .leading, spacing: 10) {
            Label { Text("Reviews").foregroundStyle(.primary) } icon: { Image(systemName: "star.bubble.fill").foregroundStyle(Brand.caution) }
                .font(.headline)
            if mine.isEmpty {
                Text(Quips.pick(["No new reviews this week. The critics are on holiday.", "Quiet in the reviews. Calm before the five stars."]))
                    .font(.callout).foregroundStyle(.secondary)
                // A quiet week still has a scoreboard: the star rating per storefront, from Apple's public
                // lookup (the same daily read as Rivals & prices), so this side isn't left empty.
                let watch = Competitors.shared
                if let me = watch.apps.first(where: { $0.mine && $0.name == app }) {
                    let rows = watch.countries.compactMap { c in watch.latest(me.id, country: c).map { (c, $0) } }
                        .filter { ($0.1.ratings ?? 0) > 0 }
                    if !rows.isEmpty {
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                            ForEach(rows, id: \.0) { c, s in
                                GridRow {
                                    Text(c.uppercased()).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                                    Text(s.rating.map { String(format: "★ %.1f", $0) } ?? "").font(.callout.bold().monospacedDigit())
                                        .foregroundStyle(Kit.vibrant((s.rating ?? 0) >= 4 ? Brand.good : Brand.caution))
                                    Text(s.ratings.map { "\($0.formatted()) rating\($0 == 1 ? "" : "s")" } ?? "Ratings count not in yet").font(.callout).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Text("Star ratings by storefront, from Apple's public App Store data.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(mine.prefix(3)) { e in
                let stars = Int(safe: e.payload[path: "rating"]?.number ?? 0)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(String(repeating: "★", count: stars) + String(repeating: "☆", count: max(0, 5 - stars)))
                            .foregroundStyle(stars <= 2 ? Brand.bad : stars == 3 ? Brand.caution : Brand.good)
                        Text(e.payload[path: "title"]?.string ?? "").font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Text(Ago.text(millis: e.occurredAt))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(e.payload[path: "body"]?.string ?? "").font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if e.payload[path: "review_id"]?.string != nil {
                        HStack {
                            Button { replying = e } label: { Label("Sort it for me: Draft reply", systemImage: "sparkles") }
                            if let id = model.snapshots("icon.snapshot").first(where: { ComingSoon.shortName($0.app ?? "") == app })?.payload[path: "appID"]?.string,
                               let url = URL(string: "https://appstoreconnect.apple.com/apps/\(id)/distribution/activity/ios/ratingsResponses") {
                                Link(destination: url) { Label("Show me how", systemImage: "safari") }
                            }
                        }
                        .buttonStyle(.pill)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .sheet(item: $replying) { e in ReplySheet(review: e, app: app, model: model).buttonStyle(.pill) }
    }
}

struct ReplySheet: View {
    let review: StoredEvent
    let app: String
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var busy = false
    @State private var confirm = false
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reply to this review").font(.title2.bold())
            Text("\u{201C}\(review.payload[path: "title"]?.string ?? "")\u{201D} · \(review.payload[path: "body"]?.string ?? "")")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(busy ? "Writing" : "Sort it for me: Write a reply") { Task { await draft() } }.buttonStyle(.pill).disabled(busy)
            TextField("Your reply", text: $text, axis: .vertical).lineLimit(4...10).input(.text(5000), $text)
            if let note { Text(note).font(.callout).foregroundStyle(note.hasPrefix("Couldn") ? Brand.bad : Brand.good).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.pill).keyboardShortcut(.cancelAction)
                Button("Send reply") { confirm = true }.buttonStyle(.pillProminent).keyboardShortcut(.defaultAction).disabled(text.isEmpty || busy)
            }
        }
        .padding(22).frame(minWidth: 560, idealWidth: 640, maxWidth: 900)
        .confirmationDialog("Post this reply publicly on the App Store?", isPresented: $confirm) {
            Button("Sort it for me: Post reply") {
                Task {
                    busy = true
                    let r = await model.shieldFix(.object(["fix": .string("review_reply"), "review_id": review.payload[path: "review_id"] ?? .null, "text": .string(text)]))
                    busy = false
                    note = r.ok ? r.message : "Couldn't send it: \(r.message)"
                }
            }
        } message: { Text("Everyone who reads the review will see it. You can remove it later in App Store Connect.") }
    }

    private func draft() async {
        busy = true; defer { busy = false }
        do {
            text = try await AIWriter.draft("""
            Write a short, warm, specific reply from the indie developer of "\(app)" to this App Store review. \
            \(Int(safe: review.payload[path: "rating"]?.number ?? 0)) stars. Title: \(review.payload[path: "title"]?.string ?? ""). Review: \(review.payload[path: "body"]?.string ?? "")
            Thank them, address their point concretely, and if it's a problem say what to try or that a fix is coming only if \
            plausible. No promises you can't keep, no emoji, under 600 characters, plain text, in the review's language.
            """).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch { note = "Couldn't draft it: " + plainError(error) }
    }
}


// MARK: Reviews waiting for a reply (all apps)

/// One review that has no published reply, from the App Store Connect add-on's `reviews.snapshot` (Apple's own
/// `exists[publishedResponse]=false` filter, read only).
struct OpenReview: Identifiable {
    let id: String, app: String, appID: String, rating: Int, title: String, body: String, territory: String, created: Date

    @MainActor static func all(_ model: AppModel) -> (rows: [OpenReview], asOf: Date?, more: Bool) { parse(model.snapshots("reviews.snapshot")) }

    static func parse(_ snapshots: [StoredEvent]) -> (rows: [OpenReview], asOf: Date?, more: Bool) {
        var rows: [OpenReview] = [], oldest: Int64?, more = false
        for snap in snapshots {
            let app = ComingSoon.shortName(snap.app ?? ""), appID = snap.payload[path: "app_id"]?.string ?? ""
            if case .bool(true)? = snap.payload[path: "more"] { more = true }
            oldest = min(oldest ?? snap.occurredAt, snap.occurredAt)
            for r in snap.payload[path: "reviews"]?.array ?? [] {
                guard let id = r[path: "review_id"]?.string else { continue }
                rows.append(OpenReview(id: id, app: app, appID: appID, rating: Int(safe: r[path: "rating"]?.number ?? 0),
                                       title: r[path: "title"]?.string ?? "", body: r[path: "body"]?.string ?? "",
                                       territory: r[path: "territory"]?.string ?? "",
                                       created: Date(timeIntervalSince1970: (r[path: "created"]?.number ?? 0) / 1000)))
            }
        }
        return (rows, oldest.map { Date(timeIntervalSince1970: Double($0) / 1000) }, more)
    }
}

/// A line at the top of Apps when reviews are waiting; opens the inbox.
struct ReviewsInboxBanner: View {
    let model: AppModel
    @State private var show = false
    @AppStorage("HMInboxMaxStars") private var maxStars = 3
    var body: some View {
        let all = OpenReview.all(model).rows
        let n = all.count
        let low = all.filter { $0.rating <= maxStars }.count
        Group {
            if n > 0 {
                HStack {
                    Label(low == n ? "\(n) review\(n == 1 ? "" : "s") waiting for your reply"
                                   : "\(low) review\(low == 1 ? "" : "s") of 1–\(maxStars) stars waiting for your reply (\(n) in all)",
                          systemImage: "bubble.left.and.bubble.right")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Button("Open inbox") { show = true }.buttonStyle(.pill)
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(Brand.surface, in: .rect(cornerRadius: 18))
            }
        }
        .sheetFlow(isPresented: $show) { AnyView(ReviewsInbox(model: model).buttonStyle(.pill)) }
    }
}

struct ReviewsInbox: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSheet) private var openSheet
    // Settings of this list, kept between visits: showing only the unhappy ones first is the default.
    @AppStorage("HMInboxMaxStars") private var maxStars = 3
    @AppStorage("HMInboxNewestFirst") private var newestFirst = false
    @AppStorage("HMInboxApp") private var appFilter = ""

    var body: some View {
        let data = OpenReview.all(model)
        let apps = Array(Set(data.rows.map(\.app))).sorted()
        let shown = data.rows
            .filter { $0.rating <= maxStars && (appFilter.isEmpty || $0.app == appFilter) }
            .sorted { newestFirst ? $0.created > $1.created : ($0.rating, $1.created) < ($1.rating, $0.created) }
        VStack(alignment: .leading, spacing: 12) {
            Text("Reviews waiting for your reply").font(.title2.bold())
            HStack {
                Picker("Show", selection: $maxStars) {
                    Text("1–3 stars").tag(3); Text("1–4 stars").tag(4); Text("All").tag(5)
                }.pickerStyle(.segmented).frame(width: 260).labelsHidden()
                Picker("Order", selection: $newestFirst) {
                    Text("Lowest first").tag(false); Text("Newest first").tag(true)
                }.frame(width: 150)
                if apps.count > 1 {
                    Picker("App", selection: $appFilter) {
                        Text("All apps").tag(""); ForEach(apps, id: \.self) { Text($0).tag($0) }
                    }.frame(width: 150)
                }
                Spacer()
            }
            if let asOf = data.asOf {
                Text("As of \(Ago.text(asOf))\(data.more ? " · the newest 50 per app" : ""). A reply you post in App Store Connect drops out on the next check.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if shown.isEmpty {
                        Text(data.rows.isEmpty ? "Nothing waiting. Every review you can see has a reply." : "Nothing at this filter. Widen it above.")
                            .foregroundStyle(.secondary).padding(.vertical, 20)
                    }
                    ForEach(shown) { r in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(String(repeating: "★", count: r.rating) + String(repeating: "☆", count: max(0, 5 - r.rating)))
                                    .foregroundStyle(r.rating <= 2 ? Brand.bad : r.rating == 3 ? Brand.caution : Brand.good)
                                Text(r.title).font(.callout.weight(.medium))
                                Spacer()
                                Text("\(r.app) · \(r.territory) · \(Ago.text(r.created))").font(.caption).foregroundStyle(.secondary)
                            }
                            Text(r.body).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Button { reply(r) } label: { Label("Sort it for me: Draft reply", systemImage: "sparkles") }
                                if let url = URL(string: "https://appstoreconnect.apple.com/apps/\(r.appID)/distribution/activity/ios/ratingsResponses") {
                                    Link(destination: url) { Label("Open in App Store Connect", systemImage: "safari") }
                                }
                            }
                        }
                        Divider()
                    }
                }
            }
            .frame(minHeight: 200, maxHeight: 460)
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.pillProminent) }
        }
        .padding(22).frame(width: 720)
    }

    /// The reply sheet replaces the inbox (one sheet at a time) and the inbox comes back when it closes.
    private func reply(_ r: OpenReview) {
        let m = model
        let event = StoredEvent(id: 0, source: "appstoreconnect", kind: "review.new", app: r.app,
                                payload: .object(["review_id": .string(r.id), "rating": .number(Double(r.rating)), "title": .string(r.title),
                                                  "body": .string(r.body), "territory": .string(r.territory)]),
                                occurredAt: Int64(r.created.timeIntervalSince1970 * 1000))
        openSheet?({ AnyView(ReplySheet(review: event, app: r.app, model: m).buttonStyle(.pill)) })
    }
}
