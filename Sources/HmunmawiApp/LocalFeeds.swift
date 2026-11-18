import AppKit
import CryptoKit
import PDFKit
import Vision
import Foundation

/// What you call the bot that does jobs for you (writes your X numbers, runs routines), as shown on screen.
/// Set with `defaults write <app> HMBotName "My Bot"`; "Your bot" until then.
enum BotName {
    static var current: String {
        let n = UserDefaults.standard.string(forKey: "HMBotName")?.trimmingCharacters(in: .whitespaces) ?? ""
        return n.isEmpty ? "Your bot" : n
    }
    /// "Your bot" mid-sentence reads "your bot"; a real name keeps its capitals.
    static var inSentence: String { current == "Your bot" ? "your bot" : current }
}
import HmunmawiCore

/// Where your X numbers file is (Settings → General → X): a file a Mac job or bot already writes (a Safari read of
/// your own X page). The X connection reads it for free (no X API, no key); here only its "plan" block is read.
@MainActor @Observable
final class XFileFeed {
    static let shared = XFileFeed()
    var path: String { didSet { UserDefaults.standard.set(path, forKey: "HMXFile") } }
    private var lastModified: Date?
    /// When the X file was last updated (its date on disk), once it has been looked at.
    private(set) var lastRead: Date?

    final class Flag: @unchecked Sendable {
        private let lock = NSLock(); private var since: Date?
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if since != nil { return false }; since = .now; return true }
        func release() { lock.lock(); since = nil; lock.unlock() }
        var stuckFor: TimeInterval? { lock.lock(); defer { lock.unlock() }; return since.map { Date.now.timeIntervalSince($0) } }
    }
    nonisolated static let reading = Flag()
    /// The file's date, read off the main thread; outer nil when it doesn't answer in 5 s, inner nil when missing.
    nonisolated static func peek(_ path: String) async -> Date?? {
        guard !path.isEmpty else { return .some(nil) }
        final class Once: @unchecked Sendable {
            let lock = NSLock(); var done = false
            func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
        }
        guard Self.reading.claim() else { return nil }
        let once = Once()
        return await withCheckedContinuation { (cont: CheckedContinuation<Date??, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let r = fileModified(path)
                Self.reading.release()
                if once.claim() { cont.resume(returning: .some(r)) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
                if once.claim() { cont.resume(returning: .none) }
            }
        }
    }

    /// Your X plan as you name it (UserDefaults HMXPlan, e.g. "Premium"); agents can set it too.
    static var planLine: String {
        let plan = UserDefaults.standard.string(forKey: "HMXPlan") ?? ""   // set by XPlan
        guard BotName.current == "Grok Bot" else { return "" }   // X's paid plans include Grok
        return plan.isEmpty ? "Your X Subscription includes Grok Bot." : "Your X Subscription (\(plan)) includes Grok Bot."
    }

    init() {
        path = UserDefaults.standard.string(forKey: "HMXFile") ?? ""   // set in Settings → General → X
    }

    /// Reads the plan block when the file changed since the last look.
    func readPlan() async {
        guard let answer = await Self.peek(path), let modified = answer, modified != lastModified else { return }
        lastModified = modified
        lastRead = modified
        XPlan.shared.readBotFile(path)
    }
}

/// Your X plan (name, price, renewal, weekly use). Where it comes from is your choice:
/// "bot": the "plan" object in the X file Grok Bot writes ({name, price, currency, renews, weekly_used_pct});
/// "receipt": a receipt email (.eml) you choose; "typed": what you type. All kept in UserDefaults (HMXPlan*),
/// so agents can read or set them.
@MainActor @Observable
final class XPlan {
    static let shared = XPlan()
    private let d = UserDefaults.standard
    var source: String { didSet { d.set(source, forKey: "HMXPlanSource") } }
    var name: String { didSet { d.set(name, forKey: "HMXPlan") } }
    var price: String { didSet { d.set(price, forKey: "HMXPlanPrice") } }
    var renews: Date? { didSet { d.set(renews, forKey: "HMXPlanRenews") } }
    var weeklyUsed: Double? { didSet { d.set(weeklyUsed, forKey: "HMXPlanWeekly") } }
    private(set) var note: String?
    /// The chosen X file has no "plan" block yet.
    private(set) var missingInFile = false

    /// A message to paste to Grok Bot (or any agent that writes the X file).
    static func botRequest(file: String) -> String {
        """
        When you update my X numbers file (\(file.isEmpty ? "the X JSON file" : file)), also add a "plan" object \
        with my current X subscription: {"name": "Premium", "price": 30, "currency": "USD", \
        "renews": "YYYY-MM-DD", "weekly_used_pct": 42}. Use the real values from my subscription and usage \
        pages; leave out any you can't see. Keep everything else in the file as it is.
        """
    }

    init() {
        source = d.string(forKey: "HMXPlanSource") ?? "bot"
        name = d.string(forKey: "HMXPlan") ?? ""
        price = d.string(forKey: "HMXPlanPrice") ?? ""
        renews = d.object(forKey: "HMXPlanRenews") as? Date
        weeklyUsed = d.object(forKey: "HMXPlanWeekly") as? Double
    }

