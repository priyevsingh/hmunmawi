import Foundation
import Testing
@testable import HmunmawiCore

@Suite struct PaymentMomentTests {
    let now = Date(timeIntervalSince1970: 1_795_000_000)

    func ev(_ kind: String, minutesAgo: Double = 1, price: Double? = nil, offerType: Int? = nil,
            discount: String? = nil, subtype: String? = nil, label: String? = nil, detail: String? = nil,
            app: String? = "Presence", id: Int64 = 1) -> StoredEvent {
        var facts: [String: JSONValue] = [:]
        if let price { facts["price"] = .number(price); facts["currency"] = .string("USD") }
        if let offerType { facts["offerType"] = .number(Double(offerType)) }
        if let discount { facts["offerDiscountType"] = .string(discount) }
        if let subtype { facts["subtype"] = .string(subtype) }
        var payload: [String: JSONValue] = ["facts": .object(facts)]
        if let label { payload["label"] = .string(label) }
        if let detail { payload["detail"] = .string(detail) }
        return StoredEvent(id: id, source: "live", kind: kind, app: app, payload: .object(payload),
                           occurredAt: Millis((now.timeIntervalSince1970 - minutesAgo * 60) * 1000))
    }

    // MARK: Apple types — existing kinds stay the same

    @Test func existingAppleTypesKeepTheirKinds() {
        #expect(PaymentMoment.kind(appleType: "SUBSCRIBED") == "revenue.purchase")
        #expect(PaymentMoment.kind(appleType: "SUBSCRIBED", subtype: "INITIAL_BUY") == "revenue.purchase")
        #expect(PaymentMoment.kind(appleType: "ONE_TIME_CHARGE") == "revenue.purchase")
        #expect(PaymentMoment.kind(appleType: "DID_RENEW") == "revenue.renewal")
        #expect(PaymentMoment.kind(appleType: "DID_RENEW", subtype: "BILLING_RECOVERY") == "revenue.renewal")
        #expect(PaymentMoment.kind(appleType: "DID_CHANGE_RENEWAL_STATUS", subtype: "AUTO_RENEW_DISABLED") == "revenue.cancelled")
        #expect(PaymentMoment.kind(appleType: "EXPIRED") == "revenue.expired")
        #expect(PaymentMoment.kind(appleType: "REFUND") == "revenue.refund")
    }

    @Test func previouslyDroppedPaymentTypesAreMapped() {
        #expect(PaymentMoment.kind(appleType: "OFFER_REDEEMED", price: 0, offerType: 1) == "revenue.free")
        #expect(PaymentMoment.kind(appleType: "OFFER_REDEEMED", price: 4.99, offerType: 3) == "revenue.purchase")
        #expect(PaymentMoment.kind(appleType: "OFFER_REDEEMED", offerDiscountType: "FREE_TRIAL") == "revenue.free")
        #expect(PaymentMoment.kind(appleType: "DID_CHANGE_RENEWAL_PREF", subtype: "UPGRADE") == "revenue.plan_change")
        #expect(PaymentMoment.kind(appleType: "DID_CHANGE_RENEWAL_PREF", subtype: "DOWNGRADE") == "revenue.plan_change")
        #expect(PaymentMoment.kind(appleType: "DID_CHANGE_RENEWAL_STATUS", subtype: "AUTO_RENEW_ENABLED") == "revenue.plan_change")
        #expect(PaymentMoment.kind(appleType: "REFUND_REVERSED") == "revenue.refund_reversed")
        #expect(PaymentMoment.kind(appleType: "REFUND_DECLINED") == "revenue.refund_declined")
        #expect(PaymentMoment.kind(appleType: "DID_FAIL_TO_RENEW") == "revenue.billing_issue")
        #expect(PaymentMoment.kind(appleType: "DID_FAIL_TO_RENEW", subtype: "GRACE_PERIOD") == "revenue.billing_issue")
        #expect(PaymentMoment.kind(appleType: "GRACE_PERIOD_EXPIRED") == "revenue.billing_issue")
        #expect(PaymentMoment.kind(appleType: "PRICE_INCREASE", subtype: "PENDING") == "revenue.price_increase")
        #expect(PaymentMoment.kind(appleType: "PRICE_INCREASE", subtype: "ACCEPTED") == "revenue.price_increase")
        #expect(PaymentMoment.kind(appleType: "RENEWAL_EXTENDED") == "revenue.renewal_extended")
        #expect(PaymentMoment.kind(appleType: "RENEWAL_EXTENSION") == "revenue.renewal_extended")
        #expect(PaymentMoment.kind(appleType: "REVOKE") == "revenue.revoked")
        #expect(PaymentMoment.kind(appleType: "CONSUMPTION_REQUEST") == "revenue.consumption_request")
    }

    @Test func nonPaymentAppleTypesStayUnmapped() {
        #expect(PaymentMoment.kind(appleType: "TEST") == nil)
        #expect(PaymentMoment.kind(appleType: "webhookPingCreated") == nil)
    }

    // MARK: Script-feed labels

    @Test func hubLabelsCoverTrialsAndPayments() {
        #expect(PaymentMoment.kind(label: "New sale", tags: "gift") == "revenue.free")
        #expect(PaymentMoment.kind(label: "Free trial started") == "revenue.free")
        #expect(PaymentMoment.kind(label: "Introductory trial") == "revenue.free")
        #expect(PaymentMoment.kind(label: "Intro offer redeemed") == "revenue.purchase")
        #expect(PaymentMoment.kind(label: "Refund reversed") == "revenue.refund_reversed")
        #expect(PaymentMoment.kind(label: "Subscription renewed") == "revenue.renewal")
        #expect(PaymentMoment.kind(label: "Billing issue") == "revenue.billing_issue")
        #expect(PaymentMoment.kind(label: "Price increase pending") == "revenue.price_increase")
        #expect(PaymentMoment.kind(label: "Anything", tags: "test_tube") == nil)
        #expect(PaymentMoment.kind(label: "A random title") == nil)
    }

