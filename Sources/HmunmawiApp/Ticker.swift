import HmunmawiCore
import SwiftUI

/// The moments worth a glance as they happen: money (sales, renewals, refunds, cancellations) and new reviews.
enum TickerItems {
    static let kinds: Set<String> = ["revenue.purchase", "revenue.renewal", "revenue.refund", "revenue.cancelled",
                                     "revenue.expired", "revenue.billing_issue", "review.new"]

    /// The last day's moments, newest first; if the day was quiet, the latest ten from the week.
    static func recent(_ events: [StoredEvent], now: Date = .now) -> [StoredEvent] {
        let moments = events.filter { kinds.contains($0.kind) }.sorted { $0.occurredAt > $1.occurredAt }
        let dayAgo = Millis(now.timeIntervalSince1970 * 1000) - TodayBuilder.day
        let today = moments.filter { $0.occurredAt > dayAgo }
        return Array((today.count >= 3 ? today : moments).prefix(10))
    }

    static func symbol(_ kind: String) -> (String, Color) {
        switch kind {
        case "revenue.purchase": ("bag.fill", Brand.good)
        case "revenue.renewal": ("arrow.triangle.2.circlepath", Brand.good)
        case "revenue.refund", "revenue.cancelled", "revenue.expired", "revenue.billing_issue": ("arrow.uturn.backward", Brand.bad)
        default: ("star.fill", Brand.Category.users)
        }
    }

    /// The buyer's country flag, when the purchase feed sends one (Apple's storefront).
    static func flag(_ event: StoredEvent) -> String? {
        guard let flag = event.payload[path: "flag"]?.string, !flag.isEmpty else { return nil }
        return flag
    }

    /// "🇨🇳 China": the flag plus the country's name in the Mac's language (read back from the flag's letters).
    static func country(_ event: StoredEvent) -> String? {
        guard let flag = flag(event) else { return nil }
        let code = String(flag.unicodeScalars.compactMap { s in
            (0x1F1E6...0x1F1FF).contains(s.value) ? Character(UnicodeScalar(s.value - 0x1F1E6 + 65)!) : nil
        })
        return "\(flag) \(Locale.current.localizedString(forRegionCode: code) ?? code)"
    }

    /// How many family members share this purchase (the feed sends the count as revenue.family_shares updates).
    static func familyShares(_ event: StoredEvent, in events: [StoredEvent]) -> Int? {
        guard let uuid = event.payload[path: "uuid"]?.string else { return nil }
        let n = events.filter { $0.kind == "revenue.family_shares" && $0.payload[path: "uuid"]?.string == uuid }
            .compactMap { $0.payload[path: "shares"]?.number }.max()
        return n.map { Int(safe: $0) }
    }

    /// "21 hours ago": the moment's age measured from `now`, which the ticker passes in from a timeline that ticks every
    /// minute. Formatting against the clock inside a plain `Text` froze the label at whatever it said when the row was first
    /// drawn, so yesterday's sale kept reading "1 minute ago".
    static func age(_ event: StoredEvent, now: Date, locale: Locale = .current) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = locale
        f.dateTimeStyle = .named
        f.unitsStyle = .full
        let at = Date(timeIntervalSince1970: Double(event.occurredAt) / 1000)
        // A clock a few seconds behind the sender must not turn a fresh moment into "in 3 seconds".
        return f.localizedString(for: min(at, now), relativeTo: now)
    }

    @MainActor static func text(_ event: StoredEvent) -> String {
        let detail = Money.shared.purchaseLine(event)
        return detail.isEmpty ? EventText.describe(event) : "\(EventText.describe(event)) · \(detail)"
    }
}

/// One moment at a time, sliding up every few seconds like the Stocks widget's headlines.
/// It holds still while the pointer is over it, and with Reduce Motion it simply cross-fades.
struct Ticker: View {
    let events: [StoredEvent]
    @State private var index = 0
    @State private var showing: StoredEvent?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Redrawn every minute so the age keeps moving even when no new event arrives.
        TimelineView(.everyMinute) { context in row(now: context.date) }
    }

    @ViewBuilder private func row(now: Date) -> some View {
        let items = TickerItems.recent(events, now: now)
        if !items.isEmpty {
            let event = items[index % items.count]
            let (badge, tint) = TickerItems.symbol(event.kind)
            HStack(spacing: 12) {
                HStack(spacing: 12) {
                    AppIcon(app: event.app, size: 26, badge: badge, badgeTint: tint)
                    if let flag = TickerItems.flag(event) { Text(flag).font(.title3) }
                    Text(TickerItems.text(event)).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                    Text(TickerItems.age(event, now: now))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                }
                .id(event.id)
                .transition(reduceMotion ? .opacity : .push(from: .bottom))
                // Still unless something new arrives; the count steps to the next moment when clicked.
                Button {
                    withAnimation(.smooth(duration: 0.45)) { index = (index + 1) % items.count }
                } label: {
                    Label("\(index % items.count + 1) of \(items.count)", systemImage: "chevron.down")
                        .labelStyle(.titleAndIcon).font(.callout).monospacedDigit()
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Show the next moment")
                .disabled(items.count < 2)
            }
            .padding(.horizontal, 16)
            // At least one line tall; a long line wraps and the row grows instead of being cut in half.
            .frame(minHeight: 46)
            .padding(.vertical, 2)
            .clipped()
            .contentCard(cornerRadius: 23)
            .contentShape(.rect)
            .onTapGesture { showing = event }
            .popover(item: $showing, arrowEdge: .bottom) { PurchaseDetail(event: $0) }
            .help("Click for the purchase details")
            // A new moment arriving brings the ticker back to the newest one; nothing turns on its own.
            .onChange(of: items.first?.id) { _, _ in withAnimation(.smooth(duration: 0.45)) { index = 0 } }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Latest: \(TickerItems.text(event))")
        }
    }
}