    /// Reads the "plan" object from the Grok Bot file, when that is the chosen source.
    func readBotFile(_ path: String) {
        guard source == "bot", !path.isEmpty, let data = smallFile(path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        guard let p = root["plan"] as? [String: Any] else { missingInFile = true; return }
        missingInFile = false
        if let n = p["name"] as? String { name = n }
        if let v = p["price"] { price = [String(describing: v), p["currency"] as? String].compactMap { $0 }.joined(separator: " ") }
        if let r = p["renews"] as? String { renews = ISO8601DateFormatter().date(from: r) ?? Self.day.date(from: String(r.prefix(10))) }
        weeklyUsed = (p["weekly_used_pct"] as? Double) ?? (p["weekly_used_pct"] as? Int).map(Double.init)
    }

    /// Takes plan, price and renewal date from a receipt: a screenshot or photo (read on this Mac by Apple's
    /// Vision), a PDF, or an email file. Files over 20 MB are refused.
    func readReceipt(_ url: URL) {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, size < 20_000_000 else { note = "That file is too large or empty."; return }
        let ext = url.pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "heic", "tiff", "gif", "webp"].contains(ext) {
            guard let img = NSImage(contentsOf: url) else { note = "Couldn't open that picture."; return }
            readReceipt(image: img); return
        }
        if ext == "pdf" {
            guard let doc = PDFDocument(url: url) else { note = "Couldn't open that PDF."; return }
            parse(String((doc.string ?? "").prefix(200_000))); return
        }
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { note = "Couldn't read that file."; return }
        parse(String(raw.prefix(500_000)))
    }

    /// A receipt picture (dropped or pasted): text is recognised on this Mac, nothing is uploaded.
    func readReceipt(image: NSImage) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { note = "Couldn't read that picture."; return }
        note = "Reading"
        Task.detached {
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            try? VNImageRequestHandler(cgImage: cg).perform([req])
            let text = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            await MainActor.run { self.parse(text) }
        }
    }

    private func parse(_ raw: String) {
        let text = raw.replacingOccurrences(of: "=\r\n", with: "").replacingOccurrences(of: "=\n", with: "")
        func first(_ pattern: String) -> String? {
            guard let r = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let m = r.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), m.numberOfRanges > 1,
                  let g = Range(m.range(at: 1), in: text) else { return nil }
            return String(text[g]).trimmingCharacters(in: .whitespaces)
        }
        if let n = first("\\b(Plus|Premium\\+?|Super|Ultra)\\b") { name = n }
        if let p = first("((?:[$€£₹]|USD|INR|EUR)\\s?[0-9][0-9,.]*)") { price = p }
        let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        if let r = text.range(of: "renew", options: .caseInsensitive),
           let m = det?.firstMatch(in: text, range: NSRange(r.lowerBound..<text.endIndex, in: text)), let date = m.date { renews = date }
        note = name.isEmpty && price.isEmpty ? "No plan found in that email." : nil
    }

    /// Where the shown plan came from, so it's clear whether it stays current.
    func origin(fileDate: Date?) -> String {
        switch source {
        case "bot" where !missingInFile:
            return "Updated by your bot" + (fileDate.map { " · \(Ago.text($0))" } ?? "")
        case "receipt": return "From your receipt · update it when your plan changes"
        default: return "Typed by you · not updated automatically"
        }
    }

    var summary: String? {
        guard !name.isEmpty else { return nil }
        var parts = [name]
        if !price.isEmpty { parts.append(price) }
        if let r = renews { parts.append("renews \(r.formatted(.dateTime.day().month(.abbreviated).year()))") }
        if let w = weeklyUsed { parts.append("\(Int(w))% of this week used") }
        return parts.joined(separator: " · ")
    }

    private static let day: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f }()
}

/// Near-live purchases with no server: asks Apple every few minutes for the notifications it tried to send
/// (App Store Server API "Get Notification History", last 180 days). Needs an In-App Purchase key and any
/// notification address set in App Store Connect (Apple keeps the history even if delivery fails).
@MainActor @Observable
final class AppleHistory {
    static let shared = AppleHistory()
    private let keychain = KeychainSecretStore()
    var keyID: String { didSet { UserDefaults.standard.set(keyID, forKey: "HMIAPKeyID") } }
    var issuerID: String { didSet { UserDefaults.standard.set(issuerID, forKey: "HMIAPIssuer") } }
    var bundleIDs: String { didSet { UserDefaults.standard.set(bundleIDs, forKey: "HMIAPBundles") } }
    private(set) var status: String?
    private(set) var lastCheck: Date?
    private var since: Double {
        get { UserDefaults.standard.double(forKey: "HMIAPSince") }
        set { UserDefaults.standard.set(newValue, forKey: "HMIAPSince") }
    }
    var hasKey: Bool { ((try? keychain.secret(plugin: "applehistory", name: "privateKey")) ?? nil)?.isEmpty == false }
    var ready: Bool { hasKey && !keyID.isEmpty && !issuerID.isEmpty && !bundleIDs.isEmpty }

