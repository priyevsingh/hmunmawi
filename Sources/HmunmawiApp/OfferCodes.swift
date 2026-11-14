import AppKit
import Foundation
import HmunmawiCore

/// Offer codes you hand out (lifetime unlocks, discounts). The app owns the list:
/// - one-time codes come from the CSV files App Store Connect exports ("CODE,https://apps.apple.com/redeem?…",
///   no header; the batch id is in the file name "OfferCodeOneTimeUseCodes_<batch>.csv"). The app finds and reads
///   them when you pick or drop the files, or when you ask it to find them (you confirm), and skips duplicates;
/// - offer names, expiry dates, custom codes and batch sizes come from App Store Connect (offercodes.snapshot);
/// - "shared" is always your own mark: Apple never says which codes were redeemed.
/// Stored in Application Support (0600), never in the portal; the portal only mirrors it when you publish.
@MainActor @Observable
final class OfferCodes {
    static let shared = OfferCodes()

    struct Code: Codable, Hashable, Identifiable {
        var code: String
        var url: String
        var appID: String
        var batch: String?
        var sharedAt: Date?
        var sharedBy: String?       // mac, menu, phone, agent, import
        var note: String?
        var id: String { code }
    }
    struct Custom: Codable, Hashable, Identifiable {
        var code: String
        var appID: String
        var offer: String?
        var capacity: Int?
        var expires: String?
        var shared: Int = 0
        var id: String { appID + ":" + code }
        var url: String { OfferCodes.redeemURL(appID: appID, code: code) }
    }
    struct Share: Codable, Hashable, Identifiable {
        var code: String
        var appID: String
        var at: Date
        var by: String
        var campaign: String? = nil      // who or where it went ("Reddit post", "Ahmed")
        var id: String { "\(code)|\(at.timeIntervalSince1970)" }
    }
    struct Book: Codable {
        var codes: [Code] = []
        var custom: [Custom] = []
        var log: [Share] = []
        var files: [String: Double] = [:]      // CSV path -> modification time already read
        var portalImported: Bool = false
    }

    private(set) var book = Book()
    private(set) var scanNote: String?
    private let url = URL.hmSupport.appending(path: "offercodes.json")

    init() {
        if let d = try? Data(contentsOf: url), let b = try? { let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601; return try dec.decode(Book.self, from: d) }() { book = b }
    }

    // MARK: Reading

    nonisolated static func redeemURL(appID: String, code: String) -> String {
        "https://apps.apple.com/redeem?ctx=offercodes&id=\(appID)&code=\(code)"
    }

    func codes(app appID: String) -> [Code] { book.codes.filter { $0.appID == appID } }
    func left(app appID: String) -> Int { codes(app: appID).filter { $0.sharedAt == nil }.count }
    func custom(app appID: String) -> [Custom] { book.custom.filter { $0.appID == appID } }
    func recent(app appID: String, limit: Int = 5) -> [Share] { Array(book.log.filter { $0.appID == appID }.suffix(limit).reversed()) }
    var appIDs: [String] { Array(Set(book.codes.map(\.appID) + book.custom.map(\.appID))).sorted() }

    /// The App Store Connect facts for this app (offer names, expiry, custom codes), from the latest snapshot.
    static func offers(_ model: AppModel, appID: String) -> [JSONValue] {
        model.snapshots("offercodes.snapshot").first { $0.payload[path: "app_id"]?.string == appID }?.payload[path: "offers"]?.array ?? []
    }

    /// Batch id -> (offer name, expiry) from App Store Connect.
    static func batchInfo(_ model: AppModel, appID: String) -> [String: (name: String, expires: String?)] {
        var out: [String: (String, String?)] = [:]
        for o in offers(model, appID: appID) {
            for b in o[path: "batches"]?.array ?? [] {
                if let id = b[path: "id"]?.string { out[id] = (o[path: "name"]?.string ?? "Offer", b[path: "expires"]?.string) }
            }
        }
        return out
    }

    // MARK: Sharing

