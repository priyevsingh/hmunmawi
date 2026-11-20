import Foundation
import HmunmawiCore

/// Automations → X unfollows (automatic): unfollows accounts that don't follow you back, a few a day, through your
/// own signed-in Safari (the same Safari control Hmunmawi already uses to read your X numbers; no X API, no key).
/// Off until you add and switch it on. Rules, page checks and pacing live in `XUnfollow` (HmunmawiCore).
///
/// Per account: ONE new background tab in Safari's front window, tagged (window.name) once it loads; the page must be
/// the right user (handle and user id), signed in as you, with a "Following" button and no "Follows you" badge. Then
/// Following → Unfollow, a check that the button now says Follow, and the tab is closed whatever happened. Other tabs
/// are never read or touched: only tabs showing that profile are looked at, and only the one carrying our tag is used.
@MainActor
final class XUnfollower {
    static let shared = XUnfollower()
    private(set) var busy = false

    struct Outcome { var ok: Bool; var note: String; var message: String? }

    // MARK: State (one file per routine in the app's folder)

    nonisolated static func stateURL(_ id: String) -> URL {
        let safe = InputRule.identifier.clean(id)
        return URL.hmSupport.appending(path: "x-unfollows", directoryHint: .isDirectory).appending(path: (safe.isEmpty ? "default" : safe) + ".json")
    }

