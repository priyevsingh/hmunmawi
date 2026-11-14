import Foundation

/// One Mac privacy permission Hmunmawi or a helper may need, described in plain words with a Settings deep link.
/// Status is computed from already-known facts (never from a probe that can present a system prompt).
public enum MacPermissionID: String, Sendable, CaseIterable, Codable {
    case fullDiskAccess
    case filesAndFolders
    case automationMessages
    case automationSafari
    case automationMail
    case notifications
    case calendars
    case accessibility
    case openAtLogin
    case keychain
    case claudeGateFDA
}

public enum MacPermissionStatus: String, Sendable, Equatable, Codable {
    case granted
    case notGranted
    case notNeeded
}

/// Whether a job may start. Missing items must be fixed in Settings; the job must not show a system prompt.
public struct MacPreflight: Sendable, Equatable {
    public var allowed: Bool
    public var missing: [MacPermissionID]
    /// Short line for a notification or menu item, e.g. "Needs permission: Safari — Fix".
    public var banner: String?

    public init(allowed: Bool, missing: [MacPermissionID], banner: String? = nil) {
        self.allowed = allowed
        self.missing = missing
        self.banner = banner
    }

    public static func ok() -> MacPreflight { MacPreflight(allowed: true, missing: []) }

    public static func blocked(_ missing: [MacPermissionID], titles: [MacPermissionID: String]) -> MacPreflight {
        let first = missing.first.flatMap { titles[$0] } ?? "Mac access"
        return MacPreflight(allowed: false, missing: missing, banner: "Needs permission: \(first) — Fix")
    }
}

public enum MacJobNeed: String, Sendable {
    case messages
    case safari
    case mail
    case calendar
    case files
    case claude
    case notifications
}

/// Facts gathered without prompting, used to build the permissions list and pre-flights. Tests pass a fixture.
public struct MacPermissionFacts: Sendable, Equatable {
    public var fullDiskAccess: Bool
    public var filesAndFolders: Bool
    public var messages: MacPermissionStatus
    public var safari: MacPermissionStatus
    public var mail: MacPermissionStatus
    public var notifications: MacPermissionStatus
    public var calendars: MacPermissionStatus
    public var accessibility: MacPermissionStatus
    public var openAtLogin: MacPermissionStatus
    public var keychain: MacPermissionStatus
    public var claudeGateURL: URL?
    public var claudeGateHasFDA: Bool?
    public var usesIMessage: Bool
    public var usesSafariLogin: Bool
    public var usesMail: Bool
    public var usesCalendar: Bool
    public var usesClaudeJobs: Bool

    public init(fullDiskAccess: Bool = false, filesAndFolders: Bool = false,
                messages: MacPermissionStatus = .notGranted, safari: MacPermissionStatus = .notGranted,
                mail: MacPermissionStatus = .notGranted, notifications: MacPermissionStatus = .notGranted,
                calendars: MacPermissionStatus = .notGranted, accessibility: MacPermissionStatus = .notGranted,
                openAtLogin: MacPermissionStatus = .notGranted, keychain: MacPermissionStatus = .notGranted,
                claudeGateURL: URL? = nil, claudeGateHasFDA: Bool? = nil,
                usesIMessage: Bool = false, usesSafariLogin: Bool = false, usesMail: Bool = false,
                usesCalendar: Bool = false, usesClaudeJobs: Bool = false) {
        self.fullDiskAccess = fullDiskAccess
        self.filesAndFolders = filesAndFolders
        self.messages = messages
        self.safari = safari
        self.mail = mail
        self.notifications = notifications
        self.calendars = calendars
        self.accessibility = accessibility
        self.openAtLogin = openAtLogin
        self.keychain = keychain
        self.claudeGateURL = claudeGateURL
        self.claudeGateHasFDA = claudeGateHasFDA
        self.usesIMessage = usesIMessage
        self.usesSafariLogin = usesSafariLogin
        self.usesMail = usesMail
        self.usesCalendar = usesCalendar
        self.usesClaudeJobs = usesClaudeJobs
    }
}

public struct MacPermissionItem: Sendable, Equatable, Identifiable {
    public var id: MacPermissionID
    public var title: String
    public var detail: String
    public var status: MacPermissionStatus
    /// Required for the person's current setup (shown as something they should grant).
    public var required: Bool
    public var settingsURL: String
    /// When set, the row can offer "Reveal in Finder" so the person can drag this app into Full Disk Access.
    public var revealURL: URL?
    /// The Grant button can ask macOS itself (true) or only open Settings (false: no public prompt API).
    public var canPrompt: Bool

    public var shortTitle: String { title }
}

public struct MacPermissionSnapshot: Sendable, Equatable {
    public var items: [MacPermissionItem]
    public var facts: MacPermissionFacts

