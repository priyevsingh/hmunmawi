import Foundation
import Testing
@testable import HmunmawiCore

@Suite struct TopicFilterTests {
    @Test func wholeWordsOnly() {
        #expect(TopicFilter.contains("New AI tools for apps", phrase: "ai"))
        #expect(!TopicFilter.contains("She said it twice", phrase: "ai"))
        #expect(TopicFilter.contains("The App Store's new rules", phrase: "app store"))
        #expect(TopicFilter.contains("Two apps shipped", phrase: "app"))
        #expect(!TopicFilter.contains("An application form", phrase: "app"))
        #expect(TopicFilter.contains("Learning C++ today", phrase: "c++"))
    }

    @Test func topicsAndAvoid() {
        let topics = TopicFilter.list("HealthKit, SwiftUI ,  indie apps,")
        #expect(topics == ["healthkit", "swiftui", "indie apps"])
        #expect(TopicFilter.problem("Shipping a SwiftUI widget today", topics: topics, avoid: []) == nil)
        #expect(TopicFilter.problem("Crypto is up again", topics: topics, avoid: []) == "off your topics")
        #expect(TopicFilter.problem("SwiftUI and crypto", topics: topics, avoid: ["crypto"])?.contains("avoid") == true)
        #expect(TopicFilter.problem("Anything at all", topics: [], avoid: []) == nil)
        #expect(TopicFilter.problem("My HealthKit sync broke", topics: ["health"], avoid: []) == nil)   // a topic may start a longer word
        #expect(TopicFilter.problem("She said so", topics: ["ai"], avoid: []) == "off your topics")
    }
}

@Suite struct WordingRulesTests {
    @Test func phrasesAndPatterns() throws {
        let json = #"{"never": ["best app ever", {"text": "clinically proven", "why": "no clinical study"}, {"text": "re:\\bno (cloud|servers?)\\b", "why": "absolute privacy claim"}, {"text": "re:([unclosed"}]}"#
        let rules = WordingRules.parse(Data(json.utf8))
        #expect(rules.rules.count == 3 && rules.problems.count == 1)
        #expect(rules.problem("This is clinically proven to help") == "uses “clinically proven”, which you never say (no clinical study)")
        #expect(rules.hits("Runs with No servers at all").first?.found == "No servers")
        #expect(rules.problem("The best app every day") == nil)   // whole words
        #expect(rules.problem("A calm, honest post") == nil)
    }

    @Test func encodeRoundTrips() {
        let rules = [WordingRules.Rule(text: "guaranteed", why: "can't promise"), WordingRules.Rule(text: "re:\\d+% better")]
        let back = WordingRules.parse(WordingRules.encode(rules))
        #expect(back.rules == rules)
    }

    @Test func missingOrBadFileIsNoRules() {
        #expect(WordingRules.load(URL(fileURLWithPath: "/nonexistent/wording-rules.json")).rules.isEmpty)
        #expect(WordingRules.parse(Data("[1,2]".utf8)).problems.count == 1)
    }
}

@Suite struct LinkCheckTests {
    @Test func sitemapAndLinks() {
        let xml = "<urlset><url><loc>https://example.com/</loc></url><url><loc> https://example.com/a?x=1&amp;y=2 </loc></url><url><loc>http://example.com/old</loc></url></urlset>"
        #expect(LinkCheck.sitemapLocations(xml) == ["https://example.com/", "https://example.com/a?x=1&y=2"])
        #expect(!LinkCheck.isSitemapIndex(xml) && LinkCheck.isSitemapIndex("<sitemapindex>"))
        let html = ##"<a href="/about">A</a> <a class=x href='https://other.example/p#top'>B</a> <a href=mailto:me@example.com>m</a> <a href="#x">x</a> <A HREF="https://www.example.com/c">c</A>"##
        let base = URL(string: "https://example.com/blog/")!
        let links = LinkCheck.links(in: html, base: base).map(\.absoluteString)
        #expect(links == ["https://example.com/about", "https://other.example/p", "https://www.example.com/c"])
        let out = LinkCheck.outside(LinkCheck.links(in: html, base: base), ownHosts: ["example.com"])
        #expect(out.map(\.absoluteString) == ["https://other.example/p"])
    }

