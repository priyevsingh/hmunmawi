import Foundation

/// AI providers whose spending or balance can be read with a read-only key, and how each answer is turned into
/// numbers. Network calls live in the app; parsing and the month's sums live here so they're tested.
///
/// - Daily spend (Anthropic, OpenAI, xAI): what was used each day, so this month's spend and its pace are exact.
/// - Balance only (OpenRouter, DeepSeek): what's left (and, for DeepSeek, free vs topped-up). Spend this month is
///   worked out from the readings Hmunmawi keeps, so it starts on the first reading of the month.
public enum SpendProvider: String, CaseIterable, Codable, Sendable, Identifiable {
    case openai, xai, openrouter, deepseek
    public var id: String { rawValue }
    public var name: String {
        switch self { case .openai: "OpenAI"; case .xai: "xAI (Grok)"; case .openrouter: "OpenRouter"; case .deepseek: "DeepSeek" }
    }
    /// Which key it takes and where to make one (read-only where the provider allows it).
    public var keyHint: String {
        switch self {
        case .openai: "An Admin key (platform.openai.com → Settings → Admin keys; organization owner)."
        case .xai: "A Management key with Billing set to read-only (console.x.ai → Settings → Management Keys), and your Team ID (Settings)."
        case .openrouter: "A Management key (openrouter.ai → Settings → Management keys)."
        case .deepseek: "Your API key (platform.deepseek.com → API keys): the balance read needs no other access."
        }
    }
    public var placeholder: String {
        switch self { case .openai: "sk-admin-…"; case .xai: "xai-…"; case .openrouter: "sk-or-…"; case .deepseek: "sk-…" }
    }
    public var needsTeamID: Bool { self == .xai }
    public var dailySpend: Bool { self == .openai || self == .xai }
    /// A quick format check before any request (the read itself is the real test).
    public func looksValid(_ key: String) -> Bool {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard k.count >= 20, k.count <= 300, !k.contains(where: \.isWhitespace) else { return false }
        switch self {
        case .openai: return k.hasPrefix("sk-admin-")
        case .openrouter: return k.hasPrefix("sk-or-")
        case .deepseek: return k.hasPrefix("sk-")
        case .xai: return true
        }
    }
}

/// One reading of a provider. Amounts in USD unless `currency` says otherwise (DeepSeek can answer in CNY).
public struct AIReading: Codable, Sendable, Equatable {
    public var provider: SpendProvider
    public var at: Date
    public var currency = "USD"
    /// Daily providers: spend per UTC day, oldest first.
    public var days: [Day] = []
    /// Balance providers: the account's running totals.
    public var bought: Double?          // OpenRouter: credits bought, all time
    public var used: Double?            // OpenRouter: credits used, all time
    public var granted: Double?         // DeepSeek: free balance left
    public var toppedUp: Double?        // DeepSeek: bought balance left; xAI: prepaid balance left
    public struct Day: Codable, Sendable, Equatable { public var day: String; public var usd: Double
        public init(day: String, usd: Double) { self.day = day; self.usd = usd } }
    public init(provider: SpendProvider, at: Date) { self.provider = provider; self.at = at }

    public var left: Double? {
        if let b = bought, let u = used { return max(0, b - u) }
        if let g = granted, let t = toppedUp { return g + t }
        return toppedUp
    }
}

public enum AISpendMath {
    static let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
    public static func day(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = utc.timeZone; f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
    public static func date(_ day: String) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = utc.timeZone; f.dateFormat = "yyyy-MM-dd"
        return f.date(from: day)
    }
    public static func monthKey(_ d: Date) -> String { String(day(d).prefix(7)) }

    // MARK: Parsers (shapes from each provider's API reference)