    init() {
        keyID = UserDefaults.standard.string(forKey: "HMIAPKeyID") ?? ""
        issuerID = UserDefaults.standard.string(forKey: "HMIAPIssuer") ?? ""
        bundleIDs = UserDefaults.standard.string(forKey: "HMIAPBundles") ?? ""
    }

    func saveKey(_ pem: String) { try? keychain.setSecret(pem, plugin: "applehistory", name: "privateKey") }

    /// New notifications since the last check, as app events.
    func check() async -> [Event] {
        guard ready, let pem = (try? keychain.secret(plugin: "applehistory", name: "privateKey")) ?? nil else { return [] }
        let now = Date.now.timeIntervalSince1970 * 1000
        // First run: the last 3 days. Later: from the last check (an hour of overlap), up to 30 days back, so a Mac that was off for a
        // week still gets the purchases of that week (Apple keeps 180 days in production); repeats are skipped by their key.
        let start = since > 0 ? max(since - 3_600_000, now - 30 * 86_400_000) : now - 3 * 86_400_000
        var events: [Event] = []
        do {
            for bundle in bundleIDs.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !bundle.isEmpty {
                let token = try Self.jwt(keyID: keyID, issuer: issuerID, bundle: bundle, pem: pem)
                var page: String?
                repeat {
                    var url = URLComponents(string: "https://api.storekit.itunes.apple.com/inApps/v1/notifications/history")!
                    if let page { url.queryItems = [URLQueryItem(name: "paginationToken", value: page)] }
                    var req = URLRequest(url: url.url!, timeoutInterval: 30)
                    req.httpMethod = "POST"
                    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = try JSONSerialization.data(withJSONObject: ["startDate": Int64(start), "endDate": Int64(now)])
                    let (data, resp) = try await URLSession(configuration: .ephemeral).data(for: req)
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    guard code == 200, let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        throw WireError("apple", code == 401 ? "Apple refused the In-App Purchase key (check key ID, issuer ID and bundle ID)." : "Apple answered with status \(code).")
                    }
                    for h in body["notificationHistory"] as? [[String: Any]] ?? [] {
                        if let jws = h["signedPayload"] as? String, let e = Self.event(jws) { events.append(e) }
                    }
                    page = (body["hasMore"] as? Bool == true) ? body["paginationToken"] as? String : nil
                } while page != nil
            }
            since = now
            lastCheck = .now
            status = nil
        } catch {
            status = (error as? WireError)?.message ?? error.localizedDescription
        }
        return events
    }

    /// App Store Server API token: ES256, audience appstoreconnect-v1, with the app's bundle ID.
    static func jwt(keyID: String, issuer: String, bundle: String, pem: String) throws -> String {
        let key = try P256.Signing.PrivateKey(pemRepresentation: pem)
        func b64(_ d: Data) -> String { d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
        let iat = Int(Date.now.timeIntervalSince1970)
        let h = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyID, "typ": "JWT"])
        let c = try JSONSerialization.data(withJSONObject: ["iss": issuer, "iat": iat, "exp": iat + 1200, "aud": "appstoreconnect-v1", "bid": bundle])
        let input = b64(h) + "." + b64(c)
        return input + "." + b64(try key.signature(for: Data(input.utf8)).rawRepresentation)
    }

    /// Reads a JWS payload (it came straight from Apple over HTTPS).
    static func payload(_ jws: String) -> [String: Any]? {
        let parts = jws.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var s = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        return Data(base64Encoded: s).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    static func event(_ jws: String) -> Event? {
        guard let n = payload(jws), let data = n["data"] as? [String: Any] else { return nil }
        let tx = (data["signedTransactionInfo"] as? String).flatMap(payload) ?? [:]
        let rn = (data["signedRenewalInfo"] as? String).flatMap(payload) ?? [:]
        let item: [String: Any] = [
            "key": "history:\(n["notificationUUID"] as? String ?? UUID().uuidString)",
            "at": n["signedDate"] ?? Date.now.timeIntervalSince1970 * 1000,
            "type": n["notificationType"] ?? "", "subtype": n["subtype"] ?? NSNull(),
            "bundleId": data["bundleId"] ?? "", "environment": data["environment"] ?? "",
            "product": tx["productId"] ?? "",
            "price": (tx["price"] as? Double).map { $0 / 1000 } ?? NSNull(),
            "currency": tx["currency"] ?? NSNull(), "storefront": tx["storefront"] ?? NSNull(),
            "inFamily": (tx["inAppOwnershipType"] as? String) == "FAMILY_SHARED",
            "autoRenew": rn["autoRenewStatus"] ?? NSNull(),
        ]
        return LivePurchases.shared.event(item)
    }
}


/// A regular file's contents, only when it's under 5 MB (a path set to a device like /dev/zero or a huge file is
/// never read into memory).
func smallFile(_ path: String, limit: Int = 5_000_000) -> Data? {
    let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path   // a linked file (iCloud, another folder) is fine
    guard let a = try? FileManager.default.attributesOfItem(atPath: real), a[.type] as? FileAttributeType == .typeRegular,
          let size = a[.size] as? Int, size <= limit else { return nil }
    return FileManager.default.contents(atPath: real)
}
