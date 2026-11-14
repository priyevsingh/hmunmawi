import Compression
import Foundation
import HmunmawiPluginKit

/// Daily sales from Apple's Sales and Trends reports: first downloads and estimated proceeds per app and day.
struct Sales {
    static let base = AppStoreConnect.base
    static let days = 7

    /// One app's totals for one report day.
    struct Totals: Sendable, Codable {
        var name: String
        var units: Double = 0
        var proceedsUSD: Double = 0
        /// First downloads per country ("US"); nil in days read before this was kept.
        var countries: [String: Double]?
    }

    /// Reports already read, kept on disk: Apple doesn't change a day's report once it's published, so each day
    /// (read with exchange rates) is downloaded once, not every day and not again after a relaunch.
    actor Cache {
        private var reports: [String: [String: Totals]] = [:]

        func totals(for day: String, today: String) -> [String: Totals]? {
            if let hit = reports[day] { return hit }
            guard let data = try? Data(contentsOf: State.file("sales-day-\(day).json")),
                  let saved = try? JSONDecoder().decode([String: Totals].self, from: data) else { return nil }
            reports[day] = saved
            return saved
        }

        func store(_ totals: [String: Totals], for day: String, today: String) {
            reports[day] = totals
            (try? JSONEncoder().encode(totals)).map { StateFile.write($0, to: State.file("sales-day-\(day).json")) }
            // Only the window matters; drop anything older (memory and disk).
            for key in reports.keys.sorted().dropLast(Sales.days + 2) {
                reports[key] = nil
                try? FileManager.default.removeItem(at: State.file("sales-day-\(key).json"))
            }
        }
    }

    static let cache = Cache()

