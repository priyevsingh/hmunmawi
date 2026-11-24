import Foundation

/// Payment events the app shows (the purchases list, the ticker, and the on-screen moment) and how each one plays.
/// Kinds are plain strings on existing rows; nothing here rewrites stored events.
public enum PaymentMoment: Sendable {
    public enum Style: String, Sendable, Equatable { case sale, gift, subtle }

    /// Every payment kind that belongs in the purchases list and ticker (reviews stay separate).
    public static let paymentKinds: Set<String> = [
        "revenue.purchase", "revenue.renewal", "revenue.free",
        "revenue.refund", "revenue.refund_reversed", "revenue.refund_declined",
        "revenue.cancelled", "revenue.expired", "revenue.billing_issue",
        "revenue.plan_change", "revenue.price_increase",
        "revenue.renewal_extended", "revenue.revoked",
        "revenue.consumption_request"
    ]

    public static let liveFreshness: TimeInterval = 15 * 60
    public static let missedKeep: TimeInterval = 12 * 3_600

    public static func canPlay(_ event: StoredEvent) -> Bool { paymentKinds.contains(event.kind) }

    /// Paid sales and renewals keep the count-up; free trials and intro offers are a gift; refunds and the rest are quieter.
    public static func style(_ event: StoredEvent) -> Style {
        if isFreeOrIntro(event) { return .gift }
        switch event.kind {
        case "revenue.purchase", "revenue.renewal", "revenue.refund_reversed", "revenue.renewal_extended": return .sale
        case "revenue.free": return .gift
        default: return .subtle
        }
    }

    /// "Free trial · Presence", "New sale · Body Vitals": the line on the moment card and the row badge.
    public static func headline(_ event: StoredEvent) -> String {
        let app = event.app ?? ""
        let word: String
        if isFreeTrial(event) { word = "Free trial" }
        else if isIntroOffer(event) { word = "Intro offer" }
        else {
            switch event.kind {
            case "revenue.renewal": word = "Renewal"
            case "revenue.purchase": word = "New sale"
            case "revenue.free": word = "Free"
            case "revenue.refund": word = "Refund"
            case "revenue.refund_reversed": word = "Refund reversed"
            case "revenue.refund_declined": word = "Refund declined"
            case "revenue.cancelled": word = "Cancelled"
            case "revenue.expired": word = "Expired"
            case "revenue.billing_issue": word = "Billing issue"
            case "revenue.plan_change":
                word = planChangeWord(event)
            case "revenue.price_increase": word = "Price increase"
            case "revenue.renewal_extended": word = "Renewal extended"
            case "revenue.revoked": word = "Access revoked"
            case "revenue.consumption_request": word = "Refund check"
            default: word = "Payment"
            }
        }
        return app.isEmpty ? word : "\(word) · \(app)"
    }

    public static func symbol(_ kind: String) -> String {
        switch kind {
        case "revenue.purchase": return "bag.fill"
        case "revenue.renewal", "revenue.renewal_extended": return "arrow.triangle.2.circlepath"
        case "revenue.free": return "gift.fill"
        case "revenue.refund", "revenue.refund_declined", "revenue.consumption_request": return "arrow.uturn.backward"
        case "revenue.refund_reversed": return "arrow.uturn.forward"
        case "revenue.cancelled", "revenue.expired", "revenue.revoked": return "xmark.circle.fill"
        case "revenue.billing_issue": return "exclamationmark.triangle.fill"
        case "revenue.plan_change": return "arrow.left.arrow.right"
        case "revenue.price_increase": return "tag.fill"
        default: return "bag.fill"
        }
    }

    /// A free trial, a $0 intro, a gift tag, or `revenue.free`. Paid intro offers are not free.
    public static func isFreeOrIntro(_ event: StoredEvent) -> Bool {
        if event.kind == "revenue.free" { return true }
        if isFreeTrial(event) { return true }
        if isIntroOffer(event), (price(event) ?? 0) == 0 { return true }
        return false
    }

    public static func isFreeTrial(_ event: StoredEvent) -> Bool {
        if discount(event) == "FREE_TRIAL" || discount(event) == "FREE" { return true }
        if (price(event) ?? -1) == 0, isIntroOffer(event) { return true }
        let text = ((event.payload[path: "label"]?.string ?? "") + " " + (event.payload[path: "detail"]?.string ?? "")).lowercased()
        return text.contains("free trial") || text.contains("introductory trial")
    }

    public static func isIntroOffer(_ event: StoredEvent) -> Bool {
        if offerType(event) == 1 { return true }
        let text = ((event.payload[path: "label"]?.string ?? "") + " " + (event.payload[path: "detail"]?.string ?? "")).lowercased()
        return text.contains("intro")
    }

    /// Live arrivals only play when they happened in the last 15 minutes. A replay (or a missed moment you come back to) skips that gate.
    public static func shouldPlay(event: StoredEvent, replay: Bool, reduceMotion: Bool, now: Date = .now) -> Bool {
        guard !reduceMotion, canPlay(event) else { return false }
        if replay { return true }
        return now.timeIntervalSince1970 * 1000 - Double(event.occurredAt) < liveFreshness * 1000
    }

    /// A missed moment is still worth playing when you come back, up to 12 hours later.
    public static func shouldReplayMissed(event: StoredEvent, now: Date = .now) -> Bool {
        guard canPlay(event) else { return false }
        return now.timeIntervalSince1970 * 1000 - Double(event.occurredAt) < missedKeep * 1000
    }

