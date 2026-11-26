import Foundation
import Testing
@testable import HmunmawiApp
@testable import HmunmawiCore

@MainActor
@Suite struct SmartOutreachTests {
    @Test func zohoMessageIDValidation() {
        #expect(ZohoSafariReader.isValidMessageID("1732590012345678"))
        #expect(ZohoSafariReader.isValidMessageID("t1732590012345678"))
        #expect(!ZohoSafariReader.isValidMessageID("123"))
        #expect(!ZohoSafariReader.isValidMessageID("17325900&evil=1"))
        #expect(!ZohoSafariReader.isValidMessageID("';alert(1)//"))
    }

    @Test func patchUpdateDetectionGatesMassRepitch() {
        #expect(Outreach.isPatchUpdate(from: "1.5.0", to: "1.5.1"))
        #expect(Outreach.isPatchUpdate(from: "1.5.1", to: "1.5.2"))
        #expect(!Outreach.isPatchUpdate(from: "1.5.2", to: "1.6.0"))
        #expect(!Outreach.isPatchUpdate(from: "1.6.0", to: "2.0.0"))
    }

    @Test func autoBookkeepingClassificationAndDraftGuards() {
        let sureFollowedUp = OSuggestion(id: "1", entry: "e1", outlet: "Blog", app: "AppA", kind: "followed up", why: "sent", day: "2026-11-26", sure: true)
        let unsureReply = OSuggestion(id: "2", entry: "e1", outlet: "Blog", app: "AppA", kind: "replied", why: "name match", day: "2026-11-26", sure: false)
        let verify = OSuggestion(id: "3", entry: "e1", outlet: "Dir", app: "AppA", kind: "verify", why: "confirm", day: "2026-11-26", sure: true)
        #expect(Outreach.isAutoBookkeeping(sureFollowedUp))
        #expect(!Outreach.isAutoBookkeeping(unsureReply))
        #expect(!Outreach.isAutoBookkeeping(verify))

        let item = OItem(id: "Blog|AppA|press pitch", outlet: "Blog", app: "AppA", type: "press pitch", status: "submitted", date: "2026-11-01", contact: "editor@blog.example")
        let otherFollowed = OItem(id: "Blog|AppB|press pitch", outlet: "Blog", app: "AppB", type: "press pitch", status: "submitted", date: "2026-10-01", followedUpOn: "2026-10-10", contact: "editor@blog.example")
        #expect(Outreach.pinnedRecipient(for: item) == "editor@blog.example")
        #expect(!Outreach.canDraft(for: item, allItems: [item, otherFollowed], side: Outreach.Side(), inReview: false, kind: "follow-up"))

        var sideDNC = Outreach.Side()
        sideDNC.extras[item.id] = OutreachExtra(dnc: true)
        #expect(!Outreach.canDraft(for: item, allItems: [item], side: sideDNC, inReview: false, kind: "thank"))

        var sideEmbargo = Outreach.Side()
        sideEmbargo.extras[item.id] = OutreachExtra(embargo: true)
        #expect(!Outreach.canDraft(for: item, allItems: [item], side: sideEmbargo, inReview: true, kind: "repitch"))
        #expect(Outreach.canDraft(for: item, allItems: [item], side: sideEmbargo, inReview: false, kind: "repitch"))
    }

    @Test func latestTheirReplyReadsMatchedThreadBody() {
        let item = OItem(id: "Blog|AppA|press pitch", outlet: "Blog", app: "AppA", type: "press pitch", status: "replied", date: "2026-11-01", contact: "jane@blog.example", subject: "AppA pitch")
        let ev1 = StoredEvent(id: 1, source: "mail", kind: "mail.seen", app: nil,
                              payload: .object(["id": .string("m1"), "from": .string("jane@blog.example"), "subject": .string("Re: AppA pitch"),
                                                "folder": .string("INBOX"), "text": .string("Could you share a promo code?")]),
                              occurredAt: 1_794_000_000_000)
        #expect(Outreach.latestTheirReply(for: item, in: [ev1]) == "Could you share a promo code?")
    }

