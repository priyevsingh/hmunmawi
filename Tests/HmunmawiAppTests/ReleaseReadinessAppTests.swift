import Foundation
import Testing
import HmunmawiCore
@testable import HmunmawiApp

/// One health truth: nothing connected (or sample data) is never "All good".
@Suite struct HealthTruthTests {
    @Test func nothingConnectedIsIdleNotHealthy() {
        let t = HealthTruth.make(connected: 0, brokenConnections: [], badChecks: [], cautionChecks: [], recovering: false, isDemo: false)
        #expect(t.dot == .idle && t.headline == "Not connected yet")
        let demo = HealthTruth.make(connected: 3, brokenConnections: [], badChecks: [], cautionChecks: [], recovering: false, isDemo: true)
        #expect(demo.dot == .idle)
    }

    @Test func brokenBeatsCautionBeatsGood() {
        let broken = HealthTruth.make(connected: 3, brokenConnections: ["YouTube"], badChecks: [], cautionChecks: ["Late"], recovering: false, isDemo: false)
        #expect(broken.dot == .broken && broken.headline == "1 needs fixing")
        let caution = HealthTruth.make(connected: 3, brokenConnections: [], badChecks: [], cautionChecks: ["Late", "Slow"], recovering: false, isDemo: false)
        #expect(caution.dot == .attention && caution.headline == "2 need a look")
        let good = HealthTruth.make(connected: 3, brokenConnections: [], badChecks: [], cautionChecks: [], recovering: false, isDemo: false)
        #expect(good.dot == .good && good.headline == "All good")
        let paused = HealthTruth.make(connected: 3, brokenConnections: [], badChecks: [], cautionChecks: [], recovering: false, isDemo: false, paused: true)
        #expect(paused.dot == .idle && paused.headline.contains("paused"))
    }
}

/// Share for a website project uses its own Today numbers; missing ones are left out, never 0.
@Suite struct ProjectShareTests {
    static let siteSearch: JSONValue = .object(["clicks": .number(30), "clicks_prev": .number(40), "impressions": .number(2100),
                                               "position": .number(6.4), "posts": .number(12), "window": .string("1–7 Nov"), "window_days": .number(7)])
    static let siteSections: [JSONValue] = [
        .object(["figures": .array([.object(["label": .string("Visitors, 7 days"), "value": .number(31)]),
                                    .object(["label": .string("WhatsApp taps, 7 days"), "value": .number(4)])])]),
        .object(["figures": .array([.object(["label": .string("Posts live"), "value": .number(12)]),
                                    .object(["label": .string("Google clicks from posts, 28 days"), "value": .number(50)])])]),
    ]

    @Test func hillTrailsGetsItsOwnNumbers() {
        let m = ProjectShare.metrics(search: Self.siteSearch, sections: Self.siteSections)
        #expect(m.map(\.id) == ["taps", "clicks", "visitors", "seen", "position", "posts", "postClicks"])
        #expect(m.first { $0.id == "taps" }?.text == "4" && m.first { $0.id == "taps" }?.window == "7 days")
        #expect(m.first { $0.id == "position" }?.text == "6.4")
        #expect(m.first { $0.id == "clicks" }?.window == "1–7 Nov")
        // 30 vs 40 the period before.
        #expect(abs((m.first { $0.id == "clicks" }?.change ?? 0) + 0.25) < 0.001)
        #expect(ProjectShare.hero(m, choice: "auto")?.id == "taps")
        #expect(ProjectShare.hero(m, choice: "posts")?.id == "posts")
    }

    @Test func missingNumbersAreLeftOutNotZero() {
        let m = ProjectShare.metrics(search: .object(["clicks_28d": .number(40)]), sections: [])
        #expect(m.map(\.id) == ["clicks"] && m[0].window == "28 days")
        #expect(ProjectShare.metrics(search: nil, sections: []).isEmpty)
        #expect(ProjectShare.hero([], choice: "auto") == nil)
    }

    @Test func captionUsesOnlyRealNumbers() {
        let m = ProjectShare.metrics(search: Self.siteSearch, sections: Self.siteSections)
        let c = ProjectShare.caption(name: "Hill Tours", metrics: m)
        #expect(c.hasPrefix("Hill Tours lately: 4 WhatsApp taps, 30 Google clicks (average position 6.4) and 31 visitors."))
        #expect(c.contains("12 blog posts live, 50 Google clicks from them."))
        let few = ProjectShare.caption(name: "Site", metrics: [ShareMetric(id: "posts", label: "Blog posts live", value: 1)])
        #expect(few == "Site. 1 blog post live. #buildinpublic")
    }

