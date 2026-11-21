import Foundation
import Testing
@testable import HmunmawiApp

@Suite struct MacJobRoutineTests {
    @Test func settingsFileLines() {
        let e = ScriptRunner.envFile("# comment\nexport TOKEN=\"abc def\"\nNAME='x'\nPLAIN=1=2\n1BAD=x\nbad key=y\n\nEMPTY=\n")
        #expect(e["TOKEN"] == "abc def")
        #expect(e["NAME"] == "x")
        #expect(e["PLAIN"] == "1=2")
        #expect(e["EMPTY"] == "")
        #expect(e["1BAD"] == nil && e["bad key"] == nil)
    }
    @Test func takeoverRemembersWhenItStarted() {
        let id = "test-\(UUID().uuidString)"
        let first = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(Routines.onSince(id, now: first) == first)
        #expect(Routines.onSince(id, now: first.addingTimeInterval(3600)) == first)   // later ticks keep the first sighting
        UserDefaults.standard.removeObject(forKey: "HMRoutineOnSince.\(id)")
    }
    @Test func readsLastExitAndShortName() {
        #expect(MacJobRoutine.lastExit("\tstate = not running\n\tlast exit code = 1\n") == 1)
        #expect(MacJobRoutine.lastExit("\tlast exit code = 0: (never exited)") == 0)
        #expect(MacJobRoutine.lastExit("\tstate = waiting") == nil)
        #expect(MacJobRoutine.shortName("com.example.mail-watch") == "mail-watch")
        #expect(MacJobRoutine.shortName("watch") == "watch")
    }
    @Test func onlyYourOwnJobsCount() {
        #expect(MacJobRoutine.isOwnJob("com.example.mail-watch", prefixes: "com.example., org.me."))
        #expect(!MacJobRoutine.isOwnJob("com.vendor.updater", prefixes: "com.example."))
        #expect(!MacJobRoutine.isOwnJob("com.apple.Safari.History", prefixes: "com."))   // never Apple's, whatever the prefixes
        #expect(!MacJobRoutine.isOwnJob("com.example.x", prefixes: "co, ,"))             // prefixes under 3 characters are ignored
    }
    @Test func onlyRealLaunchAgentLabelsAreAccepted() {
        #expect(MacJobRoutine.plist("../../etc/passwd") == nil)
        #expect(MacJobRoutine.plist("a b") == nil)
        #expect(MacJobRoutine.plist("io.example.does-not-exist-\(UUID().uuidString.prefix(6))") == nil)
    }
    @Test func scheduleKeysCoverLaunchdTimers() {
        for k in ["StartInterval", "StartCalendarInterval", "RunAtLoad", "WatchPaths"] { #expect(MacJobRoutine.scheduleKeys.contains(k)) }
        #expect(!MacJobRoutine.scheduleKeys.contains("ProgramArguments"))
    }
}
