import Foundation
import Darwin

/// The one way Hmunmawi uses a Safari tab on its own (X unfollows and numbers, the Zoho reader, Payouts, Offer codes).
///
/// 1. A job that needs a page opens its OWN new tab, does its work and closes it, whatever happened. It never depends
///    on a tab already being open.
/// 2. Every tab Hmunmawi opens is closed when the job ends (also on errors), so your Safari never fills up. Your own
///    tabs are never closed, and are only asked for their tag name on a few known hosts.
///
/// How: ONE lock file (`safari.lock` in Hmunmawi's folder, the same file the owner's scripts use) is held while a job has
/// a tab open, so two jobs never change Safari's tab list at the same moment. The tab is opened, waited for and tagged
/// (`window.name = "hm-auto:app:<job>:<epoch>:<rand>"`) inside ONE AppleScript call that holds the tab reference and
/// closes it if the page never loads; afterwards the tab is found by its tag, never by its position. At the start of
/// every session, tabs that carry one of our tags (or an older mark) and are over two minutes old are closed: leftovers
/// of a run that was killed.
enum SafariAuto {
    static let tagPrefix = "hm-auto:"
    static let legacyMarks = ["hmwatch", "etm-uf-", "hm-uf-", "etm-auto"]
    /// Pages automation opens. A sweep only looks at tabs on these hosts.
    static let sweepHosts = ["x.com", "mail.zoho.", "platform.claude.com", "accounts.google.com", "appstoreconnect.apple.com"]
    static let leftoverAfter: TimeInterval = 120

    enum Failure: Error, Equatable { case busy, noTab, script(String) }

    // MARK: Tags (pure)

