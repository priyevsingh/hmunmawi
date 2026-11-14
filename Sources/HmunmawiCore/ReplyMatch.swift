import Foundation

/// Matches mail to outreach (pitches, listings, forms): which incoming message is a reply to which entry, which
/// listing mail changes a status, and which sent message is the follow-up. Pure: no files, no network.
///
/// Sure matches (applied on their own): the message comes from the address or the domain the outreach went to, or
/// it's in the same thread (same subject after "Re:"/"Fwd:"). Name-only matches (the outlet's name appears in the
/// sender or subject) are only suggestions: names like "Indie App Catalog" and indie-apps.com look alike but differ.
public enum ReplyMatch {
    public struct Entry: Sendable, Equatable {
        public var id: String
        public var outlet: String
        public var contact: String?      // the address it went to (or just its domain)
        public var subject: String?      // the subject it was sent with
        public var date: String          // YYYY-MM-DD it was sent or submitted
        public var status: String
        public var followUp: String?     // YYYY-MM-DD the follow-up is due, if any
        public var app: String?          // the app(s) it was about ("Pulse Diary+Lift Crew")
        public var type: String?         // press pitch, contact form, directory, review site, forum post, social
        public var site: String?         // the outlet's own web address, if known
        public init(id: String, outlet: String, contact: String? = nil, subject: String? = nil, date: String,
                    status: String, followUp: String? = nil, app: String? = nil, type: String? = nil, site: String? = nil) {
            self.id = id; self.outlet = outlet; self.contact = contact; self.subject = subject
            self.date = date; self.status = status; self.followUp = followUp; self.app = app; self.type = type; self.site = site
        }
        /// A listing (directory, review site, forum, social): its mail is a decision or a notice, never a "reply".
        var isListing: Bool { !["press pitch", "contact form"].contains((type ?? "press pitch").lowercased()) }
    }

    public struct Mail: Sendable, Equatable {
        public var id: String
        public var from: String
        public var subject: String
        public var folder: String        // INBOX, SENT, NEWSLETTER, NOTIFICATION…
        public var day: String           // YYYY-MM-DD first seen
        public var at: Double?           // seconds since 1970 it was first seen, when known (pairs a bounce with its send)
        public var messageID: String?    // its Message-ID header, when read
        public var inReplyTo: String?    // the Message-ID it answers, when read
        public var text: String?         // their new words only (no quotes, signature), when read
        public init(id: String, from: String, subject: String, folder: String, day: String, at: Double? = nil,
                    messageID: String? = nil, inReplyTo: String? = nil, text: String? = nil) {
            self.id = id; self.from = from; self.subject = subject; self.folder = folder; self.day = day; self.at = at
            self.messageID = messageID; self.inReplyTo = inReplyTo; self.text = text
        }
        public var sent: Bool { folder.uppercased() == "SENT" }
    }

    public enum Kind: String, Sendable { case replied, approved, live, rejected, verify, followedUp = "followed up", autoReply = "auto-reply", notice, bounced }
    public enum Sure: String, Sendable { case sure, unsure }

    public struct Match: Sendable, Equatable {
        public var entry: String
        public var mail: String
        public var kind: Kind
        public var sure: Sure
        public var why: String
    }

    /// Statuses that still wait on the other side (a reply or a decision can still come).
    public static let open: Set<String> = ["submitted", "pending review", "no reply"]

    /// Free mail providers: the same domain says nothing about who wrote.
    static let shared: Set<String> = ["gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "yahoo.com",
                                      "icloud.com", "me.com", "mac.com", "proton.me", "protonmail.com", "protonmail.ch",
                                      "zoho.com", "zohomail.com", "aol.com", "gmx.com", "fastmail.com"]