    // MARK: All payment kinds have a style, headline, and can play

    @Test func everyPaymentKindHasAStyleAndHeadline() {
        let kinds = PaymentMoment.paymentKinds.sorted()
        #expect(kinds.count == 14)
        for kind in kinds {
            let e = ev(kind)
            #expect(PaymentMoment.canPlay(e))
            #expect(!PaymentMoment.headline(e).isEmpty)
            #expect(!PaymentMoment.symbol(kind).isEmpty)
            _ = PaymentMoment.style(e)
        }
    }

    @Test func stylesMatchTheKindOfPayment() {
        #expect(PaymentMoment.style(ev("revenue.purchase", price: 4.99)) == .sale)
        #expect(PaymentMoment.style(ev("revenue.renewal", price: 2.99)) == .sale)
        #expect(PaymentMoment.style(ev("revenue.free")) == .gift)
        #expect(PaymentMoment.style(ev("revenue.purchase", price: 0, offerType: 1, discount: "FREE_TRIAL")) == .gift)
        #expect(PaymentMoment.style(ev("revenue.purchase", price: 0, offerType: 1)) == .gift)
        #expect(PaymentMoment.style(ev("revenue.purchase", label: "Free trial started")) == .gift)
        #expect(PaymentMoment.style(ev("revenue.refund", price: 4.99)) == .subtle)
        #expect(PaymentMoment.style(ev("revenue.billing_issue")) == .subtle)
        #expect(PaymentMoment.style(ev("revenue.cancelled")) == .subtle)
        #expect(PaymentMoment.style(ev("revenue.refund_reversed")) == .sale)
    }

    @Test func headlinesNameTheKindAndApp() {
        #expect(PaymentMoment.headline(ev("revenue.purchase", price: 4.99, app: "Body Vitals")) == "New sale · Body Vitals")
        #expect(PaymentMoment.headline(ev("revenue.renewal", app: "Rep Squad")) == "Renewal · Rep Squad")
        #expect(PaymentMoment.headline(ev("revenue.purchase", price: 0, offerType: 1, discount: "FREE_TRIAL", app: "Presence"))
                == "Free trial · Presence")
        #expect(PaymentMoment.headline(ev("revenue.purchase", price: 1.99, offerType: 1, app: "Presence")) == "Intro offer · Presence")
        #expect(PaymentMoment.headline(ev("revenue.refund", app: "Presence")) == "Refund · Presence")
        #expect(PaymentMoment.headline(ev("revenue.plan_change", subtype: "UPGRADE", app: "Rep Squad")) == "Upgrade · Rep Squad")
        #expect(PaymentMoment.headline(ev("revenue.free", app: "Presence")) == "Free · Presence")
    }

    // MARK: Live gate vs replay

    @Test func livePlayRequiresAFreshPayment() {
        let fresh = ev("revenue.purchase", minutesAgo: 5)
        let late = ev("revenue.purchase", minutesAgo: 20)
        #expect(PaymentMoment.shouldPlay(event: fresh, replay: false, reduceMotion: false, now: now))
        #expect(!PaymentMoment.shouldPlay(event: late, replay: false, reduceMotion: false, now: now))
        #expect(PaymentMoment.shouldPlay(event: late, replay: true, reduceMotion: false, now: now))
        #expect(!PaymentMoment.shouldPlay(event: fresh, replay: true, reduceMotion: true, now: now))
        #expect(!PaymentMoment.shouldPlay(event: ev("review.new"), replay: true, reduceMotion: false, now: now))
    }

    @Test func missedMomentKeepsForTwelveHours() {
        let recent = ev("revenue.free", minutesAgo: 30)
        let hours = ev("revenue.purchase", minutesAgo: 11 * 60)
        let tooOld = ev("revenue.purchase", minutesAgo: 13 * 60)
        #expect(PaymentMoment.shouldReplayMissed(event: recent, now: now))
        #expect(PaymentMoment.shouldReplayMissed(event: hours, now: now))
        #expect(!PaymentMoment.shouldReplayMissed(event: tooOld, now: now))
    }

    @Test func lastReplayableIsTheNewestPayment() {
        let old = ev("revenue.purchase", minutesAgo: 60, app: "A", id: 1)
        let trial = ev("revenue.free", minutesAgo: 10, app: "Presence", id: 2)
        let review = StoredEvent(id: 3, source: "live", kind: "review.new", app: "A", payload: .object([:]),
                                 occurredAt: Millis(now.timeIntervalSince1970 * 1000))
        #expect(PaymentMoment.lastReplayable([old, trial, review])?.id == 2)
        #expect(PaymentMoment.lastReplayable([old, trial], shown: { $0 == "A" })?.id == 1)
        #expect(PaymentMoment.lastReplayable([]) == nil)
    }

    @Test func replayDoesNotRequireANewEventId() {
        let e = ev("revenue.purchase", minutesAgo: 24 * 60)
        #expect(PaymentMoment.shouldPlay(event: e, replay: true, reduceMotion: false, now: now))
        #expect(PaymentMoment.shouldPlay(event: e, replay: true, reduceMotion: false, now: now))
    }
}
