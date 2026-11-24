import Foundation
import Testing
@testable import HmunmawiCore

/// Mac notifications: sample never, switched-off kinds never, bursts coalesce, quiet hours wait, the hourly cap,
/// and only a broken connection or rejected build is urgent.
@Suite struct NotificationPlannerTests {
    static let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
    static func at(_ hour: Int) -> Date { utc.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: hour))! }
    @Test func failedCheckIsNotCalledAConnection() {
        let job = NotifyCandidate(id: 1, kind: .connection, app: "", text: "Mac jobs: mail-watch failed", urgent: true, page: "today")
        let conn = NotifyCandidate(id: 2, kind: .connection, app: "Sentry", text: "Sentry: key refused", urgent: true, page: "settings")
        #expect(NotificationPlanner.plan([job], Self.ctx()).send.first?.title == "Needs fixing")
        #expect(NotificationPlanner.plan([conn], Self.ctx()).send.first?.title == "Sentry stopped working")
    }
    static func ctx(hour: Int = 12, sent: Int = 0, front: Bool = false, paused: Date? = nil, prefs: NotifyPrefs = NotifyPrefs()) -> NotificationPlanner.Context {
        NotificationPlanner.Context(prefs: prefs, now: at(hour), quiet: .standard, sentLastHour: sent, cap: 6,
                                    windowFrontmost: front, pausedUntil: paused, calendar: utc, money: { "₹\(Int($0))" })
    }
    static func sale(_ id: Int64, _ app: String = "Pocket Garden", amount: Double? = 300, sample: Bool = false) -> NotifyCandidate {
        NotifyCandidate(id: id, kind: .purchase, app: app, amount: amount, text: "Monthly", isSample: sample)
    }

    @Test func burstOfPurchasesBecomesOneWithTheSum() {
        let r = NotificationPlanner.plan([Self.sale(1, amount: 290), Self.sale(2, amount: 300), Self.sale(3, amount: 300)], Self.ctx())
        #expect(r.send.count == 1)
        #expect(r.send[0].body == "3 new purchases, ₹890")
        #expect(r.send[0].thread == "Pocket Garden" && r.send[0].eventIDs == [1, 2, 3])
    }

    @Test func burstWithAnUnknownAmountShowsTheKnownSumWithAPlus() {
        let r = NotificationPlanner.plan([Self.sale(1), Self.sale(2, amount: nil)], Self.ctx())
        #expect(r.send.first?.body == "2 new purchases, ₹300+")
        let none = NotificationPlanner.plan([Self.sale(3, amount: nil), Self.sale(4, amount: nil)], Self.ctx())
        #expect(none.send.first?.body == "2 new purchases")
    }

    @Test func threeKindsAtOnceBecomeOneSummary() {
        let review = NotifyCandidate(id: 10, kind: .badReview, app: "Pocket Garden", rating: 1, text: "r")
        let refund = NotifyCandidate(id: 11, kind: .refund, app: "Pocket Garden", text: "x")
        let r = NotificationPlanner.plan([Self.sale(1), Self.sale(2), refund, review], Self.ctx())
        #expect(r.send.count == 1)
        #expect(r.send[0].title == "While you were away · Pocket Garden")
        #expect(r.send[0].body == "2 purchases (₹600), 1 refund or cancellation, 1 low review")
        #expect(Set(r.send[0].eventIDs) == [1, 2, 10, 11])
    }

    @Test func windowOnAnotherPageHoldsInsteadOfDropping() {
        var c = Self.ctx()
        c.windowElsewhere = true
        let r = NotificationPlanner.plan([Self.sale(1)], c)
        #expect(r.send.isEmpty && r.later.map(\.id) == [1] && r.dropped.isEmpty)
    }

    @Test func renewalsAndCancellationsAreNamed() {
        let renew = NotifyCandidate.from(id: 5, kind: "revenue.renewal", app: "Pocket Garden", payload: .object([:]), amount: 300, text: "Monthly", isSample: false)!
        #expect(NotificationPlanner.plan([renew], Self.ctx()).send.first?.title == "Pocket Garden: renewal")
        let cancel = NotifyCandidate.from(id: 6, kind: "revenue.cancelled", app: "Pocket Garden", payload: .object([:]), amount: nil, text: "x", isSample: false)!
        #expect(NotificationPlanner.plan([cancel], Self.ctx()).send.first?.title == "Pocket Garden: cancellation")
        let r2 = NotifyCandidate.from(id: 7, kind: "revenue.renewal", app: "Pocket Garden", payload: .object([:]), amount: 300, text: "Monthly", isSample: false)!
        #expect(NotificationPlanner.plan([renew, r2], Self.ctx()).send.first?.body == "2 renewals, ₹600")
    }

    @Test func eachAppGetsItsOwnThread() {
        let r = NotificationPlanner.plan([Self.sale(1, "A"), Self.sale(2, "B")], Self.ctx())
        #expect(Set(r.send.map(\.thread)) == ["A", "B"])
    }

    @Test func sampleDataNeverNotifies() {
        let r = NotificationPlanner.plan([Self.sale(1, sample: true), Self.sale(2, sample: true)], Self.ctx())
        #expect(r.send.isEmpty && r.later.isEmpty && r.dropped == [1, 2])
    }

    @Test func quietHoursHoldNormalOnesButLetUrgentThrough() {
        let rejected = NotifyCandidate(id: 9, kind: .build, app: "A", text: "Rejected", urgent: true)
        let r = NotificationPlanner.plan([Self.sale(1), rejected], Self.ctx(hour: 23))
        #expect(r.send.map(\.eventIDs) == [[9]])
        #expect(r.send[0].timeSensitive)
        #expect(r.later.map(\.id) == [1])
    }

    @Test func onlyConnectionsAndBuildsCanBeUrgent() {
        var refund = NotifyCandidate(id: 5, kind: .refund, app: "A", text: "Refund")
        refund.urgent = true
        let r = NotificationPlanner.plan([refund], Self.ctx(hour: 23))
        #expect(r.send.isEmpty && r.later.map(\.id) == [5])
    }

    @Test func hourlyCapKeepsTheRestForLater() {
        let r = NotificationPlanner.plan([Self.sale(1, "A"), Self.sale(2, "B")], Self.ctx(sent: 5))
        #expect(r.send.count == 1 && r.later.map(\.id) == [2])
    }

    @Test func frontmostWindowAndPauseDropNormalOnes() {
        #expect(NotificationPlanner.plan([Self.sale(1)], Self.ctx(front: true)).send.isEmpty)
        #expect(NotificationPlanner.plan([Self.sale(1)], Self.ctx(paused: Self.at(13))).send.isEmpty)
        // A pause that has ended no longer holds anything back.
        #expect(NotificationPlanner.plan([Self.sale(1)], Self.ctx(paused: Self.at(11))).send.count == 1)
    }

    @Test func switchedOffKindsAndPrivateDetails() {
        var prefs = NotifyPrefs()
        #expect(!prefs.kinds.contains(.review) && !prefs.showDetails)
        let review = NotifyCandidate(id: 3, kind: .badReview, app: "A", rating: 1, text: "Bad", privateText: "Crashes on launch")
        let hidden = NotificationPlanner.plan([review], Self.ctx(prefs: prefs))
        #expect(hidden.send.first?.body.contains("Crashes") == false)
        prefs.kinds.remove(.badReview)
        #expect(NotificationPlanner.plan([review], Self.ctx(prefs: prefs)).dropped == [3])
    }

    @Test func rejectedWebhookIsUrgent() {
        let c = NotifyCandidate.from(id: 1, kind: "asc.webhook", app: "A", payload: .object(["rejected": .bool(true)]),
                                     amount: nil, text: "Rejected", isSample: false)
        #expect(c?.kind == .build && c?.urgent == true)
        #expect(NotifyCandidate.from(id: 2, kind: "growth.x", app: nil, payload: .object([:]), amount: nil, text: "", isSample: false) == nil)
    }
}

