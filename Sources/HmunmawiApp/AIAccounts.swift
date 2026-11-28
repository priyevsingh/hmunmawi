import Foundation
import HmunmawiCore

/// Other AI accounts (OpenAI, xAI, OpenRouter, DeepSeek) read with read-only keys from the Keychain, for
/// "From your pocket so far" and its details. Anthropic stays in Credits (it has its own credit rules).
/// One read per account at most every 30 minutes; the last readings are kept on disk, so a restart or a refused
/// read shows real figures.
@MainActor @Observable
final class AIAccounts {
    static let shared = AIAccounts()

    struct Status: Equatable { var month: AISpendMath.Month?; var left: Double?; var currency: String; var read: Date?; var problem: String? }

    private(set) var readings: [SpendProvider: [AIReading]] = [:]
    private(set) var problems: [SpendProvider: String] = [:]
    private(set) var connected: Set<SpendProvider> = []
    private var lastAttempt: [SpendProvider: Date] = [:]
    private var busy: Set<SpendProvider> = []
    private var refusedNow: [SpendProvider: Bool] = [:]
    private let url = URL.hmSupport.appending(path: "ai-accounts.json")

    init() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: url), let r = try? dec.decode([String: [AIReading]].self, from: d) {
            for (k, v) in r { if let p = SpendProvider(rawValue: k) { readings[p] = v } }
        }
        connected = Set(SpendProvider.allCases.filter { key($0) != nil })
    }

    // MARK: Keys and choices

    private static let store = KeychainSecretStore()
    func key(_ p: SpendProvider) -> String? { ((try? Self.store.secret(plugin: "usage", name: "\(p.rawValue)-key")) ?? nil).flatMap { $0.isEmpty ? nil : $0 } }
    func teamID(_ p: SpendProvider) -> String { UserDefaults.standard.string(forKey: "HMAITeam-\(p.rawValue)") ?? "" }
    /// Whether this account's spend is your own money (default) or free credits only.
    func paying(_ p: SpendProvider) -> Bool { (UserDefaults.standard.object(forKey: "HMAIPays-\(p.rawValue)") as? Bool) ?? true }
    func setPaying(_ p: SpendProvider, _ v: Bool) { UserDefaults.standard.set(v, forKey: "HMAIPays-\(p.rawValue)") }

    /// Saves the key (and team ID), then reads once to prove it works. Returns a line for the user.
    func connect(_ p: SpendProvider, key: String, team: String) async -> String {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines), t = team.trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.looksValid(k) else { return "That doesn't look like \(p.name)'s key: \(p.keyHint)" }
        // xAI team IDs are UUIDs (its API answers "Invalid uuid" otherwise).
        if p.needsTeamID, UUID(uuidString: t) == nil { return "Add your xAI Team ID, like 1a2b3c4d-…-…: console.x.ai → Settings." }
        do { try Self.store.setSecret(k, plugin: "usage", name: "\(p.rawValue)-key") } catch { return "Couldn't save to the Keychain: \(plainError(error))" }
        if p.needsTeamID { UserDefaults.standard.set(t, forKey: "HMAITeam-\(p.rawValue)") }
        connected.insert(p)
        lastAttempt[p] = nil
        await refresh(p)
        // A key refused on its first read is never kept (a typo or the wrong kind of key); a busy or offline
        // provider is a different story: the key may be fine, so it's kept and read again later.
        if refusedNow[p] == true, let problem = problems[p] { disconnect(p); return "Not saved: \(problem)" }
        if let problem = problems[p] { return "Saved, but the first read failed: \(problem). Hmunmawi tries again within 30 minutes." }
        guard let s = status(p) else { return "Saved." }
        let m = s.month.map { String(format: "$%.2f used this month", $0.used) } ?? "first reading taken"
        return "Connected: " + m + (s.left.map { String(format: ", %@ %.2f left", s.currency == "USD" ? "$" : s.currency, $0) } ?? "") + "."
    }

    func disconnect(_ p: SpendProvider) {
        Self.store.deleteSecret(plugin: "usage", name: "\(p.rawValue)-key")
        connected.remove(p); readings[p] = nil; problems[p] = nil; shortProblems[p] = nil; refusedNow[p] = nil
        save()
    }

    // MARK: Reading

    func refreshAll() async { for p in connected { await refresh(p) } }

    func refresh(_ p: SpendProvider) async {
        guard !busy.contains(p), let k = key(p) else { return }
        if let last = lastAttempt[p], Date.now.timeIntervalSince(last) < 1800 { return }
        busy.insert(p); defer { busy.remove(p) }
        lastAttempt[p] = .now
        do {
            var r = AIReading(provider: p, at: .now)
            switch p {
            case .openai: r.days = try await Self.openAI(k)
            case .xai:
                r.days = try await Self.xaiUsage(k, team: teamID(p))
                r.toppedUp = try? await Self.xaiPrepaid(k, team: teamID(p))
            case .openrouter: (r.bought, r.used) = try await Self.openRouter(k)
            case .deepseek: (r.currency, r.granted, r.toppedUp) = try await Self.deepSeek(k)
            }
            // Daily accounts: the newest reading holds every day; balance accounts keep a history (70 days).
            if p.dailySpend { readings[p] = [r] }
            else {
                let cutoff = Date.now.addingTimeInterval(-70 * 86_400)
                readings[p] = ((readings[p] ?? []).filter { $0.at > cutoff } + [r]).suffix(400)
            }
            problems[p] = nil; shortProblems[p] = nil; refusedNow[p] = nil
            save()
        } catch {
            let e = error as? ReadError
            problems[p] = e?.text ?? error.localizedDescription
            shortProblems[p] = e?.short ?? "no connection"
            refusedNow[p] = e?.refused ?? false
        }
    }

    func status(_ p: SpendProvider) -> Status? {
        guard let list = readings[p], let last = list.last else { return problems[p].map { Status(month: nil, left: nil, currency: "USD", read: nil, problem: $0) } }
        let month = p.dailySpend ? AISpendMath.month(days: last.days, now: .now, paying: paying(p))
                                 : AISpendMath.month(readings: list, now: .now, paying: paying(p))
        return Status(month: month, left: last.left, currency: last.currency, read: last.at, problem: problems[p])
    }

    /// Paid this month across the other accounts, in USD (a CNY DeepSeek account is converted when rates allow).
    func paidUSD(_ pick: (AISpendMath.Month) -> Double) -> Double {
        connected.compactMap { p -> Double? in
            guard let s = status(p), let m = s.month else { return nil }
            return s.currency == "USD" ? pick(m) : Money.shared.usd(pick(m), from: s.currency)
        }.reduce(0, +)
    }

    private func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let out = Dictionary(uniqueKeysWithValues: readings.map { ($0.key.rawValue, $0.value) })
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? enc.encode(out).write(to: url, options: .atomic)
    }

    // MARK: Requests (read-only)

    struct ReadError: Error {
        let text: String
        var short = "couldn't read"
        var refused = false
    }
    /// The short reason for the card ("key refused"); the full one is in the details.
    private(set) var shortProblems: [SpendProvider: String] = [:]

    nonisolated private static func get(_ req: URLRequest) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let msg = ((root?["error"] as? [String: Any])?["message"] as? String) ?? (root?["error"] as? String) ?? (root?["message"] as? String)
            switch code {
            case 401, 403: throw ReadError(text: "the key was refused (\(code)): it may be the wrong kind of key or lack billing read access" + (msg.map { ": \($0)" } ?? ""), short: "key refused", refused: true)
            case 429: throw ReadError(text: "too many requests right now; Hmunmawi tries again within 30 minutes", short: "busy, trying again soon")
            default: throw ReadError(text: "status \(code)" + (msg.map { ": \($0)" } ?? ""), short: "read failed (\(code))")
            }
        }
        return data
    }

    nonisolated private static func request(_ url: URL, bearer: String) -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: 30)
        r.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        return r
    }

    /// The last 28 days and this month (whichever reaches back further), whole UTC days.
    nonisolated private static func window() -> (from: Date, to: Date) {
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let today = utc.startOfDay(for: .now)
        let monthStart = utc.dateInterval(of: .month, for: .now)!.start
        return (min(monthStart, utc.date(byAdding: .day, value: -28, to: today)!), today)
    }

    nonisolated static func openAI(_ key: String) async throws -> [AIReading.Day] {
        let w = window()
        guard w.to > w.from else { return [] }
        var all: [AIReading.Day] = [], page: String? = nil, pages = 0
        repeat {
            var c = URLComponents(string: "https://api.openai.com/v1/organization/costs")!
            c.queryItems = [.init(name: "start_time", value: "\(Int(w.from.timeIntervalSince1970))"),
                            .init(name: "end_time", value: "\(Int(w.to.timeIntervalSince1970))"),
                            .init(name: "bucket_width", value: "1d"), .init(name: "limit", value: "60")]
            if let page { c.queryItems?.append(.init(name: "page", value: page)) }
            guard let parsed = AISpendMath.openAIDays(try await get(request(c.url!, bearer: key))) else { throw ReadError(text: "OpenAI answered in an unexpected format") }
            all += parsed.days; page = parsed.next; pages += 1
        } while page != nil && pages < 5
        return all
    }

    nonisolated static func xaiUsage(_ key: String, team: String) async throws -> [AIReading.Day] {
        let w = window()
        guard let enc = team.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let u = URL(string: "https://management-api.x.ai/v1/billing/teams/\(enc)/usage") else { throw ReadError(text: "the Team ID isn't valid") }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let body: [String: Any] = ["analyticsRequest": [
            "timeRange": ["startTime": f.string(from: w.from), "endTime": f.string(from: w.to), "timezone": "Etc/UTC"],
            "timeUnit": "TIME_UNIT_DAY", "values": [["name": "usd", "aggregation": "AGGREGATION_SUM"]], "groupBy": [], "filters": []]]
        var r = request(u, bearer: key)
        r.httpMethod = "POST"; r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        guard let days = AISpendMath.xaiDays(try await get(r)) else { throw ReadError(text: "xAI answered in an unexpected format") }
        return days
    }

    nonisolated static func xaiPrepaid(_ key: String, team: String) async throws -> Double {
        guard let enc = team.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let u = URL(string: "https://management-api.x.ai/v1/billing/teams/\(enc)/prepaid/balance"),
              let v = AISpendMath.xaiPrepaidLeft(try await get(request(u, bearer: key))) else { throw ReadError(text: "no prepaid balance") }
        return v
    }

    nonisolated static func openRouter(_ key: String) async throws -> (Double?, Double?) {
        guard let v = AISpendMath.openRouter(try await get(request(URL(string: "https://openrouter.ai/api/v1/credits")!, bearer: key)))
        else { throw ReadError(text: "OpenRouter answered in an unexpected format") }
        return (v.bought, v.used)
    }

    nonisolated static func deepSeek(_ key: String) async throws -> (String, Double?, Double?) {
        var r = request(URL(string: "https://api.deepseek.com/user/balance")!, bearer: key)
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let v = AISpendMath.deepSeek(try await get(r)) else { throw ReadError(text: "DeepSeek answered in an unexpected format") }
        return (v.currency, v.granted, v.toppedUp)
    }
}