    public static func lastReplayable(_ events: [StoredEvent], shown: (String?) -> Bool = { _ in true }) -> StoredEvent? {
        events.filter { canPlay($0) && shown($0.app) }
            .sorted { $0.occurredAt == $1.occurredAt ? $0.id > $1.id : $0.occurredAt > $1.occurredAt }
            .first
    }

    // MARK: Apple notification types (App Store Server Notifications)

    /// Maps an App Store Server Notification to a kind the rest of the app already understands, or a new kind
    /// that sits beside them. Existing types keep their old kinds, so rows already stored stay valid.
    public static func kind(appleType: String, subtype: String? = nil, price: Double? = nil,
                            offerType: Int? = nil, offerDiscountType: String? = nil) -> String? {
        switch appleType {
        case "SUBSCRIBED", "ONE_TIME_CHARGE": return "revenue.purchase"
        case "DID_RENEW": return "revenue.renewal"
        case "DID_CHANGE_RENEWAL_STATUS" where subtype == "AUTO_RENEW_DISABLED": return "revenue.cancelled"
        case "DID_CHANGE_RENEWAL_STATUS": return "revenue.plan_change"
        case "EXPIRED": return "revenue.expired"
        case "REFUND": return "revenue.refund"
        case "REFUND_REVERSED": return "revenue.refund_reversed"
        case "REFUND_DECLINED": return "revenue.refund_declined"
        case "OFFER_REDEEMED":
            return isFreeOffer(price: price, offerType: offerType, offerDiscountType: offerDiscountType)
                ? "revenue.free" : "revenue.purchase"
        case "DID_CHANGE_RENEWAL_PREF": return "revenue.plan_change"
        case "DID_FAIL_TO_RENEW": return "revenue.billing_issue"
        case "GRACE_PERIOD_EXPIRED": return "revenue.billing_issue"
        case "PRICE_INCREASE": return "revenue.price_increase"
        case "RENEWAL_EXTENDED", "RENEWAL_EXTENSION": return "revenue.renewal_extended"
        case "REVOKE": return "revenue.revoked"
        case "CONSUMPTION_REQUEST": return "revenue.consumption_request"
        default: return nil
        }
    }

    /// Script-feed / hub outbox titles ("Presence Free trial started", tags "gift", …).
    public static func kind(label: String, tags: String = "") -> String? {
        if tags == "test_tube" { return nil }
        if tags == "gift" { return "revenue.free" }
        let l = label.lowercased()
        if l.contains("refund") && l.contains("revers") { return "revenue.refund_reversed" }
        if l.contains("refund") && l.contains("declin") { return "revenue.refund_declined" }
        if l.contains("refund") && (l.contains("check") || l.contains("consump")) { return "revenue.consumption_request" }
        if l.contains("refund") { return "revenue.refund" }
        if l.contains("renew") && l.contains("extend") { return "revenue.renewal_extended" }
        if l.contains("renew") { return "revenue.renewal" }
        if l.contains("cancel") || l.contains("revoke") { return l.contains("revoke") ? "revenue.revoked" : "revenue.cancelled" }
        if l.contains("expire") { return "revenue.expired" }
        if l.contains("billing") || l.contains("grace period") || l.contains("fail to renew") || l.contains("failed to renew") {
            return "revenue.billing_issue"
        }
        if l.contains("price increase") { return "revenue.price_increase" }
        if l.contains("upgrade") || l.contains("downgrade") || l.contains("plan change") || l.contains("auto-renew") {
            return "revenue.plan_change"
        }
        if l.contains("free trial") || l.contains("introductory trial") || (l.contains("intro") && l.contains("trial"))
            || l.contains("free redemption") || l.contains("gift") {
            return "revenue.free"
        }
        if l.contains("intro") || l.contains("offer redeemed") || l.contains("offer code") { return "revenue.purchase" }
        if l.contains("sale") || l.contains("purchase") || l.contains("subscri") { return "revenue.purchase" }
        return nil
    }

    public static func isFreeOffer(price: Double?, offerType: Int?, offerDiscountType: String?) -> Bool {
        let d = offerDiscountType?.uppercased()
        if d == "FREE_TRIAL" || d == "FREE" { return true }
        if let price, price == 0 { return true }
        return false
    }

    // MARK: payload facts (live items store these under "facts")

    public static func offerType(_ event: StoredEvent) -> Int? {
        number(event, "offerType") ?? number(event, "offer")
    }

    public static func discount(_ event: StoredEvent) -> String? {
        string(event, "offerDiscountType")?.uppercased()
    }

    public static func subtype(_ event: StoredEvent) -> String? { string(event, "subtype") }

    public static func price(_ event: StoredEvent) -> Double? {
        fact(event)?[path: "price"]?.number
    }

    private static func planChangeWord(_ event: StoredEvent) -> String {
        switch subtype(event) {
        case "UPGRADE": return "Upgrade"
        case "DOWNGRADE": return "Downgrade"
        case "AUTO_RENEW_ENABLED": return "Auto-renew on"
        default: return "Plan change"
        }
    }

    private static func fact(_ event: StoredEvent) -> JSONValue? { event.payload[path: "facts"] }

    private static func string(_ event: StoredEvent, _ key: String) -> String? {
        fact(event)?[path: key]?.string
    }

    private static func number(_ event: StoredEvent, _ key: String) -> Int? {
        fact(event)?[path: key]?.number.map { Int(safe: $0) }
    }
}
