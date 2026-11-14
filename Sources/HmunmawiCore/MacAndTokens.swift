import CryptoKit
import Foundation

/// Things only the signed app may do (macOS grants these permissions per app), offered to add-ons that declare them.
public protocol MacAbilities: Sendable {
    func perform(_ ability: String, params: JSONValue) async throws -> JSONValue
}

/// Builds the short-lived App Store Connect API token inside the app, so the .p8 key never reaches an add-on.
enum AppStoreConnectToken {
    static let requiredSecrets = ["keyID", "issuerID", "privateKey"]

    static func make(keyID: String, issuerID: String, privateKeyPEM: String, now: Date = .now) throws -> String {
        let key: P256.Signing.PrivateKey
        do {
            key = try P256.Signing.PrivateKey(pemRepresentation: normalizedPEM(privateKeyPEM))
        } catch {
            throw WireError("bad_key", "The App Store Connect private key could not be read; paste the whole .p8 file")
        }
        let issuedAt = Int(now.timeIntervalSince1970)
        let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyID, "typ": "JWT"],
                                                options: [.sortedKeys])
        let payload = try JSONSerialization.data(withJSONObject: ["iss": issuerID, "iat": issuedAt,
                                                                  "exp": issuedAt + 1200, "aud": "appstoreconnect-v1"],
                                                 options: [.sortedKeys])
        let signingInput = base64URL(header) + "." + base64URL(payload)
        let signature = try key.signature(for: Data(signingInput.utf8))
        return signingInput + "." + base64URL(signature.rawRepresentation)
    }

    /// Rebuilds the PEM layout when a key was pasted as one line.
    static func normalizedPEM(_ text: String) -> String {
        let begin = "-----BEGIN PRIVATE KEY-----", end = "-----END PRIVATE KEY-----"
        var body = text.replacingOccurrences(of: begin, with: "").replacingOccurrences(of: end, with: "")
        body.removeAll { $0.isWhitespace }
        var lines: [String] = []
        var rest = Substring(body)
        while !rest.isEmpty {
            lines.append(String(rest.prefix(64)))
            rest = rest.dropFirst(64)
        }
        return ([begin] + lines + [end]).joined(separator: "\n")
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Plain-language description of a job waiting for approval: what it will do, and why.
public enum JobText {
    static let channels = ["imessage": "iMessage", "ntfy": "ntfy (phone)", "notification": "Mac notification"]

    public static func title(_ job: Job) -> String {
        if job.kind == "agent.request", case .object(let p) = job.payload, let s = p["summary"]?.string {
            let reason = p["reason"]?.string ?? ""
            return reason.isEmpty ? s : "\(s) · \(reason)"
        }
        let channel = channels[job.resource] ?? job.resource
        return job.kind == "notify" ? "Send an alert by \(channel)" : "Run “\(job.kind)” with \(channel)"
    }

    /// "Send an alert by iMessage · timed out"
    public static func failure(_ job: Job) -> String {
        let error = job.lastError ?? ""
        let reason = error.hasPrefix("timeout") ? "timed out"
            : error.hasPrefix("crashed") ? "the add-on stopped"
            : error.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? "failed"
        return "\(title(job)) · \(reason.prefix(60))"
    }

    public static func detail(_ job: Job, event: StoredEvent?, ruleName: String?) -> String {
        var parts: [String] = []
        if let event { parts.append(EventText.describe(event)) }
        if let ruleName { parts.append("rule: \(ruleName)") }
        return parts.isEmpty ? "Started by hand" : parts.joined(separator: " · ")
    }
}

/// Plain-language text for alerts.
public enum EventText {
    public static func describe(_ event: StoredEvent) -> String {
        let app = event.app ?? "your app"
        switch event.kind {
        case "testflight.feedback":
            let type = event.payload[path: "type"]?.string == "crash" ? "crash report" : "feedback"
            let comment = event.payload[path: "comment"]?.string.map { ": \u{201C}\($0.prefix(120))\u{201D}" } ?? ""
            return "TestFlight \(type) for \(app)\(comment)"
        case "ci.build":
            let n = event.payload[path: "number"]?.number.map { " #\(Int(safe: $0))" } ?? ""
            let status = (event.payload[path: "status"]?.string ?? "").lowercased()
            return "Xcode Cloud build\(n) for \(app): \(status == "succeeded" ? "passed" : status == "failed" || status == "errored" ? "failed" : status)"
        case "revenue.purchase": return "New sale for \(app)"
        case "revenue.refund": return "Refund for \(app)"
        case "revenue.renewal": return "Subscription renewed for \(app)"
        case "story.win", "story.worry":
            return event.payload[path: "title"]?.string ?? (event.kind == "story.win" ? "A win for \(app)" : "A worry for \(app)")
        case "story.digest": return event.payload[path: "text"]?.string ?? "Today's story"
        case "routine.tell": return event.payload[path: "text"]?.string ?? "A routine has news"
        case "story.weekly": return event.payload[path: "text"]?.string ?? "Your week"
        case "usage.status":
            let service = event.payload[path: "service"]?.string ?? "A service"
            let pct = event.payload[path: "used_percent"]?.number.map { "\(Int(safe: $0))%" } ?? "?"
            return "\(service) is at \(pct) of its limit"
        case "offercodes.status":
            let offer = event.payload[path: "offer"]?.string.map { "Offer code \($0)" } ?? "An offer code"
            let left = event.payload[path: "left"]?.number, total = event.payload[path: "total"]?.number
            let days = event.payload[path: "days_to_expiry"]?.number
            let count = left.map { l in "\(Int(safe: l).formatted()) of \(total.map { Int(safe: $0).formatted() } ?? "?") left" }
            let ends = days.map { d in d <= 0 ? "expired" : "expires in \(Int(safe: d)) day\(Int(safe: d) == 1 ? "" : "s")" }
            return "\(app == "your app" ? "" : app + ": ")\(offer) " + [count, ends].compactMap { $0 }.joined(separator: ", ")
        case "expiry.status":
            let what = [event.payload[path: "kind"]?.string, event.payload[path: "name"]?.string].compactMap { $0 }.joined(separator: " ")
            let days = event.payload[path: "days_left"]?.number.map { Int(safe: $0) }
            return "\(what.isEmpty ? "Something" : what) " + (days.map { $0 <= 0 ? "has expired" : "expires in \($0) day\($0 == 1 ? "" : "s")" } ?? "expires soon")
        case "review.new":
            let stars = event.payload[path: "rating"]?.number.map { "\(Int(safe: $0))★ " } ?? ""
            let title = event.payload[path: "title"]?.string.map { ": “\($0)”" } ?? ""
            return "\(stars)review for \(app)\(title)"
        case "revenue.daily":
            let units = event.payload[path: "units"]?.number.map { String(Int(safe: $0)) } ?? "?"
            return "\(app): \(units) downloads on \(event.payload[path: "day"]?.string ?? "the day")"
        case "revenue.cancelled": return "Subscription cancelled for \(app)"
        case "revenue.expired": return "Subscription expired for \(app)"
        case "revenue.billing_issue": return "Billing issue for \(app)"
        case "revenue.free": return "Free redemption for \(app)"
        case "crash.daily":
            let crashed = event.payload[path: "crashed"]?.number.map { String(Int(safe: $0)) } ?? "?"
            return "\(app): \(crashed) crashes in 24 hours"
        case "job.failed": return "Mac job “\(app)” failed"
        case "job.finished": return "Mac job “\(app)” finished"
        case "quota.high": return event.payload[path: "title"]?.string ?? "A service is near its request limit"
        case "rating.drop": return event.payload[path: "title"]?.string ?? "\(app): rating fell"
        case "asc.webhook": return event.payload[path: "title"]?.string ?? "An App Store Connect update"
        case "mail.reply": return "Email: \(event.payload[path: "subject"]?.string ?? "new message")"
        case "outreach.due": return "Follow up with \(event.payload[path: "outlet"]?.string ?? "an outlet")"
        case "site.down": return "\(app) has pages down"
        case "disk.low": return "Disk space low on this Mac"
        case "analytics.daily_users":
            guard let users = event.payload[path: "users"]?.number.map({ Int(safe: $0).formatted() }) else { return "Daily visitors for \(app)" }
            return "\(app): \(users) daily users"
        default:
            // Never a raw code ("asc.access"): the first part of the kind in words, else a plain fallback.
            let words = ["revenue": "A sales update", "review": "A review update", "reviews": "A review update", "asc": "An App Store update",
                         "ci": "A build update", "crash": "A crash update", "growth": "A reach update", "analytics": "A visitors update",
                         "expiry": "A date to watch", "finance": "A payout update", "subscription": "A subscribers update",
                         "testflight": "A TestFlight update", "release": "A release update", "versions": "A release update"]
            let head = String(event.kind.split(separator: ".").first ?? "")
            return "\(words[head] ?? "An update") for \(app)"
        }
    }
}