/// Everything Apple told us about one purchase, with the portal's labels; rows without a value are left out.
struct PurchaseDetail: View {
    let event: StoredEvent
    @Environment(AppModel.self) private var model: AppModel?

    private static let intents = [1: "Cancelled by the customer", 2: "Billing error", 3: "Didn't agree to a price increase",
                                  4: "Product not available", 5: "Other"]
    private static let offers = [1: "Introductory offer", 2: "Promotional offer", 3: "Offer code", 4: "Win-back offer"]

    private func when(_ iso: String?) -> String? {
        guard let iso, let date = try? Date(iso, strategy: .iso8601) else { return nil }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var rows: [(String, String)] {
        let f = event.payload[path: "facts"] ?? .null
        func s(_ k: String) -> String? { f[path: k]?.string.flatMap { $0.isEmpty ? nil : $0 } }
        func n(_ k: String) -> Int? { f[path: k]?.number.map { Int(safe: $0) } }
        let plan: String? = Money.shared.purchaseLine(event)
        let country = TickerItems.country(event) ?? s("storefront") ?? ""
        let renewAs = s("autoRenewProductId").flatMap { $0 == s("productId") ? nil : $0 }
        let offer = n("offerType").map { [Self.offers[$0] ?? "Offer \($0)", s("offerDiscountType"), s("offerIdentifier")].compactMap { $0 }.joined(separator: " · ") }
        let revoked = (s("revocationDate") != nil || n("revocationReason") != nil)
            ? [when(s("revocationDate")), n("revocationReason").map { $0 == 1 ? "App issue" : "Other" }].compactMap { $0 }.joined(separator: " · ") : nil
        let candidates: [(String, String?)] = [
            ("Plan and price", plan), ("Country", country.isEmpty ? nil : country), ("Product", s("productId")),
            ("Family Sharing", TickerItems.familyShares(event, in: model?.events ?? []).map {
                "Shared with \($0) family member\($0 == 1 ? "" : "s"), no extra charge" }),
            ("Offer", offer), ("Original purchase", when(s("originalPurchaseDate"))), ("Bought", when(s("purchaseDate"))),
            ("Expires", when(s("expiresDate"))), ("Renewal", when(s("renewalDate"))), ("Renews as", renewAs),
            ("Auto-renew", n("autoRenewStatus").map { $0 == 1 ? "On" : "Off" }),
            ("Billing retry", f[path: "isInBillingRetryPeriod"] == .bool(true) ? "On" : nil),
            ("Expiration intent", n("expirationIntent").map { Self.intents[$0] ?? "\($0)" }),
            ("Revoked", revoked),
            ("Ownership", s("inAppOwnershipType").map { $0 == "FAMILY_SHARED" ? "Family Sharing" : $0 == "PURCHASED" ? "Purchased" : $0 }),
            ("Transaction reason", s("transactionReason").map { $0 == "RENEWAL" ? "Renewal" : $0 == "PURCHASE" ? "Purchase" : $0 }),
            ("App version", s("appVersion")),
            ("Environment", s("environment").map { $0 == "Sandbox" ? "Sandbox (test purchase, not charged)" : $0 }),
        ]
        return candidates.compactMap { label, value in value.map { (label, $0) } }
    }

    var body: some View {
        let (badge, tint) = TickerItems.symbol(event.kind)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                AppIcon(app: event.app, size: 40, badge: badge, badgeTint: tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(EventText.describe(event)).font(.headline)
                    Text(Date(timeIntervalSince1970: Double(event.occurredAt) / 1000).formatted(date: .abbreviated, time: .shortened))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                ForEach(rows, id: \.0) { label, value in
                    GridRow {
                        Text(label).font(.callout).foregroundStyle(.secondary)
                        Text(value).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if event.payload[path: "facts"] == nil {
                Text("Country, renewal and offer show for new purchases.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("Apple doesn't share the buyer's device or OS.").font(.callout).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 400, alignment: .leading)
    }
}
