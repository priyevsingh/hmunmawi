import Foundation

/// "Check before adding" for an outreach candidate (a blog, podcast, newsletter or listing site): is the page
/// there, is there a way to reach them, do they only take paid placements, which language, and have you already
/// pitched them (same website or same address). Pure: the app fetches the page and passes the text in.
public enum OutreachCheck {
    public struct Result: Sendable, Equatable {
        public var status: Int?
        public var finalURL: String?
        public var emails: [String] = []
        public var contactForm = false
        public var contactPage: String?
        public var paidWords: [String] = []
        public var language: String?
        public var duplicateOf: [String] = []

        public init() {}

        /// ok | dead | paid_only | already_pitched | no_contact (the first that applies, in that order of weight).
        public var verdict: String {
            if !duplicateOf.isEmpty { return "already_pitched" }
            guard let status, (200..<400).contains(status) else { return "dead" }
            if !paidWords.isEmpty { return "paid_only" }
            if emails.isEmpty && !contactForm && contactPage == nil { return "no_contact" }
            return "ok"
        }

        /// One plain line for the app and for agents.
        public var summary: String {
            switch verdict {
            case "already_pitched": "Already on your list: \(duplicateOf.joined(separator: ", "))."
            case "dead": "The page didn't load (\(status.map { "answered \($0)" } ?? "no answer"))."
            case "paid_only": "Looks paid-only (\(paidWords.prefix(3).joined(separator: ", ")))."
            case "no_contact": "No email or contact form found on that page."
            default:
                "Reachable" + (emails.first.map { " at \($0)" } ?? (contactForm ? " through a contact form" : contactPage.map { " (contact page: \($0))" } ?? ""))
                    + (language.map { "; page language \($0)" } ?? "") + "."
            }
        }
    }

    /// Wording that means a placement costs money.
    public static let paidPhrases = ["sponsored post", "sponsored review", "paid review", "paid placement", "submission fee",
                                     "expedited review", "pay to be featured", "featured listing for $", "review fee",
                                     "pricing for app reviews", "we charge", "fast track your review"]

    /// Mail providers anyone can use: their domain never makes two outlets the same.
    public static let freeMail: Set<String> = ["gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "yahoo.com",
                                               "icloud.com", "me.com", "mac.com", "proton.me", "protonmail.com", "pm.me", "aol.com",
                                               "gmx.com", "gmx.de", "zoho.com", "yandex.com", "mail.com", "fastmail.com", "hey.com"]

    /// "https://www.Example.com/blog" -> "example.com"; "Jane <jane@Press.example>" -> "press.example".
    public static func domain(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let email = emails(in: t).first { return email.split(separator: "@").last.map(String.init) }
        let withScheme = t.contains("://") ? t : "https://" + t
        guard let host = URL(string: withScheme)?.host, host.contains(".") else { return nil }
        return LinkCheck.site(host)
    }

    /// Addresses written on a page (mailto: links and plain text), lowercased, each once; image names
    /// ("logo@2x.png") are not addresses.
    public static func emails(in text: String) -> [String] {
        var out: [String] = []
        for m in text.matches(of: /[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9.-]{1,190}\.[A-Za-z]{2,24}/) {
            let e = String(m.0).lowercased()
            guard ![".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg"].contains(where: e.hasSuffix),
                  !e.hasPrefix("example@"), !out.contains(e) else { continue }
            out.append(e)
        }
        return Array(out.prefix(5))
    }

    /// Reads a fetched page. `existing`: your outreach entries as (outlet name, its page or address).
    public static func check(html: String, status: Int?, finalURL: String?, candidateURL: String, candidateEmail: String? = nil,
                             existing: [(outlet: String, where: String)]) -> Result {
        var r = Result()
        r.status = status; r.finalURL = finalURL
        let lower = html.lowercased()
        r.emails = emails(in: html.replacingOccurrences(of: "mailto:", with: " "))
        r.contactForm = lower.range(of: #"<form[^>]*>[\s\S]{0,4000}?(type\s*=\s*["']?email|<textarea)"#, options: .regularExpression) != nil
        if let base = URL(string: finalURL ?? candidateURL) {
            r.contactPage = LinkCheck.links(in: html, base: base).first { u in
                let p = u.path.lowercased()
                return LinkCheck.site(u.host) == LinkCheck.site(base.host) && (p.contains("contact") || p.contains("submit") || p.contains("pitch") || p.contains("tips"))
            }?.absoluteString
        }
        r.paidWords = paidPhrases.filter { lower.contains($0) }
        if let m = html.firstMatch(of: /(?i)<html[^>]*\blang\s*=\s*["']?([A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})?)/) { r.language = String(m.1) }
        r.duplicateOf = duplicates(url: candidateURL, email: candidateEmail ?? r.emails.first, existing: existing)
        return r
    }

    /// Outlets on your list with the same website or the same address.
    public static func duplicates(url: String?, email: String?, outlet: String? = nil, existing: [(outlet: String, where: String)]) -> [String] {
        let wantDomain = url.flatMap(domain)
        let wantEmail = email.flatMap { emails(in: $0).first }
        let wantName = outlet?.trimmingCharacters(in: .whitespaces).lowercased()
        var out: [String] = []
        for e in existing {
            let sameName = wantName.map { !$0.isEmpty && $0 == e.outlet.trimmingCharacters(in: .whitespaces).lowercased() } ?? false
            let theirEmail = emails(in: e.where).first
            let sameEmail = wantEmail != nil && wantEmail == theirEmail
            // A shared mail provider (gmail.com) says nothing about the outlet.
            let sameDomain = wantDomain.map { !freeMail.contains($0) && $0 == domain(e.where) } ?? false
            if (sameName || sameEmail || sameDomain), !out.contains(e.outlet) { out.append(e.outlet) }
        }
        return out
    }
}