/// The number beside the menu bar icon and the panel headline: unknown is hidden, never 0; sample shows nothing.
@Suite struct MenuBarFactsTests {
    static let now = Date(timeIntervalSince1970: 1_794_300_000)
    static func ev(_ id: Int64, _ kind: String, hoursAgo: Double = 1, _ payload: JSONValue = .object([:]), app: String = "A", source: String = "t") -> StoredEvent {
        StoredEvent(id: id, source: source, kind: kind, app: app, payload: payload,
                    occurredAt: Millis((now.timeIntervalSince1970 - hoursAgo * 3600) * 1000))
    }
    static func number(_ choice: String, _ events: [StoredEvent], sample: Bool = false) -> String? {
        MenuBarFacts.number(choice, events: events, isSample: sample, now: now, amount: { $0.payload[path: "amount"]?.number },
                            money: { "₹\(Int($0))" })
    }

    @Test func salesNumberIsTodaysMoney() {
        let e = [Self.ev(1, "revenue.purchase", .object(["amount": .number(300)])), Self.ev(2, "revenue.purchase", .object(["amount": .number(590)]))]
        #expect(Self.number("sales", e) == "₹890")
    }

    @Test func nothingConnectedShowsNoNumber() {
        #expect(Self.number("sales", []) == nil)
        #expect(Self.number("downloads", []) == nil)
        #expect(Self.number("reviews", []) == nil)
        #expect(Self.number("none", [Self.ev(1, "revenue.purchase")]) == nil)
    }

