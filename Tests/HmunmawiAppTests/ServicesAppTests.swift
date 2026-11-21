import Foundation
import HmunmawiCore
import Testing
@testable import HmunmawiApp

@Suite struct ReplyIdeasFiltersTests {
    static let url = "https://x.com/example/status/2121610856794411128"

    @Test func avoidAndWordingSkipATarget() {
        let t = ReplyIdeas.Target(url: Self.url, author: "example", tweet: "Shipping SwiftUI widgets", reply: "Our app is clinically proven to help with widgets")
        let soon = ReplyIdeas.postedAt(Self.url)!.addingTimeInterval(3600)
        #expect(ReplyIdeas.problem(t, topics: ["swiftui"], avoid: ["widgets"], versions: [:], now: soon)?.contains("avoid") == true)
        let rules = WordingRules(rules: [WordingRules.Rule(text: "clinically proven", why: "no study")])
        #expect(ReplyIdeas.problem(t, topics: ["swiftui"], wording: rules, versions: [:], now: soon)?.contains("never say") == true)
        #expect(ReplyIdeas.problem(t, topics: ["swift"], versions: [:], now: soon) == nil)   // a topic may start a longer word
    }
}

@Suite struct WordingLinesTests {
    @Test func linesRoundTrip() {
        let rules = Wording.parseLines("clinically proven | no study\n\n  best app ever  \nre:\\bno servers?\\b | absolute claim")
        #expect(rules.map(\.text) == ["clinically proven", "best app ever", "re:\\bno servers?\\b"])
        #expect(rules[0].why == "no study" && rules[1].why == nil)
        #expect(Wording.parseLines(Wording.lines(rules)) == rules)
    }
}

@Suite struct KeepAwakeTests {
    @Test func holdsOnlyWhenItShould() {
        #expect(!KeepAwake.shouldHold(.off, onAC: true))
        #expect(KeepAwake.shouldHold(.always, onAC: false))
        #expect(KeepAwake.shouldHold(.pluggedIn, onAC: true) && !KeepAwake.shouldHold(.pluggedIn, onAC: false))
        #expect(KeepAwake.Mode(rawValue: "plugged-in") == .pluggedIn)
        #expect(AgentSetting.keepAwake.validate("Always") == "always" && AgentSetting.keepAwake.validate("sometimes") == nil)
        #expect(AgentSetting.keepAwake.action == .jobs)
    }
}

@Suite struct NewRoutineKindsTests {
    @Test func kindsAndTitles() {
        for k in [RoutineKind.serviceWatch, .heartbeat, .linkCheck, .pythonCheck] {
            #expect(!k.builtIn && !k.title.isEmpty)
            #expect(JobSwitchesForm.ownJobKinds.contains(k))
        }
        #expect(RoutineKind(rawValue: "service-watch") == .serviceWatch && RoutineKind(rawValue: "python-check") == .pythonCheck)
    }

    @MainActor @Test func agentArgumentsAreChecked() {
        let r = Routines.shared
        let base = ["title": "Beat", "does": "heartbeat"]
        #expect(r.agentChange("routine-add", base.merging(["dsn": "not a dsn"]) { $1 }, dryRun: true)["ok"] as? Bool == false)
        #expect(r.agentChange("routine-add", base.merging(["dsn": "https://0123456789abcdef0123456789abcdef@o1.ingest.sentry.io/2", "slug": "mac-alive", "every": "15"]) { $1 }, dryRun: true)["ok"] as? Bool == true)
        #expect(r.agentChange("routine-add", base.merging(["slug": "Bad Slug"]) { $1 }, dryRun: true)["ok"] as? Bool == false)
        // Automatic Python repair is the owner's switch alone.
        #expect(r.agentChange("routine-add", ["title": "Py", "does": "python-check", "repair": "auto"], dryRun: true)["ok"] as? Bool == false)
        #expect(r.agentChange("routine-add", ["title": "Py", "does": "python-check", "repair": "ask"], dryRun: true)["ok"] as? Bool == true)
        #expect(r.agentChange("routine-add", ["title": "Links", "does": "link-check", "url": "https://example.com", "pages": "500"], dryRun: true)["ok"] as? Bool == false)
        #expect(r.agentChange("routine-add", ["title": "Svc", "does": "service-watch", "behind": "1"], dryRun: true)["ok"] as? Bool == false)
        #expect(r.agentChange("routine-add", ["title": "Drafts", "does": "post-drafts", "avoid": "crypto, politics"], dryRun: true)["ok"] as? Bool == true)
    }

