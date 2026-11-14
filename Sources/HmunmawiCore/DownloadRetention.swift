import Compression
import Foundation

/// Of the people who downloaded an app on a day, how many opened it again 1, 7 and 28 days later: App Store
/// Connect's own retention, from its App Sessions report (rows by "App Download Date" and "Date", with "Unique
/// Devices"). Apple fills this report only from people who share analytics with developers, so it's a sample.
public struct DownloadRetention: Sendable, Equatable {
    public struct Point: Sendable, Equatable {
        public let day: Int        // days after the download
        public let kept: Int       // devices that opened it that day
        public let of: Int         // devices that opened it on their download day, in cohorts old enough
        public var share: Double { of > 0 ? Double(kept) / Double(of) : 0 }
    }
    public let app: String
    public let fromDay: String, toDay: String   // the report days read
    public let points: [Point]

    public static let days = [1, 7, 28]

    /// `rows`: App Sessions report rows (any mix of apps). Apps are named by `name(_:)` of the "App Name" column.
    public static func make(_ rows: [[String: String]], name: (String) -> String = { $0 }) -> [String: DownloadRetention] {
        var devices: [String: [Int: [Int: Int]]] = [:]   // app -> download day -> day -> devices
        var first = Int.max, last = Int.min
        for r in rows {
            guard let d = r["Date"].flatMap(DayNumber.of) else { continue }
            first = min(first, d); last = max(last, d)
            guard let c = r["App Download Date"].flatMap(DayNumber.of), d >= c,
                  let n = Double(r["Unique Devices"] ?? ""), n > 0 else { continue }
            devices[name(r["App Name"] ?? ""), default: [:]][c, default: [:]][d, default: 0] += Int(n)
        }
        guard last >= first else { return [:] }
        var out: [String: DownloadRetention] = [:]
        for (app, cohorts) in devices where !app.isEmpty {
            let points = days.compactMap { k -> Point? in
                var of = 0, kept = 0
                for (c, byDay) in cohorts where c + k <= last && c >= first {
                    let base = byDay[c] ?? 0
                    guard base > 0 else { continue }
                    of += base
                    kept += min(base, byDay[c + k] ?? 0)
                }
                return of > 0 ? Point(day: k, kept: kept, of: of) : nil
            }
            if !points.isEmpty { out[app] = DownloadRetention(app: app, fromDay: DayNumber.day(first), toDay: DayNumber.day(last), points: points) }
        }
        return out
    }

    /// Tab-separated text (Apple's report files) into rows keyed by the header.
    public static func parseTSV(_ text: String) -> [[String: String]] {
        var lines = text.split(whereSeparator: \.isNewline).makeIterator()
        guard let header = lines.next()?.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) else { return [] }
        var out: [[String: String]] = []
        while let line = lines.next() {
            let cells = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard cells.count == header.count else { continue }
            var row: [String: String] = [:]
            for (i, key) in header.enumerated() { row[key] = String(cells[i]) }
            out.append(row)
        }
        return out
    }

    /// Unpacks a .gz file (RFC 1952): header and trailer stripped by hand, the deflate stream decoded by Compression.
    public static func gunzip(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var i = 10
        if flags & 0x04 != 0 { guard i + 2 <= bytes.count else { return nil }; i += 2 + (Int(bytes[i]) | (Int(bytes[i + 1]) << 8)) }
        if flags & 0x08 != 0 { while i < bytes.count, bytes[i] != 0 { i += 1 }; i += 1 }
        if flags & 0x10 != 0 { while i < bytes.count, bytes[i] != 0 { i += 1 }; i += 1 }
        if flags & 0x02 != 0 { i += 2 }
        let end = bytes.count - 8
        guard i < end else { return nil }
        let deflated = Array(bytes[i..<end])
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