    nonisolated static func load(_ id: String) -> XUnfollow.State {
        guard let d = try? Data(contentsOf: stateURL(id)) else { return .init() }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(XUnfollow.State.self, from: d)) ?? .init()
    }

    nonisolated static func save(_ s: XUnfollow.State, _ id: String) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(s) else { return }
        let url = stateURL(id)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    nonisolated static func fromSafari(_ r: MyRoutine) -> Bool { r.params?["source"] != "bot" }
    nonisolated static func file(_ r: MyRoutine) -> URL { UnfollowList.file(r) }
    var me: String? { XNative.validHandle(XSafariReader.shared.handle) }

    /// Settings → Jobs: the `x` channel switch or the `x_unfollows` switch in your switch file turns this off too.
    nonisolated static func switchedOff() -> String? {
        guard let url = SwitchFile.locate(chosen: UserDefaults.standard.string(forKey: "HMSwitchFile")),
              case .success(let l) = SwitchFile.load(url) else { return nil }
        if l.switches.first(where: { $0.id == "x" })?.value == false { return "X is switched off in Settings → Jobs." }
        if l.switches.first(where: { $0.id == "x_unfollows" })?.value == false { return "X unfollows are switched off in Settings → Jobs." }
        return nil
    }

    /// One line for the routine form: the list, what's done and today's state.
    func status(_ r: MyRoutine, now: Date = .now) -> String {
        let s = Self.load(r.id)
        guard s.snapshotAt != nil else { return "No list yet: it's made once, the first time it runs (or press Rebuild list)." }
        let left = XUnfollow.remaining(s, keep: XUnfollow.keepSet(r.params?["keep"])).count
        let made = s.snapshotAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
        var t = "List: \(s.snapshot.count) accounts (made \(made)) · \(s.done.count) unfollowed · \(s.skipped.count) skipped · \(left) left"
        if let d = s.days[now.localDay] { t += " · today \(d.done) done" + (d.stopped.map { ", stopped: \($0)" } ?? "") }
        if let h = s.hold { t += " · HELD: \(h)" }
        return t
    }

    func resume(_ r: MyRoutine) {
        var s = Self.load(r.id)
        s.hold = nil
        s.days[Date.now.localDay]?.stopped = nil
        Self.save(s, r.id)
    }

    // MARK: The frozen list

    /// Makes the list once (Rebuild list replaces it). Done and skipped accounts are remembered across rebuilds.
    func rebuild(_ r: MyRoutine) async -> String {
        guard !busy else { return "X unfollows is busy; try again in a minute." }
        busy = true; defer { busy = false }
        switch await makeList(r) {
        case .failure(let why): return why.text
        case .success(let (list, source)):
            var s = Self.load(r.id)
            s.snapshot = list; s.snapshotAt = .now; s.snapshotSource = source
            Self.save(s, r.id)
            let left = XUnfollow.remaining(s, keep: XUnfollow.keepSet(r.params?["keep"])).count
            return "Made the list from \(source): \(list.count) accounts that don't follow you back (\(left) to do). It stays as it is until you rebuild it."
        }
    }

    struct Why: Error { let text: String }

    private func makeList(_ r: MyRoutine) async -> Result<([XUnfollow.Account], String), Why> {
        if !Self.fromSafari(r) {
            guard let d = try? Data(contentsOf: Self.file(r)), let any = try? JSONSerialization.jsonObject(with: d) else {
                return .failure(Why(text: "No unfollow list from Grok Bot yet (\(Self.file(r).path))."))
            }
            return .success((XUnfollow.snapshot(fromFile: any), "Grok Bot's file"))
        }
        guard XSafariReader.shared.enabled, let me else { return .failure(Why(text: "Switch on Read via your Safari login and enter your handle (Settings → General → X numbers).")) }
        if let wait = Permissions.shared.deferIfNeeded([.safari]) { return .failure(Why(text: wait)) }
        let tab = SafariTab(path: "\(me)/following")
        guard await tab.open() else { return .failure(Why(text: "Couldn't use Safari. Allow Hmunmawi to control Safari (Settings → Permissions).")) }
        var best: [XUnfollow.Account]? = nil, lastCount = -1, still = 0
        for _ in 0..<60 {
            try? await Task.sleep(for: .seconds(2.5))
            guard let out = try? await tab.js(XUnfollow.followingScrollJS(handle: me)) else { continue }
            _ = try? await tab.tag()
            guard let all = XUnfollow.allFollowing(out) else { continue }
            if all == lastCount { still += 1; if still >= 4 { best = XUnfollow.snapshot(fromFollowing: out); break } } else { still = 0 }
            lastCount = all
            best = XUnfollow.snapshot(fromFollowing: out)
        }
        _ = await tab.close()
        guard let best else { return .failure(Why(text: "X didn't show your Following list. Are you signed in to x.com as @\(me) in Safari?")) }
        return .success((best, "your Following page"))
    }

    // MARK: A run (every 5 minutes; most runs only see it isn't time yet)

    func tick(_ r: MyRoutine, now: Date = .now) async -> Outcome {
        guard !busy else { return .init(ok: true, note: "Busy with another X unfollows step.", message: nil) }
        if let off = Self.switchedOff() { return .init(ok: true, note: off, message: nil) }
        guard let me else { return .init(ok: false, note: "Enter your X handle (Settings → General → X numbers).", message: nil) }
        var s = Self.load(r.id)
        if s.snapshotAt == nil {
            let note = await rebuild(r)
            return .init(ok: Self.load(r.id).snapshotAt != nil, note: note, message: nil)
        }
        let keep = XUnfollow.keepSet(r.params?["keep"]), perDay = XUnfollow.perDay(r.params?["per_day"])
        guard let win = XUnfollow.window(r.params?["window"]) else { return .init(ok: false, note: "The window must look like 10:00-20:00.", message: nil) }
        let cal = Calendar.current, midnight = cal.startOfDay(for: now)
        let start = midnight.addingTimeInterval(TimeInterval(win.start * 60)), end = midnight.addingTimeInterval(TimeInterval(win.end * 60))
        let day = now.localDay
        let previous = cal.date(byAdding: .day, value: -1, to: now)?.localDay ?? ""
        // The day's one summary, after the window closes.
        if now >= end, now < end.addingTimeInterval(3 * 3600), let d = s.days[day], !d.summarySent, d.done + d.skipped + d.failed > 0 {
            s.days[day]?.summarySent = true
            Self.save(s, r.id)
            return .init(ok: true, note: "Sent today's summary.", message: XUnfollow.summary(d, left: XUnfollow.remaining(s, keep: keep).count))
        }
        if let h = s.hold { return .init(ok: true, note: "Held: \(h). Press Resume in the routine to start again.", message: nil) }
        if XUnfollow.remaining(s, keep: keep).isEmpty { return .init(ok: true, note: "The list is finished. Rebuild it to start a new one.", message: nil) }
        if let why = s.days[day]?.stopped { return .init(ok: true, note: "Stopped for today: \(why).", message: nil) }
        guard now >= start, now < end else { return .init(ok: true, note: "Outside today's window.", message: nil) }
        var rng = SystemRandomNumberGenerator()
        guard let due = s.days[day]?.nextDue else {
            var d = s.days[day] ?? .init()
            d.nextDue = max(now, start).addingTimeInterval(Double.random(in: 0...1200, using: &rng))
            s.days[day] = d; Self.save(s, r.id)
            return .init(ok: true, note: "First unfollow today planned for \(d.nextDue!.formatted(date: .omitted, time: .shortened)).", message: nil)
        }
        guard now >= due else { return .init(ok: true, note: "Next one at \(due.formatted(date: .omitted, time: .shortened)).", message: nil) }
        if let last = s.lastDone, now.timeIntervalSince(last) < XUnfollow.minGap { return .init(ok: true, note: "Waiting for the 10-minute gap.", message: nil) }
        if let wait = Permissions.shared.deferIfNeeded([.safari]) { return .init(ok: true, note: wait, message: nil) }

        busy = true; defer { busy = false }
        var opens = 0
        while opens < XUnfollow.opensPerRun {
            let todo = XUnfollow.remaining(s, keep: keep)
            guard let a = todo.first else { Self.save(s, r.id); return .init(ok: true, note: "The list is finished.", message: nil) }
            let d0 = s.days[day] ?? .init()
            if d0.done >= perDay || d0.opened >= perDay * 2 {
                Self.save(s, r.id)
                return .init(ok: true, note: "Today's number is reached (\(d0.done) done).", message: nil)
            }
            s.days[day, default: .init()].opened += 1; opens += 1
            Self.save(s, r.id)
            let (result, why) = await process(a, me: me, dry: false)
            if result == .safety {
                let msg = XUnfollow.stop(&s, day: day, previousDay: previous, reason: why, left: todo.count)
                Self.save(s, r.id)
                return .init(ok: true, note: "Stopped for today: \(why).", message: msg)
            }
            XUnfollow.record(&s, day: day, account: a, result: result, note: why, at: .now)
            if s.failStreak.count >= XUnfollow.systemicFailures {
                let msg = XUnfollow.stop(&s, day: day, previousDay: previous,
                                         reason: "\(s.failStreak.count) different accounts failed in a row (last: @\(a.handle), \(why))",
                                         left: XUnfollow.remaining(s, keep: keep).count)
                Self.save(s, r.id)
                return .init(ok: true, note: "Stopped for today: accounts kept failing.", message: msg)
            }
            switch result {
            case .unfollowed:
                let done = s.days[day]?.done ?? 0
                s.days[day]?.nextDue = Date.now.addingTimeInterval(XUnfollow.nextGap(secondsLeftInWindow: end.timeIntervalSinceNow, doneToday: done, perDay: perDay, using: &rng))
                Self.save(s, r.id)
                return .init(ok: true, note: "Unfollowed @\(a.handle) (\(done) today).", message: nil)
            case .fail:
                s.days[day]?.nextDue = Date.now.addingTimeInterval(XUnfollow.minGap)
                Self.save(s, r.id)
                return .init(ok: true, note: "@\(a.handle): \(why); tried again later.", message: nil)
            default:
                Self.save(s, r.id)
                try? await Task.sleep(for: .seconds(Double.random(in: 30...75, using: &rng)))   // skipped: the next profile a little later
            }
        }
        s.days[day]?.nextDue = Date.now.addingTimeInterval(Double.random(in: 300...600, using: &rng))
        Self.save(s, r.id)
        return .init(ok: true, note: "Skipped \(opens) accounts; carries on in a few minutes.", message: nil)
    }

    // MARK: Try out (nothing is clicked, nothing is saved)

    /// Opens the next `count` profiles and checks each exactly as a real run would, without clicking. Works before
    /// the routine is saved (the list is then made in memory only).
    func tryOut(_ r: MyRoutine, count: Int = 3) async -> String {
        guard !busy else { return "X unfollows is busy; try again in a minute." }
        guard let me else { return "Enter your X handle (Settings → General → X numbers)." }
        if let wait = Permissions.shared.deferIfNeeded([.safari]) { return wait }
        var s = Self.load(r.id)
        if s.snapshotAt == nil {
            busy = true
            let made = await makeList(r)
            busy = false
            switch made {
            case .failure(let why): return why.text
            case .success(let (list, _)): s.snapshot = list
            }
        }
        busy = true; defer { busy = false }
        let todo = XUnfollow.remaining(s, keep: XUnfollow.keepSet(r.params?["keep"])).prefix(min(max(count, 1), 5))
        guard !todo.isEmpty else { return "Try-out: nothing left on the list." }
        var lines: [String] = []
        for (i, a) in todo.enumerated() {
            if i > 0 { try? await Task.sleep(for: .seconds(Double.random(in: 8...15))) }
            let (result, why) = await process(a, me: me, dry: true)
            let mark = switch result { case .checked: "✓ would unfollow"; case .skip: "– would skip"; case .safety: "■ would stop"; default: "! failed" }
            lines.append("\(mark) @\(a.handle): \(why)")
            if result == .safety { break }
        }
        return "Try-out (nothing clicked, nothing saved):\n" + lines.joined(separator: "\n")
    }

    // MARK: One account

    private func process(_ a: XUnfollow.Account, me: String, dry: Bool) async -> (XUnfollow.Result, String) {
        let tab = SafariTab(path: a.handle)
        guard await tab.open() else { return (.fail, "could not open a Safari tab") }
        let out = await verifyAndClick(a, me: me, tab: tab, dry: dry)
        if !(await tab.close()) {
            try? await Task.sleep(for: .seconds(2))
            _ = await tab.close()
        }
        return out
    }

    private func probe(_ tab: SafariTab, _ a: XUnfollow.Account) async throws -> XUnfollow.Page {
        XUnfollow.Page(json: try await tab.js(XUnfollow.probeJS(a))) ?? .init()
    }

    private func verifyAndClick(_ a: XUnfollow.Account, me: String, tab: SafariTab, dry: Bool) async -> (XUnfollow.Result, String) {
        do {
            var page = XUnfollow.Page()
            let deadline = Date.now.addingTimeInterval(45)
            while Date.now < deadline {
                try await Task.sleep(for: .seconds(3))
                do {
                    if !tab.marked { _ = try await tab.tag() }
                    page = try await probe(tab, a)
                } catch SafariTab.Failure.noTab { throw SafariTab.Failure.noTab } catch { continue }
                if page.settled, page.ready {
                    try await Task.sleep(for: .seconds(2.5))   // let the "Follows you" badge and toasts appear, then read again
                    page = try await probe(tab, a)
                    break
                }
            }
            let path: XUnfollow.ClickPath
            switch XUnfollow.classify(page, account: a, me: me) {
            case .safety(let why): return (.safety, why)
            case .skip(let why): return (.skip, why)
            case .fail(let why): return (.fail, why)
            case .following(let p): path = p
            }
            guard tab.marked else { return (.fail, "could not tag its tab") }
            if dry { return (.checked, "you follow them, no \"Follows you\" badge") }
            if path == .following {
                guard try await tab.js(XUnfollow.clickFollowingJS(a, pageID: page.pageID)) == "clicked" else { return (.fail, "Following button not found") }
            } else {
                guard try await tab.js(XUnfollow.ariaClickJS(a)) == "clicked" else { return (.fail, "Unfollow icon not found") }
                var opened = false
                for _ in 0..<8 {
                    try await Task.sleep(for: .seconds(0.5))
                    if ["menu", "sheet"].contains(try await tab.js(XUnfollow.ariaMenuJS(a))) { opened = true; break }
                }
                guard opened else { return (.fail, "Unfollow icon clicked but its menu did not open") }
            }
            var confirmed = ""
            for _ in 0..<10 {
                try await Task.sleep(for: .seconds(1.5))
                if confirmed.isEmpty { confirmed = try await tab.js(XUnfollow.confirmJS) }
                let after = try await probe(tab, a)
                if after.trouble, case .safety(let why) = XUnfollow.classify(after, account: a, me: me) { return (.safety, why + " after clicking Unfollow") }
                if XUnfollow.unfollowed(after) { return (.unfollowed, "button now says Follow") }
                if confirmed == "ok" { break }
            }
            for _ in 0..<8 {
                try await Task.sleep(for: .seconds(2))
                if XUnfollow.unfollowed(try await probe(tab, a)) { return (.unfollowed, "button now says Follow") }
            }
            return (.fail, confirmed.isEmpty ? "the Unfollow confirmation did not appear" : "clicked Unfollow but the button did not change to Follow")
        } catch SafariTab.Failure.noTab {
            return (.safety, "lost its Safari tab")
        } catch {
            return (.fail, "Safari error: \(error)")
        }
    }
}

