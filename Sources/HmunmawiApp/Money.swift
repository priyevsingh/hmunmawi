import Foundation
import HmunmawiCore
import Observation

/// Shows every amount in the currency the person picks (Settings > General > Show money in).
/// Rates are the European Central Bank's daily reference rates via frankfurter.app (free, no key),
/// fetched at most once a day and kept on disk so amounts still convert offline.
/// A currency the ECB doesn't publish (e.g. AED) is shown as it is, never guessed.
@Observable @MainActor
final class Money {
    static let shared = Money()

    /// ISO code to show amounts in.
    private(set) var target: String = Locale.current.currency?.identifier ?? "USD" { didSet { shareWithInsights() } }
    /// Units per 1 EUR, as the ECB publishes them (EUR itself is 1).
    private(set) var rates: [String: Double] = ["EUR": 1] { didSet { shareWithInsights() } }
    private(set) var ratesDate: String?

    private var file: URL { URL.hmSupport.appending(path: "rates.json") }

    /// Every currency that can be chosen, sorted by name in the Mac's language.
    var choices: [String] {
        rates.keys.sorted { (Locale.current.localizedString(forCurrencyCode: $0) ?? $0) < (Locale.current.localizedString(forCurrencyCode: $1) ?? $1) }
    }

    /// Findings ("MRR up since 28 Oct: about ≈₹10,430 now") read money in your currency, like every other screen.
    /// A snapshot of the rate, so the engine can format off the main thread; dollars while no rate exists.
    private func shareWithInsights() {
        let code = target
        guard code != "USD", let rate = convert(1, from: "USD") else {
            InsightEngine.money = { v in "$" + v.formatted(.number.precision(.fractionLength(v < 100 ? 2 : 0))) }
            return
        }
        InsightEngine.money = { v in "≈" + Money.text(v * rate, code, decimals: abs(v * rate) < 100 ? 2 : 0) }
    }

    func setTarget(_ code: String?) {
        target = code ?? Locale.current.currency?.identifier ?? "USD"
    }