    @MainActor @Test func draftRulesTellTheAI() {
        var r = MyRoutine(); r.params = ["topics": "SwiftUI, widgets", "avoid": "crypto"]
        let text = Routines.draftRules(r)
        #expect(text.contains("swiftui, widgets") && text.contains("crypto"))
    }
}

@Suite struct PythonRepairGuardTests {
    @Test func agentEditDropsAutomaticRepair() {
        #expect(Routines.agentEdited(["repair": "auto", "folders": "/w/.venv"])["repair"] == "ask")
        #expect(Routines.agentEdited(["repair": "ask"])["repair"] == "ask")
        #expect(Routines.agentEdited(["url": "https://example.com"])["repair"] == nil)
    }

    @MainActor @Test func foldersMustBeVenvs() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hm-venv-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("bin"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = Routines.shared
        let args = ["title": "Py", "does": "python-check", "folders": dir.path]
        #expect(r.agentChange("routine-add", args, dryRun: true)["ok"] as? Bool == false)   // bin/ only: not a venv
        FileManager.default.createFile(atPath: dir.appendingPathComponent("pyvenv.cfg").path, contents: Data("home = /x\n".utf8))
        #expect(r.agentChange("routine-add", args, dryRun: true)["ok"] as? Bool == true)
    }
}

@Suite struct PythonVenvScanTests {
    @Test func runToolReportsExitAndTimeout() async {
        let ok = await Routines.runTool(["/bin/echo", "hi"], timeout: 5)
        #expect(ok.code == 0 && ok.output.contains("hi"))
        let slow = await Routines.runTool(["/bin/sleep", "5"], timeout: 0.5)
        #expect(slow.code == -2)
    }
}

@Suite struct WebGuardTests {
    @Test func onlyPublicWebAddresses() {
        #expect(WebGuard.allowed(URL(string: "https://example.com/a")!))
        #expect(WebGuard.allowed(URL(string: "http://example.com/a")!))
        #expect(!WebGuard.allowed(URL(string: "http://127.0.0.1:8080/")!))
        #expect(!WebGuard.allowed(URL(string: "http://192.168.1.10/admin")!))
        #expect(!WebGuard.allowed(URL(string: "https://printer.local/")!))
        #expect(!WebGuard.allowed(URL(string: "file:///etc/hosts")!))
        #expect(!WebGuard.allowed(URL(string: "https://user@example.com/")!))
    }

    @Test func internalAddressesAreNeverFetched() async {
        let r = await Routines.fetch(URL(string: "http://127.0.0.1:9/")!)
        #expect(r.status == nil && r.body == nil && !r.noSuchHost)
    }

    @Test func aRedirectToThisMacIsNotFollowed() async {
        var req = URLRequest(url: URL(string: "https://example.com/")!)
        req.url = URL(string: "http://10.0.0.1/")
        let next = await WebGuard.shared.urlSession(WebGuard.session, task: WebGuard.session.dataTask(with: URL(string: "https://example.com/")!),
                                                    willPerformHTTPRedirection: HTTPURLResponse(url: URL(string: "https://example.com/")!, statusCode: 302, httpVersion: nil, headerFields: nil)!,
                                                    newRequest: req)
        #expect(next == nil)
        req.url = URL(string: "https://www.example.com/")
        let ok = await WebGuard.shared.urlSession(WebGuard.session, task: WebGuard.session.dataTask(with: URL(string: "https://example.com/")!),
                                                  willPerformHTTPRedirection: HTTPURLResponse(url: URL(string: "https://example.com/")!, statusCode: 302, httpVersion: nil, headerFields: nil)!,
                                                  newRequest: req)
        #expect(ok?.url?.host == "www.example.com")
    }
}
