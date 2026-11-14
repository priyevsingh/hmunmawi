import Foundation
import Security

/// What reading one saved key from an older storage place gave.
public enum LegacyRead: Equatable, Sendable {
    case missing
    case value(String)
    /// The item exists but this copy of the app may not read it without a Keychain password box (it was saved by a
    /// copy signed with a different certificate). Hmunmawi never shows that box on its own.
    case unreadable
}

/// An older place where Hmunmawi kept keys (for example the first Keychain service name, before `.keys.v2`).
public protocol LegacySecretSource: Sendable {
    /// Shown to people as "Keychain · <name>".
    var name: String { get }
    /// Every saved `"<add-on>/<field>"` name. Reading names never needs a password box.
    func accounts() -> [String]
    func read(account: String) -> LegacyRead
}

/// Where migrated keys go (the current Keychain store; an in-memory one in tests).
public protocol SecretMigrationTarget {
    /// True when anything is saved under that name, even an item this copy can't read: it is never overwritten.
    func hasItem(account: String) -> Bool
    func store(_ value: String, account: String) throws
}

extension KeychainSecretStore: SecretMigrationTarget {
    static func split(_ account: String) -> (String, String)? {
        guard let slash = account.firstIndex(of: "/") else { return nil }
        let plugin = String(account[..<slash]), name = String(account[account.index(after: slash)...])
        return plugin.isEmpty || name.isEmpty ? nil : (plugin, name)
    }
    public func hasItem(account: String) -> Bool {
        guard let (p, n) = Self.split(account) else { return true }
        return secretItemExists(plugin: p, name: n)
    }
    public func store(_ value: String, account: String) throws {
        guard let (p, n) = Self.split(account) else { return }
        try setSecret(value, plugin: p, name: n)
    }
}

/// A generic-password Keychain service from an older Hmunmawi. Reads never show a password box: an item saved by a
/// differently signed copy comes back `.unreadable` (the caller says so in plain words).
public struct KeychainLegacySource: LegacySecretSource {
    public let service: String
    public init(service: String) { self.service = service }
    public var name: String { service }

    public func accounts() -> [String] {
        if TestProfile.name != nil { return [] }   // a test profile never touches the real Keychain
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecMatchLimit as String: kSecMatchLimitAll, kSecReturnAttributes as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]] else { return [] }
        return Array(Set(items.compactMap { $0[kSecAttrAccount as String] as? String })).sorted()
    }

    public func read(account: String) -> LegacyRead {
        if TestProfile.name != nil { return .missing }
        Keychain.neverPrompt()
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return .missing }
        if status == errSecSuccess, let d = item as? Data {
            let s = String(decoding: d, as: UTF8.self)
            return s.isEmpty ? .missing : .value(s)
        }
        return .unreadable
    }
}

/// Copies keys saved by older versions of Hmunmawi into the current store, so nobody types a key twice after an
/// update, rebuild or reinstall. Runs at every launch and with `Hmunmawi --rebind-secrets`.
/// - never overwrites anything already in the current store (even an unreadable item);
/// - leaves the old items where they are (nothing is deleted);
/// - safe to run any number of times;
/// - the app's own trust state (`hmunmawi/…`) is never copied: it is made fresh by the current copy.
public enum LegacySecretMigrator {
    /// Older Keychain service names, oldest last. Add a name here whenever `KeychainSecretStore.service` changes.
    public static var legacyServices: [String] { ["io.github.priyevsingh.Hmunmawi" + TestProfile.suffix] }
    public static var keychainSources: [LegacySecretSource] { legacyServices.map { KeychainLegacySource(service: $0) } }
    static let skippedPrefixes = ["hmunmawi/", "agent-pending/", "keychain-probe/"]

    public struct Report: Sendable, Equatable {
        public var copied: [String] = []
        public var alreadyThere: [String] = []
        /// Saved in an old place but not readable without a Keychain password box (name → old place).
        public var needsOK: [String: String] = [:]
        public var failed: [String] = []
        public init() {}
    }

    nonisolated(unsafe) public private(set) static var lastReport = Report()

    public static func migrate(sources: [LegacySecretSource], into target: SecretMigrationTarget, also extra: [String] = []) -> Report {
        var report = Report()
        var names = Set(extra)
        let listed = sources.map { ($0, Set($0.accounts())) }
        for (_, accts) in listed { names.formUnion(accts) }
        for account in names.sorted() where !skippedPrefixes.contains(where: { account.hasPrefix($0) }) && account.contains("/") {
            if target.hasItem(account: account) { report.alreadyThere.append(account); continue }
            var done = false
            for (source, accts) in listed where accts.contains(account) {
                switch source.read(account: account) {
                case .missing: continue
                case .unreadable: if report.needsOK[account] == nil { report.needsOK[account] = source.name }
                case .value(let v):
                    let clean = v.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !clean.isEmpty else { continue }
                    do { try target.store(clean, account: account); report.copied.append(account); done = true }
                    catch { report.failed.append(account) }
                }
                if done { break }
            }
            if done { report.needsOK[account] = nil }
        }
        lastReport = report
        return report
    }

    /// The normal run: older Hmunmawi Keychain services into the current store.
    @discardableResult
    public static func migrateKeychain(into store: KeychainSecretStore) -> Report {
        migrate(sources: keychainSources, into: store, also: SecretRebinder.connectionSecretNames)
    }
}
