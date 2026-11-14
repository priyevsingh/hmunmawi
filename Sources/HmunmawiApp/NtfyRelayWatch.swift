import Foundation
import HmunmawiCore

/// Puts real ntfy deliveries made by the App Store alerts relay (Cloudflare webhook or this Mac) into the ntfy row's
/// history, so the row shows when an alert last reached your phone. One row per new success or failure; read-only.
@MainActor
enum NtfyRelayWatch {
    /// The relay's files: set in defaults (HMNtfyRelayState / HMNtfyRelayLog) or by the owner config. None on a normal
    /// install, so nothing is read there.
    static var statePath: String? {
        UserDefaults.standard.string(forKey: "HMNtfyRelayState")
            ?? OwnerConfig.current.jobsDataURL?.appending(path: "asn_relay_state.json").path
    }
    static var logPath: String? {
        UserDefaults.standard.string(forKey: "HMNtfyRelayLog") ?? OwnerConfig.current.ntfyRelayLogURL?.path
            ?? OwnerConfig.current.hubURL?.appending(path: "out/logs/asn_relay.log").path
    }

    static func check(store: Store) async {
        guard let state = statePath, let log = logPath else { return }
        let latest = await Task.detached(priority: .utility) { () -> NtfyRelay.Latest in
            let s = smallFile(state, limit: 2_000_000)
            // Only the end of the log: the newest failures are there.
            var text: String?
            if let h = FileHandle(forReadingAtPath: log) {
                let size = (try? h.seekToEnd()) ?? 0
                try? h.seek(toOffset: size > 200_000 ? size - 200_000 : 0)
                text = (try? h.readToEnd()).flatMap { String(decoding: $0, as: UTF8.self) }
                try? h.close()
            }
            return NtfyRelay.latest(state: s, log: text)
        }.value
        let d = UserDefaults.standard
        let iso = ISO8601DateFormatter()
        var rows: [(Date, String, JSONValue)] = []
        if let s = latest.success, s.timeIntervalSince1970 > d.double(forKey: "HMNtfyRelaySuccess") {
            rows.append((s, "plugin.delivered", .object(["sent_at": .string(iso.string(from: s)),
                                                         "via": .string(latest.successVia ?? "relay"),
                                                         "from": .string("App Store alerts relay")])))
            d.set(s.timeIntervalSince1970, forKey: "HMNtfyRelaySuccess")
        }
        if let f = latest.failure, f.timeIntervalSince1970 > d.double(forKey: "HMNtfyRelayFailure") {
            rows.append((f, "plugin.delivery_failed", .object(["failed_at": .string(iso.string(from: f)),
                                                               "error": .string("The App Store alerts relay couldn't reach ntfy at \(f.formatted(date: .abbreviated, time: .shortened)); it tries again on its next run"),
                                                               "from": .string("App Store alerts relay")])))
            d.set(f.timeIntervalSince1970, forKey: "HMNtfyRelayFailure")
        }
        // Oldest first, so the newest outcome is the newest row.
        for (_, action, detail) in rows.sorted(by: { $0.0 < $1.0 }) {
            try? await store.appendAudit(actor: "ntfy", action: action, subject: "ntfy.sh", detail: detail)
        }
    }
}
