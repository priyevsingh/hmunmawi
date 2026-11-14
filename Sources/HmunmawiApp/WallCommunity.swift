import AppKit
import Foundation
import HmunmawiCore
import Observation

/// The community side of the Wall of Apps: the public list read from the project's GitHub (only when you switch
/// it on, or after you added your own app), a "Share on X" for a developer whose app made it onto the wall, and,
/// for the project's maintainer (owner.json `wallShoutouts`), a welcome post drafted into the post bank for each new
/// app. Reading the list is a plain request to raw.githubusercontent.com; nothing about you is sent.
@MainActor @Observable
final class WallCommunity {
    static let shared = WallCommunity()

    static let showKey = "HMWallShow"            // "Show the community's apps" (off by default)
    static let submittedKey = "HMWallSubmitted"  // app ids you added from this Mac
    static let sharedKey = "HMWallShared"        // app ids whose "Share on X" you finished or dismissed
    static let seenKey = "HMWallSeen"            // maintainer: app ids already given a welcome draft
    static let cacheURL = URL.hmSupport.appending(path: "wall-cache.json")

    private(set) var apps: [WallOfApps.Entry] = []
    private(set) var status: String?
    private(set) var fetchedAt: Date?
    private var busy = false

    init() {
        if let d = try? Data(contentsOf: Self.cacheURL), let list = WallOfApps.decode(d) { apps = WallOfApps.sorted(list) }
        fetchedAt = (try? Self.cacheURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static var defaults: UserDefaults { .standard }
    private static func ids(_ key: String) -> Set<String> { Set(defaults.stringArray(forKey: key) ?? []) }
    private static func setIDs(_ key: String, _ s: Set<String>) { defaults.set(Array(s).sorted(), forKey: key) }

    /// Reading the list is wanted: you switched the wall on, you're waiting for your own app, or you maintain it.
    var wanted: Bool {
        Self.defaults.bool(forKey: Self.showKey) || !Self.ids(Self.submittedKey).isEmpty || OwnerConfig.current.wantsWallShoutouts
    }

    /// Your own apps that are on the wall and haven't been shared or dismissed yet.
    var mine: [WallOfApps.Entry] {
        let submitted = Self.ids(Self.submittedKey), done = Self.ids(Self.sharedKey)
        return apps.filter { e in e.appID.map { submitted.contains($0) && !done.contains($0) } ?? false }
    }

    func markSubmitted(_ e: WallOfApps.Entry) {
        guard let id = e.appID else { return }
        Self.setIDs(Self.submittedKey, Self.ids(Self.submittedKey).union([id]))
    }

    func finishShare(_ e: WallOfApps.Entry) {
        guard let id = e.appID else { return }
        Self.setIDs(Self.sharedKey, Self.ids(Self.sharedKey).union([id]))
        apps = apps   // redraw
    }

    /// Opens X with the post written; you press post yourself.
    func share(_ e: WallOfApps.Entry) {
        var c = URLComponents(string: "https://x.com/intent/post")!
        c.queryItems = [URLQueryItem(name: "text", value: WallOfApps.shareText(e))]
        if let u = c.url { NSWorkspace.shared.open(u) }
        finishShare(e)
    }

    /// Reads the public list when it's wanted and older than 12 hours (or `force`).
    func refreshIfDue(force: Bool = false) async {
        guard wanted, !busy else { return }
        if !force, let f = fetchedAt, Date.now.timeIntervalSince(f) < 12 * 3600 { return }
        busy = true; defer { busy = false }
        var req = URLRequest(url: WallOfApps.rawURL, timeoutInterval: 20)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (d, r) = try? await URLSession.shared.data(for: req), let code = (r as? HTTPURLResponse)?.statusCode else {
            status = "Couldn't reach GitHub; showing the last copy."
            return
        }
        guard code == 200, let list = WallOfApps.decode(d) else {
            status = code == 404 ? "The wall isn't public yet." : "GitHub answered \(code); showing the last copy."
            return
        }
        try? FileManager.default.createDirectory(at: Self.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: Self.cacheURL)
        ingest(list)
    }

    /// Takes in a freshly read list (also used by tests).
    func ingest(_ list: [WallOfApps.Entry]) {
        apps = WallOfApps.sorted(list)
        status = nil
        fetchedAt = .now
        draftWelcomes()
    }

    /// Maintainer only: one welcome draft per new app, into the "posts" bank (you post it yourself). The first
    /// read only remembers what's there, so switching it on never floods the bank.
    func draftWelcomes(enabled: Bool = OwnerConfig.current.wantsWallShoutouts) {
        guard enabled else { return }
        let ids = Set(apps.compactMap(\.appID))
        guard Self.defaults.object(forKey: Self.seenKey) != nil else { Self.setIDs(Self.seenKey, ids); return }
        let seen = Self.ids(Self.seenKey)
        let fresh = apps.filter { e in e.appID.map { !seen.contains($0) } ?? false }
        guard !fresh.isEmpty else { return }
        var bank = Bankfile.read("posts")
        for e in fresh where !bank.contains(where: { $0.id == "wall-\(e.appID ?? "")" }) {
            let by = e.developer.map { " by \($0)" } ?? ""
            bank.append(BankItem(id: "wall-\(e.appID ?? UUID().uuidString)",
                                 text: "Welcome to the Hmunmawi Wall of Apps: \(e.app)\(by) 🎉 \(e.link)", tag: "wall"))
        }
        Bankfile.write("posts", bank)
        Self.setIDs(Self.seenKey, seen.union(ids))
    }
}