    /// Matches, at most one per entry and message (the surest wins). `own` is your own address or domain, so your
    /// messages never count as replies.
    /// `apps` are your app names: a message that names one of them only matches entries about that app.
    public static func match(_ entries: [Entry], mail: [Mail], own: [String], apps: [String] = []) -> [Match] {
        let ownDomains = Set(own.map { domain($0) ?? $0.lowercased() })
        func mine(_ m: Mail) -> Bool { domain(m.from).map(ownDomains.contains) ?? false || own.contains(address(m.from)) }
        // A bounce names nobody: it belongs to the message you sent last before it (within 2 hours).
        let sentByTime = mail.filter { $0.sent && $0.at != nil && mine($0) }.sorted { $0.at! < $1.at! }
        // A bounce whose text was read names the address that failed: that's certain. Without its text, the message
        // sent just before it is only a guess (several pitches often go out within minutes), so it's a "maybe".
        var bouncedAddress: [String: String] = [:]                      // failed address -> bounce message
        var bouncedThread: [String: (id: String, close: Bool)] = [:]   // thread -> bounce message (guessed by time)
        for b in mail where isSystem(b.from) && isBounce(b.subject) {
            if let text = b.text, text.contains("@") {
                for a in text.lowercased().matches(of: /[a-z0-9._%+-]+@[a-z0-9-]+\.[a-z0-9.-]+/) { bouncedAddress[String(a.output)] = b.id }
                continue
            }
            guard let t = b.at, let s = sentByTime.last(where: { $0.at! <= t && t - $0.at! <= 7200 }) else { continue }
            bouncedThread[thread(s.subject)] = (b.id, false)
        }
        // Your sent messages by Message-ID, as threads: a reply that names one of them is in that thread, whatever its subject.
        var sentThread: [String: String] = [:]
        for m in mail where m.sent && mine(m) { if let id = m.messageID, !id.isEmpty { sentThread[id] = thread(m.subject) } }
        var out: [Match] = []
        for e in entries {
            let contactAddr = e.contact.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
            let contactDomain = e.contact.flatMap(domain)
            let subj = e.subject.map(thread)
            let name = compact(e.outlet)
            let siteDomain = e.site.flatMap(domain)
            let entryApps = Set((e.app ?? "").split(separator: "+").map { compact(String($0)) }.filter { !$0.isEmpty })
            var best: Match?
            if let a = contactAddr, let b = bouncedAddress[a] {
                best = Match(entry: e.id, mail: b, kind: .bounced, sure: .sure, why: "the bounce names \(a)")
            } else if let s = subj, !s.isEmpty, let b = bouncedThread[s] {
                best = Match(entry: e.id, mail: b.id, kind: .bounced, sure: .unsure, why: "a bounce came soon after you sent it (check which address failed)")
            }
            for m in mail where m.day >= e.date {
                let fromAddr = address(m.from), fromDomain = domain(m.from)
                if let d = fromDomain, ownDomains.contains(d) || own.contains(fromAddr) {
                    // Yours: a sent follow-up in the same thread closes the follow-up.
                    if m.sent, let s = subj, !s.isEmpty, thread(m.subject) == s, e.followUp != nil, m.day > e.date {
                        best = better(best, Match(entry: e.id, mail: m.id, kind: .followedUp, sure: .sure, why: "your follow-up in the same thread"))
                    }
                    continue
                }
                if m.sent { continue }
                // Bounces and mail-system notices never count (they name your subject, but nobody read it).
                if isSystem(m.from) { continue }
                // Mail about another of your apps isn't about this entry (one site, one entry per app).
                let named = Set(apps.map(compact).filter { !$0.isEmpty && compact(m.subject).contains($0) })
                if !named.isEmpty, !entryApps.isEmpty, named.isDisjoint(with: entryApps) { continue }
                var kind = kindOf(m.subject)
                if kind == .replied, e.isListing || ThreadState.isRobot(m.from) { kind = .notice }   // a mailer is never a person's reply
                var sure: Sure?, why = ""
                if let r = m.inReplyTo, let t = sentThread[r], let s = subj, !s.isEmpty, t == s { sure = .sure; why = "answers your mail" }
                else if let a = contactAddr, a.contains("@"), a == fromAddr { sure = .sure; why = "from \(a)" }
                else if let d = contactDomain, !shared.contains(d), d == fromDomain { sure = .sure; why = "from \(d)" }
                else if let s = subj, !s.isEmpty, thread(m.subject) == s { sure = .sure; why = "same thread" }
                else if let d = siteDomain, d == fromDomain { sure = .sure; why = "from \(d)" }
                // A name alone: only when the outlet's own domain isn't known to be a different one.
                else if name.count >= 5, siteDomain == nil || siteDomain == fromDomain,
                        compact(fromDomain ?? "").contains(name) || compact(m.from).contains(name) || compact(m.subject).contains(name) {
                    sure = .unsure; why = "names \(e.outlet)"
                }
                guard let sure else { continue }
                best = better(best, Match(entry: e.id, mail: m.id, kind: kind, sure: sure, why: why))
            }
            if let best { out.append(best) }
        }
        return out
    }

    /// A status change a match implies for an entry in `status`, or nil when nothing changes (already further on).
    public static func newStatus(_ kind: Kind, from status: String) -> String? {
        switch kind {
        case .replied: open.contains(status) ? "replied" : nil
        case .approved: ["submitted", "pending review", "no reply", "replied"].contains(status) ? "approved" : nil
        case .live: status == "live" ? nil : (status == "rejected" ? nil : "live")
        case .rejected: open.contains(status) ? "rejected" : nil
        case .bounced: open.contains(status) ? "bounced" : nil
        case .verify, .followedUp, .autoReply, .notice: nil
        }
    }