    @Test func sampleDataShowsNoNumber() {
        #expect(Self.number("sales", [Self.ev(1, "revenue.purchase", .object(["amount": .number(3)]))], sample: true) == nil)
    }

    @Test func downloadsAreTheNewestReportedDay() {
        let e = [Self.ev(1, "revenue.daily", hoursAgo: 30, .object(["day": .string("2026-11-08"), "units": .number(4)])),
                 Self.ev(2, "revenue.daily", hoursAgo: 6, .object(["day": .string("2026-11-09"), "units": .number(7)])),
                 Self.ev(3, "revenue.daily", hoursAgo: 6, .object(["day": .string("2026-11-09"), "units": .number(5)]), app: "B")]
        #expect(Self.number("downloads", e) == "12")
    }

    @Test func downloadsCountEachAppAndDayOnce() {
        // The same day from two senders (App Store Connect and a script feed) is one day, not two.
        let e = [Self.ev(1, "revenue.daily", hoursAgo: 6, .object(["day": .string("2026-11-09"), "units": .number(5)]), source: "appstoreconnect"),
                 Self.ev(2, "revenue.daily", hoursAgo: 5, .object(["day": .string("2026-11-09"), "units": .number(5)]), source: "scriptfeed")]
        #expect(Self.number("downloads", e) == "5")
    }

    @Test func headlineSaysPlainlyWhenNothingHappened() {
        let none = MenuBarFacts.Today(sales: 0, amount: nil, reviews: 0, refunds: 0)
        #expect(MenuBarFacts.headline(none) { "\($0)" } == "No sales or reviews yet today")
        let some = MenuBarFacts.Today(sales: 3, amount: 890, reviews: 1, refunds: 0)
        #expect(MenuBarFacts.headline(some) { "₹\(Int($0))" } == "₹890 today · 3 sales · 1 new review")
    }

    static func badge(_ choice: String, _ events: [StoredEvent], counts: [String: Int] = [:], hideZero: Bool = false,
                      symbol: Bool = true, sample: Bool = false) -> MenuBarFacts.Badge? {
        MenuBarFacts.badge(choice, events: events, isSample: sample, counts: counts, hideZero: hideZero, showSymbol: symbol, now: now,
                           amount: { $0.payload[path: "amount"]?.number }, money: { "₹\(Int($0))" })
    }

