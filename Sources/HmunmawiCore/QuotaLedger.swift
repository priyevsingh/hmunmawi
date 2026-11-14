import Foundation

/// What a web service says about its own request limit, read from the headers of every answer an add-on gets.
/// Nothing is guessed: a service that reports no limit is shown only by how many requests Hmunmawi made to it.
public struct QuotaReading: Sendable, Equatable {
    public var host: String
    public var limit: Int?
    public var remaining: Int?
    public var window: String?          // "hour", "15 minutes" ... as the service names it, when it does
    public var resetsAt: Date?
    public var callsLastHour: Int
    public var lastTooMany: Date?       // last HTTP 429
    public var seen: Date
    public var usedPercent: Double? {
        guard let limit, let remaining, limit > 0 else { return nil }
        return min(100, max(0, Double(limit - remaining) / Double(limit) * 100))
    }
}

public enum QuotaHeaders {
    public struct Parsed: Equatable { public var limit: Int?, remaining: Int?, window: String?, resetsAt: Date? }

    /// Reads the limit headers in the forms in common use. `headers` has lowercase names.
    /// - Apple (App Store Connect): a value like `user-hour-lim:3500;user-hour-rem:500;` (any header name).
    /// - `x-rate-limit-*` and `x-ratelimit-*` (reset = a time in seconds since 1970), `ratelimit-*` (reset = seconds from now).
    public static func parse(_ headers: [String: String], now: Date = .now) -> Parsed? {
        for value in headers.values {
            guard value.contains("-lim:"), value.contains("-rem:") else { continue }
            var limit: Int?, remaining: Int?, window: String?
            for part in value.split(separator: ";") {
                let kv = part.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
                guard kv.count == 2, let n = Int(kv[1]) else { continue }
                if kv[0].hasSuffix("-lim") { limit = n; window = kv[0].split(separator: "-").dropFirst().first.map(String.init) }
                else if kv[0].hasSuffix("-rem") { remaining = n }
            }
            if limit != nil || remaining != nil { return Parsed(limit: limit, remaining: remaining, window: window, resetsAt: nil) }
        }
        for prefix in ["x-rate-limit-", "x-ratelimit-", "ratelimit-"] {
            let limit = headers[prefix + "limit"].flatMap { Int($0.split(separator: ",").first.map(String.init) ?? "") }
            let remaining = headers[prefix + "remaining"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard limit != nil || remaining != nil else { continue }
            var reset: Date?
            if let r = headers[prefix + "reset"].flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }), r >= 0 {
                reset = r > 1_000_000_000 ? Date(timeIntervalSince1970: r) : now.addingTimeInterval(r)
            }
            return Parsed(limit: limit, remaining: remaining, window: nil, resetsAt: reset)
        }
        return nil
    }

    /// When a 429's Retry-After says to try again: seconds or an HTTP date.
    public static func retryAfter(_ value: String?, now: Date = .now) -> Date? {
        guard let v = value?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
        if let s = Double(v), s >= 0, s < 86_400 * 7 { return now.addingTimeInterval(s) }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: v)
    }
}

/// The running record, in memory: the newest limit each host reported, and how many requests went to each in the
/// last hour. Safe to call from any thread.
public final class QuotaLedger: @unchecked Sendable {
    public static let shared = QuotaLedger()
    private let lock = NSLock()
    private var latest: [String: QuotaReading] = [:]
    private var calls: [String: [Date]] = [:]

    public init() {}

    public func note(host rawHost: String?, status: Int, headers: [AnyHashable: Any], now: Date = .now) {
        guard let host = rawHost?.lowercased(), !host.isEmpty else { return }
        var lower: [String: String] = [:]
        for (k, v) in headers { if let k = k as? String, let v = v as? String { lower[k.lowercased()] = v } }
        let parsed = QuotaHeaders.parse(lower, now: now)
        lock.withLock {
            var times = (calls[host] ?? []).filter { now.timeIntervalSince($0) < 3600 }
            times.append(now); calls[host] = times
            var r = latest[host] ?? QuotaReading(host: host, limit: nil, remaining: nil, window: nil, resetsAt: nil, callsLastHour: 0, lastTooMany: nil, seen: now)
            if let p = parsed { r.limit = p.limit ?? r.limit; r.remaining = p.remaining; r.window = p.window ?? r.window; r.resetsAt = p.resetsAt ?? r.resetsAt }
            if status == 429 {
                r.lastTooMany = now
                if let again = QuotaHeaders.retryAfter(lower["retry-after"], now: now) { r.resetsAt = again }
            }
            r.callsLastHour = times.count; r.seen = now
            latest[host] = r
        }
    }

    /// Hosts with a reported limit, or that said "too many" in the last day, newest first. Others are left out: a
    /// count of requests alone isn't a quota.
    public func readings(now: Date = .now) -> [QuotaReading] {
        lock.withLock {
            latest.values.compactMap { r -> QuotaReading? in
                var r = r
                r.callsLastHour = (calls[r.host] ?? []).filter { now.timeIntervalSince($0) < 3600 }.count
                let recent429 = r.lastTooMany.map { now.timeIntervalSince($0) < 86_400 } ?? false
                return r.limit != nil || r.remaining != nil || recent429 ? r : nil
            }.sorted { $0.seen > $1.seen }
        }
    }

    public func reset() { lock.withLock { latest = [:]; calls = [:] } }
}


public extension QuotaReading {
    /// A friendly name for well-known hosts, else the host itself.
    var service: String {
        switch host {
        case "api.appstoreconnect.apple.com": "App Store Connect API"
        case "api.x.com", "api.twitter.com": "X API"
        case "api.github.com": "GitHub API"
        default: host
        }
    }

    /// "3,400 of 3,500 requests left this hour" (or just how many requests went out, when no limit is reported).
    func detail(now: Date = .now) -> String {
        if let limit, let remaining {
            return "\(remaining.formatted()) of \(limit.formatted()) requests left" + (window.map { " this \($0)" } ?? "")
        }
        if let remaining { return "\(remaining.formatted()) requests left" }
        return "\(callsLastHour) request\(callsLastHour == 1 ? "" : "s") in the last hour"
    }

    /// Plain words when the service recently said "too many requests".
    func trouble(now: Date = .now) -> String? {
        guard let t = lastTooMany, now.timeIntervalSince(t) < 3600 else { return nil }
        let minutes = max(1, Int(now.timeIntervalSince(t) / 60))
        return "Said \u{201C}too many requests\u{201D} \(minutes) minute\(minutes == 1 ? "" : "s") ago. It slows down on its own."
    }
}
