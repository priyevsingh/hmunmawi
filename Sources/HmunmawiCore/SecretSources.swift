import Foundation

/// Where a connection secret was picked from. Only paths and field names are stored, never the secret value.
public struct SecretSourceRef: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case envLine
        case tomlKey
        case wholeFile
        case tomlPathFile
    }

    public var path: String
    public var kind: Kind
    /// Env var name, TOML key, or (for `tomlPathFile`) the TOML key whose value is a path to the secret file.
    public var field: String

    public init(path: String, kind: Kind, field: String) {
        self.path = path
        self.kind = kind
        self.field = field
    }
}

public struct SecretSourceCatalog: Sendable {
    public static let fileName = "secret-sources.json"
    private let url: URL
    private let lock = NSLock()

    public let fileURL: URL
    public init(url: URL) { self.url = url; self.fileURL = url }

    private struct Entry: Codable {
        var sources: [String: SecretSourceRef] = [:]
    }

    private func load() -> Entry {
        guard let data = try? Data(contentsOf: url),
              let e = try? JSONDecoder().decode(Entry.self, from: data) else { return Entry() }
        return e
    }

    private func save(_ entry: Entry) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func key(plugin: String, name: String) -> String { "\(plugin)/\(name)" }

    public func record(plugin: String, name: String, ref: SecretSourceRef) {
        lock.lock()
        defer { lock.unlock() }
        var entry = load()
        entry.sources[Self.key(plugin: plugin, name: name)] = ref
        save(entry)
    }

    public func ref(plugin: String, name: String) -> SecretSourceRef? {
        lock.lock()
        defer { lock.unlock() }
        return load().sources[Self.key(plugin: plugin, name: name)]
    }

    public func allPluginNames() -> [(String, String)] {
        lock.lock()
        defer { lock.unlock() }
        return load().sources.keys.compactMap { k in
            let parts = k.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return (parts[0], parts[1])
        }
    }
}

/// Reads secrets from local files the app is already allowed to read (no network).
public enum SecretFileReader {
    public static func value(ref: SecretSourceRef) -> String? {
        let path = NSString(string: ref.path).expandingTildeInPath
        switch ref.kind {
        case .envLine:
            return envValue(path: path, key: ref.field)
        case .tomlKey:
            return tomlValue(path: path, key: ref.field)
        case .wholeFile:
            return wholeFile(path: path)
        case .tomlPathFile:
            guard let inner = tomlValue(path: path, key: ref.field) else { return nil }
            return wholeFile(path: inner)
        }
    }

