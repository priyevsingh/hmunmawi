import Foundation

/// How a connection row in Settings should read, from the activity log (newest first).
public enum ConnectionAudit {
    private static let failing: Set<String> = [
        "plugin.unresponsive", "plugin.start_failed", "plugin.poll_failed", "plugin.http_blocked", "plugin.flood",
        "plugin.delivery_failed",
    ]
    private static let succeeding: Set<String> = ["plugin.http", "plugin.mac", "plugin.delivered"]

    public struct RowDisplay: Equatable {
        public var label: String
        public var tone: Tone
        public var detail: String?

        public enum Tone: String { case good, caution, bad }

        public init(label: String, tone: Tone, detail: String?) {
            self.label = label
            self.tone = tone
            self.detail = detail
        }
    }

    public static func display(audit: [AuditEntry], actor: String, approved: Bool, missing: Bool,
                               coveredByFile: Bool = false, viaFileLabel: String? = nil) -> RowDisplay {
        if coveredByFile, let viaFileLabel { return RowDisplay(label: viaFileLabel, tone: .good, detail: nil) }
        if !approved { return RowDisplay(label: "Needs your OK", tone: .caution, detail: nil) }
        if missing { return RowDisplay(label: "Needs setup", tone: .caution, detail: nil) }

        let mine = audit.filter { $0.actor == actor }
        let recentFailure = mine.first { failing.contains($0.action) }
        let recentSuccess = mine.first { succeeding.contains($0.action) }
        if let s = recentSuccess, s.at > (recentFailure?.at ?? 0), s.subject == "xfile.read" {
            // X from your Mac's X file: fresh is green; an old file is amber with the plain reason.
            if s.detail[path: "status"]?.string == "stale" {
                return RowDisplay(label: "X file is out of date", tone: .caution,
                                  detail: s.detail[path: "reason"]?.string ?? "Your Mac's X file hasn't been updated lately.")
            }
            return RowDisplay(label: "Connected", tone: .good, detail: nil)
        }
        if let f = recentFailure, let s = recentSuccess, s.at > f.at {
            return RowDisplay(label: "Connected", tone: .good, detail: nil)
        }
        let recentRetry = mine.first { $0.action == "plugin.poll_retry" }
        if let r = recentRetry,
           (recentFailure == nil || r.at >= recentFailure!.at),
           (recentSuccess == nil || r.at >= recentSuccess!.at) {
            let raw = r.detail[path: "error"]?.string ?? Engine.pollTimeoutText
            let plain = raw.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? raw
            return RowDisplay(label: "Checking again", tone: .caution, detail: plain)
        }
        if let f = recentFailure, recentSuccess == nil || (recentSuccess?.at ?? 0) <= f.at {
            let raw = f.detail[path: "error"]?.string ?? "The last check failed"
            let plain = raw.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? raw
            if raw.hasPrefix("x_file_missing") {
                return RowDisplay(label: "X file missing", tone: .bad, detail: plain)
            }
            if plain.contains(Keychain.cantReadText) || plain.hasPrefix("keychain:") {
                return RowDisplay(label: "Last check failed", tone: .bad, detail: Keychain.cantReadText)
            }
            return RowDisplay(label: "Last check failed", tone: .bad, detail: plain)
        }
        return RowDisplay(label: "Connected", tone: .good, detail: nil)
    }
}