    @Test func cardChoicesPerProject() {
        #expect(ShareSource.offered(hasSales: true, hasSite: true, project: .apps) == [.sales])
        #expect(ShareSource.offered(hasSales: false, hasSite: true, project: .website) == [.site])
        #expect(ShareSource.offered(hasSales: true, hasSite: true, project: nil) == [.everything, .sales, .site])
        #expect(ShareSource.offered(hasSales: false, hasSite: false, project: .website).isEmpty)
    }
}

/// Owner-only choices stay hidden for new users; Find my key reads short labels aloud.
@Suite struct OwnerGatingAppTests {
    @Test func zohoOnlyForTheOwnerOrWhenAlreadyPicked() {
        #expect(!MailSourceKind.offered(current: .off, owner: OwnerConfig(), extras: false).contains(.zohoSafari))
        #expect(MailSourceKind.offered(current: .zohoSafari, owner: OwnerConfig()).contains(.zohoSafari))
        var owner = OwnerConfig(enabled: true); owner.zohoMail = true
        #expect(MailSourceKind.offered(current: .off, owner: owner).contains(.zohoSafari))
    }

    @Test func noOwnerPathsByDefault() {
        // Test runs never have owner.json, so no hub, key folder or repos folder are searched.
        #expect(SecretSourceDefaults.hub() == nil || OwnerConfig.override != nil)
        let roots = KeyFinder.envRoots().map(\.path)
        #expect(!roots.contains { $0.hasSuffix("/Documents/repos") })
    }

    @Test func accessibilityLabelsAreShort() {
        #expect(KeyFinder.shortLabel("Issuer ID (from Users and Access)") == "Issuer ID")
        let m = KeyFinder.Match(label: "POSTHOG_API_KEY · /Users/x/secrets/posthog.env", source: "File", sourceRef: nil, fetch: { nil }, rank: 0)
        #expect(KeyFinder.spokenLabel(m) == "File, POSTHOG_API_KEY in posthog.env")
    }

    @Test func appsPageSaysHowToGetApps() {
        let e = AppsPager.emptyState(ascConnected: false, isSample: true)
        #expect(e.action == "Connect App Store Connect" && e.detail.contains("sample"))
        #expect(AppsPager.emptyState(ascConnected: true, isSample: false).action == nil)
    }
}

@Suite struct CommaListFieldTests {
    @Test func parseKeepsItemsWithSpacesAndDropsEmpties() {
        #expect(CommaListField.parse("My App, site.com, ") == ["My App", "site.com"])
        #expect(CommaListField.parse(" , ,") == [])
    }
}

@MainActor @Suite struct PauseAndDefaultsTests {
    @Test func untilTomorrowEndsWithQuietHours() {
        let d = UserDefaults(suiteName: "hm-test-pause-\(UUID().uuidString)")!
        let s = MenuBarSettings(defaults: d)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_794_480_000)  // 12 Nov 2026, 12:00 UTC
        s.pause(.untilTomorrow, quiet: QuietHours(enabled: true, startHour: 23, endHour: 6), now: now, calendar: cal)
        #expect(cal.component(.hour, from: s.pausedUntil!) == 6)
        s.pause(.untilTomorrow, quiet: QuietHours(enabled: false), now: now, calendar: cal)
        #expect(cal.component(.hour, from: s.pausedUntil!) == 8)
    }

    /// New installs show the icon alone (narrow, so macOS is less likely to hide it); a chosen number is kept.
    @Test func newInstallsShowTheIconAloneAndKeepAChosenNumber() {
        let d = UserDefaults(suiteName: "hm-test-defaults-\(UUID().uuidString)")!
        let s = MenuBarSettings(defaults: d)
        #expect(s.number == .none && s.hideZero)
        d.set("problems", forKey: "HMMenuBarNumber")
        #expect(MenuBarSettings(defaults: d).number == .problems)
    }
}

@Suite struct StoryWordingTests {
    @Test func namesKeepTheirCapital() {
        #expect(StoryCards.startsWithName("Google clicks over 7 days hit 28 today."))
        #expect(StoryCards.startsWithName("X followers up"))
        #expect(!StoryCards.startsWithName("First downloads fell"))
    }
}