    public static func envValue(path: String, key: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let want = key.uppercased()
        for line in text.split(whereSeparator: \.isNewline) {
            let l = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "export ", with: "")
            guard !l.hasPrefix("#"), let eq = l.firstIndex(of: "=") else { continue }
            let name = String(l[..<eq])
            guard name.uppercased() == want else { continue }
            return envRHS(String(l[l.index(after: eq)...]))
        }
        return nil
    }

    public static func tomlValue(path: String, key: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let pattern = try? NSRegularExpression(pattern: "^\(NSRegularExpression.escapedPattern(for: key))\\s*=\\s*\"([^\"]+)\"", options: [.anchorsMatchLines])
        guard let pattern, let m = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    public static func wholeFile(path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    private static func envRHS(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if !s.hasPrefix("\""), !s.hasPrefix("'"), let hash = s.range(of: " #") { s = String(s[..<hash.lowerBound]) }
        let value = s.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        return value.isEmpty ? nil : value
    }
}

/// Where the owner's own key files live (see `OwnerConfig`): nothing on a normal install, so a new user's keys are
/// only ever read from places they chose. No secret values here.
public enum SecretSourceDefaults {
    public static func home() -> URL { .homeDirectory }

    /// The owner's script hub (nil unless owner extras are on).
    public static func hub() -> URL? { OwnerConfig.current.hubURL }

    /// The owner's key folder of `.env` files (nil unless owner extras are on).
    public static func keyFolder() -> URL? { OwnerConfig.current.keyFolderURL }

    /// The owner's App Store Connect config.toml (nil unless owner extras are on).
    public static func ascConfig() -> URL? { OwnerConfig.current.ascConfigURL }

    /// Which file and field holds each connection key in the owner's key folder (names only, no values).
    static let keyFolderFields: [String: (file: String, kind: SecretSourceRef.Kind, field: String)] = [
        "posthog/apiKey": ("posthog.env", .envLine, "POSTHOG_API_KEY"),
        "sentry/authToken": ("sentry.env", .envLine, "SENTRY_AUTH_TOKEN"),
        "bing/apiKey": ("bing.env", .envLine, "BING_WEBMASTER_API_KEY"),
        "cloudflare/apiToken": ("cloudflare_analytics.env", .envLine, "CF_ANALYTICS_TOKEN"),
        "searchconsole/serviceAccount": ("gsc_service_account.json", .wholeFile, ""),
        "live/hookRelayKey": ("asn_relay.env", .envLine, "RELAY_KEY"),
        // Same file as the hooks key: the Pages purchase outbox uses this name.
        "live/relayKey": ("asn_relay.env", .envLine, "RELAY_KEY"),
        "live/hookCloudflareToken": ("cloudflare_analytics.env", .envLine, "CF_ANALYTICS_TOKEN"),
    ]

    public static func ref(plugin: String, name: String) -> SecretSourceRef? {
        func existing(_ url: URL?, _ kind: SecretSourceRef.Kind, _ field: String) -> SecretSourceRef? {
            guard let p = url?.path, FileManager.default.fileExists(atPath: p) else { return nil }
            return SecretSourceRef(path: p, kind: kind, field: field)
        }
        switch (plugin, name) {
        case ("appstoreconnect", "issuerID"): return existing(ascConfig(), .tomlKey, "issuer_id")
        case ("appstoreconnect", "keyID"): return existing(ascConfig(), .tomlKey, "key_id")
        case ("appstoreconnect", "privateKey"): return existing(ascConfig(), .tomlPathFile, "private_key_path")
        case ("sentry", "authToken"):
            return existing(keyFolder()?.appending(path: "sentry.env"), .envLine, "SENTRY_AUTH_TOKEN")
                ?? existing(ascConfig(), .tomlKey, "auth_token")
        default:
            guard let f = keyFolderFields["\(plugin)/\(name)"] else { return nil }
            return existing(keyFolder()?.appending(path: f.file), f.kind, f.field)
        }
    }
}

public enum SecretRebinder {
  /// Tries to read from the catalog or defaults and write into the Keychain with the current app signature.
    public static func rebind(store: KeychainSecretStore, catalog: SecretSourceCatalog, plugin: String, name: String) -> Bool {
        if (try? store.peekSecret(plugin: plugin, name: name))?.isEmpty == false { return true }
        guard let value = readValue(catalog: catalog, plugin: plugin, name: name), !value.isEmpty else { return false }
        do {
            try store.replaceSecret(value, plugin: plugin, name: name)
            if let ref = catalog.ref(plugin: plugin, name: name) ?? SecretSourceDefaults.ref(plugin: plugin, name: name) {
                catalog.record(plugin: plugin, name: name, ref: ref)
            }
        } catch {
            return false
        }
        return (try? store.peekSecret(plugin: plugin, name: name))?.isEmpty == false
    }

    public static func rebindAll(store: KeychainSecretStore, catalog: SecretSourceCatalog) -> Int {
        var ok = 0
        var seen = Set<String>()
        for (plugin, name) in catalog.allPluginNames() {
            let k = "\(plugin)/\(name)"
            guard seen.insert(k).inserted, rebind(store: store, catalog: catalog, plugin: plugin, name: name) else { continue }
            ok += 1
        }
        for pair in Self.builtInConnectionSecrets() {
            let k = "\(pair.0)/\(pair.1)"
            guard seen.insert(k).inserted, rebind(store: store, catalog: catalog, plugin: pair.0, name: pair.1) else { continue }
            ok += 1
        }
        return ok
    }

    /// Every built-in connection key as `"<add-on>/<field>"` (used by the legacy migration too).
    public static var connectionSecretNames: [String] { builtInConnectionSecrets().map { "\($0.0)/\($0.1)" } + ["youtube/apiKey"] }

    private static func builtInConnectionSecrets() -> [(String, String)] {
        [
            ("appstoreconnect", "issuerID"), ("appstoreconnect", "keyID"), ("appstoreconnect", "privateKey"),
            ("posthog", "apiKey"), ("sentry", "authToken"), ("bing", "apiKey"),
            ("cloudflare", "apiToken"), ("searchconsole", "serviceAccount"),
            ("live", "hookRelayKey"), ("live", "hookCloudflareToken"),
        ]
    }

    private static func readValue(catalog: SecretSourceCatalog, plugin: String, name: String) -> String? {
        if let r = catalog.ref(plugin: plugin, name: name), let v = SecretFileReader.value(ref: r), !v.isEmpty { return v }
        if let r = SecretSourceDefaults.ref(plugin: plugin, name: name), let v = SecretFileReader.value(ref: r), !v.isEmpty { return v }
        return nil
    }
}
