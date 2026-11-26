import Testing
@testable import HmunmawiCore

@Suite struct ReplyMatchTests {
    let own = ["me@mydomain.example"]

    /// A podcaster answered in the pitch thread from the address it went to.
    @Test func replyFromThePitchedAddressIsSure() {
        let e = ReplyMatch.Entry(id: "mgg", outlet: "Example Podcast (podcast)", contact: "feedback@podcast.example",
                                 subject: "Listener apps: MyApp, my readiness app", date: "2026-10-29",
                                 status: "submitted", followUp: "2026-11-05")
        let mail = [
            ReplyMatch.Mail(id: "s", from: "me@mydomain.example", subject: "Listener apps: MyApp, my readiness app", folder: "SENT", day: "2026-10-29"),
            ReplyMatch.Mail(id: "r", from: "feedback@podcast.example", subject: "Re: Listener apps: MyApp, my readiness app", folder: "", day: "2026-11-04"),
        ]
        let m = ReplyMatch.match([e], mail: mail, own: own)
        #expect(m == [ReplyMatch.Match(entry: "mgg", mail: "r", kind: .replied, sure: .sure, why: "from feedback@podcast.example")])
        #expect(ReplyMatch.newStatus(.replied, from: "submitted") == "replied")
    }

    /// The same thread counts even without a stored address (a colleague answered from another address).
    @Test func sameThreadWithoutAddress() {
        let e = ReplyMatch.Entry(id: "x", outlet: "Some Blog", subject: "PITCH: AppA", date: "2026-10-20", status: "submitted")
        let m = ReplyMatch.match([e], mail: [ReplyMatch.Mail(id: "1", from: "Jane <jane@other.com>", subject: "RE: Fwd: pitch: appa", folder: "INBOX", day: "2026-10-22")], own: own)
        #expect(m.first?.sure == .sure && m.first?.why == "same thread")
    }

    /// Listing sites: Directory's "approved" and Indie Apps' "is live" mails.
    @Test func listingDecisions() {
        #expect(ReplyMatch.kindOf("✅ AppB was approved") == .approved)
        #expect(ReplyMatch.kindOf("AppA: Health Widgets is live") == .live)
        #expect(ReplyMatch.kindOf("Confirm your e-mail | Alternatives Site") == .verify)
        #expect(ReplyMatch.kindOf("Your submission was rejected") == .rejected)
        #expect(ReplyMatch.kindOf("Confirm your Dev Forum account") == .verify)
        #expect(ReplyMatch.kindOf("Automatic reply: Cool Stuff Made") == .autoReply)
        #expect(ReplyMatch.newStatus(.live, from: "pending review") == "live")
        #expect(ReplyMatch.newStatus(.approved, from: "live") == nil)   // never backwards
    }

    /// Name-only is a suggestion; a shared mail provider's domain proves nothing; bounces never count.
    @Test func unsureSharedAndBounces() {
        let saas = ReplyMatch.Entry(id: "s", outlet: "Directory", date: "2026-10-27", status: "pending review")
        let gm = ReplyMatch.Entry(id: "g", outlet: "Tiny Podcast", contact: "host@gmail.com", date: "2026-10-27", status: "submitted")
        let mail = [
            ReplyMatch.Mail(id: "a", from: "stan@directory.example", subject: "✅ AppA Health Widgets was approved", folder: "INBOX", day: "2026-10-30"),
            ReplyMatch.Mail(id: "b", from: "someoneelse@gmail.com", subject: "hello", folder: "INBOX", day: "2026-10-30"),
            ReplyMatch.Mail(id: "c", from: "mailer-daemon@mail.provider.example", subject: "Undelivered Mail Returned to Sender", folder: "INBOX", day: "2026-10-30"),
        ]
        let m = ReplyMatch.match([saas, gm], mail: mail, own: own)
        #expect(m.count == 1)
        #expect(m.first?.entry == "s" && m.first?.sure == .unsure && m.first?.kind == .approved)
    }

    /// Your follow-up in the same thread closes the follow-up; mail before the pitch never matches.
    @Test func followUpSentAndOrdering() {
        let e = ReplyMatch.Entry(id: "f", outlet: "Some Blog", contact: "tips@blog.example", subject: "AppA pitch", date: "2026-10-11",
                                 status: "submitted", followUp: "2026-10-18")
        let mail = [
            ReplyMatch.Mail(id: "old", from: "tips@blog.example", subject: "newsletter", folder: "INBOX", day: "2026-10-01"),
            ReplyMatch.Mail(id: "fu", from: "me@mydomain.example", subject: "Re: AppA pitch", folder: "SENT", day: "2026-10-19"),
        ]
        let m = ReplyMatch.match([e], mail: mail, own: own)
        #expect(m == [ReplyMatch.Match(entry: "f", mail: "fu", kind: .followedUp, sure: .sure, why: "your follow-up in the same thread")])
        #expect(ReplyMatch.domain("News <news@mail.example.co.uk>") == "example.co.uk")
        #expect(ReplyMatch.domain("https://www.directory.example/appb-alternatives") == "directory.example")
        #expect(ReplyMatch.domain("indielist.example/app/x") == "indielist.example")
        #expect(ReplyMatch.thread("Re: AW: Fwd:  Hello   World") == "hello world")
    }