/// An update or rebuild seen by the previous copy of the app must not keep the dot red after the new one starts.
@Suite struct StaleUpdateFailureTests {
    func e(_ at: Millis, _ action: String, _ err: String? = nil) -> AuditEntry {
        AuditEntry(id: at, at: at, actor: "x", action: action, subject: nil,
                   detail: err.map { .object(["error": .string($0)]) } ?? .object([:]))
    }
    @Test func onlyChangedOnDiskBeforeLaunchIsIgnored() {
        let launch: Millis = 1_000
        #expect(SystemStatus.staleUpdateFailure(e(900, "plugin.changed_on_disk"), launchedAt: launch))
        #expect(SystemStatus.staleUpdateFailure(e(900, "plugin.poll_failed", "not_approved: X changed on disk since you approved it"), launchedAt: launch))
        #expect(!SystemStatus.staleUpdateFailure(e(900, "plugin.poll_failed", "timeout"), launchedAt: launch))
        #expect(!SystemStatus.staleUpdateFailure(e(1_100, "plugin.changed_on_disk"), launchedAt: launch))
    }
}

@Suite struct PageTitleTests {
    @Test func pathsBecomeTitles() {
        #expect(Plain.pageTitle("Blog/sample travel guide") == "Sample Travel Guide")
        #expect(Plain.pageTitle("Destinations/thenzawl") == "Thenzawl")
        #expect(Plain.pageTitle("blog/athlytic-vs-bevel") == "Athlytic vs Bevel")
        #expect(Plain.pageTitle("Home page") == "Home page")
        #expect(Plain.pageTitle("ChatGPT-User · live") == "ChatGPT-User · live")
        #expect(Plain.pageTitle("https://example.com/a") == "https://example.com/a")
        #expect(Plain.pageTitle("Apps/Pulse Diary") == "Apps/Pulse Diary")
    }
}

@Suite struct PortalUploadRunTests {
    @Test func runsInTheFolderWithoutKeysAndReportsFailure() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hm-upload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ok = PortalUpload.run("test \"$(pwd -P)\" = \"$(cd \"$HM_PORTAL_DIR\" && pwd -P)\" && test -z \"$ANTHROPIC_API_KEY\" && echo done", in: dir)
        #expect(ok.hasPrefix("Uploaded") && ok.contains("done"), "\(ok)")
        let bad = PortalUpload.run("echo nope >&2; exit 3", in: dir)
        #expect(bad.contains("failed") && bad.contains("exit 3") && bad.contains("nope"))
    }
}

@Suite struct UploadHostTests {
    @Test func examplesMatchTheirHostAndHaveSteps() {
        for h in UploadHost.allCases {
            #expect(UploadHost.match(h.command) == h)
            #expect(h.steps.count >= 4)
        }
        #expect(UploadHost.match("echo hi") == nil)
    }
}

@Suite struct NumberFieldTests {
    @Test func numberFieldsRefuseLetters() {
        #expect(InputRule.number.clean("Up to 2 post drafts, 5 hours") == "25")
        #expect(InputRule.number.clean("2.5") == "2.5")
        #expect(InputRule.number.clean("123456789012") == "12345678")
        #expect(InputRule.numberList.clean("30, 7 and 1") == "30,71")
    }
}

@Suite struct PathFieldTests {
    @Test func shortPathKeepsTheEnd() {
        let h = NSHomeDirectory()
        #expect(PathField.short(h + "/Documents/repos/hub/.venv/bin") == "~/…/hub/.venv/bin")
        #expect(PathField.short(h + "/bin") == "~/bin")
        #expect(PathField.short("/usr/bin") == "/usr/bin")
    }
}

@Suite struct PlainRoutineTextTests {
    @Test func elsewhereHidesScriptsAndOldCounts() {
        #expect(RoutinesSheet.elsewhereText("Runs in your hub: X post drafts (x_drop_notify.sh, 3 a day from the post bank)") == "Not used: your own job does this: X post drafts")
        #expect(RoutinesSheet.elsewhereText("Runs in your hub: site_watch.py (every 30 min, usage tracker)") == "Not used: one of your own jobs does this")
    }
    @Test func unknownEventKindsAreWords() {
        let e = StoredEvent(id: 1, source: "t", kind: "asc.access", app: "A", payload: .object([:]), occurredAt: 0)
        #expect(EventText.describe(e) == "An App Store update for A")
    }
}
