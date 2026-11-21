import Foundation

/// Extras anyone can switch on: a workspace folder, extra folders for Find my key, the AI job pause card, the Zoho
/// Mail (Safari) reader, an X numbers file and a fixed time zone. Set them in Settings → General → Your extras (or
/// with `hm set extras.*`), or in your private workspace's `config/hmunmawi-extras.json`.
///
/// Order, highest first: an owner settings file (`owner.json`, see `OwnerConfig`) > this Mac's settings > the
/// workspace file. So an owner Mac keeps exactly what its owner.json says.
///
/// Some extras stay owner-only (see `ownerOnly`): they need a build made on that Mac or run a program of the owner's.
public struct UserExtras: Codable, Sendable, Equatable {
    /// Your private workspace folder (scripts, configs, the switch file, this extras file).
    public var workspace: String?
    /// A folder of `.env` and key files that Find my key looks in first (read only when you press it).
    public var keyFolder: String?
    /// A folder of repositories Find my key also looks through (one level, up to 40).
    public var reposFolder: String?
    /// Show the AI job pause card (Today and the menu bar) for your own AI runner.
    public var aiPauseCard: Bool?
    /// Offer the Zoho Mail (Safari) reader in Settings → Connections → Mail.
    public var zohoMail: Bool?
    /// Your X numbers file (workspace file only; Settings uses `x.file`). Relative paths are inside the workspace.
    public var xFile: String?
    /// Fixed time zone for every date and "today" in the app, e.g. "Europe/Berlin". Unset = this Mac's.
    public var timeZone: String?

    public init(workspace: String? = nil, keyFolder: String? = nil, reposFolder: String? = nil, aiPauseCard: Bool? = nil,
                zohoMail: Bool? = nil, xFile: String? = nil, timeZone: String? = nil) {
        self.workspace = workspace; self.keyFolder = keyFolder; self.reposFolder = reposFolder
        self.aiPauseCard = aiPauseCard; self.zohoMail = zohoMail; self.xFile = xFile; self.timeZone = timeZone
    }

    enum CodingKeys: String, CodingKey {
        case workspace, keyFolder = "key_folder", reposFolder = "repos_folder", aiPauseCard = "ai_pause_card"
        case zohoMail = "zoho_mail", xFile = "x_file", timeZone = "time_zone"
    }

    /// The workspace file's name, inside the workspace folder.
    public static let workspaceFileName = "config/hmunmawi-extras.json"

    public enum FileState: Equatable, Sendable { case none, missing, ok, unreadable(String) }

    /// Reads a workspace extras file. A missing file is `.missing`; a broken one says why and switches nothing on.
    public static func load(_ url: URL) -> (UserExtras, FileState) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (UserExtras(), .missing) }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 64 * 1024 else { return (UserExtras(), .unreadable("larger than 64 KB")) }
            return (try JSONDecoder().decode(UserExtras.self, from: data), .ok)
        } catch let e as DecodingError {
            return (UserExtras(), .unreadable(Self.plain(e)))
        } catch {
            return (UserExtras(), .unreadable(error.localizedDescription))
        }
    }

    private static func plain(_ e: DecodingError) -> String {
        switch e {
        case .typeMismatch(_, let c), .valueNotFound(_, let c):
            let key = c.codingPath.map(\.stringValue).joined(separator: ".")
            return key.isEmpty ? "not a JSON object" : "\(key) has the wrong type"
        case .dataCorrupted: return "not valid JSON"
        default: return "not valid JSON"
        }
    }
}

/// Where an extra's value comes from.
public enum ExtraSource: String, Sendable, Equatable {
    case owner = "owner settings file", settings = "Settings", workspace = "workspace file", build = "this build", none = "off"
}

/// One extra as it is in effect now.
public struct ExtraItem: Sendable, Equatable {
    public let id: String          // the `hm set` key, e.g. "extras.time_zone"
    public let title: String
    public let on: Bool
    public let value: String?      // a path or zone, never a secret
    public let source: ExtraSource
    /// Only the owner can change it (an owner settings file sets it, or it is owner-only by nature).
    public let ownerOnly: Bool
    public let note: String
}

