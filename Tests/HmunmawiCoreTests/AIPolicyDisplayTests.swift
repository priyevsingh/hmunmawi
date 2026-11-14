import Foundation
import Testing
@testable import HmunmawiCore

@Suite struct AIPolicyDisplayTests {
    private let teamPauseEpoch = 1_794_477_600 // Thu 12 Nov 2026 15:30 IST when tz=Asia/Kolkata

    @Test func activeTeamPauseHeadlineUsesEffectiveUntil() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let json: [String: Any] = [
            "account_id": "team",
            "blocked": true,
            "until_epoch": teamPauseEpoch,
            "reasons": [
                ["kind": "manual", "until_epoch": teamPauseEpoch, "source": "user", "confidence": "high",
                 "detail": "User weekly Claude limit (P S 8 Nov)"],
                ["kind": "weekly", "until_epoch": 1_794_218_400, "source": "migrated_ai_state",
                 "confidence": "medium", "detail": "weekly"],
            ],
        ]
        let snap = AIPolicyDisplay.parse(json)
        let now = Date(timeIntervalSince1970: 1_762_000_000)
        let headline = AIPolicyDisplay.headline(snap, now: now, calendar: cal)
        #expect(headline.hasPrefix("Claude · Team paused until"))
        #expect(headline.contains("12") && headline.contains("November"))
        let lines = AIPolicyDisplay.restrictionLines(snap, now: now, calendar: cal)
        #expect(lines.contains { $0.contains("You set this pause") })
        #expect(lines.contains { $0.contains("Older weekly-limit record") })
    }

    @Test func manualFormDefaultsFromSavedManual() {
        let json: [String: Any] = [
            "blocked": true,
            "until_epoch": teamPauseEpoch,
            "reasons": [
                ["kind": "manual", "until_epoch": teamPauseEpoch, "source": "user", "detail": "User weekly Claude limit"],
            ],
        ]
        let d = AIPolicyDisplay.manualFormDefaults(from: AIPolicyDisplay.parse(json))!
        #expect(Int(d.until.timeIntervalSince1970) == teamPauseEpoch)
        #expect(d.indefinite == false)
        #expect(d.reason.contains("User weekly"))
    }

    @Test func indefiniteManual() {
        let json: [String: Any] = [
            "blocked": true,
            "until_epoch": 9_999_999_999,
            "reasons": [["kind": "manual", "until_epoch": 9_999_999_999, "source": "user", "detail": "hold"]],
        ]
        let snap = AIPolicyDisplay.parse(json)
        #expect(AIPolicyDisplay.headline(snap).contains("until you clear it"))
        #expect(AIPolicyDisplay.manualFormDefaults(from: snap)?.indefinite == true)
    }

    @Test func notBlockedDoesNotClaimPaused() {
        let json: [String: Any] = ["account_id": "team", "blocked": false, "until_epoch": 0, "reasons": []]
        let h = AIPolicyDisplay.headline(AIPolicyDisplay.parse(json))
        #expect(h.contains("allowed"))
        #expect(!h.contains("paused until"))
    }

    @Test func loadFailedHeadline() {
        let h = AIPolicyDisplay.headline(AIPolicyDisplay.parse([:], loadFailed: true))
        #expect(h.contains("Couldn't read"))
    }

    @Test func expiredShowsRecheckNotAvailable() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let json: [String: Any] = ["account_id": "team", "blocked": true, "until_epoch": 1, "reasons": []]
        let snap = AIPolicyDisplay.parse(json)
        let h = AIPolicyDisplay.headline(snap, now: Date(timeIntervalSince1970: 9_000_000_000), calendar: cal)
        #expect(h.contains("ended") || h.contains("Check availability"))
    }

    @Test func freshEmptyPolicy() {
        let snap = AIPolicyDisplay.parse(["account_id": "team", "blocked": false, "reasons": []])
        #expect(AIPolicyDisplay.manualFormDefaults(from: snap) == nil)
        #expect(AIPolicyDisplay.restrictionLines(snap).isEmpty)
    }
}

@Suite struct AIPolicyEditFormTests {
    private func snap(_ reasons: [[String: Any]], blocked: Bool = true) -> AIPolicyDisplay.Snapshot {
        AIPolicyDisplay.parse(["account_id": "team", "blocked": blocked, "until_epoch": 1_794_477_600, "reasons": reasons])
    }

    @Test func hasManualPauseOnlyForManualReason() {
        #expect(AIPolicyDisplay.hasManualPause(snap([["kind": "manual", "detail": "x"]])))
        #expect(!AIPolicyDisplay.hasManualPause(snap([["kind": "weekly", "source": "migrated_ai_state"]])))
        #expect(!AIPolicyDisplay.hasManualPause(AIPolicyDisplay.parse([:], loadFailed: true)))
    }

    @Test func emptyNoteKeepsSavedReason() {
        let s = snap([["kind": "manual", "source": "user", "detail": "User weekly Claude limit (P S 8 Nov)"]])
        #expect(AIPolicyDisplay.reasonToSave(typed: "  ", snap: s) == "User weekly Claude limit (P S 8 Nov)")
        #expect(AIPolicyDisplay.reasonToSave(typed: "Travel", snap: s) == "Travel")
        #expect(AIPolicyDisplay.notePrompt(s).contains("User weekly Claude limit"))
    }

    @Test func noSavedNoteFallsBackToDefault() {
        let s = snap([], blocked: false)
        #expect(AIPolicyDisplay.reasonToSave(typed: "", snap: s) == "Paused in Hmunmawi")
        #expect(AIPolicyDisplay.notePrompt(s) == "Why you're pausing (optional)")
        #expect(AIPolicyDisplay.currentManualNote(s) == nil)
    }

    @Test func indefiniteCopyIsExplicit() {
        #expect(AIPolicyDisplay.indefiniteConfirmMessage.contains("no end time"))
        #expect(AIPolicyDisplay.indefiniteConfirmMessage.contains("Clear my pause"))
        #expect(AIPolicyDisplay.indefiniteExplainer.contains("until you clear"))
    }
}

/// Regression guard: display-only cards must not use input controls for their read-only text.
@Suite struct ReadOnlyDisplaySourceTests {
    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: "Sources/HmunmawiApp/\(name)"), encoding: .utf8)
    }

    @Test func weeklyStoryHasNoEditableText() throws {
        let s = try source("WeeklyStory.swift")
        #expect(!s.contains("TextField("))
        #expect(!s.contains("TextEditor("))
    }

    @Test func pauseCardOnlyInputIsTheNoteField() throws {
        let s = try source("AIPolicyPauseCard.swift")
        #expect(s.components(separatedBy: "TextField(").count - 1 == 1)
        #expect(!s.contains("TextEditor("))
        #expect(!s.contains("Toggle(\"Pause indefinitely\""))
        #expect(s.contains("confirmationDialog(AIPolicyDisplay.indefiniteConfirmTitle"))
    }
}
