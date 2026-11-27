import Foundation
import Testing
@testable import HmunmawiApp
@testable import HmunmawiCore

@MainActor @Suite struct TelemetryPolishTests {
    @Test func releaseDateConvertsUTCMidnightTimestampToLocalDay() {
        let ist = TimeZone(identifier: "Asia/Kolkata")!
        let utc = TimeZone(identifier: "UTC")!
        let raw = "2026-11-25T19:15:00Z"
        #expect(ReleaseDates.dayString(fromISO: raw, timeZone: ist) == "2026-11-26")
        #expect(ReleaseDates.dayString(fromISO: raw, timeZone: utc) == "2026-11-25")
        #expect(ReleaseDates.dayString(fromISO: "2026-11-25", timeZone: ist) == "2026-11-25")
    }

    @Test func storyBoardRanksMonetizationDropsAboveCriticalRatingFloorNotice() {
        let ratingCritical = AttentionItem(app: "Body Vitals", severity: "critical", title: "Rated below 4 stars in US", detail: "3.7")
        let crashSpike = AttentionItem(app: "Body Vitals", severity: "critical", title: "Crash spike", detail: "Crashes up")
        #expect(StoryBoard.declaredScore(for: ratingCritical) < 1.0)
        #expect(StoryBoard.declaredScore(for: crashSpike) > StoryBoard.declaredScore(for: ratingCritical))
    }

    @Test func exhaustedNonMonthlyGrantIsRetiredWhileMonthlyStaysTracked() {
        let grant = Credits.Credit(name: "Startup credit", amountUSD: 1000, start: .now, monthly: false)
        let monthly = Credits.Credit(name: "Team monthly credit", amountUSD: 40, start: .now, monthly: true)
        #expect(Credits.isExhaustedGrant(grant, left: 0))
        #expect(!Credits.isExhaustedGrant(grant, left: 10))
        #expect(!Credits.isExhaustedGrant(monthly, left: 0))
    }

    @Test func agentUsageRowFlagsStaleResetAndAtLimit() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let staleReading = UsageWatch.Reading(service: "Claude", detail: "Personal", usedPercent: 2,
                                              resets: now.addingTimeInterval(-3600), source: "files", read: nil, problem: nil)
        let staleRow = AgentBridge.usageRow(staleReading, now: now)
        #expect(staleRow["stale"] as? Bool == true)
        #expect((staleRow["problem"] as? String)?.contains("Old reading") == true)

        let maxedReading = UsageWatch.Reading(service: "Grok Bot", detail: "Premium", usedPercent: 100,
                                              resets: now.addingTimeInterval(3600), source: "file", read: nil, problem: nil)
        let maxedRow = AgentBridge.usageRow(maxedReading, now: now)
        #expect(maxedRow["stale"] as? Bool == false)
        #expect((maxedRow["problem"] as? String)?.contains("100%") == true)
    }

    @Test func freezeSummaryAnnotatesSupersededReleaseAgainstLiveVersion() {
        let summary = FreezeSummary(
            checkedAt: .now,
            releases: [FreezeReleaseCount(app: "Body Vitals", release: "com.etm.bv@4.1.7+176", events: 21, users: 7)],
            issues: [FreezeIssueCount(app: "Body Vitals", issueID: "1", events: 21, verdict: .noAppCode)]
        )
        let lines = summary.lines(for: "Body Vitals", liveVersion: "4.1.9")
        #expect(lines[0].contains("21 on 4.1.7 (older release)"))
        #expect(lines[0].contains("0 on live 4.1.9"))
    }

    @Test func sentryTriageRanksRealCrashesAheadOfAggregateRollupsAndHangs() {
        let issues = [
            SentryIssues.Issue(id: "1", title: "Cron failure: mac-jobs-ok", project: "mac-jobs", category: "cron", count: 4010),
            SentryIssues.Issue(id: "2", title: "App Hang Fully Blocked: 11.8s", project: "Body Vitals", category: "error", count: 11),
            SentryIssues.Issue(id: "3", title: "EXC_BREAKPOINT", project: "Presence", category: "error", count: 3),
        ]
        let sorted = SentryIssues.sortedForTriage(issues)
        #expect(sorted.map(\.id) == ["3", "2", "1"])
        #expect(SentryIssues.isAggregate(issues[0]))
        #expect(SentryIssues.isHangTitle(issues[1].title))
        #expect(!SentryIssues.isAggregate(issues[2]))
    }
}
