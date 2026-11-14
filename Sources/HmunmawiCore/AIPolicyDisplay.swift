import Foundation

/// Read-only labels for the shared AI pause policy JSON (`ai_policy.py status`).
public enum AIPolicyDisplay {
    public struct Reason: Equatable, Sendable {
        public let kind: String
        public let source: String
        public let confidence: String
        public let detail: String
        public let untilEpoch: Int?
    }

    public struct Snapshot: Equatable, Sendable {
        public let accountID: String
        public let blocked: Bool
        public let effectiveUntilEpoch: Int?
        public let reasons: [Reason]
        public let loadFailed: Bool
    }

    public static func parse(_ json: [String: Any], loadFailed: Bool = false) -> Snapshot {
        let reasons = (json["reasons"] as? [[String: Any]] ?? []).map { r in
            Reason(
                kind: r["kind"] as? String ?? "limit",
                source: r["source"] as? String ?? "",
                confidence: r["confidence"] as? String ?? "",
                detail: r["detail"] as? String ?? "",
                untilEpoch: r["until_epoch"] as? Int ?? (r["until_epoch"] as? Double).map { Int($0) }
            )
        }
        let until = json["until_epoch"] as? Int ?? (json["until_epoch"] as? Double).map { Int($0) }
        return Snapshot(
            accountID: json["account_id"] as? String ?? "team",
            blocked: json["blocked"] as? Bool == true,
            effectiveUntilEpoch: until,
            reasons: reasons,
            loadFailed: loadFailed
        )
    }

    public static func accountLabel(_ accountID: String) -> String {
        switch accountID.lowercased() {
        case "team": return "Claude · Team"
        case "personal", "claude-local": return "Claude · Personal"
        default:
            let pretty = accountID.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
            return pretty.isEmpty ? "Claude" : "Claude · \(pretty)"
        }
    }

    /// Primary passive status — what is saved/effective now (not the edit form).
    public static func headline(_ snap: Snapshot, now: Date = .now, calendar: Calendar = .current) -> String {
        if snap.loadFailed { return "Couldn't read pause policy" }
        let who = accountLabel(snap.accountID)
        guard snap.blocked else {
            return "\(who) — hub jobs allowed by this Mac's policy (Anthropic may still refuse)"
        }
        guard let until = snap.effectiveUntilEpoch, until > 0, !isIndefiniteEpoch(until) else {
            return "\(who) paused until you clear it"
        }
        if until <= Int(now.timeIntervalSince1970) {
            return "\(who) — pause window ended; tap Check availability to refresh"
        }
        return "\(who) paused until \(formatUntil(until, now: now, calendar: calendar))"
    }

    public static func recheckFootnote(_ snap: Snapshot) -> String? {
        guard snap.blocked, !snap.loadFailed else { return nil }
        return "Passing this time only updates Hmunmawi's policy file — it does not reset Anthropic's account limits for you."
    }

    /// Plain-language lines for each restriction (not raw kind/source).
    public static func restrictionLines(_ snap: Snapshot, now: Date = .now, calendar: Calendar = .current) -> [String] {
        guard !snap.loadFailed else { return [] }
        if snap.reasons.isEmpty {
            return snap.blocked ? ["Hub Claude jobs are deferred."] : []
        }
        return snap.reasons.map { explain($0, now: now, calendar: calendar) }
    }

    public static func manualFormDefaults(from snap: Snapshot) -> (until: Date, indefinite: Bool, reason: String)? {
        guard let manual = snap.reasons.first(where: { $0.kind == "manual" }) else {
            if snap.blocked, let u = snap.effectiveUntilEpoch, u > 0, !isIndefiniteEpoch(u) {
                return (Date(timeIntervalSince1970: TimeInterval(u)), false, "")
            }
            return nil
        }
        if let u = manual.untilEpoch, u > 0, !isIndefiniteEpoch(u) {
            return (Date(timeIntervalSince1970: TimeInterval(u)), false, manual.detail)
        }
        if manual.untilEpoch == nil || isIndefiniteEpoch(manual.untilEpoch ?? 0) {
            return (.now.addingTimeInterval(3600), true, manual.detail)
        }
        return nil
    }

    /// True when a manual pause (yours) is part of the saved policy, so "Clear my pause" has something to clear.
    public static func hasManualPause(_ snap: Snapshot) -> Bool {
        !snap.loadFailed && snap.reasons.contains { $0.kind == "manual" }
    }

    /// The saved manual note, if any (shown read-only in the status, used as the field's placeholder).
    public static func currentManualNote(_ snap: Snapshot) -> String? {
        let d = snap.reasons.first { $0.kind == "manual" }?.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return (d?.isEmpty ?? true) ? nil : d
    }

    /// Placeholder for the note field: the saved note (kept if left empty) or a generic hint.
    public static func notePrompt(_ snap: Snapshot) -> String {
        if let n = currentManualNote(snap) { return "Keep: \(n)" }
        return "Why you're pausing (optional)"
    }

    /// What reason to save: what you typed, else the saved note, else a default. Never wipes the saved note.
    public static func reasonToSave(typed: String, snap: Snapshot) -> String {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        return currentManualNote(snap) ?? "Paused in Hmunmawi"
    }

    public static let indefiniteConfirmTitle = "Pause hub AI jobs indefinitely?"
    public static let indefiniteConfirmMessage = "Claude hub jobs stay deferred with no end time. Nothing resumes on its own: you clear it here (Clear my pause) when you want jobs back. Anthropic's own limits are not changed."
    public static let indefiniteExplainer = "No end time: hub AI jobs stay deferred until you clear the pause yourself."

  private static func isIndefiniteEpoch(_ epoch: Int) -> Bool {
        epoch > 4_000_000_000 // ~2096; policy uses large sentinel for indefinite
    }

    public static func formatUntil(_ epoch: Int, now: Date = .now, calendar: Calendar = .current) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(epoch))
        let fmt = DateFormatter()
        fmt.calendar = calendar
        fmt.timeZone = calendar.timeZone
        fmt.locale = .current
        fmt.dateStyle = .full
        fmt.timeStyle = .short
        if calendar.isDate(date, inSameDayAs: now) { fmt.doesRelativeDateFormatting = true }
        return fmt.string(from: date)
    }

    private static func explain(_ r: Reason, now: Date, calendar: Calendar) -> String {
        let untilBit: String = {
            guard let u = r.untilEpoch, u > 0, !isIndefiniteEpoch(u) else { return "" }
            return " (until \(formatUntil(u, now: now, calendar: calendar)))"
        }()
        switch (r.kind, r.source) {
        case ("manual", "user"):
            if r.detail.isEmpty { return "You set this pause\(untilBit)." }
            return "You set this pause: \(r.detail)\(untilBit)."
        case ("manual", _):
            return "Manual pause\(untilBit)\(r.detail.isEmpty ? "" : ": \(r.detail)")."
        case ("weekly", "migrated_ai_state"):
            return "Older weekly-limit record carried over from the previous ai_state file\(untilBit). Hub defers until the latest end time."
        case ("weekly", _):
            return "Weekly Claude limit\(untilBit)\(r.detail.isEmpty ? "" : " (\(r.detail))")."
        case ("daily", _):
            return "Daily limit\(untilBit)\(r.detail.isEmpty ? "" : ": \(r.detail)")."
        case ("session", _):
            return "Session limit\(untilBit)."
        default:
            let label = r.kind.isEmpty ? "Limit" : r.kind.capitalized
            return "\(label)\(untilBit)\(r.detail.isEmpty ? "" : " — \(r.detail)")"
        }
    }
}