    /// Loads cached rates, then refreshes them from the ECB when they are older than today.
    func load() async {
        if let data = try? Data(contentsOf: file), let cached = try? JSONDecoder().decode(Cached.self, from: data) {
            rates = Self.withPegs(cached.rates.merging(["EUR": 1]) { a, _ in a })
            ratesDate = cached.date
        }
        let today = Date.now.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        guard ratesDate != today, let url = URL(string: "https://api.frankfurter.app/latest"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let fresh = try? JSONDecoder().decode(Cached.self, from: data) else { return }
        rates = Self.withPegs(fresh.rates.merging(["EUR": 1]) { a, _ in a })
        ratesDate = fresh.date
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(Cached(date: fresh.date, rates: rates)).write(to: file, options: .atomic)
    }

    /// Currencies Apple pays in that the ECB doesn't publish but that are fixed to the dollar (same list as the
    /// App Store Connect add-on), so Apple's finance report isn't quietly short by them.
    static let dollarPegs: [String: Double] = ["AED": 3.6725, "SAR": 3.75, "QAR": 3.64, "BHD": 0.376, "OMR": 0.3845, "JOD": 0.709]
    static func withPegs(_ perEUR: [String: Double]) -> [String: Double] {
        guard let usd = perEUR["USD"] else { return perEUR }
        var out = perEUR
        for (code, perUSD) in dollarPegs where out[code] == nil { out[code] = perUSD * usd }
        return out
    }

    /// The same amount in US dollars (for a "≈ $x" beside amounts shown in your currency).
    func usd(_ amount: Double, from code: String) -> Double? {
        guard let from = rates[code.uppercased()], let usd = rates["USD"], from > 0 else { return nil }
        return amount / from * usd
    }

    /// "≈ $1.72" when you see money in another currency; nil when you already see dollars.
    func usdNote(_ amount: Double, from code: String) -> String? {
        guard target != "USD", let v = usd(amount, from: code) else { return nil }
        return "≈ " + Self.text(v, "USD", decimals: abs(v) < 100 ? 2 : 0)
    }

    func convert(_ amount: Double, from code: String) -> Double? {
        guard let from = rates[code.uppercased()], let to = rates[target], from > 0 else { return nil }
        return amount / from * to
    }

    /// The amount in the chosen currency; in its own currency when no rate exists.
    func format(_ amount: Double, from code: String, decimals: Int? = nil) -> String {
        if let converted = convert(amount, from: code) {
            return Self.text(converted, target, decimals: decimals)
        }
        return Self.text(amount, code.uppercased(), decimals: decimals)
    }

    nonisolated static func text(_ amount: Double, _ code: String, decimals: Int? = nil) -> String {
        let d = decimals ?? (abs(amount) < 100 && amount != amount.rounded() ? 2 : 0)
        return amount.formatted(.currency(code: code).precision(.fractionLength(d)))
    }

    /// A purchase line ("Weekly · 15 CNY (≈ ₹214)") rewritten for the chosen currency:
    /// the original price stays, the converted one follows ("Weekly · CN¥15 (≈ $2.10)").
    func purchaseLine(_ event: StoredEvent) -> String {
        let raw = event.payload[path: "detail"]?.string ?? ""
        let base = raw.replacingOccurrences(of: #"\s*\(≈[^)]*\)"#, with: "", options: .regularExpression)
        let facts = event.payload[path: "facts"]
        var price = facts?[path: "price"]?.number
        var code = facts?[path: "currency"]?.string
        if price == nil || code == nil, let parsed = Self.parsePrice(base) { (price, code) = (parsed.0, parsed.1) }
        guard let price, let code, code.uppercased() != target, let converted = convert(price, from: code) else { return base }
        return "\(base) (≈ \(Self.text(converted, target)))"
    }

    /// One purchase's price in the chosen currency (from its facts, else its price text); nil when unknown.
    func amount(_ event: StoredEvent) -> Double? {
        let facts = event.payload[path: "facts"]
        if let p = facts?[path: "price"]?.number, let c = facts?[path: "currency"]?.string { return convert(p, from: c) }
        let base = (event.payload[path: "detail"]?.string ?? "").replacingOccurrences(of: #"\s*\(≈[^)]*\)"#, with: "", options: .regularExpression)
        return Self.parsePrice(base).flatMap { convert($0.0, from: $0.1) }
    }

    /// "15 CNY", "$2.99", "€2.99", "£4.99", "14.99 PLN" → (amount, ISO code).
    static func parsePrice(_ text: String) -> (Double, String)? {
        if let m = text.firstMatch(of: /(\d[\d.,]*\d|\d)\s([A-Z]{3})/), let v = number(String(m.output.1)) {
            return (v, String(m.output.2))
        }
        let symbols: [Character: String] = ["$": "USD", "€": "EUR", "£": "GBP", "₹": "INR"]
        if let m = text.firstMatch(of: /([$€£₹])\s?(\d[\d.,]*\d|\d)/), let code = symbols[m.output.1.first!],
           let v = number(String(m.output.2)) {
            return (v, code)
        }
        return nil
    }

    /// "1,299" and "1,23,456" (thousands, Indian grouping too) → 1299 / 123456; "2,99" → 2.99; "1.299,50" → 1299.5.
    static func number(_ raw: String) -> Double? {
        var s = raw
        let comma = s.lastIndex(of: ","), dot = s.lastIndex(of: ".")
        if let c = comma, let d = dot {
            // Both: the later one is the decimal mark.
            s = c > d ? s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
                      : s.replacingOccurrences(of: ",", with: "")
        } else if comma != nil {
            let parts = s.split(separator: ",")
            s = parts.count > 1 && parts.last?.count == 3 ? s.replacingOccurrences(of: ",", with: "")
                                                           : s.replacingOccurrences(of: ",", with: ".")
        }
        return Double(s)
    }

    private struct Cached: Codable {
        let date: String
        let rates: [String: Double]
    }
}