    /// Copies the next unshared one-time code's link and marks it shared. Returns the code, or nil when none left.
    @discardableResult
    func copyNext(app appID: String, by: String, toClipboard: Bool = true, campaign: String? = nil) -> Code? {
        guard let i = book.codes.firstIndex(where: { $0.appID == appID && $0.sharedAt == nil }) else { return nil }
        book.codes[i].sharedAt = .now
        book.codes[i].sharedBy = by
        book.codes[i].note = campaign
        let c = book.codes[i]
        if toClipboard { copy(c.url) }
        book.log.append(Share(code: c.code, appID: appID, at: .now, by: by, campaign: campaign))
        trimLog(); save()
        return c
    }

    /// Marks one particular one-time code as given (you handed out that exact code, not the next one).
    /// Returns nil when the code isn't in the book or was already given.
    @discardableResult
    func markShared(code: String, by: String, campaign: String? = nil) -> Code? {
        guard let i = book.codes.firstIndex(where: { $0.code == code }), book.codes[i].sharedAt == nil else { return nil }
        book.codes[i].sharedAt = .now
        book.codes[i].sharedBy = by
        book.codes[i].note = campaign
        let c = book.codes[i]
        book.log.append(Share(code: c.code, appID: c.appID, at: .now, by: by, campaign: campaign))
        trimLog(); save()
        return c
    }