    @Test func verdicts() {
        #expect(LinkCheck.verdict(status: 404) == .dead && LinkCheck.verdict(status: 410) == .dead)
        #expect(LinkCheck.verdict(status: 403) == .unknown && LinkCheck.verdict(status: 503) == .unknown && LinkCheck.verdict(status: nil) == .unknown)
        #expect(LinkCheck.verdict(status: 301) == .ok && LinkCheck.verdict(status: nil, noSuchHost: true) == .dead)
        #expect(LinkCheck.appStoreVerdict(lookupCount: 0, pageStatus: 404) == .dead)
        #expect(LinkCheck.appStoreVerdict(lookupCount: 0, pageStatus: 200) == .unknown)
        #expect(LinkCheck.appStoreVerdict(lookupCount: 1, pageStatus: nil) == .ok)
        let a = LinkCheck.appStoreID(URL(string: "https://apps.apple.com/gb/app/some-app/id1234567890?l=en")!)
        #expect(a?.id == "1234567890" && a?.country == "gb")
        #expect(LinkCheck.appStoreID(URL(string: "https://apps.apple.com/app/id12345678")!)?.country == "us")
        #expect(LinkCheck.appStoreID(URL(string: "https://example.com/id1234567")!) == nil)
    }

    @Test func deadOnlyAfterTwoRuns() {
        var s = LinkCheck.State()
        let dead: [String: (verdict: LinkCheck.Verdict, page: String, status: String)] = ["https://gone.example/": (.dead, "https://example.com/", "404")]
        var r = LinkCheck.fold(s, results: dead, day: "2026-11-01")
        #expect(r.newDead.isEmpty && r.state.suspects.count == 1)
        s = r.state
        r = LinkCheck.fold(s, results: ["https://gone.example/": (.unknown, "https://example.com/", "503")], day: "2026-11-08")
        #expect(r.newDead.isEmpty && r.state.suspects.count == 1)   // unknown neither proves nor clears
        r = LinkCheck.fold(r.state, results: dead, day: "2026-11-15")
        #expect(r.newDead == ["https://gone.example/"] && r.state.dead["https://gone.example/"]?.since == "2026-11-01")
        r = LinkCheck.fold(r.state, results: dead, day: "2026-11-22")
        #expect(r.newDead.isEmpty)   // told once
        r = LinkCheck.fold(r.state, results: ["https://gone.example/": (.ok, "https://example.com/", "200")], day: "2026-11-29")
        #expect(r.fixed == ["https://gone.example/"] && r.state.dead.isEmpty)
    }
}

@Suite struct OutreachCheckTests {
    let existing: [(outlet: String, where: String)] = [("Indie Weekly", "editor@indieweekly.example"), ("Apps Blog", "https://www.appsblog.example/submit"),
                                                     ("Gmail Person", "someone@gmail.com")]

    @Test func duplicatesByDomainEmailAndName() {
        #expect(OutreachCheck.duplicates(url: "https://appsblog.example/", email: nil, existing: existing) == ["Apps Blog"])
        #expect(OutreachCheck.duplicates(url: "https://indieweekly.example/", email: nil, existing: existing) == ["Indie Weekly"])
        #expect(OutreachCheck.duplicates(url: nil, email: "Editor <EDITOR@indieweekly.example>", existing: existing) == ["Indie Weekly"])
        #expect(OutreachCheck.duplicates(url: nil, email: "other@gmail.com", existing: existing).isEmpty)   // shared mail provider
        #expect(OutreachCheck.duplicates(url: "https://new.example", email: nil, outlet: "apps blog", existing: existing) == ["Apps Blog"])
        #expect(OutreachCheck.duplicates(url: "https://new.example", email: nil, existing: existing).isEmpty)
    }

