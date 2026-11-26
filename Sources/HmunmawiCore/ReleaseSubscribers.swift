import Foundation

/// A single opt-in subscriber for release notifications.
/// Stored locally in `release-subscribers.json` with `0o600` permissions.
public struct ReleaseSubscriber: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var email: String
    public var name: String?
    public var apps: [String]
    public var tags: [String]?
    public var addedAt: String
    public var unsubscribedAt: String?
    public var bouncedAt: String?
    public var notes: String?

    public var isActive: Bool { unsubscribedAt == nil && bouncedAt == nil }

    /// True when the subscriber is subscribed to `"all"` (case-insensitive) or to `app`.
    public func subscribed(toApp app: String) -> Bool {
        let target = app.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return false }
        return apps.contains {
            $0.caseInsensitiveCompare("all") == .orderedSame ||
            $0.caseInsensitiveCompare(target) == .orderedSame
        }
    }

    public init(
        id: String = UUID().uuidString.lowercased(),
        email: String,
        name: String? = nil,
        apps: [String] = ["all"],
        tags: [String]? = nil,
        addedAt: String = "",
        unsubscribedAt: String? = nil,
        bouncedAt: String? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.name = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.apps = apps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        self.tags = tags
        self.addedAt = addedAt
        self.unsubscribedAt = unsubscribedAt
        self.bouncedAt = bouncedAt
        self.notes = notes
    }
}

/// Per-app release notification preferences.
public struct ReleaseNotifyAppConfig: Codable, Hashable, Sendable {
    public var allowPatchUpdates: Bool
    public var autoDraftOnRelease: Bool
    public var customSubject: String?
    public var customTemplate: String?

    public init(
        allowPatchUpdates: Bool = false,
        autoDraftOnRelease: Bool = true,
        customSubject: String? = nil,
        customTemplate: String? = nil
    ) {
        self.allowPatchUpdates = allowPatchUpdates
        self.autoDraftOnRelease = autoDraftOnRelease
        self.customSubject = customSubject
        self.customTemplate = customTemplate
    }
}

/// Delivery record for a single `(app, version)` release notification run.
public struct ReleaseNotifyLog: Codable, Hashable, Sendable {
    public var app: String
    public var version: String
    public var sentEmails: [String]
    public var failedEmails: [String: String]?
    public var lastSentAt: String?

    public init(
        app: String,
        version: String,
        sentEmails: [String] = [],
        failedEmails: [String: String]? = nil,
        lastSentAt: String? = nil
    ) {
        self.app = app
        self.version = version
        self.sentEmails = sentEmails
        self.failedEmails = failedEmails
        self.lastSentAt = lastSentAt
    }
}

/// Audit record of an unsubscribe or bounce detected from incoming mail.
public struct ReleaseMailRecord: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case unsubscribe, bounce }

    public var id: String
    public var email: String
    public var kind: Kind
    public var mailID: String
    public var reason: String
    public var day: String
    public var undone: Bool?

    public init(
        id: String = UUID().uuidString.lowercased(),
        email: String,
        kind: Kind,
        mailID: String,
        reason: String,
        day: String,
        undone: Bool? = nil
    ) {
        self.id = id
        self.email = email
        self.kind = kind
        self.mailID = mailID
        self.reason = reason
        self.day = day
        self.undone = undone
    }
}

/// On-disk state for release subscribers, per-app config, delivery logs, and processed mail actions.
public struct ReleaseSubscribersBook: Codable, Sendable {
    public var subscribers: [ReleaseSubscriber] = []
    public var configs: [String: ReleaseNotifyAppConfig] = [:]
    public var notifiedVersions: [String: String] = [:]
    public var deliveries: [String: ReleaseNotifyLog] = [:]
    public var processedMailIDs: [String]? = nil
    public var mailActions: [ReleaseMailRecord]? = nil

    public init(
        subscribers: [ReleaseSubscriber] = [],
        configs: [String: ReleaseNotifyAppConfig] = [:],
        notifiedVersions: [String: String] = [:],
        deliveries: [String: ReleaseNotifyLog] = [:],
        processedMailIDs: [String]? = nil,
        mailActions: [ReleaseMailRecord]? = nil
    ) {
        self.subscribers = subscribers
        self.configs = configs
        self.notifiedVersions = notifiedVersions
        self.deliveries = deliveries
        self.processedMailIDs = processedMailIDs
        self.mailActions = mailActions
    }
}

