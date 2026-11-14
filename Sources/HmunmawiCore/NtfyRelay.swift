import Foundation

/// Real ntfy deliveries made outside Hmunmawi: the App Store alerts relay on this Mac (asn_relay.py) records each
/// alert that reached ntfy, sent either by the Cloudflare webhook ("cloudflare") or from the Mac itself (a time in
/// ms), and logs "ntfy FAILED" when a Mac send didn't get through. Read-only.
public enum NtfyRelay {
    public struct Latest: Equatable, Sendable {
        public var success: Date?
        public var successVia: String?
        public var successCount = 0
        public var failure: Date?
    }

    public static func latest(state: Data?, log: String?) -> Latest {
        var out = Latest()
        if let state, let root = try? JSONSerialization.jsonObject(with: state) as? [String: Any],
           let delivered = root["delivered"] as? [String: Any] {
            for case let rec as [String: Any] in delivered.values {
                let when: Date?, via: String
                if let ms = (rec["ntfy"] as? Double) ?? (rec["ntfy"] as? Int).map(Double.init) {
                    when = Date(timeIntervalSince1970: ms / 1000); via = "this Mac"
                } else if rec["ntfy"] as? String == "cloudflare" {
                    let seen = (rec["seen"] as? Double) ?? (rec["seen"] as? Int).map(Double.init)
                    when = seen.map { Date(timeIntervalSince1970: $0 / 1000) }; via = "Cloudflare"
                } else { continue }
                guard let when else { continue }
                out.successCount += 1
                if when > (out.success ?? .distantPast) { out.success = when; out.successVia = via }
            }
        }
        if let log {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd HH:mm:ssZ"
            for line in log.split(separator: "\n") where line.contains("ntfy FAILED") {
                guard let d = f.date(from: String(line.prefix(24))) else { continue }
                if d > (out.failure ?? .distantPast) { out.failure = d }
            }
        }
        return out
    }
}
