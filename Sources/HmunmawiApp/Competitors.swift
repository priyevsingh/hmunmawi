import Foundation
import HmunmawiCore
import SwiftUI

/// Competitor & price watch: rival apps (and your own) from Apple's public lookup (rating, rating count, price,
/// version, release notes), once a day per country. Each day is kept, so changes show up: a new version, a price
/// change, a jump in ratings. Your own apps are watched too, so a price-tier change or wrong storefront price shows.
/// Read-only and free; about 20 requests a minute at most (Apple's guidance), one call per country for all apps.
@MainActor @Observable
final class Competitors {
    static let shared = Competitors()

    struct Watched: Codable, Hashable, Identifiable { var id: String; var name: String; var mine: Bool }
    struct Snapshot: Codable, Hashable {
        var day: String; var country: String; var rating: Double?; var ratings: Int?; var price: Double?
        var currency: String?; var version: String?; var notes: String?
    }
    struct Change: Identifiable, Hashable { let id = UUID(); let app: String; let text: String; let day: String; let mine: Bool }

    private let url = URL.hmSupport.appending(path: "competitors.json")
    private struct File: Codable {
        var apps: [Watched] = []; var countries: [String] = ["us", "in", "gb", "de"]; var history: [String: [Snapshot]] = [:]
        var removed: Set<String>? = nil      // your own apps you stopped watching (not re-added automatically)
    }
    private var file = File()
    private(set) var lastRun: Date?
    private(set) var problem: String?
    @ObservationIgnored private var running = false

    var apps: [Watched] { file.apps }
    var countries: [String] { file.countries }

    init() {
        if let d = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(File.self, from: d) { file = f }
    }
    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(file).write(to: url, options: .atomic)
    }

    func add(_ id: String, name: String, mine: Bool = false) {
        guard id.allSatisfy(\.isNumber), id.count < 15, !file.apps.contains(where: { $0.id == id }) else { return }
        // Your own apps are added automatically, except ones you chose to stop watching; adding by hand undoes that.
        if mine, file.removed?.contains(id) == true { return }
        if !mine { file.removed?.remove(id) }
        file.apps.append(Watched(id: id, name: String(name.prefix(60)), mine: mine)); save()
    }
    func remove(_ id: String) { file.removed = (file.removed ?? []).union([id]); file.apps.removeAll { $0.id == id }; file.history = file.history.filter { !$0.key.hasPrefix(id + "|") }; save() }
    func setCountries(_ list: [String]) {
        file.countries = Array(Set(list.map { $0.lowercased() }.filter { $0.count == 2 && $0.allSatisfy(\.isLetter) })).sorted().prefix(10).map { $0 }; save()
    }

    /// Search the App Store by name (to add a rival).
    nonisolated static func search(_ term: String, country: String = "us") async -> [(id: String, name: String, seller: String)] {
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [.init(name: "term", value: term), .init(name: "entity", value: "software"), .init(name: "limit", value: "8"), .init(name: "country", value: country)]
        guard let u = c.url, let (d, _) = try? await URLSession.shared.data(from: u), let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [] }
        return ((root["results"] as? [[String: Any]]) ?? []).compactMap { r in
            guard let id = r["trackId"] as? Int, let name = r["trackName"] as? String else { return nil }
            return (String(id), name, r["sellerName"] as? String ?? "")
        }
    }

    /// Once a day: one lookup per country for every watched app.
    func refresh(force: Bool = false) async {
        // Local day, matching "is it today" below (UTC filed early-morning checks under yesterday in India).
        let today = Date.now.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        if !force, let last = lastRun, Calendar.current.isDateInToday(last) { return }
        // One run at a time: the card sits on every app page, and paging through them mustn't start several.
        guard !file.apps.isEmpty, !running else { return }
        running = true; defer { running = false }
        problem = nil
        let ids = file.apps.map(\.id).joined(separator: ",")
        for country in file.countries {
            guard let u = URL(string: "https://itunes.apple.com/lookup?id=\(ids)&country=\(country)") else { continue }
            do {
                let (d, resp) = try await URLSession.shared.data(from: u)
                guard (resp as? HTTPURLResponse)?.statusCode == 200, let root = try JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                    problem = "Apple's lookup didn't answer for \(country.uppercased()); trying again next round."; continue
                }
                for r in (root["results"] as? [[String: Any]]) ?? [] {
                    guard let id = (r["trackId"] as? Int).map(String.init) else { continue }
                    let snap = Snapshot(day: today, country: country, rating: r["averageUserRating"] as? Double, ratings: r["userRatingCount"] as? Int,
                                        price: r["price"] as? Double, currency: r["currency"] as? String, version: r["version"] as? String,
                                        notes: (r["releaseNotes"] as? String).map { String($0.prefix(400)) })
                    var list = file.history["\(id)|\(country)"] ?? []
                    list.removeAll { $0.day == today }
                    list.append(snap)
                    file.history["\(id)|\(country)"] = Array(list.suffix(90))
                }
            } catch {
                problem = "Couldn't reach Apple's lookup: \(error.localizedDescription)"
            }
            try? await Task.sleep(for: .seconds(3))      // gentle on Apple's public API
        }
        // A country that didn't answer is retried next round (as the message says), not tomorrow.
        if problem == nil { lastRun = .now }
        save()
    }

    func latest(_ id: String, country: String) -> Snapshot? { file.history["\(id)|\(country)"]?.last }

    /// What changed between each app's last two snapshots (new version, price, rating moves).
    func changes() -> [Change] {
        var out: [Change] = []
        for app in file.apps {
            for country in file.countries {
                guard let list = file.history["\(app.id)|\(country)"], list.count >= 2 else { continue }
                let a = list[list.count - 2], b = list[list.count - 1]
                let cc = country.uppercased()
                if a.version != b.version, let v = b.version { out.append(Change(app: app.name, text: "shipped \(v)" + (b.notes.map { ": \($0.prefix(90))" } ?? ""), day: b.day, mine: app.mine)) }
                if a.price != b.price, let p = b.price { out.append(Change(app: app.name, text: "price in \(cc) \(a.price.map { String(format: "%.2f", $0) } ?? "?") → \(String(format: "%.2f", p)) \(b.currency ?? "")", day: b.day, mine: app.mine)) }
                if let x = a.rating, let y = b.rating, abs(x - y) >= 0.1 { out.append(Change(app: app.name, text: String(format: "rating in \(cc) %.1f → %.1f", x, y), day: b.day, mine: app.mine)) }
            }
        }
        // Same version shipping shows once, not per country.
        var seen = Set<String>()
        return out.filter { seen.insert($0.app + $0.text.prefix(20)).inserted }
    }
}