/// Parses pasted email lists, `Name <email>` lines, and CSV/TSV exports into normalized subscriber entries.
public enum ReleaseSubscriberImport {
    public struct Entry: Equatable, Sendable {
        public var email: String
        public var name: String?
        public var apps: [String]

        public init(email: String, name: String? = nil, apps: [String] = ["all"]) {
            self.email = email
            self.name = name
            self.apps = apps
        }
    }

    public struct Result: Equatable, Sendable {
        public var entries: [Entry]
        public var invalid: [String]

        public init(entries: [Entry] = [], invalid: [String] = []) {
            self.entries = entries
            self.invalid = invalid
        }
    }

    private struct HeaderLayout {
        let separator: Character
        let emailColumn: Int
        let nameColumn: Int?
        let appsColumn: Int?
    }

    private static let maxInvalidCount = 500
    private static let headerEmailNames: Set<String> = ["email", "e-mail", "email address"]

    /// Parses bare emails, `Name <email>` tokens, or CSV/TSV text (with optional header row).
    public static func parse(_ raw: String, defaultApps: [String] = ["all"]) -> Result {
        let normalizedDefaults = normalizeApps(defaultApps)
        let lines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let firstLine = lines.first else { return Result() }

        var entries: [Entry] = []
        var indexByEmail: [String: Int] = [:]
        var invalid: [String] = []

        func recordValid(email: String, name: String?, apps: [String]) {
            let normApps = normalizeApps(apps.isEmpty ? normalizedDefaults : apps)
            let cleanName = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            if let existingIdx = indexByEmail[email] {
                if entries[existingIdx].name == nil || entries[existingIdx].name?.isEmpty == true, let cleanName {
                    entries[existingIdx].name = cleanName
                }
                entries[existingIdx].apps = mergeApps(entries[existingIdx].apps, normApps)
            } else {
                indexByEmail[email] = entries.count
                entries.append(Entry(email: email, name: cleanName, apps: normApps))
            }
        }

        func recordInvalid(_ token: String) {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, invalid.count < maxInvalidCount else { return }
            invalid.append(trimmed)
        }

        if let header = detectHeader(firstLine) {
            for line in lines.dropFirst() {
                let fields = splitDelimitedFields(line, delimiters: [header.separator])
                guard header.emailColumn < fields.count else { continue }
                let rawEmail = fields[header.emailColumn].trimmingCharacters(in: .whitespacesAndNewlines)
                let colName = header.nameColumn.flatMap { $0 < fields.count ? fields[$0].trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty : nil }
                let colApps = header.appsColumn.flatMap { $0 < fields.count ? parseAppsList(fields[$0], fallback: normalizedDefaults) : nil } ?? normalizedDefaults

                if rawEmail.isEmpty {
                    continue
                }
                if let parsed = parseEmailToken(rawEmail) {
                    recordValid(email: parsed.email, name: colName ?? parsed.name, apps: colApps)
                } else {
                    recordInvalid(rawEmail)
                }
            }
            return Result(entries: entries, invalid: invalid)
        }

        for line in lines {
            let tokens = splitDelimitedFields(line, delimiters: [",", ";", "\t"])
            for token in tokens {
                let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                let stripped = stripOuterTokenWrappers(trimmed)
                if stripped.isEmpty { continue }
                if let parsed = parseEmailToken(trimmed) {
                    recordValid(email: parsed.email, name: parsed.name, apps: normalizedDefaults)
                } else {
                    recordInvalid(trimmed)
                }
            }
        }

        return Result(entries: entries, invalid: invalid)
    }