    public init(items: [MacPermissionItem], facts: MacPermissionFacts) {
        self.items = items
        self.facts = facts
    }

    public static let empty = MacPermissionSnapshot(items: [], facts: MacPermissionFacts())

    public func item(_ id: MacPermissionID) -> MacPermissionItem? { items.first { $0.id == id } }

    public var requiredMissing: [MacPermissionItem] { items.filter { $0.required && $0.status == .notGranted } }
    public var requiredGranted: Bool { requiredMissing.isEmpty }
    public var cautionLines: [String] { requiredMissing.map { "Mac permissions: \($0.title) isn't on yet" } }
    public var titles: [MacPermissionID: String] { Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.title) }) }

    public func preflight(_ needs: [MacJobNeed]) -> MacPreflight {
        MacPermissionCatalog.preflight(needs, snapshot: self)
    }
}

/// Catalogue, Settings URLs, Full Disk Access probe and job pre-flight. No system prompt lives in this type.
public enum MacPermissionCatalog {
    /// Current System Settings (Ventura–macOS 26). Legacy `com.apple.preference.security` still works as a fallback.
    public static let modernBase = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
    public static let legacyBase = "x-apple.systempreferences:com.apple.preference.security"

    public static func privacyURL(_ fragment: String) -> String {
        "\(modernBase)?\(fragment)"
    }

    public static let filesAndFoldersURL = privacyURL("Privacy_FilesAndFolders")
    public static let fullDiskAccessURL = privacyURL("Privacy_AllFiles")
    public static let automationURL = privacyURL("Privacy_Automation")
    public static let accessibilityURL = privacyURL("Privacy_Accessibility")
    public static let calendarsURL = privacyURL("Privacy_Calendars")
    public static let notificationsURL = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"

    /// Locations only Full Disk Access can read. Listing them must never prompt (it is not a Files and Folders path).
    public static func defaultFDAProbePaths(home: URL = URL.homeDirectory) -> [String] {
        [
            "Library/Safari/Bookmarks.plist",
            "Library/Safari/CloudTabs.db",
            "Library/Mail",
            "Library/Messages",
            "Library/Suggestions",
            "Library/HomeKit",
            "Library/Application Support/com.apple.TCC/TCC.db",
        ].map { home.appending(path: $0).path }
    }

    /// True when at least one existing FDA-protected path is readable. Missing paths are skipped.
    /// Never pass a Documents / Desktop / Downloads path here: those can present a Files and Folders prompt.
    public static func hasFullDiskAccess(probePaths: [String] = defaultFDAProbePaths(),
                                         exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                                         readable: (String) -> Bool = { FileManager.default.isReadableFile(atPath: $0) }) -> Bool {
        let existing = probePaths.filter(exists)
        guard !existing.isEmpty else { return false }
        return existing.contains(where: readable)
    }

