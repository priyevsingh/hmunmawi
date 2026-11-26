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
}