    private static func detectHeader(_ line: String) -> HeaderLayout? {
        for sep in [Character("\t"), Character(","), Character(";")] {
            let fields = splitDelimitedFields(line, delimiters: [sep])
            let lowered = fields.map { stripQuotes($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            if fields.contains(where: { parseEmailToken($0) != nil }) {
                continue
            }
            if let emailCol = lowered.firstIndex(where: { headerEmailNames.contains($0) }) {
                let nameCol = lowered.firstIndex(where: { $0 == "name" || $0 == "full name" })
                let appsCol = lowered.firstIndex(where: { $0 == "apps" || $0 == "app" })
                return HeaderLayout(separator: sep, emailColumn: emailCol, nameColumn: nameCol, appsColumn: appsCol)
            }
        }
        return nil
    }

    private static func splitDelimitedFields(_ line: String, delimiters: Set<Character>) -> [String] {
        var out: [String] = []
        var current = ""
        var inQuotes = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                if inQuotes, i + 1 < chars.count, chars[i + 1] == "\"" {
                    current.append("\"")
                    i += 2
                    continue
                }
                inQuotes.toggle()
                current.append(c)
                i += 1
                continue
            }
            if !inQuotes, delimiters.contains(c) {
                out.append(unquoteCSVCell(current))
                current = ""
                i += 1
                continue
            }
            current.append(c)
            i += 1
        }
        out.append(unquoteCSVCell(current))
        return out
    }