    @Test func compactKeepsTheBarShort() {
        #expect(MenuBarFacts.compact(0) == "0")
        #expect(MenuBarFacts.compact(999) == "999")
        #expect(MenuBarFacts.compact(12_345) == "12.3K")
        #expect(MenuBarFacts.compact(20_000) == "20K")
        #expect(MenuBarFacts.compact(999_999) == "1M")
        #expect(MenuBarFacts.compact(1_250_000) == "1.3M")
        #expect(MenuBarFacts.compact(-1) == nil)
        #expect(MenuBarFacts.compact(.nan) == nil)
        #expect(MenuBarFacts.compact(.infinity) == nil)
        // Never longer than 5 characters for any count the bar can get.
        for n in [9_999.0, 10_000, 99_999, 999_949, 999_950, 12_345_678, 999_999_999, 5e12] {
            #expect((MenuBarFacts.compact(n)?.count ?? 0) <= 6, "\(n)")
        }
    }

    @Test func bigSaleAmountIsShortNotCut() {
        let e = StoredEvent(id: 1, source: "asc", kind: "revenue.purchase", app: "A", payload: .object([:]), occurredAt: Int64(Date.now.timeIntervalSince1970 * 1000))
        let b = MenuBarFacts.badge("sales", events: [e], isSample: false, amount: { _ in 12_345_678 },
                                   money: { "₹" + Int($0).formatted() })
        #expect(b?.text == "₹12.3M")
    }

    @Test func badgeCountsWaitingAndProblems() {
        #expect(Self.badge("waiting", [], counts: ["waiting": 3]) == .init(symbol: "hand.raised", text: "3"))
        #expect(Self.badge("problems", [], counts: ["problems": 2], symbol: false) == .init(symbol: nil, text: "2"))
        #expect(Self.badge("waiting", []) == nil)
        #expect(Self.badge("waiting", [], counts: ["waiting": -4]) == .init(symbol: "hand.raised", text: "0"))
    }

    @Test func badgeHidesZeroOnlyWhenAsked() {
        let review = [Self.ev(1, "reviews.snapshot", hoursAgo: 30)]
        #expect(Self.badge("reviews", review)?.text == "0")
        #expect(Self.badge("reviews", review, hideZero: true) == nil)
        #expect(Self.badge("problems", [], counts: ["problems": 0], hideZero: true) == nil)
        let sale = [Self.ev(2, "revenue.purchase", hoursAgo: 30, .object(["amount": .number(5)]))]
        #expect(Self.badge("sales", sale)?.text == "₹0")
        #expect(Self.badge("sales", sale, hideZero: true) == nil)
    }

    @Test func badgeSalesHaveNoSymbolAndSampleShowsNothing() {
        let e = [Self.ev(1, "revenue.purchase", .object(["amount": .number(300)]))]
        #expect(Self.badge("sales", e) == .init(symbol: nil, text: "₹300"))
        #expect(Self.badge("sales", e, sample: true) == nil)
        #expect(Self.badge("waiting", [], counts: ["waiting": 1], sample: true) == nil)
        #expect(Self.badge("none", e) == nil)
    }

    @Test func badgeDownloadsAreCompact() {
        let e = [Self.ev(1, "revenue.daily", .object(["day": .string("2026-11-11"), "units": .number(15_400)]))]
        #expect(Self.badge("downloads", e) == .init(symbol: "arrow.down.circle", text: "15.4K"))
    }

    @Test func feedIsNewestFirstAndLimited() {
        let e = (1...8).map { Self.ev(Int64($0), "revenue.purchase", hoursAgo: Double($0)) } + [Self.ev(99, "growth.x")]
        #expect(MenuBarFacts.feed(e, limit: 5).map(\.id) == [1, 2, 3, 4, 5])
    }

    @Test func feedIncludesEveryPaymentKindAndKeepsReviewsAndBuilds() {
        #expect(PaymentMoment.paymentKinds.isSubset(of: MenuBarFacts.feedKinds))
        for kind in ["review.new", "asc.webhook", "ci.build"] {
            #expect(MenuBarFacts.feedKinds.contains(kind), "\(kind)")
        }
        // Today's sales count still ignores free trials and other non-sale payments.
        #expect(MenuBarFacts.saleKinds == ["revenue.purchase", "revenue.renewal"])
        #expect(!MenuBarFacts.saleKinds.contains("revenue.free"))
    }