    /// OpenAI GET /v1/organization/costs: data[].start_time (Unix s), results[].amount.value (USD).
    public static func openAIDays(_ data: Data) -> (days: [AIReading.Day], next: String?)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let buckets = root["data"] as? [[String: Any]] else { return nil }
        var out: [AIReading.Day] = []
        for b in buckets {
            guard let t = (b["start_time"] as? NSNumber)?.doubleValue else { continue }
            let usd = ((b["results"] as? [[String: Any]]) ?? []).compactMap { r -> Double? in
                guard let a = r["amount"] as? [String: Any] else { return nil }
                let cur = (a["currency"] as? String)?.lowercased() ?? "usd"
                return cur == "usd" ? (a["value"] as? NSNumber)?.doubleValue : nil
            }.reduce(0, +)
            out.append(.init(day: day(Date(timeIntervalSince1970: t)), usd: usd))
        }
        let next = (root["has_more"] as? Bool) == true ? root["next_page"] as? String : nil
        return (out, next)
    }

    /// xAI POST /v1/billing/teams/{id}/usage (values [{name: "usd", SUM}], TIME_UNIT_DAY): every series' points summed
    /// per day. Amounts are USD.
    public static func xaiDays(_ data: Data) -> [AIReading.Day]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let series = root["timeSeries"] as? [[String: Any]] else { return nil }
        var byDay: [String: Double] = [:]
        let iso = ISO8601DateFormatter(), isoFrac = ISO8601DateFormatter(); isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for s in series {
            for p in (s["dataPoints"] as? [[String: Any]]) ?? [] {
                guard let ts = p["timestamp"] as? String, let d = iso.date(from: ts) ?? isoFrac.date(from: ts) else { continue }
                let v = ((p["values"] as? [Any]) ?? []).compactMap { ($0 as? NSNumber)?.doubleValue ?? Double("\($0)") }.first ?? 0
                byDay[day(d), default: 0] += v
            }
        }
        return byDay.keys.sorted().map { .init(day: $0, usd: byDay[$0]!) }
    }

    /// xAI GET /v1/billing/teams/{id}/prepaid/balance: total.val in USD cents; purchases are negative.
    public static func xaiPrepaidLeft(_ data: Data) -> Double? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let total = root["total"] as? [String: Any], let v = (total["val"] as? String).flatMap(Double.init) ?? (total["val"] as? NSNumber)?.doubleValue
        else { return nil }
        return max(0, -v / 100)
    }

    /// OpenRouter GET /api/v1/credits: data.total_credits, data.total_usage (USD).
    public static func openRouter(_ data: Data) -> (bought: Double, used: Double)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let d = root["data"] as? [String: Any],
              let b = (d["total_credits"] as? NSNumber)?.doubleValue, let u = (d["total_usage"] as? NSNumber)?.doubleValue else { return nil }
        return (b, u)
    }

    /// DeepSeek GET /user/balance: balance_infos[] (USD preferred, else the first), amounts as strings.
    public static func deepSeek(_ data: Data) -> (currency: String, granted: Double, toppedUp: Double)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let infos = root["balance_infos"] as? [[String: Any]],
              let pick = infos.first(where: { ($0["currency"] as? String) == "USD" }) ?? infos.first else { return nil }
        func num(_ k: String) -> Double? { (pick[k] as? String).flatMap(Double.init) ?? (pick[k] as? NSNumber)?.doubleValue }
        guard let g = num("granted_balance"), let t = num("topped_up_balance") else { return nil }
        return ((pick["currency"] as? String) ?? "USD", g, t)
    }

    // MARK: This month

    public struct Month: Sendable, Equatable {
        public var used: Double              // all spend this month (free and bought)
        public var paid: Double              // from your own money (what counts as a cost)
        public var low: Double, high: Double // month-end range of `paid`
        public var since: String?            // balance providers: the first reading this month, if after the 1st
    }

    /// Daily providers: this month's spend, and the month-end range from this month's pace to the last 28 days'.
    /// `paying`: whether this account's spend is your own money (no free credits).
    public static func month(days: [AIReading.Day], now: Date, paying: Bool) -> Month {
        let m = monthKey(now), today = day(now)
        let thisMonth = days.filter { $0.day.hasPrefix(m) && $0.day < today }
        let used = thisMonth.map(\.usd).reduce(0, +)
        let daysDone = max(0, utc.component(.day, from: now) - 1)
        let total = utc.range(of: .day, in: .month, for: now)?.count ?? 30
        let start28 = day(utc.date(byAdding: .day, value: -28, to: utc.startOfDay(for: now))!)
        let pace28 = days.filter { $0.day >= start28 && $0.day < today }.map(\.usd).reduce(0, +) / 28
        let paceOwn = daysDone > 0 ? used / Double(daysDone) : pace28
        let rest = Double(total - daysDone)
        let a = used + paceOwn * rest, b = used + pace28 * rest
        return paying ? Month(used: used, paid: used, low: min(a, b), high: max(a, b), since: nil)
                      : Month(used: used, paid: 0, low: 0, high: 0, since: nil)
    }

    /// Balance providers: spend this month from the kept readings (oldest first). OpenRouter: the rise in credits
    /// used. DeepSeek: falls in each balance (free ones aren't your money; a rise in the topped-up balance is a
    /// purchase, not spend). The range scales what's been seen to the whole month.
    public static func month(readings: [AIReading], now: Date, paying: Bool) -> Month? {
        let m = monthKey(now)
        let list = readings.filter { monthKey($0.at) == m }.sorted { $0.at < $1.at }
        guard let first = list.first, let last = list.last else { return nil }
        var used = 0.0, paid = 0.0
        if let u0 = first.used, let u1 = last.used {
            used = max(0, u1 - u0); paid = paying ? used : 0
        } else {
            for (a, b) in zip(list, list.dropFirst()) {
                let freeSpent = max(0, (a.granted ?? 0) - (b.granted ?? 0))
                let ownSpent = max(0, (a.toppedUp ?? 0) - (b.toppedUp ?? 0))
                used += freeSpent + ownSpent
                paid += ownSpent
            }
            if !paying { paid = 0 }
        }
        let startDay = day(first.at)
        let since = startDay.hasSuffix("-01") ? nil : startDay
        let seenDays = max(1, last.at.timeIntervalSince(first.at) / 86_400)
        let total = Double(utc.range(of: .day, in: .month, for: now)?.count ?? 30)
        let elapsed = Double(utc.component(.day, from: now)) - (since == nil ? 1 : Double(utc.component(.day, from: first.at)))
        // Too little seen to project (under a day): the range is what's been paid so far.
        let high = seenDays >= 1 && elapsed >= 1 ? paid + paid / seenDays * max(0, total - Double(utc.component(.day, from: now)) + 1) : paid
        return Month(used: used, paid: paid, low: paid, high: max(paid, high), since: since)
    }
}

/// A paid plan or tool with no API to read (ChatGPT Plus, Claude Pro, Cursor…): quick-add names, typed amounts.
public enum AIPlanPresets {
    public static let names: [String] = [
        "Claude Pro", "Claude Max", "Claude Team", "ChatGPT Plus", "ChatGPT Pro", "ChatGPT Business",
        "Google AI Pro (Gemini)", "Gemini API (Google Cloud billing)", "SuperGrok", "Cursor Pro", "GitHub Copilot", "Perplexity Pro",
    ]
}