    /// What a message's subject says: a listing decision, a "confirm your email", or (otherwise) a reply.
    public static func kindOf(_ subject: String) -> Kind {
        let s = subject.lowercased()
        // "Still waiting for review", "in the queue": news about a listing, not a decision.
        if ["waiting for review", "waiting in", "in review", "under review", "in the queue", "review queue", "still waiting",
            "received your submission", "thanks for submitting", "we got your"].contains(where: s.contains) { return .notice }
        // Out-of-office and other automatic answers aren't a reply from a person: the follow-up stays.
        if ["automatic reply", "auto reply", "auto-reply", "autoreply", "out of office", "out of the office", "ooo:",
            "away from", "on vacation", "on leave", "abwesenheit"].contains(where: s.contains) { return .autoReply }
        if ["confirm your e-mail", "confirm your email", "verify your email", "verify your e-mail", "confirm your account",
            "verify your account", "activate your account"].contains(where: s.contains)
            || s.range(of: #"(confirm|verify|activate) your .{0,40}(account|e-?mail)"#, options: .regularExpression) != nil { return .verify }
        if ["rejected", "declined", "not approved", "was not accepted", "unable to approve"].contains(where: s.contains) { return .rejected }
        if [" is live", "is now live", "now listed", "published", "went live"].contains(where: s.contains) { return .live }
        if ["approved", "accepted"].contains(where: s.contains) { return .approved }
        return .replied
    }

    /// A delivery failure ("Undelivered Mail Returned to Sender", "Delivery Status Notification (Failure)").
    static func isBounce(_ subject: String) -> Bool {
        let s = subject.lowercased()
        return ["undeliver", "returned to sender", "delivery status notification", "delivery failure", "failure notice",
                "mail delivery failed", "could not be delivered", "delivery has failed"].contains(where: s.contains)
    }

    /// Mail-system senders: bounces and delivery notices.
    static func isSystem(_ from: String) -> Bool {
        let a = address(from)
        return ["mailer-daemon", "postmaster", "mail-daemon", "bounce", "no-reply@accounts."].contains(where: a.contains)
    }

    // MARK: Pieces

    /// The subject without "Re:", "Fwd:", "AW:" and the like, lowercased: the thread it belongs to.
    public static func thread(_ subject: String) -> String {
        var s = subject.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while let r = s.range(of: #"^(re|fw|fwd|aw|wg|sv|antw)\s*(\[\d+\])?\s*:\s*"#, options: .regularExpression) { s.removeSubrange(r) }
        return s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    /// The address inside "Name <a@b.c>", or the text itself, lowercased.
    static func address(_ from: String) -> String {
        let f = from.lowercased()
        if let r = f.range(of: #"<[^>]+>"#, options: .regularExpression) { return String(f[r].dropFirst().dropLast()) }
        return f.trimmingCharacters(in: .whitespaces)
    }

    /// "news@mail.example.com" → "example.com"; nil when there's no domain.
    public static func domain(_ text: String) -> String? {
        var a = address(text)
        // A web address: just its host ("https://www.saashub.com/x" → "www.saashub.com").
        if a.contains("://") { a = URL(string: a)?.host?.lowercased() ?? "" }
        else if let slash = a.firstIndex(of: "/"), !a.contains("@") { a = String(a[..<slash]) }
        let host = a.contains("@") ? String(a.split(separator: "@").last ?? "") : (a.contains(".") && !a.contains(" ") ? a : "")
        let parts = host.split(separator: ".").map(String.init).filter { !$0.isEmpty }
        guard parts.count >= 2 else { return nil }
        // Keep two labels, three for "co.uk"-style endings.
        let two = ["co", "com", "org", "net", "ac", "gov"].contains(parts[parts.count - 2]) && parts.last!.count == 2 && parts.count >= 3
        return parts.suffix(two ? 3 : 2).joined(separator: ".")
    }

    /// Letters and digits only, without a trailing "(podcast)" or "(news post)": "Mac Geek Gab (podcast)" → "macgeekgab".
    static func compact(_ s: String) -> String {
        let base = s.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
        return base.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func better(_ a: Match?, _ b: Match) -> Match {
        guard let a else { return b }
        if a.sure != b.sure { return a.sure == .sure ? a : b }
        // A decision (approved, live, rejected) says more than a plain reply; otherwise the newer message wins.
        let rank: (Kind) -> Int = { [.rejected: 4, .live: 3, .approved: 2, .replied: 1, .followedUp: 1, .verify: 0, .notice: 0, .autoReply: -1, .bounced: 5][$0] ?? 0 }
        return rank(b.kind) >= rank(a.kind) ? b : a
    }
}