extension XUnfollow {
    /// How many followed accounts the Following page has loaded so far (to know when scrolling stops adding more).
    static func allFollowing(_ json: String) -> Int? {
        guard let d = json.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let users = o["users"] as? [Any] else { return nil }
        return users.count
    }
}

/// Exactly one new background Safari tab for one x.com page: opened once (never retried), found again only among
/// tabs showing that page and carrying our tag, closed at the end. Through /usr/bin/osascript, so macOS asks about
/// Hmunmawi controlling Safari once, as for the X numbers read.
@MainActor
final class SafariTab {
    enum Failure: Error { case noTab, script(String) }
    let path: String, url: String, mark: String
    private var windowID: Int?, index: Int?
    private(set) var marked = false

    init(path: String) {
        self.path = path
        url = "https://x.com/" + path
        mark = "hm-uf-\(Int(Date.now.timeIntervalSince1970))-\(Int.random(in: 1000...9999))"
    }

    nonisolated static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    func open() async -> Bool {
        guard url.wholeMatch(of: /https:\/\/x\.com\/[A-Za-z0-9_]{1,15}(\/following)?/) != nil else { return false }
        let script = """
        tell application "Safari"
          if (count of windows) = 0 then make new document
          set w to window 1
          set wid to id of w
          set n to count of tabs of w
          make new tab at end of tabs of w with properties {URL:\(Self.quoted(url))}
          return (wid as text) & " " & (n as text)
        end tell
        """
        guard case .success(let out) = await Self.run(script, timeout: 30) else { return false }
        let parts = out.split(separator: " ").compactMap { Int($0) }
        guard parts.count == 2 else { return false }
        windowID = parts[0]; index = parts[1] + 1
        return true
    }