    public static func claudeGateURL(ownerPath: String?, home: URL = URL.homeDirectory,
                                     exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL? {
        if let ownerPath, !ownerPath.trimmingCharacters(in: .whitespaces).isEmpty {
            let full = ownerPath.hasPrefix("~") ? (ownerPath as NSString).expandingTildeInPath : ownerPath
            let url = URL(fileURLWithPath: full)
            if exists(url) { return url }
        }
        return nil
    }

    public static func items(from facts: MacPermissionFacts) -> [MacPermissionItem] {
        let filesGranted = facts.fullDiskAccess || facts.filesAndFolders
        let filesStatus: MacPermissionStatus = filesGranted ? .granted : .notGranted
        let messagesNeeded = facts.usesIMessage
        let safariNeeded = facts.usesSafariLogin
        let mailNeeded = facts.usesMail
        let calendarNeeded = facts.usesCalendar
        let claudeNeeded = facts.usesClaudeJobs || facts.claudeGateURL != nil
        let claudeStatus: MacPermissionStatus = {
            if !claudeNeeded { return .notNeeded }
            if facts.claudeGateURL == nil { return .notGranted }
            if let ok = facts.claudeGateHasFDA { return ok ? .granted : .notGranted }
            return .notGranted
        }()

        func auto(_ status: MacPermissionStatus, needed: Bool) -> MacPermissionStatus {
            if !needed && status != .granted { return .notNeeded }
            return status == .granted ? .granted : .notGranted
        }

        return [
            MacPermissionItem(id: .fullDiskAccess, title: "All files on this Mac",
                              detail: "Lets routines keep working in folders macOS otherwise locks (Documents, Mail, Safari data). Turn it on once in System Settings, and Hmunmawi won't ask folder by folder.",
                              status: facts.fullDiskAccess ? .granted : .notGranted, required: false,
                              settingsURL: fullDiskAccessURL, revealURL: nil, canPrompt: false),
            MacPermissionItem(id: .filesAndFolders, title: "Files in Documents, Downloads and Desktop",
                              detail: "Lets Hmunmawi find key files and scripts you keep in those folders. Already included if All files is on.",
                              status: filesStatus, required: true,
                              settingsURL: filesAndFoldersURL, revealURL: nil, canPrompt: true),
            MacPermissionItem(id: .notifications, title: "Mac notifications",
                              detail: "Tells you when something needs a look, including a missing permission, without interrupting a routine. You can also get alerts by iMessage or ntfy.",
                              status: facts.notifications == .granted ? .granted : .notGranted, required: false,
                              settingsURL: notificationsURL, revealURL: nil, canPrompt: true),
            MacPermissionItem(id: .automationMessages, title: "Messages",
                              detail: "Sends an iMessage to your own number only when a rule you switched on says so.",
                              status: auto(facts.messages, needed: messagesNeeded), required: messagesNeeded,
                              settingsURL: automationURL, revealURL: nil, canPrompt: true),
            MacPermissionItem(id: .automationSafari, title: "Safari",
                              detail: "Reads a page you already have open, only when you choose “Read using my Safari login”.",
                              status: auto(facts.safari, needed: safariNeeded), required: safariNeeded,
                              settingsURL: automationURL, revealURL: nil, canPrompt: true),
            MacPermissionItem(id: .automationMail, title: "Apple Mail",
                              detail: "Lists sender, subject and date for outreach replies, only if you pick Apple Mail as the mail source. Hmunmawi never sends or deletes mail.",
                              status: auto(facts.mail, needed: mailNeeded), required: mailNeeded,
                              settingsURL: automationURL, revealURL: nil, canPrompt: true),
            MacPermissionItem(id: .calendars, title: "Calendar",
                              detail: "Adds an event to its own “Hmunmawi” calendar when a routine has “Also put it in my Calendar” on. Nothing else in your Calendar is read or changed.",
                              status: auto(facts.calendars, needed: calendarNeeded), required: calendarNeeded,
                              settingsURL: calendarsURL, revealURL: nil, canPrompt: true),
            MacPermissionItem(id: .openAtLogin, title: "Open at login",
                              detail: "Keeps watching your apps after a restart, quietly in the background. Optional — it is your choice.",
                              status: facts.openAtLogin == .granted ? .granted : .notGranted, required: false,
                              settingsURL: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
                              revealURL: nil, canPrompt: true),
            MacPermissionItem(id: .keychain, title: "Keychain",
                              detail: "Hmunmawi keeps your keys in your Mac’s Keychain and never shows a password box. If this needs attention after a rebuild, use the same signing certificate as before.",
                              status: facts.keychain == .granted ? .granted : .notGranted, required: true,
                              settingsURL: "file:///System/Applications/Utilities/Keychain%20Access.app",
                              revealURL: nil, canPrompt: false),
            MacPermissionItem(id: .accessibility, title: "Accessibility",
                              detail: "Only needed if a routine has to click in another app’s windows. Everyday Safari and Messages use does not need this.",
                              status: facts.accessibility == .granted ? .granted : .notNeeded, required: false,
                              settingsURL: accessibilityURL, revealURL: nil, canPrompt: false),
            MacPermissionItem(id: .claudeGateFDA, title: "Claude helper (all files)",
                              detail: "Background Claude jobs must run through the signed ClaudeGate helper, not the versioned Claude program, so macOS does not ask again after an update. Add ClaudeGate to Full Disk Access once. Use Reveal in Finder, then drag it into the list.",
                              status: claudeStatus, required: claudeNeeded,
                              settingsURL: fullDiskAccessURL, revealURL: facts.claudeGateURL, canPrompt: false),
        ]
    }

    public static func snapshot(from facts: MacPermissionFacts) -> MacPermissionSnapshot {
        MacPermissionSnapshot(items: items(from: facts), facts: facts)
    }

    public static func needs(for job: MacJobNeed) -> [MacPermissionID] {
        switch job {
        case .messages: [.automationMessages]
        case .safari: [.automationSafari]
        case .mail: [.automationMail]
        case .calendar: [.calendars]
        case .files: [.filesAndFolders]
        case .claude: [.claudeGateFDA]
        case .notifications: [.notifications]
        }
    }

    public static func preflight(_ needs: [MacJobNeed], snapshot: MacPermissionSnapshot) -> MacPreflight {
        var missing: [MacPermissionID] = []
        for need in needs {
            for id in Self.needs(for: need) {
                let item = snapshot.item(id)
                // filesAndFolders is satisfied by Full Disk Access too (already reflected in status).
                if item?.status == .granted || item?.status == .notNeeded { continue }
                if !missing.contains(id) { missing.append(id) }
            }
        }
        if missing.isEmpty { return .ok() }
        return .blocked(missing, titles: snapshot.titles)
    }
}
