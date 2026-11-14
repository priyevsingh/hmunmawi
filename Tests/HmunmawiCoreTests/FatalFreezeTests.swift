import Foundation
import Testing
@testable import HmunmawiCore
import HmunmawiProtocol

@Suite struct FatalFreezeTests {
    private func event(currentFrames: [JSONValue]) -> JSONValue {
        .object(["entries": .array([.object(["type": .string("threads"), "data": .object(["values": .array([
            .object(["current": .bool(false), "stacktrace": .object(["frames": .array([])])]),
            .object(["current": .bool(true), "stacktrace": .object(["frames": .array(currentFrames)])]),
        ])])])])])
    }
    private let ours = JSONValue.object(["inApp": .bool(true), "function": .string("main")])
    private let system = JSONValue.object(["inApp": .bool(false), "function": .string("UIApplicationMain")])

    /// The freeze sorting rules.
    @Test func sortsFreezesLikeTheHubsFreezeCheck() {
        // Longer than iOS lets a blocked app live: noise, whatever the stack says.
        #expect(FreezeClassifier.verdict(issueTitle: "App Hang Fully Blocked: App hanging between 1098.3 and 1099.5 seconds.",
                                         latestEvent: event(currentFrames: [ours, ours, ours])) == .noAppCode)
        // Idle screen thread with only `main` from our binary: noise.
        #expect(FreezeClassifier.verdict(issueTitle: "Fatal App Hang Fully Blocked", latestEvent: event(currentFrames: [system, ours, system])) == .noAppCode)
        // Two or more of our frames on the screen thread: our code.
        #expect(FreezeClassifier.verdict(issueTitle: "Fatal App Hang Fully Blocked", latestEvent: event(currentFrames: [ours, system, ours])) == .ourCode)
        // A package inside the .app counts as ours, like the hub.
        let pkg = JSONValue.object(["package": .string("/private/var/containers/Bundle/Application/X/Pulse Diary.app/Pulse Diary")])
        #expect(FreezeClassifier.verdict(issueTitle: "App Hang", latestEvent: event(currentFrames: [pkg, pkg])) == .ourCode)
        // A short hang under 60 s still goes by the stack.
        #expect(FreezeClassifier.verdict(issueTitle: "App Hang Fully Blocked: App hanging between 8.8 and 10.0 seconds.",
                                         latestEvent: event(currentFrames: [ours])) == .noAppCode)
        // No readable event: not sorted (never guessed).
        #expect(FreezeClassifier.verdict(issueTitle: "Fatal App Hang Fully Blocked", latestEvent: nil) == .unchecked)
        #expect(FreezeClassifier.isHang("Fatal App Hang Fully Blocked: The user or the OS watchdog terminated your app"))
        #expect(!FreezeClassifier.isHang("EXC_BAD_ACCESS"))
        #expect(FreezeClassifier.version("com.example.pulsediary@4.1.7+176") == "4.1.7")
    }

    @Test func cardLinesCountPerReleaseAndByVerdictWithoutHidingAnything() {
        let s = FreezeSummary(checkedAt: .now, releases: [
            FreezeReleaseCount(app: "Pulse Diary", release: "x@4.1.7+176", events: 1025, users: 204),
            FreezeReleaseCount(app: "Pulse Diary", release: "x@4.1.6+165", events: 4, users: 3),
            FreezeReleaseCount(app: "Lift Crew", release: "y@3.9+1", events: 2, users: 1),
        ], issues: [
            FreezeIssueCount(app: "Pulse Diary", issueID: "1", events: 977, verdict: .noAppCode),
            FreezeIssueCount(app: "Pulse Diary", issueID: "2", events: 50, verdict: .ourCode),
            FreezeIssueCount(app: "Pulse Diary", issueID: "3", events: 2, verdict: .unchecked),
        ])
        let lines = s.lines(for: "Pulse Diary")
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("1,029 fatal freezes in 7 days (Sentry): 1,025 on 4.1.7 (204 users), 4 on 4.1.6 (3 users)"), "got: \(lines[0])")
        #expect(lines[1].contains("50 with our code") && lines[1].contains("977 with no app code") && lines[1].contains("2 not checked"), "got: \(lines[1])")
        #expect(s.lines(for: "Pocket Garden") == ["No fatal freezes in 7 days (Sentry)."])
    }

    /// Discover answers {"issue.id": 7817959608, ...}: a dotted key, not a path.
    @Test func readsDiscoversDottedIssueIdColumn() {
        let row = JSONValue.object(["project": .string("body-vitals"), "issue.id": .number(7817959608), "count()": .number(977)])
        #expect(FreezeClassifier.issueID(row) == "7817959608")
        #expect(FreezeClassifier.issueID(.object(["issue.id": .string("123")])) == "123")
        #expect(FreezeClassifier.issueID(.object(["issue": .object(["id": .number(1)])])) == nil)
    }

    @Test func unreachableSentryIsNotAvailableNeverZero() {
        let lines = FreezeSummary.failed("Sentry did not accept the saved token.").lines(for: "Pulse Diary")
        #expect(lines == ["Fatal freezes (Sentry): not available. Sentry did not accept the saved token."])
        #expect(!lines[0].contains("0"))
    }
}