    @Test func isOwnMatchesOwnAddressAndCustomDomainButNotSharedProvidersForStrangers() {
        #expect(ReplyMatch.isOwn("me@mydomain.example", own: own))
        #expect(ReplyMatch.isOwn("My Name <me@mydomain.example>", own: own))
        #expect(ReplyMatch.isOwn("team@mydomain.example", own: own))
        #expect(!ReplyMatch.isOwn("stranger@otherdomain.example", own: own))

        let sharedOwn = ["owner@gmail.com"]
        #expect(ReplyMatch.isOwn("owner@gmail.com", own: sharedOwn))
        #expect(ReplyMatch.isOwn("Owner <owner@gmail.com>", own: sharedOwn))
        #expect(!ReplyMatch.isOwn("stranger@gmail.com", own: sharedOwn))
    }
}

/// Found on the real outreach list (4 Nov 2026).
@Suite struct ReplyMatchRealCases {
    let own = ["me@mydomain.example"]
    let apps = ["AppA", "AppB", "AppC"]

    @Test func waitingNoticeIsNotAReply() {
        let e = ReplyMatch.Entry(id: "a", outlet: "Alternatives Site", date: "2026-10-27", status: "pending review", app: "AppB", type: "directory", site: "https://alternatives.example/software/appb")
        let m = ReplyMatch.match([e], mail: [ReplyMatch.Mail(id: "1", from: "support@alternatives.example", subject: "Last reminder: AppB is still waiting for review", folder: "NEWSLETTER", day: "2026-11-01")], own: own, apps: apps)
        #expect(m.first?.kind == .notice)
        #expect(ReplyMatch.newStatus(.notice, from: "pending review") == nil)
    }

    @Test func otherAppsMailDoesNotMatch() {
        let bv = ReplyMatch.Entry(id: "bv", outlet: "Indie List", date: "2026-10-27", status: "pending review", app: "AppA", type: "directory")
        let rs = ReplyMatch.Entry(id: "rs", outlet: "Indie List", date: "2026-10-27", status: "pending review", app: "AppB", type: "directory")
        let mail = [ReplyMatch.Mail(id: "1", from: "mail@indielist.example", subject: "AppB: Workout With Friends is live on Indie List", folder: "INBOX", day: "2026-10-28")]
        let m = ReplyMatch.match([bv, rs], mail: mail, own: own, apps: apps)
        #expect(m.map(\.entry) == ["rs"])
        #expect(m.first?.kind == .live)
    }

    @Test func differentKnownDomainIsNoNameMatch() {
        let e = ReplyMatch.Entry(id: "i", outlet: "Indie Catalog (indie-catalog.example)", date: "2026-10-27", status: "submitted", app: "AppB",
                                 type: "directory", site: "https://indie-catalog.example/app/appb")
        let mail = [ReplyMatch.Mail(id: "1", from: "mail@indielist.example", subject: "AppB: Workout With Friends is live on Indie List", folder: "INBOX", day: "2026-10-28")]
        #expect(ReplyMatch.match([e], mail: mail, own: own, apps: apps).isEmpty)
    }
}

@Suite struct ReplyMatchBounces {
    /// 29 Oct 2026: the mail provider returned a pitch 1 minute after it was sent.
    @Test func bounceBelongsToTheMessageSentJustBefore() {
        let e = ReplyMatch.Entry(id: "p", outlet: "Review Site", contact: "editor@example.com",
                                 subject: "Product review: AppB, an iPhone app that counts reps with the camera",
                                 date: "2026-10-29", status: "submitted", followUp: "2026-11-05", type: "press pitch")
        let other = ReplyMatch.Entry(id: "o", outlet: "Other", contact: "a@b.com", subject: "Tip: AppA", date: "2026-10-29", status: "submitted")
        let t: Double = 1_793_300_000
        let mail = [
            ReplyMatch.Mail(id: "s1", from: "me@mydomain.example", subject: "Tip: AppA", folder: "SENT", day: "2026-10-29", at: t - 300),
            ReplyMatch.Mail(id: "s2", from: "me@mydomain.example", subject: "Product review: AppB, an iPhone app that counts reps with the camera", folder: "SENT", day: "2026-10-29", at: t - 60),
            ReplyMatch.Mail(id: "b", from: "mailer-daemon@mail.provider.example", subject: "Undelivered Mail Returned to Sender", folder: "INBOX", day: "2026-10-29", at: t),
        ]
        let m = ReplyMatch.match([e, other], mail: mail, own: ["me@mydomain.example"])
        #expect(m.count == 1)
        #expect(m.first?.entry == "p" && m.first?.kind == .bounced && m.first?.sure == .unsure)   // timing alone is only a guess
        // 4 Nov 2026: the 22:27 bounce named info@fitnesssite.example, not the pitch sent just before it.
        let barbend = ReplyMatch.Entry(id: "bb", outlet: "Fitness Site", contact: "info@fitnesssite.example", subject: "For Best Workout Apps", date: "2026-10-29", status: "submitted")
        var withText = mail
        withText[2].text = "Delivery failed to: info@fitnesssite.example"
        let m2 = ReplyMatch.match([e, barbend], mail: withText, own: ["me@mydomain.example"])
        #expect(m2.map(\.entry) == ["bb"] && m2.first?.sure == .sure)
        #expect(ReplyMatch.newStatus(.bounced, from: "submitted") == "bounced")
    }
}
