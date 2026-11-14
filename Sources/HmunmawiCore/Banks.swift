import Foundation

/// A bank of prepared items (post drafts, captions): used first, before any AI is asked. One JSON file per bank,
/// `{"items": [{"id", "text", "tag"?, "used_on"?: "YYYY-MM-DD"}]}`, editable by you, agents or your scripts.
public struct BankItem: Codable, Sendable, Equatable {
    public var id: String
    public var text: String
    public var tag: String?
    public var used_on: String?
    public init(id: String, text: String, tag: String? = nil, used_on: String? = nil) {
        self.id = id; self.text = text; self.tag = tag; self.used_on = used_on
    }
}

public enum Bank {
    /// The next item to use: never used, or last used at least `reuseDays` ago; oldest-unused first, file order
    /// otherwise. Items the guard refuses are skipped.
    /// `score`: when given, the best-scoring draft goes first (ties: the one unused longest).
    public static func next(_ items: [BankItem], today: String, reuseDays: Int = 14, allowed: (BankItem) -> Bool = { _ in true },
                            score: ((BankItem) -> Double)? = nil) -> BankItem? {
        guard let t = DayNumber.of(today) else { return nil }
        let fresh = items.filter { i in
            guard !i.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            guard let u = i.used_on.flatMap(DayNumber.of) else { return true }
            return t - u >= reuseDays
        }
        let byAge = fresh.sorted { ($0.used_on ?? "") < ($1.used_on ?? "") }
        guard let score else { return byAge.first(where: allowed) }
        let ranked = byAge.enumerated().sorted { a, b in
            let (sa, sb) = (score(a.element), score(b.element))
            return sa != sb ? sa > sb : a.offset < b.offset
        }.map(\.element)
        return ranked.first(where: allowed)
    }

    /// Items still unused (or free again), for "the bank is running low".
    public static func available(_ items: [BankItem], today: String, reuseDays: Int = 14) -> Int {
        guard let t = DayNumber.of(today) else { return 0 }
        return items.filter { i in i.used_on.flatMap(DayNumber.of).map { t - $0 >= reuseDays } ?? true }.count
    }
}

/// Checks a draft against the facts before it goes out (like a release-version guard): a draft naming an app's
/// version that isn't its current one is refused, so an old "4.1.5 is out" never goes out after 4.1.7 shipped.
public enum DraftGuard {
    /// `versions`: app name -> current version ("Pulse Diary" -> "4.1.7"). Returns why it's refused, or nil.
    public static func problem(_ text: String, versions: [String: String], maxLength: Int? = nil) -> String? {
        if let maxLength, text.count > maxLength { return "longer than \(maxLength) characters" }
        for (app, current) in versions {
            // Version-looking words (4.1.5, v2.0) within a few words after the app's name ("iOS 26.1" later on is not the app's).
            var near: [String] = []
            var search = text.startIndex..<text.endIndex
            while let r = text.range(of: app, options: .caseInsensitive, range: search) {
                let window = text[r.upperBound..<(text.index(r.upperBound, offsetBy: 16, limitedBy: text.endIndex) ?? text.endIndex)]
                if let m = window.firstMatch(of: /^\W{0,3}(?:version\s+|v)?(\d+\.\d+(?:\.\d+)?)/) { near.append(String(m.1)) }
                search = r.upperBound..<text.endIndex
            }
            for v in near {
                if v != current, !current.hasPrefix(v + "."), !(v.split(separator: ".").count == 2 && current.hasPrefix(v)) {
                    return "mentions \(app) \(v), but \(current) is current"
                }
            }
        }
        return nil
    }
}

/// Outreach you've done (press pitches, listings, forum posts), with at most one follow-up per outlet.
/// `{"entries": [{"outlet", "app", "type", "status", "date", "follow_up"?: "YYYY-MM-DD", "followed_up"?: true}]}`
public struct OutreachEntry: Codable, Sendable, Equatable {
    public var outlet: String
    public var app: String
    public var type: String
    public var status: String
    public var date: String
    public var follow_up: String?
    public var followed_up: Bool?
    public var followed_up_on: String?   // YYYY-MM-DD the one follow-up went out
    public var contact: String?          // the address it went to (or a web form's domain)
    public var subject: String?          // the subject it was sent with
    public var url: String?              // the listing's or outlet's page
    public init(outlet: String, app: String, type: String, status: String, date: String, follow_up: String? = nil, followed_up: Bool? = nil,
                contact: String? = nil, subject: String? = nil, url: String? = nil) {
        self.outlet = outlet; self.app = app; self.type = type; self.status = status; self.date = date
        self.follow_up = follow_up; self.followed_up = followed_up; self.contact = contact; self.subject = subject; self.url = url
    }

    /// Due (today or overdue) and not yet followed up.
    public func due(today: String) -> Bool {
        guard followed_up != true, let f = follow_up.flatMap(DayNumber.of), let t = DayNumber.of(today) else { return false }
        return f <= t
    }
}

/// Whether a connection's error reads like its key or login stopped working (refused, expired, revoked), as
/// opposed to a passing outage. Used to tell you to reconnect, once, instead of failing quietly for days.
public enum KeyTrouble {
    static let words = ["401", "403", "unauthor", "forbidden", "invalid_grant", "invalid grant", "expired",
                        "revoked", "invalid token", "invalid_token", "invalid api key", "invalid key", "authentication",
                        "not authorized", "not authorised", "permission denied", "access denied", "reauth", "sign in again"]
    public static func isKeyProblem(_ error: String) -> Bool {
        let e = error.lowercased()
        // "timed out", "offline" and server errors are outages, not keys.
        // Server errors only as a status code on its own ("request 7f500a1c" or "1500 ms" isn't one).
        let serverError = e.range(of: "(^|[^0-9])50[0-4]([^0-9]|$)", options: .regularExpression) != nil
        let keyWords = ["401", "403", "unauthor", "forbidden", "invalid_grant", "invalid api key", "revoked", "expired"]
        if serverError || ["timed out", "timeout", "offline", "could not connect"].contains(where: e.contains),
           !keyWords.contains(where: e.contains) { return false }
        // "refused" alone is often the network ("Connection refused"); only with a key word is it about the key.
        if e.contains("refused"), ["key", "token", "auth", "credential", "login", "password"].contains(where: e.contains) { return true }
        return words.contains { w in
            guard w.allSatisfy(\.isNumber) else { return e.contains(w) }
            // A status code on its own, not inside a longer number ("14010 bytes").
            return e.range(of: "(^|[^0-9])\(w)([^0-9]|$)", options: .regularExpression) != nil
        }
    }
}