    /// `apps` are the account's apps from /v1/apps with name and sku.
    static func events(vendor: String, apps: [JSONValue], core: Core) async -> [PluginEvent] {
        var names: [String: String] = [:]      // app ID → short name
        var bySKU: [String: String] = [:]      // SKU → app ID
        for app in apps {
            guard let id = app[path: "id"]?.string else { continue }
            names[id] = shortName(app[path: "attributes.name"]?.string ?? id)
            if let sku = app[path: "attributes.sku"]?.string { bySKU[sku] = id }
        }
        let rates = await usdRates(core: core)
        if rates == nil { core.log("sales: exchange rates unavailable, proceeds left out this time") }

        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let format = DateFormatter()
        format.calendar = pacific
        format.timeZone = pacific.timeZone
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"
        let now = Date.now
        let today = format.string(from: now)

        var byDay: [(day: String, totals: [String: Totals])] = []
        for back in 1...days where Budget.left {
            guard let date = pacific.date(byAdding: .day, value: -back, to: now) else { continue }
            let day = format.string(from: date)
            if let cached = await cache.totals(for: day, today: today) {
                byDay.append((day, cached))
                continue
            }
            do {
                guard let rows = try await report(vendor: vendor, day: day, core: core) else { continue }
                var unconverted = 0
                let totals = summarize(rows, names: names, bySKU: bySKU, rates: rates, unconverted: &unconverted)
                if unconverted > 0 { core.log("sales \(day): \(unconverted) paid rows in currencies without a rate, left out") }
                // Without rates the proceeds are incomplete; fetch the day again next poll rather than keep them.
                if rates != nil { await cache.store(totals, for: day, today: today) }
                byDay.append((day, totals))
            } catch {
                core.log("sales \(day): \(error)")
            }
        }

        // Backfill: older days (up to 365 back: a year, so quarterly and yearly cards are complete) read once each, a dozen per round, so payday and the month forecast
        // use whole months. A day is marked done only after it was read with exchange rates.
        let recentDays = Set(byDay.map(\.day))
        var fetched = 0
        for back in (days + 1)...365 where fetched < 12 && Budget.left {
            guard let date = pacific.date(byAdding: .day, value: -back, to: now) else { continue }
            let day = format.string(from: date)
            let mark = State.file("hm-sales-\(vendor)-\(day)")
            if FileManager.default.fileExists(atPath: mark.path) { continue }
            fetched += 1
            do {
                guard let rows = try await report(vendor: vendor, day: day, core: core) else {
                    Pending.note(mark, "")               // Apple has no report for that day (nothing sold)
                    continue
                }
                var unconverted = 0
                let totals = summarize(rows, names: names, bySKU: bySKU, rates: rates, unconverted: &unconverted)
                byDay.append((day, totals))
                if rates != nil { Pending.note(mark, "") }
            } catch {
                core.log("sales backfill \(day): \(error)")
            }
        }

        // Every app seen in the window gets a row each day (0 when it sold nothing that day).
        let seen = Set(byDay.flatMap { $0.totals.keys })
        var events: [PluginEvent] = []
        var shares: [String: Double] = [:]
        var total = 0.0
        let utcDay = DateFormatter()
        utcDay.locale = Locale(identifier: "en_US_POSIX")
        utcDay.timeZone = TimeZone(identifier: "UTC")
        utcDay.dateFormat = "yyyy-MM-dd"
        for (day, totals) in byDay {
            guard let start = utcDay.date(from: day) else { continue }
            let endOfDay = Int64(start.timeIntervalSince1970 * 1000) + 86_400_000 - 1
            for key in seen {
                let t = totals[key] ?? Totals(name: byDay.lazy.compactMap { $0.totals[key]?.name }.first ?? key)
                var payload: [String: JSONValue] = ["day": .string(day), "units": .number(t.units)]
                if let c = t.countries, !c.isEmpty { payload["units_by_country"] = .object(c.mapValues { .number($0) }) }
                if rates != nil {
                    payload["proceeds_usd"] = .number(round2(t.proceedsUSD))
                    // The 7-day money summary counts only the recent window, never backfilled days.
                    if recentDays.contains(day) { shares[t.name, default: 0] += t.proceedsUSD; total += t.proceedsUSD }
                }
                // Without exchange rates the day is held back (not cached, so the next round fetches it again):
                // a rate-less event would take the dedupe key and the day would stay at zero for good.
                guard rates != nil else { continue }
                events.append(PluginEvent(kind: "revenue.daily", app: t.name, payload: .object(payload),
                                          occurredAt: endOfDay, dedupeKey: "sales-\(key)-\(day)"))
            }
        }

        if rates != nil, !byDay.isEmpty {
            let list = shares.sorted { $0.value > $1.value }
                .map { JSONValue.object(["name": .string($0.key), "usd": .number(round2($0.value))]) }
            events.append(PluginEvent(
                kind: "money.portal", app: "All apps",
                payload: .object(["proceeds_usd": .number(round2(total)), "window": .string("USD · 7 days"),
                                  "meaning": .string("Money Apple estimates you keep over the last 7 days, in US dollars."),
                                  "shares": .array(list)]),
                occurredAt: Int64(now.timeIntervalSince1970 * 1000),
                dedupeKey: "money-portal-\(AppStoreConnect.hour().replacingOccurrences(of: "T", with: "-"))"))
        }
        return events
    }

    /// The day's report rows, or nil when Apple has not published it yet.
    /// `type`/`version`: SALES 1_1 (downloads and proceeds) or SUBSCRIPTION 1_3 (active subscriptions and prices).
    static func report(vendor: String, day: String, core: Core, type: String = "SALES", version: String = "1_1") async throws -> [[String: String]]? {
        let v = vendor.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? vendor
        let url = "\(base)/salesReports?filter%5Bfrequency%5D=DAILY&filter%5BreportType%5D=\(type)"
            + "&filter%5BreportSubType%5D=SUMMARY&filter%5BvendorNumber%5D=\(v)&filter%5BreportDate%5D=\(day)"
            + "&filter%5Bversion%5D=\(version)"
        let response = try await core.http(HTTPRequestSpec(
            url: url, headers: ["Authorization": "Bearer {{asc-jwt}}", "Accept": "application/a-gzip"]))
        if response.status == 404 { core.log("404 report not published yet: \(url.split(separator: "?").first.map(String.init) ?? url) \(url.contains("reportDate") ? String(url.split(separator: "=").last ?? "") : "")"); return nil }
        guard response.status == 200 else {
            let body = (try? JSONValue.parse(response.body ?? "")) ?? .null
            let detail = body[path: "errors"]?.array?.first?[path: "detail"]?.string ?? "status \(response.status)"
            throw WireError("asc_sales_failed", "App Store Connect sales: \(detail)")
        }
        let text: String
        if let b64 = response.bodyBase64, let data = Data(base64Encoded: b64) {
            guard let raw = gunzip(data) ?? (data.starts(with: [0x1F, 0x8B]) ? nil : data),
                  let decoded = String(data: raw, encoding: .utf8)
            else { throw WireError("asc_sales_failed", "App Store Connect sales: report could not be unpacked") }
            text = decoded
        } else {
            // Already unpacked on the way (a transfer-level gzip) and sent as text.
            text = response.body ?? ""
        }
        return parseTSV(text)
    }