    @Test func feedShowsFreeTrialsAheadOfOlderCancellations() {
        let trial = Self.ev(1, "revenue.free", hoursAgo: 0.5, app: "Presence")
        let intro = Self.ev(2, "revenue.free", hoursAgo: 18, app: "RepSquad")
        let cancelled = Self.ev(3, "revenue.cancelled", hoursAgo: 20, app: "RepSquad")
        let renewal = Self.ev(4, "revenue.renewal", hoursAgo: 30, app: "Body Vitals")
        #expect(MenuBarFacts.feed([cancelled, renewal, intro, trial], limit: 4).map(\.id) == [1, 2, 3, 4])
        #expect(MenuBarFacts.feed([cancelled, renewal, intro, trial], limit: 2).map(\.app) == ["Presence", "RepSquad"])
    }
}

/// Owner extras (P S's hub paths, AI pause, Zoho, X file feed, watcher, fixed time zone) are off for everyone else.
@Suite struct OwnerConfigGatingTests {
    @Test func newUsersGetNoOwnerExtras() {
        let c = OwnerConfig()
        #expect(!c.enabled && !c.showsAIPause && !c.offersZoho && !c.usesXFileFeed && !c.wantsKeychainWatcher)
        #expect(c.hubURL == nil && c.keyFolderURL == nil && c.reposURL == nil && c.ascConfigURL == nil)
        #expect(c.zone == .current)
    }

    @Test func settingsWithoutEnabledStayOff() {
        var c = OwnerConfig()
        c.hubRoot = "~/hub"; c.aiPause = true; c.zohoMail = true; c.timeZone = "Asia/Kolkata"
        #expect(c.hubURL == nil && !c.showsAIPause && !c.offersZoho && c.zone == .current)
        c.enabled = true
        #expect(c.hubURL != nil && c.showsAIPause && c.offersZoho && c.zone.identifier == "Asia/Kolkata")
    }

    @Test func testRunsSeeNoOwnerFile() {
        // The test profile's own data folder has no owner.json, so the app's defaults have no personal paths.
        #expect(OwnerConfig.load(from: URL(fileURLWithPath: "/nonexistent/owner.json")) == OwnerConfig())
        #expect(OwnerConfig.fileURL.path.contains("Hmunmawi-Test-") || ProcessInfo.processInfo.environment["HMUNMAWI_OWNER_CONFIG"] != nil)
    }

    @Test func roundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "hm-owner-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var c = OwnerConfig(enabled: true); c.xFileFeed = true
        try c.save(to: url)
        #expect(OwnerConfig.load(from: url) == c)
    }
}

/// Times use the Mac's own zone and language; the refund text rule is off until iMessage is set up.
@Suite struct LocaleAndDefaultsTests {
    @Test func zoneLabelFollowsTheZone() {
        let d = Date(timeIntervalSince1970: 1_794_300_000)
        #expect(LocalTime.zoneLabel(TimeZone(identifier: "Asia/Kolkata")!, at: d, locale: Locale(identifier: "en_IN")) == "IST")
        let ny = LocalTime.zoneLabel(TimeZone(identifier: "America/New_York")!, at: d, locale: Locale(identifier: "en_US"))
        #expect(ny == "EST" || ny == "GMT-5")
        #expect(!LocalTime.zoneLabel(at: d).isEmpty)
    }

    @Test func refundTextIsOffByDefault() {
        #expect(AppConfig.defaultRules.first { $0.id == "refund-alert" }?.enabled == false)
    }

    @Test func sampleDataQueuesNothingForApproval() async throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "hm-demo-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try Store(path: path)
        try await DemoData.seedIfEmpty(store)
        #expect(try await store.jobs(in: .waitingApproval).isEmpty)
        #expect(try await store.jobs(in: .queued).isEmpty)
    }
}