    @Test func zohoJSLiteralEscapesSpecialCharactersSafely() {
        let lit = ZohoSafariSender.jsLiteral("Hello \"world\"\nLine 2'; alert(1)")
        #expect(lit != nil)
        #expect(lit?.contains("\\n") == true)
        #expect(lit?.contains("\\\"world\\\"") == true)
    }

    @Test func actionableDraftSuggestionsPicksNewDraftKindsAndSkipsDoneOrDismissed() {
        let suggestions: [OSuggestion] = [
            OSuggestion(id: "1", entry: "e1", outlet: "Blog A", app: "AppA", kind: "repitch", why: "new release", day: "2026-11-26", sure: true, state: "new"),
            OSuggestion(id: "2", entry: "e2", outlet: "Blog B", app: "AppA", kind: "answer", why: "question", day: "2026-11-26", sure: true, state: "new"),
            OSuggestion(id: "3", entry: "e3", outlet: "Blog C", app: "AppA", kind: "thank", why: "covered", day: "2026-11-26", sure: true, state: "new"),
            OSuggestion(id: "4", entry: "e4", outlet: "Blog D", app: "AppA", kind: "check in", why: "stale thread", day: "2026-11-26", sure: true, state: "new"),
            OSuggestion(id: "5", entry: "e5", outlet: "Blog E", app: "AppA", kind: "thread", why: "your turn", day: "2026-11-26", sure: true, state: "new", thread: "your turn"),
            OSuggestion(id: "6", entry: "e6", outlet: "Blog F", app: "AppA", kind: "repitch", why: "already drafted", day: "2026-11-26", sure: true, state: "done"),
            OSuggestion(id: "7", entry: "e7", outlet: "Blog G", app: "AppA", kind: "thank", why: "skipped", day: "2026-11-26", sure: true, state: "dismissed"),
            OSuggestion(id: "8", entry: "e8", outlet: "Blog H", app: "AppA", kind: "thread", why: "waiting", day: "2026-11-26", sure: true, state: "new", thread: "waiting"),
            OSuggestion(id: "9", entry: "e9", outlet: "Blog I", app: "AppA", kind: "replied", why: "bookkeeping", day: "2026-11-26", sure: true, state: "new"),
        ]
        let picked = Routines.actionableDraftSuggestions(from: suggestions)
        #expect(picked.map(\.id) == ["1", "2", "3", "4", "5"])
    }

    @Test func threadSuggestionsAndLatestTheirReplyIgnoreOwnAddressEvenInInboxWithInReplyTo() {
        let own = ["me@example.com"]
        let item = OItem(
            id: "Example Blog|AppA|press pitch",
            outlet: "Example Blog",
            app: "AppA",
            type: "press pitch",
            status: "submitted",
            date: "2026-11-01",
            contact: "editor@example.com",
            subject: "AppA pitch"
        )
        let evSent = StoredEvent(
            id: 1,
            source: "mail",
            kind: "mail.seen",
            app: nil,
            payload: .object([
                "id": .string("sent-1"),
                "from": .string("me@example.com"),
                "subject": .string("AppA pitch"),
                "folder": .string("SENT"),
                "message_id": .string("<pitch-1@example.com>"),
            ]),
            occurredAt: 1_794_000_000_000
        )
        let evOwnInbox = StoredEvent(
            id: 2,
            source: "mail",
            kind: "mail.seen",
            app: nil,
            payload: .object([
                "id": .string("self-inbox-2"),
                "from": .string("Me <me@example.com>"),
                "subject": .string("Re: AppA pitch"),
                "folder": .string("INBOX"),
                "in_reply_to": .string("<pitch-1@example.com>"),
                "text": .string("Could you clarify if you got my earlier pitch?"),
            ]),
            occurredAt: 1_794_100_000_000
        )

        #expect(Outreach.latestTheirReply(for: item, in: [evSent, evOwnInbox], own: own) == nil)

        let mail = Outreach.mail([evSent, evOwnInbox])
        let today = DayNumber.of("2026-11-10") ?? 0
        let suggestions = Outreach.threadSuggestions(items: [item], mail: mail, side: Outreach.Side(), today: today, own: own)
        #expect(suggestions.isEmpty)
    }