    private static func unquoteCSVCell(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 2, trimmed.first == "\"", trimmed.last == "\"" {
            // Only unwrap when the closing quote closes the opening quote cleanly (not `"Name" <email>`).
            let inner = String(trimmed.dropFirst().dropLast())
            if !inner.contains("<") && !inner.contains(">") {
                return inner.replacingOccurrences(of: "\"\"", with: "\"").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return trimmed
    }

    private static func parseEmailToken(_ raw: String) -> (email: String, name: String?)? {
        var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.count >= 2, token.first == "\"", token.last == "\"", token.contains("<"), token.contains(">") {
            token = String(token.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let open = token.lastIndex(of: "<"), let close = token.lastIndex(of: ">"), open < close {
            let trailing = token[token.index(after: close)...].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
            guard trailing.isEmpty else { return nil }
            let rawAddress = String(token[token.index(after: open)..<close])
            let normalizedEmail = normalizeCandidateEmail(rawAddress)
            guard isValidCandidateEmail(normalizedEmail) else { return nil }
            let rawName = String(token[..<open])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanName = stripQuotes(rawName).trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            return (normalizedEmail, cleanName)
        }

        let normalizedEmail = normalizeCandidateEmail(token)
        guard isValidCandidateEmail(normalizedEmail) else { return nil }
        return (normalizedEmail, nil)
    }

    private static func normalizeCandidateEmail(_ raw: String) -> String {
        let wrappers = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'<>"))
        return raw.trimmingCharacters(in: wrappers).lowercased()
    }

    private static func stripOuterTokenWrappers(_ raw: String) -> String {
        let wrappers = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'<>"))
        return raw.trimmingCharacters(in: wrappers)
    }

    private static func stripQuotes(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.count >= 2, ((s.first == "\"" && s.last == "\"") || (s.first == "'" && s.last == "'")) {
            s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }

    private static func isValidCandidateEmail(_ email: String) -> Bool {
        guard !email.isEmpty, !headerEmailNames.contains(email) else { return false }
        return SMTPConfig.isSingleEmail(email)
    }

    private static func parseAppsList(_ raw: String, fallback: [String]) -> [String] {
        let cleaned = stripQuotes(raw)
        guard !cleaned.isEmpty else { return fallback }
        let parts = cleaned
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "|" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? fallback : normalizeApps(parts)
    }

    fileprivate static func normalizeApps(_ apps: [String]) -> [String] {
        let cleaned = apps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if cleaned.isEmpty { return ["all"] }
        if cleaned.contains(where: { $0.caseInsensitiveCompare("all") == .orderedSame }) {
            return ["all"]
        }
        return deduplicateCaseInsensitive(cleaned)
    }

    fileprivate static func mergeApps(_ existing: [String], _ incoming: [String]) -> [String] {
        let normExisting = normalizeApps(existing)
        let normIncoming = normalizeApps(incoming)
        if normExisting.contains(where: { $0.caseInsensitiveCompare("all") == .orderedSame }) ||
            normIncoming.contains(where: { $0.caseInsensitiveCompare("all") == .orderedSame }) {
            return ["all"]
        }
        return deduplicateCaseInsensitive(normExisting + normIncoming)
    }

    private static func deduplicateCaseInsensitive(_ items: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for item in items {
            let key = item.lowercased()
            if seen.insert(key).inserted {
                out.append(item)
            }
        }
        return out
    }
}

/// Pure storage and mutation operations for `ReleaseSubscribersBook`.
public enum ReleaseSubscribersStore {
    public static let fileName = "release-subscribers.json"

    public struct UpsertSummary: Equatable, Sendable {
        public var added: Int
        public var updatedApps: Int
        public var duplicates: Int
        public var unsubscribedSkipped: Int
        public var invalid: [String]

        public init(
            added: Int = 0,
            updatedApps: Int = 0,
            duplicates: Int = 0,
            unsubscribedSkipped: Int = 0,
            invalid: [String] = []
        ) {
            self.added = added
            self.updatedApps = updatedApps
            self.duplicates = duplicates
            self.unsubscribedSkipped = unsubscribedSkipped
            self.invalid = invalid
        }
    }

    /// Canonical delivery dictionary key for `(app, version)`.
    public static func deliveryKey(app: String, version: String) -> String {
        "\(app.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(version.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    /// True when `after` is a patch release (`x.y.z` with `z > 0`) on the same `x.y` minor line as `before`.
    public static func isPatchUpdate(from before: String, to after: String) -> Bool {
        func parts(_ v: String) -> [Int]? {
            let clean = v.trimmingCharacters(in: .whitespacesAndNewlines)
            let p = clean.split(separator: ".").compactMap { Int($0) }
            return p.count == 3 ? p : nil
        }
        guard let b = parts(before), let a = parts(after) else {
            let bp = before.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".").compactMap { Int($0) }
            let ap = after.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".").compactMap { Int($0) }
            if bp.count == 2, ap.count == 3, bp[0] == ap[0], bp[1] == ap[1], ap[2] > 0 { return true }
            return false
        }
        return b[0] == a[0] && b[1] == a[1] && a[2] > 0 && a[2] != b[2]
    }

    /// Loads `release-subscribers.json` (ignoring missing, empty, invalid, or >= 5 MB files).
    public static func load(_ url: URL) -> ReleaseSubscribersBook {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attrs?[.size] as? NSNumber, size.int64Value >= 5_000_000 {
            return ReleaseSubscribersBook()
        }
        guard let data = try? Data(contentsOf: url), data.count < 5_000_000, !data.isEmpty else {
            return ReleaseSubscribersBook()
        }
        return (try? JSONDecoder().decode(ReleaseSubscribersBook.self, from: data)) ?? ReleaseSubscribersBook()
    }

    /// Saves `book` atomically with `.completeFileProtection` and `0o600` permissions, capping audit logs.
    public static func save(_ book: ReleaseSubscribersBook, to url: URL) {
        var trimmed = book
        if let ids = trimmed.processedMailIDs, ids.count > 2000 {
            trimmed.processedMailIDs = Array(ids.suffix(2000))
        }
        if let actions = trimmed.mailActions, actions.count > 200 {
            trimmed.mailActions = Array(actions.suffix(200))
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(trimmed) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Imports subscribers from `raw`, merging apps and names without ever auto-resubscribing opted-out addresses.
    @discardableResult
    public static func upsert(
        book: inout ReleaseSubscribersBook,
        raw: String,
        defaultApps: [String],
        today: String
    ) -> UpsertSummary {
        let parsed = ReleaseSubscriberImport.parse(raw, defaultApps: defaultApps)
        var summary = UpsertSummary(invalid: parsed.invalid)

        for entry in parsed.entries {
            if let idx = book.subscribers.firstIndex(where: { $0.email.caseInsensitiveCompare(entry.email) == .orderedSame }) {
                if book.subscribers[idx].unsubscribedAt != nil {
                    summary.unsubscribedSkipped += 1
                    continue
                }
                let beforeApps = ReleaseSubscriberImport.normalizeApps(book.subscribers[idx].apps)
                let mergedApps = ReleaseSubscriberImport.mergeApps(beforeApps, entry.apps)
                let appsChanged = beforeApps.map { $0.lowercased() } != mergedApps.map { $0.lowercased() }
                if appsChanged {
                    book.subscribers[idx].apps = mergedApps
                    summary.updatedApps += 1
                } else {
                    summary.duplicates += 1
                }
                if (book.subscribers[idx].name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let newName = entry.name {
                    book.subscribers[idx].name = newName
                }
            } else {
                book.subscribers.append(
                    ReleaseSubscriber(
                        email: entry.email,
                        name: entry.name,
                        apps: entry.apps,
                        addedAt: today
                    )
                )
                summary.added += 1
            }
        }
        return summary
    }

    /// Removes `email` (or only `app` from its subscriptions if multiple apps remain). Returns true if modified.
    @discardableResult
    public static func remove(book: inout ReleaseSubscribersBook, email: String, app: String? = nil) -> Bool {
        let targetEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let idx = book.subscribers.firstIndex(where: { $0.email.lowercased() == targetEmail }) else {
            return false
        }
        guard let rawApp = app else {
            book.subscribers.remove(at: idx)
            return true
        }
        let targetApp = rawApp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetApp.isEmpty else { return false }

        if book.subscribers[idx].apps.contains(where: { $0.caseInsensitiveCompare("all") == .orderedSame }) {
            book.subscribers.remove(at: idx)
            return true
        }
        let beforeCount = book.subscribers[idx].apps.count
        book.subscribers[idx].apps.removeAll { $0.caseInsensitiveCompare(targetApp) == .orderedSame }
        guard book.subscribers[idx].apps.count != beforeCount else {
            return false
        }
        if book.subscribers[idx].apps.isEmpty {
            book.subscribers.remove(at: idx)
        }
        return true
    }

    /// Clears `unsubscribedAt` and `bouncedAt` for `email`. Returns true if the subscriber changed.
    @discardableResult
    public static func reactivate(book: inout ReleaseSubscribersBook, email: String) -> Bool {
        let targetEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let idx = book.subscribers.firstIndex(where: { $0.email.lowercased() == targetEmail }) else {
            return false
        }
        guard book.subscribers[idx].unsubscribedAt != nil || book.subscribers[idx].bouncedAt != nil else {
            return false
        }
        book.subscribers[idx].unsubscribedAt = nil
        book.subscribers[idx].bouncedAt = nil
        return true
    }

    /// Active subscribers subscribed to `app` who have not yet been sent `version`.
    public static func eligibleRecipients(in book: ReleaseSubscribersBook, app: String, version: String) -> [ReleaseSubscriber] {
        let key = deliveryKey(app: app, version: version)
        let alreadySent = Set((book.deliveries[key]?.sentEmails ?? []).map { $0.lowercased() })
        return book.subscribers.filter { sub in
            sub.isActive &&
            sub.subscribed(toApp: app) &&
            !alreadySent.contains(sub.email.lowercased())
        }
    }

    /// Records a successful send for `(app, version, email)` and clears any prior failure for that address.
    public static func recordSent(
        book: inout ReleaseSubscribersBook,
        app: String,
        version: String,
        email: String,
        today: String
    ) {
        let key = deliveryKey(app: app, version: version)
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanApp = app.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)

        var log = book.deliveries[key] ?? ReleaseNotifyLog(app: cleanApp, version: cleanVersion)
        if !log.sentEmails.contains(where: { $0.caseInsensitiveCompare(cleanEmail) == .orderedSame }) {
            log.sentEmails.append(cleanEmail)
        }
        if var failed = log.failedEmails {
            for k in failed.keys where k.caseInsensitiveCompare(cleanEmail) == .orderedSame {
                failed.removeValue(forKey: k)
            }
            log.failedEmails = failed.isEmpty ? nil : failed
        }
        log.lastSentAt = today
        book.deliveries[key] = log
    }

    /// Records a send failure for `(app, version, email)`.
    public static func recordFailure(
        book: inout ReleaseSubscribersBook,
        app: String,
        version: String,
        email: String,
        error: String
    ) {
        let key = deliveryKey(app: app, version: version)
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanApp = app.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)

        var log = book.deliveries[key] ?? ReleaseNotifyLog(app: cleanApp, version: cleanVersion)
        var failed = log.failedEmails ?? [:]
        failed[cleanEmail] = String(error.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        log.failedEmails = failed
        book.deliveries[key] = log
    }
}

/// Renders and personalizes plain-text release notification emails.
public enum ReleaseNotifyTemplate {
    public static let defaultSubjectPattern = "{{app}} {{version}} is now available"
    public static let signOff = "PS, (escapethematrix.app)"
    public static let optOutLine = "If you'd rather not receive update notes, just reply \"unsubscribe\" and I'll remove you right away."

    public static let defaultBodyPattern = """
    Hi{{greeting_name}},

    {{app}} {{version}} is now live on the App Store.

    {{whats_new_section}}{{app_store_url}}

    Thank you for using {{app}}.
    PS, (escapethematrix.app)

    ---
    If you'd rather not receive update notes, just reply "unsubscribe" and I'll remove you right away.
    """

    /// Normalizes App Store release notes text, returning `nil` when empty.
    public static func cleanWhatsNew(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let lines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var s = String(line)
                while let last = s.last, last.isWhitespace { s.removeLast() }
                return s
            }
        var normalized = lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.contains("\n\n\n") {
            normalized = normalized.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return normalized.isEmpty ? nil : normalized
    }

    /// Renders `(subject, body)` for a release using optional per-app overrides and subscriber name.
    public static func render(
        app: String,
        version: String,
        whatsNew: String?,
        appStoreURL: String,
        subscriberName: String? = nil,
        config: ReleaseNotifyAppConfig? = nil
    ) -> (subject: String, body: String) {
        let subjectTemplate = config?.customSubject?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? defaultSubjectPattern
        let bodyTemplate = config?.customTemplate?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? defaultBodyPattern

        let cleanedNotes = cleanWhatsNew(whatsNew)
        let whatsNewSection = cleanedNotes.map { "What's new:\n\($0)\n\n" } ?? ""
        let whatsNewPlain = cleanedNotes ?? ""
        let firstName = extractFirstName(subscriberName)
        let greetingName = firstName.map { " \($0)" } ?? ""

        let replacements: [(String, String)] = [
            ("{{app}}", app),
            ("{{version}}", version),
            ("{{app_store_url}}", appStoreURL),
            ("{{whats_new_section}}", whatsNewSection),
            ("{{whats_new}}", whatsNewPlain),
            ("{{greeting_name}}", greetingName),
            ("{{name}}", firstName ?? ""),
            ("{{sign_off}}", signOff),
            ("{{opt_out}}", optOutLine),
        ]

        var subject = applyReplacements(replacements, to: subjectTemplate)
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if subject.isEmpty {
            subject = "\(app) \(version) is now available"
        }

        var body = applyReplacements(replacements, to: bodyTemplate)
        while body.contains("\n\n\n") {
            body = body.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return (subject, body)
    }

    /// Personalizes an owner-edited master draft for one subscriber using a safely extracted first name.
    public static func personalizeBody(_ masterBody: String, subscriberName: String?) -> String {
        let first = extractFirstName(subscriberName)
        var body = masterBody

        body = body.replacingOccurrences(of: "{{greeting_name}}", with: first.map { " \($0)" } ?? "")
        if let first {
            body = body.replacingOccurrences(of: "{{name}}", with: first)
            if let r = body.range(of: "Hi there,", options: [.anchored, .caseInsensitive]) {
                body.replaceSubrange(r, with: "Hi \(first),")
            } else if let r = body.range(of: "Hi,", options: [.anchored, .caseInsensitive]) {
                body.replaceSubrange(r, with: "Hi \(first),")
            }
        } else {
            body = body.replacingOccurrences(of: "Hi {{name}},", with: "Hi,", options: .caseInsensitive)
            body = body.replacingOccurrences(of: "{{name}}", with: "")
            if let r = body.range(of: "Hi there,", options: [.anchored, .caseInsensitive]) {
                body.replaceSubrange(r, with: "Hi,")
            }
        }
        return body
    }

    private static func applyReplacements(_ replacements: [(String, String)], to template: String) -> String {
        var out = template
        for (token, value) in replacements {
            out = out.replacingOccurrences(of: token, with: value)
        }
        return out
    }

    private static func extractFirstName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("@"),
              !trimmed.contains(where: \.isNewline) else {
            return nil
        }
        guard let firstToken = trimmed.split(whereSeparator: \.isWhitespace).first else { return nil }
        let clean = String(firstToken).trimmingCharacters(in: CharacterSet(charactersIn: ",;:"))
        guard !clean.isEmpty, clean.count <= 40, clean.contains(where: \.isLetter) else { return nil }
        return clean
    }
}

/// Deliverability and policy lint for outbound release notification drafts.
public enum ReleaseNotifySpamLint {
    private static let optOutMarkers = ["unsubscribe", "opt out", "opt-out", "stop receiving"]
    private static let shortenerHosts = ["bit.ly", "tinyurl.com", "goo.gl", "ow.ly", "is.gd"]
    private static let spamTriggers = [
        "act now", "limited time", "buy now", "click here", "100% free",
        "guaranteed", "urgent", "claim your", "winner",
    ]
    private static let blockedLocationTokens = [
        "bangalore", "bengaluru", "karnataka", "from india", "based in india",
    ]

    /// Returns a human-readable refusal reason if the notification fails any check, or `nil` when clean.
    public static func problem(
        _ text: String,
        subject: String? = nil,
        wording: WordingRules? = nil,
        versions: [String: String] = [:]
    ) -> String? {
        if let subject {
            if let p = wording?.problem(subject) { return p }
        }
        if let p = wording?.problem(text) { return p }

        if !versions.isEmpty {
            if let subject, let p = DraftGuard.problem(subject, versions: versions) { return p }
            if let p = DraftGuard.problem(text, versions: versions) { return p }
        }

        if let subject {
            let trimmedSub = subject.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedSub.isEmpty { return "Subject can't be blank." }
            if subject.contains(where: \.isNewline) { return "Subject can't contain line breaks." }
            if trimmedSub.count > 120 { return "Subject is longer than 120 characters." }
            let letters = trimmedSub.filter(\.isLetter)
            if letters.count >= 5, letters.allSatisfy(\.isUppercase) {
                return "Subject is all uppercase."
            }
        }

        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Email body is empty."
        }

        let combined = [subject, text].compactMap { $0 }.joined(separator: "\n")

        for loc in blockedLocationTokens where TopicFilter.contains(combined, phrase: loc) {
            return "mentions a developer location (“\(loc)”)"
        }

        for phrase in spamTriggers where TopicFilter.contains(combined, phrase: phrase) {
            return "uses spam-trigger phrase “\(phrase)”"
        }

        for host in shortenerHosts {
            if combined.range(of: #"(?i)(?:https?://)?(?:www\.)?"# + NSRegularExpression.escapedPattern(for: host) + #"(?:/|\b)"#, options: .regularExpression) != nil {
                return "uses blocked URL shortener (\(host))"
            }
        }

        let linkCount = combined.matches(of: /(?i)https?:\/\//).count
        if linkCount > 2 {
            return "has \(linkCount) links (maximum 2)"
        }

        if combined.contains("!!") {
            return "contains repeated exclamation marks (!!)"
        }
        let exclamationCount = combined.filter { $0 == "!" }.count
        if exclamationCount > 1 {
            return "has \(exclamationCount) exclamation marks (maximum 1)"
        }

        let lowerBody = text.lowercased()
        if !optOutMarkers.contains(where: lowerBody.contains) {
            return "missing an unsubscribe instruction"
        }

        return nil
    }
}

/// Detects and applies unsubscribe replies and bounce notices from incoming mail.
public enum ReleaseSubscriberMailMatch {
    public struct Action: Equatable, Sendable {
        public var mailID: String
        public var email: String
        public var kind: ReleaseMailRecord.Kind
        public var reason: String
        public var day: String

        public init(
            mailID: String,
            email: String,
            kind: ReleaseMailRecord.Kind,
            reason: String,
            day: String
        ) {
            self.mailID = mailID
            self.email = email
            self.kind = kind
            self.reason = reason
            self.day = day
        }
    }

    private static let unsubscribeSubjectPhrases = [
        "unsubscribe", "opt out", "opt-out", "remove me", "stop sending", "take me off",
    ]
    private static let unsubscribeExactReplies: Set<String> = [
        "unsubscribe", "stop", "remove", "opt out", "opt-out",
    ]
    private static let unsubscribeBodyPhrases = [
        "unsubscribe", "opt out", "opt-out", "remove me", "take me off",
        "stop sending", "stop emailing", "don't email", "do not email",
        "no more emails", "no more updates",
    ]

    /// Scans unread/unprocessed incoming mail for subscriber bounces and unsubscribe replies.
    public static func detect(mail: [ReplyMatch.Mail], book: ReleaseSubscribersBook) -> [Action] {
        let processed = Set(book.processedMailIDs ?? [])
        var subscribersByEmail: [String: ReleaseSubscriber] = [:]
        for sub in book.subscribers {
            let key = sub.email.lowercased()
            if subscribersByEmail[key] == nil {
                subscribersByEmail[key] = sub
            }
        }

        var actions: [Action] = []
        var seenPairs: Set<String> = []

        for m in mail {
            if processed.contains(m.id) || m.sent { continue }

            if ReplyMatch.isSystem(m.from) {
                guard ReplyMatch.isBounce(m.subject) else { continue }
                let searchText = [m.text ?? "", m.subject].joined(separator: "\n").lowercased()
                for match in searchText.matches(of: /[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}/) {
                    let candidate = String(match.output)
                    guard let sub = subscribersByEmail[candidate], sub.bouncedAt == nil else { continue }
                    let pairKey = "\(m.id)|\(sub.email.lowercased())|bounce"
                    guard seenPairs.insert(pairKey).inserted else { continue }
                    let reason = m.subject.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "delivery bounce"
                    actions.append(Action(mailID: m.id, email: sub.email, kind: .bounce, reason: reason, day: m.day))
                }
                continue
            }

            let sender = ReplyMatch.address(m.from)
            guard let sub = subscribersByEmail[sender], sub.unsubscribedAt == nil else { continue }
            if let reason = unsubscribeReason(subject: m.subject, text: m.text) {
                let pairKey = "\(m.id)|\(sub.email.lowercased())|unsubscribe"
                guard seenPairs.insert(pairKey).inserted else { continue }
                actions.append(Action(mailID: m.id, email: sub.email, kind: .unsubscribe, reason: reason, day: m.day))
            }
        }

        return actions
    }

    /// Applies detected actions to `book`, recording `processedMailIDs` and `mailActions`.
    @discardableResult
    public static func apply(_ actions: [Action], to book: inout ReleaseSubscribersBook) -> [ReleaseMailRecord] {
        var processed = book.processedMailIDs ?? []
        var processedSet = Set(processed)
        var records = book.mailActions ?? []
        var applied: [ReleaseMailRecord] = []

        for action in actions {
            if processedSet.insert(action.mailID).inserted {
                processed.append(action.mailID)
            }
            guard let idx = book.subscribers.firstIndex(where: { $0.email.caseInsensitiveCompare(action.email) == .orderedSame }) else {
                continue
            }

            switch action.kind {
            case .unsubscribe:
                guard book.subscribers[idx].unsubscribedAt == nil else { continue }
                book.subscribers[idx].unsubscribedAt = action.day
            case .bounce:
                guard book.subscribers[idx].bouncedAt == nil else { continue }
                book.subscribers[idx].bouncedAt = action.day
            }

            let record = ReleaseMailRecord(
                email: book.subscribers[idx].email,
                kind: action.kind,
                mailID: action.mailID,
                reason: action.reason,
                day: action.day
            )
            records.append(record)
            applied.append(record)
        }

        book.processedMailIDs = processed.isEmpty ? nil : processed
        book.mailActions = records.isEmpty ? nil : records
        return applied
    }

    private static func unsubscribeReason(subject: String, text: String?) -> String? {
        let lowerSub = subject.lowercased()
        if unsubscribeSubjectPhrases.contains(where: { TopicFilter.contains(lowerSub, phrase: $0) }) {
            return subject.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "unsubscribe subject"
        }

        guard let text else { return nil }
        let cleaned = stripQuotedOptOut(text)
        guard !cleaned.isEmpty else { return nil }

        let compactReply = cleaned
            .lowercased()
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        if unsubscribeExactReplies.contains(compactReply) {
            return "replied \"\(compactReply)\""
        }
        for phrase in unsubscribeBodyPhrases where TopicFilter.contains(cleaned, phrase: phrase) {
            return "replied \"\(String(cleaned.prefix(80)))\""
        }
        return nil
    }

    private static func stripQuotedOptOut(_ text: String) -> String {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        var kept: [String] = []
        for rawLine in lines {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(">") || trimmed == "---" { break }
            if trimmed.range(of: #"^On .+ wrote:$"#, options: .regularExpression) != nil { break }
            if trimmed.localizedCaseInsensitiveContains("rather not receive update notes") { continue }
            kept.append(trimmed)
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

fileprivate extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
