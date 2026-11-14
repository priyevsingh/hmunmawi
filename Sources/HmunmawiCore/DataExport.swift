import Foundation

/// Turns what Hmunmawi has stored into a file you can open in a spreadsheet or hand to an accountant. Pure text
/// formatting: nothing here touches the network or writes anywhere (the app saves where you choose).
public enum DataExport {
    public enum Dataset: String, CaseIterable, Sendable {
        case reviews, daily, everything
        public var title: String {
            switch self { case .reviews: "Reviews"; case .daily: "Daily downloads and proceeds"; case .everything: "Everything (every event)" }
        }
        /// The event kinds to read; nil = all of them.
        public var kinds: Set<String>? {
            switch self { case .reviews: ["review.new"]; case .daily: ["revenue.daily"]; case .everything: nil }
        }
    }

    public struct Table: Sendable, Equatable {
        public var header: [String]
        public var rows: [[String]]
        /// Columns holding numbers (kept as they are); every other cell is text and is made safe for a spreadsheet.
        public var numeric: Set<Int>
    }

    private static func iso(_ ms: Int64) -> String {
        ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    public static func table(_ dataset: Dataset, events: [StoredEvent]) -> Table {
        let sorted = events.sorted { ($0.occurredAt, $0.id) < ($1.occurredAt, $1.id) }
        switch dataset {
        case .reviews:
            let rows = sorted.filter { $0.kind == "review.new" }.map { e -> [String] in
                [iso(e.occurredAt), e.app ?? "", e.payload[path: "rating"]?.number.map { String(Int(safe: $0)) } ?? "",
                 e.payload[path: "title"]?.string ?? "", e.payload[path: "body"]?.string ?? "", e.payload[path: "territory"]?.string ?? "",
                 e.payload[path: "review_id"]?.string ?? ""]
            }
            return Table(header: ["date", "app", "stars", "title", "text", "country", "review_id"], rows: rows, numeric: [2])
        case .daily:
            // One row per app and day (the newest reading of that day wins).
            var latest: [String: StoredEvent] = [:]
            for e in sorted where e.kind == "revenue.daily" { latest["\(e.app ?? "")|\(e.payload[path: "day"]?.string ?? iso(e.occurredAt))"] = e }
            let rows = latest.values.sorted { ($0.payload[path: "day"]?.string ?? "", $0.app ?? "") < ($1.payload[path: "day"]?.string ?? "", $1.app ?? "") }.map { e in
                [e.payload[path: "day"]?.string ?? iso(e.occurredAt), e.app ?? "",
                 e.payload[path: "units"]?.number.map { String(Int(safe: $0)) } ?? "",
                 e.payload[path: "proceeds_usd"]?.number.map { String(format: "%.2f", $0) } ?? ""]
            }
            return Table(header: ["day", "app", "downloads", "proceeds_usd"], rows: rows, numeric: [2, 3])
        case .everything:
            let rows = sorted.map { e -> [String] in
                let raw = (try? JSONEncoder().encode(e.payload)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                return [iso(e.occurredAt), e.kind, e.app ?? "", EventText.describe(e), raw]
            }
            return Table(header: ["time", "kind", "app", "summary", "details_json"], rows: rows, numeric: [])
        }
    }

    /// A cell that starts with = + - @ (or a tab or return) would run as a formula in a spreadsheet, so text cells get a
    /// leading apostrophe-free guard: a single quote prefix, which spreadsheets show as plain text.
    static func safeText(_ s: String) -> String {
        guard let f = s.unicodeScalars.first, "=+-@\t\r".unicodeScalars.contains(f) else { return s }
        return "'" + s
    }

    public static func csv(_ t: Table) -> String {
        func cell(_ s: String) -> String {
            s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        var lines = [t.header.map(cell).joined(separator: ",")]
        for r in t.rows {
            lines.append(r.enumerated().map { i, v in cell(t.numeric.contains(i) ? v : safeText(v)) }.joined(separator: ","))
        }
        return "\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n"     // BOM so Excel reads accents correctly
    }

    public static func json(_ t: Table) -> String {
        let objects: [[String: Any]] = t.rows.map { r in
            var o: [String: Any] = [:]
            for (i, h) in t.header.enumerated() where i < r.count {
                o[h] = t.numeric.contains(i) ? (Double(r[i]).map { $0 == $0.rounded() && abs($0) < 1e15 ? (Int($0) as Any) : ($0 as Any) } ?? r[i]) : r[i]
            }
            return o
        }
        let data = (try? JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    public static func filename(_ d: Dataset, json: Bool, now: Date = .now) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return "hmunmawi-\(d.rawValue)-\(f.string(from: now)).\(json ? "json" : "csv")"
    }
}