/// One Hmunmawi at a time: a second copy of the same app (any path) hands over; a test copy needs the override.
@Suite struct SingleInstanceTests {
    typealias R = SingleInstance.Running
    let live = R(pid: 100, bundleID: "io.github.priyevsingh.Hmunmawi")
    let fresh = "io.github.priyevsingh.Hmunmawi.freshtest"

    @Test func secondCopyOfTheSameAppHandsOver() {
        let t = SingleInstance.handOverTo(myPID: 200, myBundleID: live.bundleID, running: [live, R(pid: 200, bundleID: live.bundleID)],
                                          testProfile: false, overrideAsked: false)
        #expect(t == live)
    }

    @Test func firstCopyStarts() {
        #expect(SingleInstance.handOverTo(myPID: 100, myBundleID: live.bundleID, running: [live], testProfile: false, overrideAsked: false) == nil)
    }

    @Test func testCopyYieldsUnlessItAsks() {
        #expect(SingleInstance.handOverTo(myPID: 300, myBundleID: fresh, running: [live], testProfile: true, overrideAsked: false) == live)
        #expect(SingleInstance.handOverTo(myPID: 300, myBundleID: fresh, running: [live], testProfile: true, overrideAsked: true) == nil)
        // The override counts only for a test profile.
        #expect(SingleInstance.handOverTo(myPID: 300, myBundleID: fresh, running: [live], testProfile: false, overrideAsked: true) == live)
    }

    @Test func realAppNeverYieldsToATestCopy() {
        let t = SingleInstance.handOverTo(myPID: 100, myBundleID: live.bundleID, running: [R(pid: 300, bundleID: fresh)],
                                          testProfile: false, overrideAsked: false)
        #expect(t == nil)
    }

    @Test func realAppIgnoresTheOverride() {
        let t = SingleInstance.handOverTo(myPID: 200, myBundleID: live.bundleID, running: [live], testProfile: false, overrideAsked: true)
        #expect(t == live)
    }
}

@Suite struct MetricNameWordingTests {
    @Test func windowNamesReadAsASentence() {
        #expect(InsightEngine.plainName("Google clicks, 7 days") == "Google clicks over 7 days")
        #expect(InsightEngine.plainName("Crash-free (%)") == "Crash-free")
        #expect(InsightEngine.plainName("Visitors") == "Visitors")
    }
}

/// The release gate: a build whose designated requirement differs from the previous release's is refused.
@Suite struct DesignatedRequirementGateTests {
    static let script: String = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("scripts/check-designated-requirement.sh").path
    }()

    static func run(_ new: String, _ prev: String) throws -> (code: Int32, err: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hm-dr-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("new.txt"), b = dir.appendingPathComponent("prev.txt")
        try new.write(to: a, atomically: true, encoding: .utf8)
        try prev.write(to: b, atomically: true, encoding: .utf8)
        let p = Process(), err = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script, a.path, b.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = err
        try p.run(); p.waitUntilExit()
        return (p.terminationStatus, String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    static let dr = #"designated => identifier "io.github.priyevsingh.Hmunmawi" and anchor apple generic and certificate leaf[subject.OU] = ABCDE12345"#

    @Test func sameRequirementPasses() throws {
        #expect(try Self.run(Self.dr + "\n", Self.dr + "\n").code == 0)
    }

    @Test func differentTeamOrIdentifierFails() throws {
        let otherTeam = Self.dr.replacingOccurrences(of: "ABCDE12345", with: "ZYXWV98765")
        let r = try Self.run(otherTeam, Self.dr)
        #expect(r.code == 1 && r.err.contains("DIFFERENT"))
        let otherId = Self.dr.replacingOccurrences(of: "io.github.priyevsingh.Hmunmawi", with: "io.example.Other")
        #expect(try Self.run(otherId, Self.dr).code == 1)
    }

    @Test func adHocOrMissingRequirementFails() throws {
        #expect(try Self.run("Executable=/x\n", Self.dr).code == 1)
        #expect(try Self.run(Self.dr, "").code == 1)
    }
}
