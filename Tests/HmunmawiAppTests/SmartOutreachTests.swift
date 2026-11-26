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
}
