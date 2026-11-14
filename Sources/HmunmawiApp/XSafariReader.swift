import Foundation
import HmunmawiCore

/// Settings → Connections → X → "Read via your Safari login": every 6 hours, your own X profile is opened in a
/// background Safari tab (where you're already signed in), the numbers X's page loaded are read, and the tab is closed.
/// The result is the X file (x-file.json in the app's data folder) that the X connection reads. Read-only: nothing is
/// clicked, posted or sent; no paid X API, no key. Needs Safari → Develop → "Allow JavaScript from Apple Events".
@MainActor @Observable
final class XSafariReader {
    static let shared = XSafariReader()
    nonisolated static let enabledKey = "HMXSafariRead", handleKey = "HMXHandle", lastKey = "HMXSafariLast", historyKey = "HMXFollowersHistory"
    static var file: URL { URL.hmSupport.appending(path: "x-file.json") }

    var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey) } }
    var handle: String { didSet { UserDefaults.standard.set(handle, forKey: Self.handleKey) } }
    private(set) var note: String?
    private(set) var busy = false

    init() {
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        handle = UserDefaults.standard.string(forKey: Self.handleKey) ?? ""
    }

    var lastRun: Date? { UserDefaults.standard.object(forKey: Self.lastKey) as? Date }

    /// Reads when switched on and 6 hours have passed (or `force`). Returns a short result for the screen.
    @discardableResult
    func readIfDue(force: Bool = false) async -> String? {
        guard enabled, !busy, let h = XNative.validHandle(handle) else { return nil }
        if !force, let l = lastRun, Date.now.timeIntervalSince(l) < 6 * 3600 { return nil }
        if let wait = Permissions.shared.deferIfNeeded([.safari]) { note = wait; return wait }
        busy = true; defer { busy = false }
        UserDefaults.standard.set(Date.now, forKey: Self.lastKey)
        var merged: [String: XNative.Post] = [:]
        var counts: XNative.Read?
        for page in ["with_replies", ""] {          // replies tab first; the posts tab adds older originals
            let url = "https://x.com/\(h)" + (page.isEmpty ? "" : "/\(page)")
            guard let answer = await Self.readTab(url: url, js: XNative.storeJS(handle: h)) else {
                note = "Couldn't use Safari. Allow Hmunmawi to control Safari (Settings → Permissions)."; return note
            }
            do {
                let r = try XNative.parse(answer, handle: h)
                counts = counts ?? r
                for p in r.posts { merged[p.url] = p }
            } catch {
                if merged.isEmpty { note = "X didn't give your numbers: \(error). Are you signed in to x.com as @\(h) in Safari?"; return note }
            }
        }
        guard let c = counts, !merged.isEmpty else { note = "No posts of @\(h) on the page yet."; return note }
        var history = (UserDefaults.standard.dictionary(forKey: Self.historyKey) as? [String: Int]) ?? [:]
        let doc = XNative.file(handle: h, read: .init(followers: c.followers, following: c.following, posts: Array(merged.values), pinned: c.pinned),
                               now: .now, today: Date.now.localDay, history: &history)
        UserDefaults.standard.set(history, forKey: Self.historyKey)
        guard let data = try? JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys]) else { return nil }
        try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.file)
        UserDefaults.standard.set(Self.file.path, forKey: "HMXSafariFile")   // its glance competes even when another X file is set
        if XFileFeed.shared.path.isEmpty { XFileFeed.shared.path = Self.file.path }
        let week = (doc["posts"] as? [Any])?.count ?? 0
        note = "Read @\(h): \(week) posts in 7 days, \(c.followers.map { "\($0) followers" } ?? "followers unknown")."
        return note
    }

    /// Opens `url` in a new background tab of Safari's front window, polls the page with `js` until it answers with
    /// posts (up to ~24 s), closes that tab and returns the answer. Only the tab it opened is read or closed.
    nonisolated static func readTab(url: String, js: String, until: String = "\\\"tweets\\\":[{") async -> String? {
        // Only x.com pages, and only URL-safe characters (search queries arrive percent-encoded).
        guard url.hasPrefix("https://x.com/"), url.count < 600,
              url.wholeMatch(of: /https:\/\/x\.com\/[A-Za-z0-9_\/?=&%.\-+~]+/) != nil else { return nil }
        let esc = js.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Safari"
            if (count of windows) is 0 then make new document
            set t to make new tab at end of tabs of window 1 with properties {URL:"\(url)"}
            set r to ""
            repeat 15 times
                delay 2
                try
                    set r to (do JavaScript "\(esc)" in t) as text
                on error e
                    set r to "{\\"error\\":\\"" & e & "\\"}"
                end try
                if r contains "\(until)" or r contains "signed out" then exit repeat
            end repeat
            try
                close t
            end try
            return r
        end tell
        """
        return await Task.detached { () -> String? in
            let p = Process(), out = Pipe(), input = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-"]
            p.standardInput = input; p.standardOutput = out; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            try? input.fileHandleForWriting.write(contentsOf: Data(script.utf8)); try? input.fileHandleForWriting.close()
            let killer = Task.detached { try? await Task.sleep(for: .seconds(60)); if p.isRunning { p.terminate() } }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit(); killer.cancel()
            guard p.terminationStatus == 0 else { return nil }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }

    // MARK: For people without a bot (read-only, same files a bot would write)

    /// Where the Safari route saves the day's reply targets (the reply-ideas routine reads it like a bot's folder).
    nonisolated static var findsFolder: URL { URL.hmSupport.appending(path: "x-reply-finds", directoryHint: .isDirectory) }

    /// Reads your Following page and saves the accounts that don't follow you back as unfollow-queue.json.
    func refreshUnfollow(to file: URL) async -> String {
        guard enabled, let h = XNative.validHandle(handle) else { return "Switch on Read via your Safari login and enter your handle (Settings → General → X numbers)." }
        if let wait = Permissions.shared.deferIfNeeded([.safari]) { return wait }
        guard let answer = await Self.readTab(url: "https://x.com/\(h)/following", js: XSafariFinds.followingJS(handle: h),
                                              until: "\\\"users\\\":[{") else { return "Couldn't use Safari. Allow Hmunmawi to control Safari (Settings → Permissions)." }
        guard let list = XSafariFinds.nonFollowbacks(answer) else { return "X didn't show your Following list. Are you signed in to x.com as @\(h) in Safari?" }
        let doc: [String: Any] = ["generated": ISO8601DateFormatter().string(from: .now), "source": "Hmunmawi Safari read of your Following page",
                                  "non_followbacks": list]
        guard let data = try? JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys]) else { return "Couldn't save the list." }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file)
        return "Read @\(h)'s Following page: \(list.count) don't follow back."
    }

    /// Searches X for your topics, keeps the best fresh posts and (with an AI key) drafts a reply to each, saving
    /// today's file in `findsFolder`. Without an AI key each target comes with no draft: you write the reply.
    func findReplies(topics: [String], count: Int, about: String, day: String, drafter: XSafariFinds.Drafter) async -> String {
        guard enabled, let h = XNative.validHandle(handle) else { return "Switch on Read via your Safari login and enter your handle (Settings → General → X numbers)." }
        guard let url = XSafariFinds.searchURL(topics: topics) else { return "Add your topics first." }
        if let wait = Permissions.shared.deferIfNeeded([.safari]) { return wait }
        guard let answer = await Self.readTab(url: url, js: XSafariFinds.searchJS(handle: h)) else {
            return "Couldn't use Safari. Allow Hmunmawi to control Safari (Settings → Permissions)."
        }
        let picks = XSafariFinds.pick(answer, topics: topics, now: .now, count: count * 2)
        guard !picks.isEmpty else { return "No fresh posts on your topics right now." }
        var targets: [[String: String]] = []
        for c in picks where targets.count < count {
            var reply = ""
            if drafter != .none {
                let prompt = XSafariFinds.replyPrompt(c, about: about)
                let raw = drafter == .onDevice ? try? await OnDeviceAI.draft(prompt, instructions: XSafariFinds.replyInstructions)
                                               : try? await AIWriter.draft(prompt)
                // Nothing real to add, or the model's safety check declined: skip the post rather than send it bare.
                guard let raw, let r = XSafariFinds.cleanReply(raw) else { continue }
                reply = r
            }
            targets.append(["tweet_url": c.url, "author": c.author, "tweet_text": c.text, "reply_text": reply])
        }
        guard let data = try? JSONSerialization.data(withJSONObject: targets, options: [.sortedKeys]) else { return "Couldn't save the targets." }
        try? FileManager.default.createDirectory(at: Self.findsFolder, withIntermediateDirectories: true)
        try? data.write(to: Self.findsFolder.appending(path: day + ".json"))
        let by = drafter == .onDevice ? ", replies drafted on this Mac" : drafter == .aiKey ? ", replies drafted with your AI key" : " (you write the replies)"
        return "Found \(targets.count) posts to reply to\(by)."
    }
}