    /// Apple numbers finance reports by fiscal period, not by calendar month: the year is the fiscal year (starts in
    /// October) and the month is the period (October = 1 … September = 12). "2026-09" (September) is asked for as
    /// "2026-12". Same rule as AppleFiscal.reportDate in the app (tested there).
    static func reportDate(forFiscalName name: String) -> String? {
        let p = name.split(separator: "-")
        guard p.count == 2, let y = Int(p[0]), let m = Int(p[1]), (1...12).contains(m) else { return nil }
        return String(format: "%04d-%02d", m >= 10 ? y + 1 : y, (m + 2) % 12 + 1)
    }

    /// Apple's official monthly finance report (FINANCIAL, all regions "ZZ") for one fiscal month "YYYY-MM":
    /// what Apple owes you, per currency. nil when Apple hasn't published that month yet.
    static func finance(vendor: String, month: String, core: Core) async throws -> [String: Double]? {
        let v = vendor.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? vendor
        let url = "\(base)/financeReports?filter%5BregionCode%5D=ZZ&filter%5BreportType%5D=FINANCIAL"
            + "&filter%5BvendorNumber%5D=\(v)&filter%5BreportDate%5D=\(month)"
        let response = try await core.http(HTTPRequestSpec(url: url, headers: ["Authorization": "Bearer {{asc-jwt}}", "Accept": "application/a-gzip"]))
        if response.status == 404 { core.log("404 report not published yet: \(url.split(separator: "?").first.map(String.init) ?? url) \(url.contains("reportDate") ? String(url.split(separator: "=").last ?? "") : "")"); return nil }
        guard response.status == 200 else {
            let body = (try? JSONValue.parse(response.body ?? "")) ?? .null
            throw WireError("asc_finance_failed", "App Store Connect finance: " + (body[path: "errors"]?.array?.first?[path: "detail"]?.string ?? "status \(response.status)"))
        }
        var text = response.body ?? ""
        if let b64 = response.bodyBase64, let data = Data(base64Encoded: b64), let raw = gunzip(data) ?? (data.starts(with: [0x1F, 0x8B]) ? nil : data) {
            text = String(decoding: raw, as: UTF8.self)
        }
        var totals: [String: Double] = [:]
        for row in parseTSV(text) {
            guard let cur = row["Partner Share Currency"], cur.count == 3,
                  let amount = Double((row["Extended Partner Share"] ?? "").replacingOccurrences(of: ",", with: "")) else { continue }
            totals[cur, default: 0] += amount
        }
        return totals
    }

    static func parseTSV(_ text: String) -> [[String: String]] {
        let lines = text.split(whereSeparator: \.isNewline)
        guard let header = lines.first?.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        else { return [] }
        return lines.dropFirst().compactMap { line in
            let cells = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cells.count >= header.count / 2 else { return nil }
            var row: [String: String] = [:]
            for (i, key) in header.enumerated() where i < cells.count { row[key] = cells[i] }
            return row
        }
    }