    static func newTag(job: String, now: Date = .now) -> String {
        let clean = String(job.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }.prefix(24))
        return "\(tagPrefix)app:\(clean.isEmpty ? "job" : clean):\(Int(now.timeIntervalSince1970)):\(Int.random(in: 1000...9999))"
    }

    /// Seconds since the tag was made, nil when it has no time.
    static func tagAge(_ name: String, now: Date = .now) -> TimeInterval? {
        let parts = name.split(separator: ":", omittingEmptySubsequences: false)
        guard name.hasPrefix(tagPrefix), parts.count >= 5, let t = TimeInterval(parts[parts.count - 2]) else { return nil }
        return now.timeIntervalSince1970 - t
    }

    /// An old tag of ours or a legacy mark: safe to close. A fresh tag belongs to a session that is still working.
    static func isLeftover(_ name: String, now: Date = .now) -> Bool {
        if legacyMarks.contains(where: { name == $0 || name.hasPrefix($0) }) { return true }
        guard name.hasPrefix(tagPrefix) else { return false }
        guard let age = tagAge(name, now: now) else { return true }
        return age >= leftoverAfter
    }

    static func isPlainHTTPS(_ url: String) -> Bool {
        url.wholeMatch(of: /https:\/\/[A-Za-z0-9._\-]+(\/[^\s"'\\]*)?/) != nil
    }

    static func host(of url: String) -> String {
        url.firstMatch(of: /https?:\/\/([^\/?#]+)/).map { String($0.1) } ?? url
    }

    // MARK: The lock

    /// flock on one shared file; released when the process ends, so a crash never leaves Safari blocked.
    final class Lock: @unchecked Sendable {
        private var fd: Int32 = -1
        let path: URL
        init(path: URL = SafariAuto.lockURL) { self.path = path }

        func acquire(timeout: TimeInterval = 240, poll: Double = 1) async throws {
            try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            let f = Darwin.open(path.path, O_CREAT | O_RDWR, 0o600)
            guard f >= 0 else { throw Failure.script("Couldn't open the Safari lock file.") }
            let end = Date.now.addingTimeInterval(timeout)
            while flock(f, LOCK_EX | LOCK_NB) != 0 {
                if Date.now >= end { _ = Darwin.close(f); throw Failure.busy }
                try? await Task.sleep(for: .seconds(poll))
            }
            fd = f
        }

        func release() {
            guard fd >= 0 else { return }
            flock(fd, LOCK_UN)
            _ = Darwin.close(fd)
            fd = -1
        }

        deinit { release() }
    }

    static var lockURL: URL { URL.hmSupport.appending(path: "safari.lock") }

    // MARK: AppleScript (the same pieces as the owner's scripts/safari_tabs.py)

    private static let find = #"""
    on findTab(tag, needle)
      tell application "Safari"
        repeat with w in windows
          repeat with t in tabs of w
            try
              if (URL of t) contains needle then
                if ((do JavaScript "window.name" in t) as text) is tag then return t
              end if
            end try
          end repeat
        end repeat
      end tell
      return missing value
    end findTab
    """#

    /// argv: url, tag, needle, seconds. Open, wait, tag; closes the tab itself when anything goes wrong.
    static let openScript = #"""
    on run argv
      set theURL to item 1 of argv
      set tag to item 2 of argv
      set needle to item 3 of argv
      set secs to (item 4 of argv) as integer
      tell application "Safari"
        if (count of windows) is 0 then
          make new document with properties {URL:theURL}
          set w to window 1
          set t to current tab of w
        else
          set w to window 1
          set t to make new tab at end of tabs of w with properties {URL:theURL}
        end if
        set wid to id of w
        set n to count of tabs of w
        try
          set ok to false
          repeat with i from 1 to secs
            delay 1
            try
              if (URL of t) contains needle then
                if ((do JavaScript "document.readyState" in t) as text) is "complete" then
                  set ok to true
                  exit repeat
                end if
              end if
            end try
          end repeat
          if not ok then
            set u to ""
            try
              set u to URL of t
            end try
            if u does not contain needle then error "the page did not open (" & u & ")"
          end if
          do JavaScript ("window.name='" & tag & "'") in t
          if ((do JavaScript "window.name" in t) as text) is not tag then error "the tab could not be tagged"
          return (wid as text) & " " & (n as text)
        on error errMsg
          try
            close t
          end try
          error errMsg
        end try
      end tell
    end run
    """#

    static let runScript = find + #"""

    on run argv
      set t to my findTab(item 1 of argv, item 2 of argv)
      if t is missing value then return "__NOTAB__"
      tell application "Safari" to return (do JavaScript (item 3 of argv) in t) as text
    end run
    """#

    static let closeScript = find + #"""

    on run argv
      set t to my findTab(item 1 of argv, item 2 of argv)
      if t is missing value then return "__NOTAB__"
      tell application "Safari" to close t
      return "closed"
    end run
    """#

    /// Brings our tagged tab forward in Safari and activates Safari (used only when the user needs to sign in).
    static let revealScript = #"""
    on run argv
      set tag to item 1 of argv
      set needle to item 2 of argv
      tell application "Safari"
        activate
        repeat with w in windows
          repeat with t in tabs of w
            try
              if (URL of t) contains needle then
                if ((do JavaScript "window.name" in t) as text) is tag then
                  set current tab of w to t
                  set index of w to 1
                  return "shown"
                end if
              end if
            end try
          end repeat
        end repeat
      end tell
      return "__NOTAB__"
    end run
    """#

    /// Clears Hmunmawi's automation tag so an abandoned login tab stays open for the user without future auto-sweep.
    static let untagScript = find + #"""

    on run argv
      set t to my findTab(item 1 of argv, item 2 of argv)
      if t is missing value then return "__NOTAB__"
      tell application "Safari" to do JavaScript "window.name=''" in t
      return "untagged"
    end run
    """#

    /// argv: URL part, JavaScript. Runs it in an already-open tab of yours (read only, nothing else is touched);
    /// "__NONE__" when no tab shows that page.
    static let readExistingScript = #"""
    on run argv
      tell application "Safari"
        repeat with w in windows
          repeat with t in tabs of w
            try
              if (URL of t) contains (item 1 of argv) then return (do JavaScript (item 2 of argv) in t) as text
            end try
          end repeat
        end repeat
      end tell
      return "__NONE__"
    end run
    """#

    /// argv: hosts joined by "|". Lists "url<TAB>name" for tabs on our hosts that have a window name.
    static let listScript = #"""
    on run argv
      set AppleScript's text item delimiters to "|"
      set needleList to text items of (item 1 of argv)
      set AppleScript's text item delimiters to ""
      set out to ""
      tell application "Safari"
        repeat with w in windows
          repeat with t in tabs of w
            try
              set u to URL of t
              set match to false
              repeat with h in needleList
                if u contains (contents of h) then set match to true
              end repeat
              if match then
                set nm to (do JavaScript "window.name" in t) as text
                if nm is not "" and nm is not "missing value" then set out to out & u & tab & nm & linefeed
              end if
            end try
          end repeat
        end repeat
      end tell
      return out
    end run
    """#

    /// Runs AppleScript through /usr/bin/osascript (macOS asks about Hmunmawi controlling Safari once, as before).
    nonisolated static func run(_ script: String, args: [String] = [], timeout: Int) async -> Result<String, Failure> {
        await Task.detached { () -> Result<String, Failure> in
            let p = Process(), out = Pipe(), err = Pipe(), input = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-"] + args
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

    /// Closes tabs that carry an old tag of ours or an older mark. Returns how many.
    @discardableResult
    static func sweep(hosts: [String] = sweepHosts, now: Date = .now) async -> Int {
        guard case .success(let listing) = await run(listScript, args: [hosts.joined(separator: "|")], timeout: 45) else { return 0 }
        var closed = 0
        for line in listing.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, isLeftover(parts[1], now: now) else { continue }
            let needle = hosts.first { parts[0].contains($0) } ?? host(of: parts[0])
            if case .success("closed") = await run(closeScript, args: [parts[1], needle], timeout: 30) { closed += 1 }
        }
        return closed
    }

    // MARK: Tab and session

    final class Tab: @unchecked Sendable {
        let windowID: Int, index: Int, tag: String, needle: String
        private(set) var closed = false
        init(windowID: Int, index: Int, tag: String, needle: String) {
            self.windowID = windowID; self.index = index; self.tag = tag; self.needle = needle
        }

        func js(_ code: String, timeout: Int = 45) async throws -> String {
            switch await SafariAuto.run(SafariAuto.runScript, args: [tag, needle, code], timeout: timeout) {
            case .success(let out): if out == "__NOTAB__" { throw Failure.noTab }; return out
            case .failure(let e): throw e
            }
        }

        /// True when the tab is closed or was already gone. Never throws.
        func close() async -> Bool {
            if closed { return true }
            guard case .success(let out) = await SafariAuto.run(SafariAuto.closeScript, args: [tag, needle], timeout: 30) else { return false }
            closed = out == "closed" || out == "__NOTAB__"
            return closed
        }

        /// Brings the tab forward and activates Safari so the user can sign in interactively.
        @discardableResult
        func revealInSafari() async -> Bool {
            guard case .success("shown") = await SafariAuto.run(SafariAuto.revealScript, args: [tag, needle], timeout: 20) else { return false }
            return true
        }

        /// Clears the automation tag and leaves the tab open in Safari for the user.
        @discardableResult
        func releaseToUser() async -> Bool {
            closed = true
            guard case .success("untagged") = await SafariAuto.run(SafariAuto.untagScript, args: [tag, needle], timeout: 20) else { return false }
            return true
        }
    }

    /// `let s = Session(job:); try await s.enter(); defer ...; let tab = try await s.open(url:); ...; await s.exit()`.
    /// exit() closes every tab it opened and gives the lock back; call it on every path.
    final class Session: @unchecked Sendable {
        let job: String
        let lock: Lock
        private(set) var tabs: [Tab] = []
        init(job: String, lock: Lock = Lock()) { self.job = job; self.lock = lock }

        func enter(timeout: TimeInterval = 240) async throws {
            try await lock.acquire(timeout: timeout)
            await SafariAuto.sweep()
        }

        func open(url: String, needle: String? = nil, seconds: Int = 40) async throws -> Tab {
            guard SafariAuto.isPlainHTTPS(url) else { throw Failure.script("Not a plain https address.") }
            let needle = needle ?? SafariAuto.host(of: url)
            let tag = SafariAuto.newTag(job: job)
            switch await SafariAuto.run(SafariAuto.openScript, args: [url, tag, needle, String(seconds)], timeout: seconds + 40) {
            case .failure(let e): throw e
            case .success(let out):
                let p = out.split(separator: " ").compactMap { Int($0) }
                let tab = Tab(windowID: p.first ?? 0, index: p.count > 1 ? p[1] : 0, tag: tag, needle: needle)
                tabs.append(tab)
                return tab
            }
        }

        /// Leaves `tab` open in Safari (e.g. so the user can finish signing in) while `exit()` frees `safari.lock`.
        func handOffToUser(_ tab: Tab) async {
            _ = await tab.releaseToUser()
            tabs.removeAll { $0 === tab }
        }

        func exit() async {
            for t in tabs { _ = await t.close() }
            tabs = []
            lock.release()
        }
    }
}