    @Test func readsAPage() {
        let html = #"<html lang="en-GB"><body><a href="/contact-us">Contact</a> Write to tips@new.example or <img src="logo@2x.png"></body></html>"#
        let r = OutreachCheck.check(html: html, status: 200, finalURL: "https://new.example/", candidateURL: "https://new.example/", existing: existing)
        #expect(r.emails == ["tips@new.example"] && r.language == "en-GB" && r.contactPage == "https://new.example/contact-us")
        #expect(r.verdict == "ok" && r.summary.contains("tips@new.example"))
        let paid = OutreachCheck.check(html: "<p>Sponsored post: $99</p><form><input type=email></form>", status: 200, finalURL: nil,
                                       candidateURL: "https://paid.example", existing: existing)
        #expect(paid.contactForm && paid.verdict == "paid_only")
        #expect(OutreachCheck.check(html: "", status: 404, finalURL: nil, candidateURL: "https://x.example", existing: existing).verdict == "dead")
        #expect(OutreachCheck.check(html: "<p>hello</p>", status: 200, finalURL: nil, candidateURL: "https://x.example", existing: existing).verdict == "no_contact")
        #expect(OutreachCheck.check(html: "", status: 200, finalURL: nil, candidateURL: "https://appsblog.example", existing: existing).verdict == "already_pitched")
    }
}