struct CompetitorsCard: View {
    let model: AppModel
    @State private var watch = Competitors.shared
    @State private var adding = false

    var body: some View {
        KitCard {
            HStack {
                CardHeader(symbol: "binoculars.fill", title: "Rivals & prices", tint: Brand.Category.web,
                           caption: watch.lastRun.map { "checked \(Ago.text($0))" } ?? "Apple's public App Store data")
                Button { Task { await watch.refresh(force: true) } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Check now")
                Button { adding = true } label: { Label("Add a rival", systemImage: "plus") }.buttonStyle(.pill)
            }
            if watch.apps.isEmpty {
                Text(Quips.pick(["No rivals on the radar. Add one and we'll keep an eye on them, quietly.",
                                 "Keep your friends close and your competitors in this card."]))
                    .foregroundStyle(.secondary)
            } else {
                let changes = watch.changes()
                if !changes.isEmpty {
                    ForEach(changes.prefix(6)) { c in
                        Label { Text("\(Text(c.app).bold()) \(c.text)").fixedSize(horizontal: false, vertical: true) } icon: {
                            Image(systemName: c.mine ? "exclamationmark.circle.fill" : "sparkle").foregroundStyle(c.mine ? Brand.caution : Brand.Category.web)
                        }
                        .font(.callout)
                    }
                    Divider()
                }
                let country = watch.countries.first ?? "us"
                ForEach(watch.apps) { a in
                    let s = watch.latest(a.id, country: country)
                    HStack(spacing: 10) {
                        Text(a.name).fontWeight(a.mine ? .semibold : .regular)
                        if a.mine { Text("you").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if let s {
                            Text([s.ratings == 0 ? "no ratings yet" : s.rating.map { String(format: "★ %.1f", $0) },
                                  s.ratings == 0 ? nil : s.ratings.map { "\($0.formatted()) ratings" },
                                  s.price.map { $0 == 0 ? "Free" : String(format: "%.2f %@", $0, s.currency ?? "") }, s.version.map { "v\($0)" }]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.callout.monospacedDigit()).foregroundStyle(.secondary).liveNumber(s)
                        } else {
                            Text(watch.lastRun == nil ? "first check pending" : "not on the App Store here yet").font(.callout).foregroundStyle(.secondary)
                        }
                        Button { watch.remove(a.id) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless).help("Stop watching")
                    }
                }
                Text("Showing \(country.uppercased()); watching \(watch.countries.map { $0.uppercased() }.joined(separator: ", ")). Changes compare today with the last check.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let p = watch.problem { Text(p).font(.caption).foregroundStyle(Brand.caution) }
        }
        .task {
            // Your own apps are watched too (price-tier or storefront mistakes show up).
            for e in model.snapshots("icon.snapshot") {
                if let id = e.payload[path: "appID"]?.string { watch.add(id, name: ComingSoon.shortName(e.app ?? id), mine: true) }
            }
            await watch.refresh()
        }
        .sheet(isPresented: $adding) { AddRival().buttonStyle(.pill) }
    }
}

private struct AddRival: View {
    @Environment(\.dismiss) private var dismiss
    @State private var term = ""
    @State private var results: [(id: String, name: String, seller: String)] = []
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a rival").font(.title2.bold())
            HStack {
                TextField("App name, e.g. Bevel", text: $term).input(.name, $term).onSubmit { Task { await go() } }
                Button(busy ? "Searching" : "Search") { Task { await go() } }.buttonStyle(.pill).disabled(term.isEmpty || busy)
            }
            ForEach(results, id: \.id) { r in
                HStack {
                    VStack(alignment: .leading) { Text(r.name); Text(r.seller).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Watch") { Competitors.shared.add(r.id, name: r.name); Task { await Competitors.shared.refresh(force: true) }; dismiss() }.buttonStyle(.pill)
                }
            }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.pillProminent) }
        }
        .padding(22).frame(width: 520)
    }

    private func go() async { busy = true; results = await Competitors.search(term); busy = false }
}