/// The extras in effect: owner settings file > this Mac's settings > workspace file.
public struct Extras: Sendable {
    public let owner: OwnerConfig
    public let settings: UserExtras
    public let file: UserExtras
    public let fileState: UserExtras.FileState
    /// The Keychain-prompt watcher is inside this app (only builds made on the owner's Mac carry it).
    public let watcherBundled: Bool

    public init(owner: OwnerConfig, settings: UserExtras, file: UserExtras = UserExtras(),
                fileState: UserExtras.FileState = .none, watcherBundled: Bool = false) {
        self.owner = owner; self.settings = settings; self.file = file; self.fileState = fileState
        self.watcherBundled = watcherBundled
    }

    // MARK: Paths

    static func expand(_ p: String?, relativeTo base: URL? = nil) -> URL? {
        guard let raw = p?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.hasPrefix("~") { return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath) }
        if raw.hasPrefix("/") { return URL(fileURLWithPath: raw) }
        guard let base else { return nil }   // a relative path means "inside the workspace"
        return base.appending(path: raw)
    }

    private func pick(_ ownerValue: URL?, _ setting: String?, _ fromFile: String?, base: URL?) -> (URL?, ExtraSource) {
        if let ownerValue { return (ownerValue, .owner) }
        if let u = Self.expand(setting) { return (u, .settings) }
        if let u = Self.expand(fromFile, relativeTo: base) { return (u, .workspace) }
        return (nil, .none)
    }

    /// The workspace folder: the owner's hub, else the one chosen in Settings. (The workspace file can't move the
    /// workspace it lives in.)
    public var workspace: (url: URL?, source: ExtraSource) {
        if let hub = owner.hubURL { return (hub, .owner) }
        if let u = Self.expand(settings.workspace) { return (u, .settings) }
        return (nil, .none)
    }
    public var workspaceFileURL: URL? { workspace.url?.appending(path: UserExtras.workspaceFileName) }

    public var keyFolder: (url: URL?, source: ExtraSource) {
        pick(owner.keyFolderURL, settings.keyFolder, file.keyFolder, base: workspace.url)
    }
    public var reposFolder: (url: URL?, source: ExtraSource) {
        pick(owner.reposURL, settings.reposFolder, file.reposFolder, base: workspace.url)
    }
    /// The X numbers file from the workspace file (Settings' own `x.file` is read by the X feed itself first).
    public var workspaceXFile: URL? { Self.expand(file.xFile, relativeTo: workspace.url) }

    private func flag(_ ownerOn: Bool, _ setting: Bool?, _ fromFile: Bool?) -> (on: Bool, source: ExtraSource) {
        if ownerOn { return (true, .owner) }
        if let setting { return (setting, setting ? .settings : .none) }
        if let fromFile, fromFile { return (true, .workspace) }
        return (false, .none)
    }
    public var aiPauseCard: (on: Bool, source: ExtraSource) { flag(owner.showsAIPause, settings.aiPauseCard, file.aiPauseCard) }
    public var zohoMail: (on: Bool, source: ExtraSource) { flag(owner.offersZoho, settings.zohoMail, file.zohoMail) }

    /// A valid fixed time zone and where it is set; nil = this Mac's own.
    public var fixedZone: (zone: TimeZone, source: ExtraSource)? {
        if owner.enabled, let z = owner.timeZone.flatMap(TimeZone.init(identifier:)) { return (z, .owner) }
        if let z = settings.timeZone.flatMap(TimeZone.init(identifier:)) { return (z, .settings) }
        if let z = file.timeZone.flatMap(TimeZone.init(identifier:)) { return (z, .workspace) }
        return nil
    }
    /// The zone every date in the app uses.
    public var zone: TimeZone { fixedZone?.zone ?? .current }

    public var keychainWatcher: (on: Bool, source: ExtraSource) {
        if owner.wantsKeychainWatcher { return (true, .owner) }
        return watcherBundled ? (true, .build) : (false, .none)
    }

    // MARK: The list (Settings → General and `hm extras`)

    private static func short(_ u: URL?) -> String? { u.map { $0.path.replacingOccurrences(of: URL.homeDirectory.path, with: "~") } }

    /// Every extra with its state, in the order the section shows them. `xFileSetting` is Settings' `x.file`.
    public func items(xFileSetting: String = "") -> [ExtraItem] {
        let ws = workspace, kf = keyFolder, rf = reposFolder, ai = aiPauseCard, zo = zohoMail, kw = keychainWatcher
        let xSetting = xFileSetting.trimmingCharacters(in: .whitespaces)
        let x: (URL?, ExtraSource) = owner.usesXFileFeed && xSetting.isEmpty ? (nil, .owner)
            : !xSetting.isEmpty ? (Self.expand(xSetting), .settings) : (workspaceXFile, workspaceXFile == nil ? .none : .workspace)
        let fz = fixedZone
        return [
            ExtraItem(id: "extras.workspace", title: "Workspace folder", on: ws.url != nil, value: Self.short(ws.url), source: ws.source,
                      ownerOnly: ws.source == .owner, note: "Your private workspace: Find my key looks in it, Settings → Jobs finds its switch file, and its config/hmunmawi-extras.json can switch on the extras below."),
            ExtraItem(id: "extras.key_folder", title: "Key folder for Find my key", on: kf.url != nil, value: Self.short(kf.url), source: kf.source,
                      ownerOnly: kf.source == .owner, note: "A folder of .env and key files Find my key looks in first. Nothing is read until you press Find my key."),
            ExtraItem(id: "extras.repos_folder", title: "Repositories folder for Find my key", on: rf.url != nil, value: Self.short(rf.url), source: rf.source,
                      ownerOnly: rf.source == .owner, note: "Find my key also looks through the projects in this folder (up to 40)."),
            ExtraItem(id: "extras.ai_pause_card", title: "AI job pause card", on: ai.on, value: nil, source: ai.source,
                      ownerOnly: ai.source == .owner, note: "Shows when your own AI jobs are paused (Today and the menu bar). Your runner asks with hm ai-pause-check."),
            ExtraItem(id: "extras.zoho_mail", title: "Zoho Mail reader (Safari)", on: zo.on, value: nil, source: zo.source,
                      ownerOnly: zo.source == .owner, note: "Offers Zoho Mail in Settings → Connections → Mail, read through your Safari login (for Zoho plans without IMAP)."),
            ExtraItem(id: "x.file", title: "X numbers from a file", on: x.0 != nil || x.1 == .owner, value: Self.short(x.0), source: x.1,
                      ownerOnly: false, note: "A file your bot or a Mac job writes with your X numbers; the X connection reads it for free."),
            ExtraItem(id: "extras.time_zone", title: "Fixed time zone", on: fz != nil, value: fz?.zone.identifier, source: fz?.source ?? .none,
                      ownerOnly: fz?.source == .owner, note: "Every date and \u{201C}today\u{201D} in the app follows this zone instead of the Mac's. Fully applied after the next start."),
            ExtraItem(id: "extras.keychain_watcher", title: "Keychain-prompt watcher", on: kw.on, value: nil, source: kw.source,
                      ownerOnly: true, note: "Texts you when a macOS Keychain box waits. Only in builds you make yourself on your own Mac (scripts/make-app.sh with your own watcher script); never in the published app."),
        ]
    }

    /// Owner-only extras that are not in the list above, for `hm extras` (on/off only).
    public var ownerOnly: [(id: String, title: String, on: Bool, why: String)] {
        [("owner.safari_driver", "Safari steps through the owner's automation helper", owner.safariDriverURL != nil,
          "Runs a program of the owner's for every Safari step; only an owner settings file can name it."),
         ("owner.ai_policy_adapter", "AI pause through the owner's own policy script", owner.hubURL != nil && owner.showsAIPause,
          "Uses the owner's own ai_policy.py and job-data folder; everyone else gets Hmunmawi's built-in pause."),
         ("owner.typed_key_files", "Typed keys also kept in 0600 files", owner.enabled,
          "A recovery copy for the owner's re-signed builds; a normal install keeps keys only in the Keychain."),
         ("owner.wall_shoutouts", "Welcome drafts for new Wall of Apps entries", owner.wantsWallShoutouts,
          "For the project's maintainer only.")]
    }

    // MARK: Current

    /// This Mac's settings (UserDefaults keys below) as one value.
    public static func settingsFromDefaults(_ d: UserDefaults = .standard) -> UserExtras {
        UserExtras(workspace: d.string(forKey: Key.workspace), keyFolder: d.string(forKey: Key.keyFolder),
                   reposFolder: d.string(forKey: Key.reposFolder),
                   aiPauseCard: d.object(forKey: Key.aiPauseCard) as? Bool, zohoMail: d.object(forKey: Key.zohoMail) as? Bool,
                   xFile: nil, timeZone: d.string(forKey: Key.timeZone))
    }

    public enum Key {
        public static let workspace = "HMExtrasWorkspace", keyFolder = "HMExtrasKeyFolder", reposFolder = "HMExtrasReposFolder"
        public static let aiPauseCard = "HMExtrasAIPauseCard", zohoMail = "HMExtrasZohoMail", timeZone = "HMExtrasTimeZone"
    }

    public static var watcherInThisBuild: Bool {
        FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appending(path: "Contents/Helpers/keychain-prompt-watch.sh").path)
    }

    nonisolated(unsafe) private static var cached: (Extras, Date)?
    private static let lock = NSLock()
    /// Tests set this.
    nonisolated(unsafe) public static var override: Extras?

    /// The extras in effect (re-read at most every 30 seconds; `reload()` after a change).
    public static var current: Extras {
        lock.lock(); defer { lock.unlock() }
        if let override { return override }
        if let (c, at) = cached, Date.now.timeIntervalSince(at) < 30 { return c }
        let owner = OwnerConfig.current
        let settings = settingsFromDefaults()
        var e = Extras(owner: owner, settings: settings, watcherBundled: watcherInThisBuild)
        if let url = e.workspaceFileURL {
            let (f, state) = UserExtras.load(url)
            e = Extras(owner: owner, settings: settings, file: f, fileState: state, watcherBundled: e.watcherBundled)
        }
        cached = (e, .now)
        return e
    }

    public static func reload() { lock.lock(); cached = nil; lock.unlock() }

    // MARK: The app's time zone

    nonisolated(unsafe) private static var launchTZ: String??
    nonisolated(unsafe) private static var macZoneID: String?

    /// This Mac's own zone, as it was before a fixed zone was applied.
    public static var macZone: TimeZone { macZoneID.flatMap(TimeZone.init(identifier:)) ?? NSTimeZone.system }

    /// Makes the fixed zone the whole app's: `Date.formatted`, `TimeZone.current`, calendars and formatters all follow
    /// it (NSTimeZone.default alone isn't enough: format styles use the system zone). Only when it differs from the
    /// Mac's own; otherwise the process keeps its original zone untouched. Scripts and add-ons Hmunmawi starts inherit
    /// it, so their "today" matches the app's. Clearing it restores the original.
    public static func applyProcessZone() {
        lock.lock()
        if launchTZ == nil {
            launchTZ = .some(getenv("TZ").map { String(cString: $0) })
            macZoneID = NSTimeZone.system.identifier
        }
        let original = launchTZ ?? nil, mac = macZoneID
        lock.unlock()
        let want = current.fixedZone?.zone
        if let want, want.identifier != mac {
            setenv("TZ", want.identifier, 1)
        } else if let original {
            setenv("TZ", original, 1)
        } else {
            unsetenv("TZ")
        }
        tzset()
        NSTimeZone.resetSystemTimeZone()
        NSTimeZone.default = want ?? NSTimeZone.system
    }
}
