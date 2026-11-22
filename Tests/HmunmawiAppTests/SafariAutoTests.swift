import Foundation
import Testing
@testable import HmunmawiApp

/// SafariAuto: one lock, tagged tabs found by tag (never by position), leftovers swept (no Safari needed).
@Suite struct SafariAutoTests {
    @Test func tagsCarryOwnerJobAndTime() {
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        let tag = SafariAuto.newTag(job: "zoho mail!", now: now)
        #expect(tag.hasPrefix("hm-auto:app:zohomail:1795000000:"))
        #expect(SafariAuto.tagAge(tag, now: now.addingTimeInterval(30)) == 30)
        #expect(SafariAuto.tagAge("something-else") == nil)
    }

    @Test func onlyOldOrLegacyTagsAreLeftovers() {
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        #expect(SafariAuto.isLeftover("hmwatch", now: now))
        #expect(SafariAuto.isLeftover("hm-uf-1795000000-1234", now: now))
        #expect(SafariAuto.isLeftover("hm-auto:hub:x_unfollow:1794999700:1111", now: now))      // five minutes old
        #expect(!SafariAuto.isLeftover("hm-auto:hub:x_unfollow:1794999980:1111", now: now))     // a live session
        #expect(!SafariAuto.isLeftover("the-sites-own-name", now: now))                          // never your pages
        #expect(!SafariAuto.isLeftover("", now: now))
    }

    @Test func onlyPlainHttpsAddressesOpen() {
        #expect(SafariAuto.isPlainHTTPS("https://x.com/someone"))
        #expect(SafariAuto.isPlainHTTPS("https://mail.zoho.in/zm/#mail/views/all"))
        for bad in ["http://x.com/a", "https://x.com/a b", "https://x.com/\"; do shell script", "javascript:alert(1)", "https://x.com/a\\b"] {
            #expect(!SafariAuto.isPlainHTTPS(bad), "\(bad)")
        }
        #expect(SafariAuto.host(of: "https://mail.zoho.in/zm/#x") == "mail.zoho.in")
    }

    @Test func theLockKeepsASecondJobOutUntilTheFirstIsDone() async throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "safari-lock-\(UUID().uuidString).lock")
        defer { try? FileManager.default.removeItem(at: path) }
        let a = SafariAuto.Lock(path: path), b = SafariAuto.Lock(path: path)
        try await a.acquire(timeout: 1)
        await #expect(throws: SafariAuto.Failure.busy) { try await b.acquire(timeout: 0.3, poll: 0.05) }
        a.release()
        try await b.acquire(timeout: 1)
        b.release()
    }

    @Test func aLockIsFreedWhenItsOwnerGoesAway() async throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "safari-lock-\(UUID().uuidString).lock")
        defer { try? FileManager.default.removeItem(at: path) }
        do { let a = SafariAuto.Lock(path: path); try await a.acquire(timeout: 1) }       // dropped without release()
        let b = SafariAuto.Lock(path: path)
        try await b.acquire(timeout: 1)
        b.release()
    }

    @Test func tabsAreFoundByTagNeverByPositionAndCloseOnTheErrorPath() {
        // The tab is only ever looked up by its tag; the open script closes its own tab when anything goes wrong.
        for script in [SafariAuto.runScript, SafariAuto.closeScript] {
            #expect(script.contains("window.name") && script.contains("findTab"))
            #expect(!script.contains("last tab") && !script.contains("front") && !script.contains("tab idx"))
        }
        #expect(SafariAuto.openScript.contains("on error errMsg") && SafariAuto.openScript.contains("close t"))
        #expect(SafariAuto.openScript.contains("window.name='\" & tag"))
        // Nothing here touches pages outside the allowed hosts: the sweep lists only tabs on them.
        #expect(SafariAuto.sweepHosts.contains("x.com") && !SafariAuto.sweepHosts.contains("github.com"))
    }
}