    /// AppleScript that sets `t` to our tab, or returns "__NOTAB__".
    private var find: String {
        let page = Self.quoted("x.com/" + path)
        if marked {
            return """
            set t to missing value
              repeat with x in (tabs of w)
                if (URL of x) contains \(page) then
                  if ((do JavaScript "window.name" in x) as text) is \(Self.quoted(mark)) then
                    set t to x
                    exit repeat
                  end if
                end if
              end repeat
              if t is missing value then return "__NOTAB__"
            """
        }
        return """
        if (count of tabs of w) < \(index ?? 0) then return "__NOTAB__"
          set t to tab \(index ?? 0) of w
          if (URL of t) does not contain \(page) then return "__NOTAB__"
        """
    }

    func js(_ code: String) async throws -> String {
        guard let windowID else { throw Failure.noTab }
        let script = """
        tell application "Safari"
          try
            set w to window id \(windowID)
          on error
            return "__NOTAB__"
          end try
          \(find)
          return (do JavaScript \(Self.quoted(code)) in t) as text
        end tell
        """
        switch await Self.run(script, timeout: 45) {
        case .success(let out): if out == "__NOTAB__" { throw Failure.noTab }; return out
        case .failure(let e): throw e
        }
    }

    /// Tags the tab once it shows the page (window.name survives X's in-page navigation).
    func tag() async throws -> Bool {
        if marked { return true }
        let got = try await js("(function(){if(!window.name){window.name=\(XUnfollow.jsString(mark));}return window.name;})()")
        if got == mark { marked = true }
        return marked
    }