    /// Totals per app ID for one day's rows.
    static func summarize(_ rows: [[String: String]], names: [String: String], bySKU: [String: String],
                          rates: [String: Double]?, unconverted: inout Int) -> [String: Totals] {
        var out: [String: Totals] = [:]
        for row in rows {
            let type = row["Product Type Identifier"] ?? ""
            let appleID = row["Apple Identifier"] ?? ""
            let isApp = type.hasPrefix("1") || type.hasPrefix("F1") || type.hasPrefix("3") || type.hasPrefix("7")
            // App rows carry the app's own ID; in-app rows point at the app's SKU in "Parent Identifier".
            let key: String
            if isApp || names[appleID] != nil {
                key = appleID
            } else if let parent = row["Parent Identifier"], let id = bySKU[parent] {
                key = id
            } else {
                continue
            }
            guard !key.isEmpty else { continue }
            let name = names[key] ?? shortName(isApp ? (row["Title"] ?? key) : key)
            var t = out[key] ?? Totals(name: name, countries: [:])
            let units = Double(row["Units"] ?? "") ?? 0
            if type == "1" || type == "1F" || type == "1T" || type == "F1" {
                t.units += units
                let c = (row["Country Code"] ?? "").trimmingCharacters(in: .whitespaces).uppercased()
                if c.count == 2 { t.countries?[c, default: 0] += units }
            }
            if let rates {
                let amount = units * (Double(row["Developer Proceeds"] ?? "") ?? 0)
                let currency = (row["Currency of Proceeds"] ?? "").trimmingCharacters(in: .whitespaces).uppercased()
                if currency.isEmpty || currency == "USD" {
                    t.proceedsUSD += amount
                } else if let rate = rates[currency], rate > 0 {
                    t.proceedsUSD += amount / rate
                } else if amount != 0 {
                    unconverted += 1
                }
            }
            out[key] = t
        }
        return out
    }

    /// ECB rates per US dollar (EUR → 0.92 means 1 USD buys 0.92 EUR).
    static func usdRates(core: Core) async -> [String: Double]? {
        guard let response = try? await core.http(HTTPRequestSpec(url: "https://api.frankfurter.dev/v1/latest?from=USD")),
              response.status == 200,
              let body = try? JSONValue.parse(response.body ?? ""),
              case .object(let rates)? = body[path: "rates"]
        else { return nil }
        var out = rates.compactMapValues(\.number)
        // The ECB does not publish these; they are fixed to the dollar.
        for (code, rate) in ["AED": 3.6725, "SAR": 3.75, "QAR": 3.64, "BHD": 0.376, "OMR": 0.3845, "JOD": 0.709]
        where out[code] == nil { out[code] = rate }
        out["USD"] = 1
        return out
    }

    /// "My App: Photo Editor" → "My App".
    static func shortName(_ full: String) -> String {
        String(full.split(separator: ":", maxSplits: 1).first ?? Substring(full)).trimmingCharacters(in: .whitespaces)
    }

    static func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }

    /// Unpacks a gzip file (RFC 1952). Foundation has no gunzip, so the header and trailer are stripped
    /// by hand and the raw deflate stream is decoded with Compression's ZLIB (raw deflate) decoder.
    static func gunzip(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var i = 10
        if flags & 0x04 != 0 {  // FEXTRA
            guard i + 2 <= bytes.count else { return nil }
            i += 2 + (Int(bytes[i]) | (Int(bytes[i + 1]) << 8))
        }
        if flags & 0x08 != 0 {  // FNAME
            while i < bytes.count, bytes[i] != 0 { i += 1 }
            i += 1
        }
        if flags & 0x10 != 0 {  // FCOMMENT
            while i < bytes.count, bytes[i] != 0 { i += 1 }
            i += 1
        }
        if flags & 0x02 != 0 { i += 2 }  // FHCRC
        let end = bytes.count - 8
        guard i < end else { return nil }
        let deflated = Array(bytes[i..<end])
        // The trailer's last 4 bytes give the unpacked size (mod 2^32); grow if that is ever wrong.
        let isize = Int(bytes[end + 4]) | (Int(bytes[end + 5]) << 8) | (Int(bytes[end + 6]) << 16) | (Int(bytes[end + 7]) << 24)
        var capacity = max(isize + 1, deflated.count * 4, 1024)
        for _ in 0..<6 {
            var out = [UInt8](repeating: 0, count: capacity)
            let n = compression_decode_buffer(&out, capacity, deflated, deflated.count, nil, COMPRESSION_ZLIB)
            if n == 0 { return nil }
            if n < capacity { return Data(out[0..<n]) }
            capacity *= 4
        }
        return nil
    }
}
