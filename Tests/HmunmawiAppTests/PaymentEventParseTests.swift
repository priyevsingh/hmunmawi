import Foundation
import Testing
import HmunmawiCore
@testable import HmunmawiApp

@Suite struct PaymentEventParseTests {
    @Test func applePaymentTypesBecomeEvents() {
        let sub = LivePurchases.parseApplePayment([
            "type": "SUBSCRIBED", "subtype": "INITIAL_BUY", "bundleId": "app.presence",
            "product": "weekly", "price": 0.0, "currency": "USD", "offer": 1,
            "offerDiscountType": "FREE_TRIAL", "at": 1_795_000_000_000.0, "key": "k1"
        ], appName: { _ in "Presence" })
        #expect(sub?.kind == "revenue.purchase")  // existing type keeps its kind
        #expect(sub?.app == "Presence")
        #expect(sub?.payload[path: "facts"]?[path: "offerType"]?.number == 1)
        #expect(PaymentMoment.style(StoredEvent(id: 1, source: "live", kind: sub!.kind, app: sub!.app,
                                                payload: sub!.payload, occurredAt: sub!.occurredAt)) == .gift)

        let offer = LivePurchases.parseApplePayment([
            "type": "OFFER_REDEEMED", "bundleId": "app.presence", "product": "weekly",
            "price": 0.0, "currency": "USD", "offer": 1, "at": 1_795_000_000_000.0, "key": "k2"
        ], appName: { _ in "Presence" })
        #expect(offer?.kind == "revenue.free")

        let paidOffer = LivePurchases.parseApplePayment([
            "type": "OFFER_REDEEMED", "bundleId": "app.repsquad", "product": "yearly",
            "price": 29.99, "currency": "USD", "offer": 3, "at": 1_795_000_000_000.0, "key": "k3"
        ], appName: { _ in "Rep Squad" })
        #expect(paidOffer?.kind == "revenue.purchase")

        let billing = LivePurchases.parseApplePayment([
            "type": "DID_FAIL_TO_RENEW", "subtype": "GRACE_PERIOD", "bundleId": "app.x",
            "product": "monthly", "at": 1_795_000_000_000.0, "key": "k4"
        ], appName: { _ in "X" })
        #expect(billing?.kind == "revenue.billing_issue")
        #expect(billing?.payload[path: "facts"]?[path: "subtype"]?.string == "GRACE_PERIOD")

        #expect(LivePurchases.parseApplePayment([
            "type": "REFUND_REVERSED", "bundleId": "a", "product": "p", "at": 1.0, "key": "k5"
        ], appName: { _ in "A" })?.kind == "revenue.refund_reversed")

        #expect(LivePurchases.parseApplePayment([
            "type": "PRICE_INCREASE", "subtype": "PENDING", "bundleId": "a", "product": "p", "at": 1.0, "key": "k6"
        ], appName: { _ in "A" })?.kind == "revenue.price_increase")

        #expect(LivePurchases.parseApplePayment(["type": "TEST", "bundleId": "a", "key": "k7"], appName: { _ in "A" }) == nil)
        #expect(LivePurchases.parseApplePayment([
            "type": "SUBSCRIBED", "environment": "Sandbox", "bundleId": "a", "product": "p", "key": "k8"
        ], appName: { _ in "A" }) == nil)
    }

    @Test func tickerKindsIncludeEveryPaymentKindAndReviews() {
        for kind in PaymentMoment.paymentKinds {
            #expect(TickerItems.kinds.contains(kind), "\(kind) missing from the ticker / purchases list")
        }
        #expect(TickerItems.kinds.contains("review.new"))
    }
}