    func close() async -> Bool {
        guard let windowID else { return true }
        let body = marked ? find + "\n  close t\n  return \"closed\"" : """
        if (count of tabs of w) is not \(index ?? 0) then return "__NOTAB__"
          set t to tab \(index ?? 0) of w
          if (URL of t) does not contain \(Self.quoted("x.com/" + path)) and (URL of t) is not "" and (URL of t) does not start with "about:" then return "__NOTAB__"
          close t
          return "closed"
        """
        let script = """
        tell application "Safari"
          try
            set w to window id \(windowID)
          on error
            return "__NOTAB__"
          end try
          \(body)
        end tell
        """
        if case .success(let out) = await Self.run(script, timeout: 30) { return out == "closed" }
        return false
    }

    nonisolated static func run(_ script: String, timeout: Int) async -> Result<String, Failure> {
        await Task.detached { () -> Result<String, Failure> in
            let p = Process(), out = Pipe(), err = Pipe(), input = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-"]
            p.standardInput = input; p.standardOutput = out; p.standardError = err
            guard (try? p.run()) != nil else { return .failure(.script("osascript did not start")) }
            try? input.fileHandleForWriting.write(contentsOf: Data(script.utf8)); try? input.fileHandleForWriting.close()
            let killer = Task.detached { try? await Task.sleep(for: .seconds(timeout)); if p.isRunning { p.terminate() } }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit(); killer.cancel()
            guard p.terminationStatus == 0 else {
                return .failure(.script(String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).prefix(200).description))
            }
            return .success(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }.value
    }
}