    @Test func outreachDraftsIncludeHighlightsAndSignOffWithoutPromoCouponOrLifetimeMentions() {
        let item = OItem(
            id: "Example Site|ExampleApp|press pitch",
            outlet: "Example Site",
            app: "ExampleApp",
            type: "press pitch",
            status: "replied",
            date: "2026-11-01",
            contact: "editor@example.com",
            subject: "ExampleApp pitch"
        )
        let highlights = AppPitchHighlights(
            outcome: "ExampleApp spots recovery patterns on your iPhone before fatigue hits.",
            bullets: [
                "Signal A vs Signal B - flags overnight drops early",
                "Private on-device tracking with no account",
            ],
            whatsNew: ["Added weekly correlation summary"]
        )
        let link = "https://apps.apple.com/app/id123456789?ct=pr-example&mt=8"

        let drafts = [
            Outreach.repitchDraft(item, version: "2.1.0", appLink: link, highlights: highlights),
            Outreach.followUpDraft(item, appLink: link, highlights: highlights),
            Outreach.checkInDraft(item, appLink: link, highlights: highlights),
        ]

        for draft in drafts {
            #expect(draft.body.contains(highlights.outcome))
            #expect(draft.body.contains("• Signal A vs Signal B - flags overnight drops early\n• Private on-device tracking with no account"))
            #expect(draft.body.contains("\n\n\(link)\n\n"))
            #expect(draft.body.contains("\n\nThanks,\nPS, (escapethematrix.app)"))
            #expect(AppStorePitchExtract.couponLeakProblem(draft.body, allowCode: false) == nil)
            let lower = draft.body.lowercased()
            #expect(!lower.contains("promo"))
            #expect(!lower.contains("coupon"))
            #expect(!lower.contains("lifetime"))
            #expect(!lower.contains("free code"))
        }
        #expect(drafts[0].body.contains("Added weekly correlation summary"))
    }