@Suite struct ServiceWatchTests {
    @Test func sentryIssuesInPlainWords() {
        let payload = try! JSONValue.parse(#"{"issues": [{"id": "1", "title": "GET https://example.com failed", "project": "website", "category": "uptime"}, {"id": "2", "title": "Monitor failure: nightly-backup", "project": "mac-jobs", "category": "cron"}, {"id": "3", "title": "Fatal error: Index out of range", "project": "my-app", "category": "error", "count": 4}]}"#)
        let issues = SentryIssues.parse(payload)
        #expect(issues.map { SentryIssues.kind($0) } == [.websiteDown, .jobProblem, .crash])
        #expect(SentryIssues.opened(issues[0]).hasPrefix("⚠️ Website down"))
        #expect(SentryIssues.opened(issues[2]) == "🐞 New problem in my-app: Fatal error: Index out of range (4 times so far).")
        // First run: nothing told. Then only what's new or closed.
        #expect(SentryIssues.diff(previous: nil, now: issues).opened.isEmpty)
        let d = SentryIssues.diff(previous: ["1": "old title", "9": "gone"], now: issues)
        #expect(d.opened.map(\.id) == ["2", "3"] && d.closed.map(\.id) == ["9"])
        #expect(SentryIssues.closed(title: "x", kind: .websiteDown).hasPrefix("✅ Website back"))
    }

    @Test func deployStatus() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var s = DeployWatch.Snapshot(project: "site", branch: "main", headSHA: "abc1234def", headAt: now.addingTimeInterval(-3600),
                                     productionSHA: "abc1234def", productionState: "READY")
        #expect(DeployWatch.status(s, now: now) == .ok)
        s.productionSHA = "0000000"
        #expect(DeployWatch.status(s, now: now) == .behind)              // no deploy for the head after the grace time
        #expect(DeployWatch.sentence(s, status: .behind)?.contains("abc1234") == true)
        s.headAt = now.addingTimeInterval(-120)
        #expect(DeployWatch.status(s, now: now) == .building)            // still inside the grace time
        s.headDeployState = "BUILDING"; s.headDeployAt = now.addingTimeInterval(-600)
        #expect(DeployWatch.status(s, now: now) == .building)
        s.headDeployAt = now.addingTimeInterval(-3600)
        #expect(DeployWatch.status(s, now: now) == .failed)              // stuck
        s.headDeployState = "ERROR"
        #expect(DeployWatch.status(s, now: now) == .failed)
        let noHead = DeployWatch.Snapshot(project: "site", productionState: "ERROR")
        #expect(DeployWatch.status(noHead, now: now) == .failed)
        #expect(DeployWatch.sentence(noHead, status: .ok) == nil)
        let p = try! JSONValue.parse(#"{"project": "site", "branch": "main", "head_sha": "abc", "head_at": 1800000000000, "production_sha": "abc", "production_state": "READY"}"#)
        #expect(DeployWatch.Snapshot(p)?.headAt == now)
    }

    @Test func heartbeatFromDSN() {
        let t = Heartbeat.parse(dsn: "https://0123456789abcdef0123456789abcdef@o12345.ingest.us.sentry.io/678")
        #expect(t == Heartbeat.Target(host: "o12345.ingest.us.sentry.io", projectID: "678", publicKey: "0123456789abcdef0123456789abcdef"))
        #expect(Heartbeat.url(t!, slug: "mac-alive")?.absoluteString == "https://o12345.ingest.us.sentry.io/api/678/cron/mac-alive/0123456789abcdef0123456789abcdef/")
        #expect(Heartbeat.url(t!, slug: "Bad Slug") == nil)
        #expect(Heartbeat.parse(dsn: "https://key@evil.example/1") == nil)
        #expect(Heartbeat.parse(dsn: "http://0123456789abcdef@o1.ingest.sentry.io/1") == nil)
        let body = Heartbeat.body(status: "ok", everyMinutes: 15, marginMinutes: 10, timezone: "Europe/London")
        let config = body["monitor_config"] as? [String: Any]
        #expect((config?["schedule"] as? [String: Any])?["unit"] as? String == "minute" && config?["checkin_margin"] as? Int == 10)
    }
}

@Suite struct PythonEnvTests {
    @Test func findsAndJudgesVenvs() {
        let files: Set<String> = ["/w/.venv/pyvenv.cfg", "/w/.venv/bin/python3", "/opt/py/bin", "/b/env/pyvenv.cfg"]
        let exists: (String) -> Bool = { files.contains($0) }
        #expect(PythonEnv.root(ofInterpreter: "/w/.venv/bin/python3", exists: exists) == "/w/.venv")
        #expect(PythonEnv.root(ofInterpreter: "/usr/bin/python3", exists: exists) == nil)
        #expect(PythonEnv.root(ofInterpreter: "/w/.venv/bin/node", exists: exists) == nil)
        #expect(PythonEnv.interpreters(program: "/bin/bash", args: ["-c", "x", "/w/.venv/bin/python3.12"]) == ["/w/.venv/bin/python3.12"])
        #expect(PythonEnv.shebang("#!/w/.venv/bin/python3 -u") == "/w/.venv/bin/python3")
        #expect(PythonEnv.shebang("#!/usr/bin/env python3") == nil)
        let cfg: [String: String] = ["/w/.venv/pyvenv.cfg": "home = /opt/py/bin\nversion = 3.14", "/b/env/pyvenv.cfg": "home = /gone/bin"]
        #expect(PythonEnv.health(root: "/w/.venv", exists: exists, read: { cfg[$0] }) == .ok)
        if case .broken(let why) = PythonEnv.health(root: "/b/env", exists: exists, read: { cfg[$0] }) { #expect(why.contains("gone")) } else { Issue.record("expected broken") }
    }

    @Test func repairKeepsTheOldFolder() {
        let steps = PythonEnv.repairSteps(root: "/w/.venv", python3: "/opt/homebrew/bin/python3", lock: "/locks/w.txt", day: "2026-11-20")
        #expect(steps.first == ["/bin/mv", "/w/.venv", "/w/.venv.broken-2026-11-20"])
        #expect(steps.count == 3 && steps[2].contains("-r"))
        #expect(PythonEnv.repairCommand(root: "/w/my venv", lock: nil, day: "2026-11-20") == "mv '/w/my venv' '/w/my venv.broken-2026-11-20' && python3 -m venv '/w/my venv'")
        #expect(PythonEnv.lockName("/Users/a/w/.venv") == "Users_a_w_.venv.txt")
    }
}

@Suite struct PageCTRTests {
    @Test func flagsRankingPagesNobodyClicks() throws {
        let p = try JSONValue.parse(#"{"impressions_28d": 10000, "clicks_28d": 400, "top_pages_28d": [{"page": "/a", "impressions": 900, "clicks": 9, "position": 4.2}, {"page": "/b", "impressions": 900, "clicks": 60, "position": 3}, {"page": "/c", "impressions": 900, "clicks": 1, "position": 18}, {"page": "/d", "impressions": 50, "clicks": 0, "position": 2}, {"page": "/e", "impressions": 300, "clicks": 2}]}"#)
        let weak = PageCTR.weak(p)
        #expect(weak.map(\.page) == ["/a"])            // b clicks well, c ranks too low, d too few, e has no position
        #expect(PageCTR.percent(weak[0].siteCTR) == "4.0%")
        #expect(PageCTR.weak(try JSONValue.parse(#"{"impressions_28d": 100, "clicks_28d": 1, "top_pages_28d": []}"#)).isEmpty)
    }
}
