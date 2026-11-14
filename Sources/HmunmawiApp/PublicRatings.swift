import Foundation
import HmunmawiCore

/// Star ratings for apps without a script feed: reads each app's public App Store listing (the same page anyone sees),
/// a few storefronts, once a day, and stores a `rating.snapshot`. Only the app's id and a storefront code are sent.
/// Off in Settings → General → Alerts. A storefront that answers nothing useful is skipped, never recorded as zero.
@MainActor
enum PublicRatings {
    static let onKey = "HMPublicRatings", lastKey = "HMPublicRatingsLast"
    private static var running = false

    static func runIfDue(model: AppModel) {
        let d = UserDefaults.standard
        guard !running, !model.isDemo, (d.object(forKey: onKey) as? Bool) ?? true,
              Date.now.timeIntervalSince1970 - d.double(forKey: lastKey) > 24 * 3600 else { return }
        // App ids from the add-on's icon snapshots, and the storefronts people buy from (plus the US, always).
        var apps: [(name: String, id: String)] = []
        for s in model.snapshots("icon.snapshot") {
            if let id = s.payload[path: "appID"]?.string, let name = s.app, !apps.contains(where: { $0.id == id }) { apps.append((name, id)) }
        }
        guard !apps.isEmpty else { return }
        // Storefronts to ask, per app: every one that has ever answered with ratings (so the set only grows and today's
        // number stays comparable with last week's), the big stores, and the countries people download from. At most 60.
        var seen: [String: Int] = [:]
        for e in model.events where e.kind == "revenue.daily" {
            if case .object(let byCountry)? = e.payload[path: "units_by_country"] {
                for (c, n) in byCountry { seen[c.lowercased(), default: 0] += Int(safe: n.number ?? 0) }
            }
        }
        let popular = ["us", "gb", "ca", "au", "de", "fr", "it", "es", "nl", "se", "no", "dk", "fi", "ie", "ch", "at", "be", "pt", "pl", "jp", "kr", "cn", "tw", "hk", "sg",
                       "in", "id", "th", "vn", "ph", "my", "br", "mx", "ar", "cl", "co", "tr", "sa", "ae", "il", "za", "ng", "eg", "ru", "ua", "nz", "ro", "cz", "gr", "hu"]
        let sales = seen.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.map(\.key)
                running = true
        d.set(Date.now.timeIntervalSince1970, forKey: lastKey)
        Task.detached(priority: .utility) {
            var payloads: [(String, JSONValue)] = []
            for app in apps {
                var by: [String: StoreListing] = [:]
                let known = (UserDefaults.standard.stringArray(forKey: "HMRatingCountries-\(app.id)") ?? [])
                var codes: [String] = []
                for c in known + popular + sales where c.count == 2 && !codes.contains(c) { codes.append(c) }
                for code in codes.prefix(60) {
                    guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(app.id)&country=\(code)") else { continue }
                    if let (data, response) = try? await URLSession.shared.data(from: url), (response as? HTTPURLResponse)?.statusCode == 200,
                       let l = StoreListing.parse(data) { by[code] = l }
                    try? await Task.sleep(for: .seconds(3.5))      // Apple's public search pages say about 20 calls a minute
                }
                if let p = NativeApps.ratingPayload(by, appID: app.id) {
                    payloads.append((app.name, p))
                    UserDefaults.standard.set(Array(by.keys).sorted(), forKey: "HMRatingCountries-\(app.id)")
                }
            }
            let slot = Int(Date.now.timeIntervalSince1970 / (6 * 3600))
            let events = payloads.map { name, p in
                Event(source: "applepublic", kind: "rating.snapshot", app: name, payload: p,
                      occurredAt: Millis(Date.now.timeIntervalSince1970 * 1000), dedupeKey: "ratingsnap-\(name)-\(slot)")
            }
            await MainActor.run { running = false }
            if !events.isEmpty { await model.ingestLocal(events) }
        }
    }
}