    @Test func purgeSelfAuthoredThreadsCleansPoisonedThreadsAndDismissesBogusAnswerSuggestions() {
        let own = ["me@example.com"]
        let entryID = "Example Site|ExampleApp|press pitch"
        let item = OItem(
            id: entryID,
            outlet: "Example Site",
            app: "ExampleApp",
            type: "press pitch",
            status: "replied",
            date: "2026-11-01",
            contact: "editor@example.com",
            subject: "ExampleApp pitch"
        )
        let cleanEntryID = "Other Site|ExampleApp|press pitch"
        let selfMail = ReplyMatch.Mail(
            id: "m-self-1",
            from: "me@example.com",
            subject: "Re: ExampleApp pitch",
            folder: "INBOX",
            day: "2026-11-05",
            inReplyTo: "<pitch-1@example.com>",
            text: "Following up with a question?"
        )
        let externalMail = ReplyMatch.Mail(
            id: "m-them-2",
            from: "writer@other.example",
            subject: "Re: Other pitch",
            folder: "INBOX",
            day: "2026-11-05",
            text: "Can you share screenshots?"
        )

        var side = Outreach.Side()
        side.threads = [
            entryID: Outreach.Thread(state: "your turn", promise: nil, since: "2026-11-05", mail: "m-self-1", evidence: "“Following up with a question?”"),
            cleanEntryID: Outreach.Thread(state: "your turn", promise: nil, since: "2026-11-05", mail: "m-them-2", evidence: "“Can you share screenshots?”"),
        ]
        side.suggestions = [
            OSuggestion(id: "\(entryID)|thread|m-self-1", entry: entryID, outlet: "Example Site", app: "ExampleApp", kind: "thread", why: "self", mailFrom: "me@example.com", mailSubject: "Re: ExampleApp pitch", day: "2026-11-05", sure: true, state: "done", thread: "your turn"),
            OSuggestion(id: "\(entryID)|checkin|m-self-1", entry: entryID, outlet: "Example Site", app: "ExampleApp", kind: "answer", why: "asked you something 5 days ago", mailFrom: nil, mailSubject: "ExampleApp pitch", day: "2026-11-10", sure: true, state: "new"),
            OSuggestion(id: "\(cleanEntryID)|checkin|m-them-2", entry: cleanEntryID, outlet: "Other Site", app: "ExampleApp", kind: "answer", why: "asked you something 5 days ago", mailFrom: nil, mailSubject: "Other pitch", day: "2026-11-10", sure: true, state: "new"),
        ]
        side.draftedIDs = ["sug|\(entryID)|checkin|m-self-1", "v2|sug|\(entryID)|checkin|m-self-1", "sug|\(cleanEntryID)|checkin|m-them-2"]

        let purged = Outreach.purgeSelfAuthoredThreads(side: &side, items: [item], mail: [selfMail, externalMail], own: own)

        #expect(purged.contains("\(entryID)|thread|m-self-1"))
        #expect(purged.contains("\(entryID)|checkin|m-self-1"))
        #expect(!purged.contains("\(cleanEntryID)|checkin|m-them-2"))
        #expect(side.threads?[entryID] == nil)
        #expect(side.threads?[cleanEntryID] != nil)
        #expect(side.suggestions.first { $0.id == "\(entryID)|checkin|m-self-1" }?.state == "dismissed")
        #expect(side.suggestions.first { $0.id == "\(entryID)|thread|m-self-1" }?.state == "dismissed")
        #expect(side.suggestions.first { $0.id == "\(cleanEntryID)|checkin|m-them-2" }?.state == "new")
        #expect(side.draftedIDs == ["sug|\(cleanEntryID)|checkin|m-them-2"])
    }

    @Test func outreachSheetSeparatesRealEmailsFromListingsAndForms() {
        let emailPitch = OItem(id: "Podcast|AppA|press pitch", outlet: "Podcast", app: "AppA", type: "press pitch", status: "submitted", date: "2026-11-01", contact: "host@podcast.example")
        let nominationForm = OItem(id: "Apple featuring nomination|AppA|press pitch", outlet: "Apple featuring nomination", app: "AppA", type: "press pitch", status: "submitted", date: "2026-10-29", contact: nil)
        let directory = OItem(id: "Indie App Catalog|AppA|directory", outlet: "Indie App Catalog", app: "AppA", type: "directory", status: "pending review", date: "2026-10-30")
        let social = OItem(id: "YouTube Shorts|AppA|social", outlet: "YouTube Shorts", app: "AppA", type: "social", status: "submitted", date: "2026-11-20")
        let all = [emailPitch, nominationForm, directory, social]
        let side = Outreach.Side()

        #expect(OutreachSheet.filterItems(all, side: side, filter: .awaiting).map(\.id) == [emailPitch.id])
        #expect(OutreachSheet.filterItems(all, side: side, filter: .listings).map(\.id).sorted() == [directory.id, nominationForm.id, social.id].sorted())
        #expect(OutreachSheet.isDraftSuggestion(OSuggestion(id: "1", entry: "e1", outlet: "Podcast", app: "AppA", kind: "repitch", why: "new release", day: "2026-11-26", sure: true)))
        #expect(!OutreachSheet.isDraftSuggestion(OSuggestion(id: "2", entry: "e2", outlet: "Blog", app: "AppA", kind: "bounced", why: "bounced", day: "2026-11-26", sure: true)))
    }
}