    /// Copies a custom code's link (shared by many people) and counts the share.
    /// Shares per campaign for one app, most used first ("No tag" for untagged ones).
    func campaigns(app appID: String) -> [(name: String, count: Int)] {
        Dictionary(grouping: book.log.filter { $0.appID == appID }, by: { $0.campaign ?? "No tag" })
            .map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }
    }

    func copyCustom(_ custom: Custom, by: String, campaign: String? = nil) {
        copy(custom.url)
        if let i = book.custom.firstIndex(where: { $0.id == custom.id }) { book.custom[i].shared += 1 }
        book.log.append(Share(code: custom.code, appID: custom.appID, at: .now, by: by, campaign: campaign))
        trimLog(); save()
    }

    /// Undo the last share of this code (one-time: back to unshared; custom: count down).
    func undo(_ share: Share) {
        if let i = book.codes.firstIndex(where: { $0.code == share.code && $0.appID == share.appID }) {
            book.codes[i].sharedAt = nil; book.codes[i].sharedBy = nil; book.codes[i].note = nil   // (its "for whom" goes too)
        } else if let i = book.custom.firstIndex(where: { $0.code == share.code && $0.appID == share.appID }) {
            book.custom[i].shared = max(0, book.custom[i].shared - 1)
        }
        book.log.removeAll { $0.id == share.id }
        save()
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func trimLog() { if book.log.count > 2000 { book.log.removeFirst(book.log.count - 2000) } }

    // MARK: App Store Connect facts

    /// Keeps custom codes (FREE4LIFE, OFF60…) in step with App Store Connect; counts you made stay.
    func merge(_ model: AppModel) {
        var changed = false
        for snap in model.snapshots("offercodes.snapshot") {
            guard let appID = snap.payload[path: "app_id"]?.string else { continue }
            for o in snap.payload[path: "offers"]?.array ?? [] {
                for c in o[path: "custom"]?.array ?? [] {
                    guard let code = c[path: "code"]?.string.map({ InputRule.identifier.clean($0) }), !code.isEmpty else { continue }
                    let capacity = c[path: "count"]?.number.map { Int(safe: $0) }
                    let expires = c[path: "expires"]?.string
                    if let i = book.custom.firstIndex(where: { $0.appID == appID && $0.code == code }) {
                        if book.custom[i].capacity != capacity || book.custom[i].expires != expires || book.custom[i].offer != o[path: "name"]?.string {
                            book.custom[i].capacity = capacity; book.custom[i].expires = expires; book.custom[i].offer = o[path: "name"]?.string
                            changed = true
                        }
                    } else {
                        book.custom.append(Custom(code: code, appID: appID, offer: o[path: "name"]?.string, capacity: capacity, expires: expires))
                        changed = true
                    }
                }
            }
        }
        if changed { save() }
    }

    // MARK: CSV files (automatic)

    /// Searches iCloud Drive, Downloads, Documents and Desktop for App Store Connect code exports
    /// ("OfferCodeOneTimeUseCodes_<batch>.csv") that aren't imported yet. You confirm before anything is added.
    nonisolated static func findCSVs(skipping known: Set<String>) -> [URL] {
        // Spotlight first: one query over the whole Mac, no folder-by-folder walking.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        p.arguments = ["kMDItemFSName == 'OfferCodeOneTimeUseCodes_*.csv'c"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let hits = String(decoding: data, as: UTF8.self).split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
                .filter { $0.pathExtension.lowercased() == "csv" && !known.contains($0.path) && !$0.path.contains("/.Trash/") }
            if !hits.isEmpty { return Array(hits.prefix(200)) }
        }
        // Spotlight off or not indexed yet: walk the usual places.
        let home = URL.homeDirectory
        let roots = ["Library/Mobile Documents/com~apple~CloudDocs", "Downloads", "Documents", "Desktop"].map { home.appending(path: $0) }
        var out: [URL] = []
        for root in roots {
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey],
                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            var seen = 0
            while let f = e.nextObject() as? URL {
                seen += 1
                if seen > 60_000 { break }
                if e.level > 7 { e.skipDescendants(); continue }
                if f.lastPathComponent.hasPrefix("OfferCodeOneTimeUseCodes_"), f.pathExtension.lowercased() == "csv",
                   !known.contains(f.path) { out.append(f) }
            }
        }
        return out
    }

    /// Imports the files you picked or confirmed. Returns a plain summary.
    @discardableResult
    func importFiles(_ files: [URL]) async -> String {
        // Reading happens off the main thread (files can sit in iCloud or behind a macOS prompt); only the
        // small parse-and-add step runs here.
        let texts = await Task.detached(priority: .userInitiated) { () -> [(URL, String?)] in
            files.prefix(200).map { f in
                let scoped = f.startAccessingSecurityScopedResource()
                defer { if scoped { f.stopAccessingSecurityScopedResource() } }
                return (f, Self.readCSV(f))
            }
        }.value
        var added = 0, unreadable: [String] = []
        for (f, text) in texts {
            // A file that couldn't be read isn't marked imported, so "Find CSV files" offers it again.
            guard let text, let n = importCSV(text: text, name: f.deletingPathExtension().lastPathComponent) else {
                unreadable.append(f.lastPathComponent); continue
            }
            added += n
            book.files[f.path] = Date.now.timeIntervalSince1970
        }
        save()
        scanNote = (added == 0 ? "No new codes" + (unreadable.isEmpty ? " (already imported)" : "") : "Added \(added) code\(added == 1 ? "" : "s")")
            + (unreadable.isEmpty ? "" : ". Couldn't read \(unreadable.prefix(3).joined(separator: ", "))\(unreadable.count > 3 ? " and \(unreadable.count - 3) more" : ""): macOS may need Files access in Settings → Permissions.")
        return scanNote ?? ""
    }

    var knownFiles: Set<String> { Set(book.files.keys) }

    /// One App Store Connect export: "CODE,REDEEM_URL" per line. Returns how many new codes were added, or nil
    /// when the file couldn't be read at all.
    nonisolated static func readCSV(_ file: URL) -> String? {
        // Exports are a few hundred KB; anything far bigger isn't one.
        if let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 20_000_000 { return nil }
        return (try? String(contentsOf: file, encoding: .utf8)) ?? (try? String(contentsOf: file, encoding: .isoLatin1))
    }

    @discardableResult
    func importCSV(text: String, name: String) -> Int? {
        let batch = name.hasPrefix("OfferCodeOneTimeUseCodes_")
            ? String(name.dropFirst("OfferCodeOneTimeUseCodes_".count).prefix(36)) : nil
        var have = Set(book.codes.map(\.code))
        var added = 0
        for line in text.split(whereSeparator: \.isNewline).prefix(20_000) {
            let parts = line.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces.union(.init(charactersIn: "\"\u{FEFF}"))) }   // (a byte-order mark too)
            guard let code = parts.first, Self.validCode(code), !have.contains(code) else { continue }
            let link = parts.count > 1 ? parts[1] : ""
            guard let comps = URLComponents(string: link), comps.host == "apps.apple.com",
                  let appID = comps.queryItems?.first(where: { $0.name == "id" })?.value, appID.allSatisfy(\.isNumber) else { continue }
            book.codes.append(Code(code: code, url: Self.redeemURL(appID: appID, code: code), appID: appID, batch: batch))
            have.insert(code); added += 1
        }
        return added
    }

    nonisolated static func validCode(_ s: String) -> Bool {
        (4...40).contains(s.count) && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    // MARK: One-time import of marks you made before (the old portal page), then the app owns them.

    /// When no key can read a tracker (e.g. a page behind a login), read it through the Safari session you're
    /// already logged into. Only on your request; reads the one address you give, once, and nothing else.
    func importUsingSafari(_ address: String) async -> String {
        guard let u = InputCheck.httpsURL(address), let host = u.host, host.wholeMatch(of: /[A-Za-z0-9.-]+/) != nil
        else { return "Enter a full https:// address (a plain host name, no special characters)" }
        if let note = Permissions.shared.deferIfNeeded([.safari]) { return note }
        // Safe inside both the AppleScript string and the JavaScript string: no backslash, double or single quote.
        let esc = u.absoluteString.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "%27")
        let script = """
        tell application "Safari"
            set t to missing value
            repeat with w in windows
                repeat with x in tabs of w
                    if URL of x starts with "https://\(host)/" then set t to x
                end repeat
            end repeat
            if t is missing value then
                if (count of windows) is 0 then make new document
                set t to make new tab at end of tabs of window 1 with properties {URL:"https://\(host)/"}
                delay 6
            end if
            return do JavaScript "var x=new XMLHttpRequest();x.open('GET','\(esc)',false);x.send();x.status==200?x.responseText:'HTTP '+x.status" in t
        end tell
        """
        // A separate osascript process (NSAppleScript is main-thread only, and would freeze the window while Safari
        // loads); stopped after 60 seconds.
        let text: String? = await Task.detached {
            let p = Process(), out = Pipe(), input = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-"]
            p.standardInput = input; p.standardOutput = out; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            try? input.fileHandleForWriting.write(contentsOf: Data(script.utf8)); try? input.fileHandleForWriting.close()
            let killer = Task.detached { try? await Task.sleep(for: .seconds(60)); if p.isRunning { p.terminate() } }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit(); killer.cancel()
            guard p.terminationStatus == 0 else { return nil }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
        guard let text, let data = text.data(using: .utf8), text.hasPrefix("{") else {
            return text.map { "Couldn't read it (\($0.prefix(40))). Are you logged in to \(host) in Safari?" }
                ?? "Couldn't use Safari. Allow Hmunmawi to control Safari in System Settings → Privacy & Security → Automation."
        }
        return importPortalState(data)
    }

    /// A one-time export of the old page's marks dropped at import/lifetime-free.json is read once, then deleted.
    func importPendingPortalFile() {
        let f = URL.hmSupport.appending(path: "import/lifetime-free.json")
        guard let d = try? Data(contentsOf: f) else { return }
        scanNote = importPortalState(d)
        try? FileManager.default.removeItem(at: f)
    }

    func importPortalState(_ data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let apps = root["apps"] as? [String: Any] else { return "Nothing new here. You already have it all" }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso2 = ISO8601DateFormatter()
        func date(_ s: Any?) -> Date? { (s as? String).flatMap { iso.date(from: $0) ?? iso2.date(from: $0) } }
        var have = Set(book.codes.map(\.code)), codes = 0, shared = 0
        for case let app as [String: Any] in apps.values {
            guard let appID = app["app_id"] as? String, let inv = app["inventory"] as? [String: Any] else { continue }
            for case let item as [String: Any] in (inv["items"] as? [Any]) ?? [] {
                guard let code = item["code"] as? String, Self.validCode(code) else { continue }
                let when = (item["status"] as? String) == "shared" ? (date(item["shared_at"]) ?? .now) : nil
                if have.contains(code) {
                    if let when, let i = book.codes.firstIndex(where: { $0.code == code }), book.codes[i].sharedAt == nil {
                        book.codes[i].sharedAt = when; book.codes[i].sharedBy = "import"; shared += 1
                    }
                    continue
                }
                book.codes.append(Code(code: code, url: Self.redeemURL(appID: appID, code: code), appID: appID,
                                       batch: item["batch_id"] as? String, sharedAt: when, sharedBy: when == nil ? nil : "import",
                                       note: (item["note"] as? String).map { InputRule.text(200).clean($0) }))
                have.insert(code); codes += 1
                if when != nil { shared += 1 }
            }
            if let custom = inv["custom_code"] as? String, Self.validCode(custom) {
                let count = ((inv["counts"] as? [String: Any])?["shared"] as? Int) ?? 0
                if let i = book.custom.firstIndex(where: { $0.appID == appID && $0.code == custom }) {
                    book.custom[i].shared = max(book.custom[i].shared, count)
                } else {
                    book.custom.append(Custom(code: custom, appID: appID, offer: (app["offer"] as? [String: Any])?["name"] as? String,
                                              capacity: inv["capacity"] as? Int, shared: count))
                }
            }
        }
        book.portalImported = true
        save()
        return "Imported \(codes) codes, \(shared) already shared"
    }

    // MARK: Daily status for rules ("offercodes.status": codes left, days to expiry), once a day per offer.

    func statusEvents(_ model: AppModel) -> [Event] {
        let day = Date.now.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())   // your day, not UTC's
        let now = Millis(Date.now.timeIntervalSince1970 * 1000)
        // Whole calendar days from today to the expiry date, both local (reading the date as UTC midnight
        // made it "expired" on the expiry day itself in India).
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current; f.dateFormat = "yyyy-MM-dd"
        func days(_ iso: String?) -> Double? {
            guard let iso, let d = f.date(from: String(iso.prefix(10))) else { return nil }
            return Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: .now), to: d).day.map(Double.init)
        }
        var out: [Event] = []
        for appID in appIDs {
            let name = QuickName.of(appID, model: model)
            let all = codes(app: appID)
            if !all.isEmpty {
                let info = Self.batchInfo(model, appID: appID)
                let expiry = all.filter { $0.sharedAt == nil }.compactMap { $0.batch.flatMap { info[$0]?.expires } }.min()
                var p: [String: JSONValue] = ["offer": .string(all.compactMap { $0.batch.flatMap { info[$0]?.name } }.first ?? "One-time codes"),
                                              "left": .number(Double(left(app: appID))), "total": .number(Double(all.count))]
                if let d = days(expiry) { p["days_to_expiry"] = .number(d) }
                out.append(Event(source: "hmunmawi", kind: "offercodes.status", app: name, payload: .object(p),
                                 occurredAt: now, dedupeKey: "codes-\(appID)-onetime-\(day)"))
            }
            for c in custom(app: appID) {
                var p: [String: JSONValue] = ["offer": .string(c.code), "shared": .number(Double(c.shared))]
                if let cap = c.capacity { p["left"] = .number(Double(max(0, cap - c.shared))); p["total"] = .number(Double(cap)) }
                if let d = days(c.expires) { p["days_to_expiry"] = .number(d) }
                out.append(Event(source: "hmunmawi", kind: "offercodes.status", app: name, payload: .object(p),
                                 occurredAt: now, dedupeKey: "codes-\(appID)-\(c.code)-\(day)"))
            }
        }
        return out
    }

    // MARK: Storage

    func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]; enc.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let d = try? enc.encode(book) else { return }
        try? d.write(to: url, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Short app name for an App Store id ("My App: Photo Editor" -> "My App").
@MainActor enum QuickName {
    static func of(_ appID: String, model: AppModel) -> String {
        let full = model.snapshots("icon.snapshot").first { $0.payload[path: "appID"]?.string == appID }?.app
            ?? model.snapshots("offercodes.snapshot").first { $0.payload[path: "app_id"]?.string == appID }?.app
        return full.map { $0.split(separator: ":").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? $0 } ?? "App \(appID)"
    }
}
