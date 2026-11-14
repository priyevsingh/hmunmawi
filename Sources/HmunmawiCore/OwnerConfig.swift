import Foundation

/// Extras for one particular owner's Mac (their own script hub, key folder, bot-written X file, AI pause policy,
/// Zoho mail, Keychain-prompt watcher, fixed time zone or currency). Off for everyone else: a new install has no
/// `owner.json`, so it scans only standard places and folders you choose, and shows none of these extras.
///
/// Lives in the app's data folder as `owner.json` (Settings → Advanced shows what it switches on). Every field is
/// optional; paths may start with `~`. Nothing here is a secret: only where files are.
public struct OwnerConfig: Codable, Sendable, Equatable {
    public static let fileName = "owner.json"

    /// The master switch. False (or no file) = a normal install.
    public var enabled: Bool = false
    /// A folder of your own scripts and configs (e.g. a repo that writes Hmunmawi's script feed).
    public var hubRoot: String?
    /// The App Store Connect config inside `hubRoot` (relative) or anywhere (absolute), with issuer_id / key_id /
    /// private_key_path keys.
    public var ascConfig: String?
    /// A folder of `.env` files and key files that Find my key reads first.
    public var keyFolder: String?
    /// A folder of repositories Find my key also looks through (two levels).
    public var reposFolder: String?
    /// Show the AI pause card and policy controls (needs the hub's ai_policy.py).
    public var aiPause: Bool?
    /// Offer the Zoho Mail (Safari) reader in Settings → Mail.
    public var zohoMail: Bool?
    /// Show the X row fed by a file your own bot writes.
    public var xFileFeed: Bool?
    /// Builds for this Mac include the Keychain-prompt watcher (texts you when a Keychain box waits).
    public var keychainWatcher: Bool?
    /// Fixed time zone for labels (e.g. "Asia/Kolkata"); nil = the Mac's own.
    public var timeZone: String?
    /// The ntfy relay log your hub writes (for the ntfy row's "last delivered").
    public var ntfyRelayLog: String?
    /// An osascript-compatible helper (`<tool> -e <script>`) that Safari fixes go through instead of Hmunmawi's own
    /// Apple Events permission (e.g. an automation app that already holds the Safari permission).
    public var safariDriver: String?
    /// Optional path to the signed ClaudeGate helper. When set, Mac permissions treats its Full Disk Access as required.
    /// Leave unset to use the standard Application Support location if that app is installed.
    public var claudeGateApp: String?
    /// Optional folder where the owner's own job scripts keep their state (AI pause policy, relay state).
    public var jobsData: String?
    /// The project's maintainer: draft a welcome post into the post bank when a new app joins the Wall of Apps.
    public var wallShoutouts: Bool?

    public init(enabled: Bool = false) { self.enabled = enabled }

    // MARK: Reading

    /// Where `owner.json` lives: the app's data folder (a test profile has its own, so it never sees the owner's).
    public static var fileURL: URL {
        if let p = ProcessInfo.processInfo.environment["HMUNMAWI_OWNER_CONFIG"], !p.isEmpty {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        }
        return URL.applicationSupportDirectory.appending(path: TestProfile.supportFolderName, directoryHint: .isDirectory)
            .appending(path: fileName)
    }

    nonisolated(unsafe) private static var cached: OwnerConfig?
    private static let lock = NSLock()

    /// The owner extras in effect (read once; `reload()` after the file changes). Tests set `override`.
    public static var current: OwnerConfig {
        lock.lock(); defer { lock.unlock() }
        if let override { return override }
        if let cached { return cached }
        let c = load(from: fileURL)
        cached = c
        return c
    }

    nonisolated(unsafe) public static var override: OwnerConfig?

    public static func reload() { lock.lock(); cached = nil; lock.unlock() }

    public static func load(from url: URL) -> OwnerConfig {
        guard let data = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(OwnerConfig.self, from: data) else {
            return OwnerConfig()
        }
        return c
    }

    public func save(to url: URL = OwnerConfig.fileURL) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try e.encode(self).write(to: url, options: .atomic)
    }

    // MARK: What it switches on (all false / nil when not enabled)

    public var isOn: Bool { enabled }
    public var showsAIPause: Bool { enabled && (aiPause ?? false) }
    public var offersZoho: Bool { enabled && (zohoMail ?? false) }
    public var usesXFileFeed: Bool { enabled && (xFileFeed ?? false) }
    public var wantsKeychainWatcher: Bool { enabled && (keychainWatcher ?? false) }
    public var wantsWallShoutouts: Bool { enabled && (wallShoutouts ?? false) }

    private static func expand(_ p: String?) -> URL? {
        guard let p, !p.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let full = p.hasPrefix("~") ? (p as NSString).expandingTildeInPath : p
        return URL(fileURLWithPath: full)
    }
    public var hubURL: URL? { enabled ? Self.expand(hubRoot) : nil }
    public var keyFolderURL: URL? { enabled ? Self.expand(keyFolder) : nil }
    public var reposURL: URL? { enabled ? Self.expand(reposFolder) : nil }
    public var ntfyRelayLogURL: URL? { enabled ? Self.expand(ntfyRelayLog) : nil }
    public var safariDriverURL: URL? { enabled ? Self.expand(safariDriver) : nil }
    public var claudeGateURL: URL? { enabled ? Self.expand(claudeGateApp) : nil }
    public var jobsDataURL: URL? { enabled ? Self.expand(jobsData) : nil }
    public var ascConfigURL: URL? {
        guard enabled, let a = ascConfig, !a.isEmpty else { return nil }
        if a.hasPrefix("/") || a.hasPrefix("~") { return Self.expand(a) }
        return hubURL?.appending(path: a)
    }
    /// The fixed time zone, else the Mac's.
    public var zone: TimeZone { (enabled ? timeZone.flatMap(TimeZone.init(identifier:)) : nil) ?? .current }
}
