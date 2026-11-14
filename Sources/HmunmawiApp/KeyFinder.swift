import AppKit
import Foundation
import HmunmawiCore
import Security
import SwiftUI

/// "Find my key": looks for a connection's key where people usually keep them (nothing is read until you press it):
///   1. folders you added under "Also look in" (and, on an owner Mac, the owner's key folder and hub; see OwnerConfig)
///   2. .env and config.toml in standard places (~/.config, .env files in your home folder) and those folders
///   3. App Store Connect AuthKey_*.p8 files
///   4. keys an older Hmunmawi saved in the Keychain under an older name ("Keychain · <service>")
///   5. macOS Keychain passwords whose name mentions the service
/// You pick one; macOS may ask once to let Hmunmawi read a Keychain item. Values are never shown, only where they're from.
enum KeyFinder {
    struct Match: Identifiable, Hashable {
        let id = UUID()
        let label: String
        let source: String
        let sourceRef: SecretSourceRef?
        let fetch: @Sendable () -> String?
        let rank: Int

        static func == (a: Match, b: Match) -> Bool { a.id == b.id }
        func hash(into h: inout Hasher) { h.combine(id) }
    }

    static func find(addOn: String, field: String, wantsFile: Bool) async -> [Match] {
        await Task.detached(priority: .userInitiated) {
            Self.collect(addOn: addOn, field: field, wantsFile: wantsFile)
        }.value
    }

    // MARK: Sources

    nonisolated private static func collect(addOn: String, field: String, wantsFile: Bool) -> [Match] {
        var out: [Match] = []
        out += canonical(addOn: addOn, field: field, wantsFile: wantsFile)
        out += legacyKeychain(addOn: addOn, field: field, sources: LegacySecretMigrator.keychainSources)
        let hints = hints(addOn: addOn, field: field)
        let envKeys = preferredEnvKeys(addOn: addOn, field: field)
        if wantsFile || addOn == "appstoreconnect" && field.lowercased().contains("private") {
            out += p8Files(rank: 1)
        }
        out += envFiles(hints: hints, envKeys: envKeys)
        out += wholeFileCandidates(addOn: addOn, field: field, wantsFile: wantsFile)
        out += keychain(hints: hints, rank: 3)
        return deduped(out)
    }

    /// Folders you chose for Find my key to look in too (Settings → Connections → Also look in).
    static let foldersKey = "HMKeyFolders"
    nonisolated static var userFolders: [URL] {
        (UserDefaults.standard.stringArray(forKey: foldersKey) ?? []).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    }
    static func addFolder(_ url: URL) {
        var list = UserDefaults.standard.stringArray(forKey: foldersKey) ?? []
        let p = url.path.replacingOccurrences(of: URL.homeDirectory.path, with: "~")
        if !list.contains(p) { list.append(p); UserDefaults.standard.set(list, forKey: foldersKey) }
    }
    static func removeFolder(_ path: String) {
        UserDefaults.standard.set((UserDefaults.standard.stringArray(forKey: foldersKey) ?? []).filter { $0 != path }, forKey: foldersKey)
    }

    /// Where Find my key looks, in order: your chosen folders, the owner's folders (owner Macs only), then standard
    /// places. Never a hard-coded personal folder.
    nonisolated static func envRoots() -> [URL] {
        let home = URL.homeDirectory
        var roots: [URL] = userFolders
        if let k = SecretSourceDefaults.keyFolder() { roots.append(k) }
        if let h = SecretSourceDefaults.hub() { roots.append(h) }
        roots.append(home.appending(path: ".config"))
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []) where name == ".env" || name.hasSuffix(".env") {
            roots.append(home.appending(path: name))
        }
        if let repos = OwnerConfig.current.reposURL,
           let list = try? FileManager.default.contentsOfDirectory(at: repos, includingPropertiesForKeys: nil) {
            roots += list.prefix(40)
        }
        return roots
    }

    /// Folders that rank first (yours, and the owner's own).
    nonisolated static func preferredRoot(_ path: String) -> Bool {
        let firsts = userFolders + [SecretSourceDefaults.keyFolder(), SecretSourceDefaults.hub()].compactMap { $0 }
        return firsts.contains { path.hasPrefix($0.path) }
    }

    /// The owner's own key files (owner Macs only; see OwnerConfig).
    nonisolated private static func canonical(addOn: String, field: String, wantsFile: Bool) -> [Match] {
        guard let ref = SecretSourceDefaults.ref(plugin: addOn, name: field) else { return [] }
        guard let value = SecretFileReader.value(ref: ref), !value.isEmpty else { return [] }
        if wantsFile || ref.kind == .wholeFile || ref.kind == .tomlPathFile {
            guard value.count >= 8 else { return [] }
        }
        let home = URL.homeDirectory
        let short = ref.path.replacingOccurrences(of: home.path, with: "~")
        let label = ref.kind == .wholeFile ? short : "\(ref.field.isEmpty ? ref.path : ref.field) · \(short)"
        return [Match(label: label, source: "Your key folder", sourceRef: ref, fetch: { value }, rank: 0)]
    }

    nonisolated private static func wholeFileCandidates(addOn: String, field: String, wantsFile: Bool) -> [Match] {
        guard wantsFile, addOn == "searchconsole", field == "serviceAccount" else { return [] }
        let home = URL.homeDirectory
        guard let path = SecretSourceDefaults.keyFolder()?.appending(path: "gsc_service_account.json"),
              let text = try? String(contentsOf: path, encoding: .utf8), text.count >= 32 else { return [] }
        let ref = SecretSourceRef(path: path.path, kind: .wholeFile, field: "")
        let short = path.path.replacingOccurrences(of: home.path, with: "~")
        return [Match(label: short, source: "File", sourceRef: ref, fetch: { text }, rank: 0)]
    }

    /// Words to look for when scanning generic env files and the Keychain.
    static func hints(addOn: String, field: String) -> [String] {
        let base: [String: [String]] = [
            "appstoreconnect": ["APPSTORE", "ASC", "APP_STORE", "ISSUER", "KEY_ID"],
            "posthog": ["POSTHOG"],
            "sentry": ["SENTRY"],
            "revenuecat": ["REVENUECAT", "RC_"],
            "youtube": ["YOUTUBE", "GOOGLE_API", "GCP"],
            "bing": ["BING"],
            "searchconsole": ["GSC", "SEARCH_CONSOLE", "SERVICE_ACCOUNT"],
            "cloudflare": ["CLOUDFLARE", "CF_"],
            "ntfy": ["NTFY"],
            "ai": ["ANTHROPIC", "OPENAI", "GEMINI", "OPENROUTER", "GROQ", "MISTRAL"],
            "usage": ["ANTHROPIC_ADMIN"],
        ]
        var words = base[addOn] ?? [addOn.uppercased()]
        let f = field.uppercased()
        if f.contains("ISSUER") { words += ["ISSUER", "ISSUER_ID"] }
        if f.contains("KEYID") || f == "KEY_ID" { words += ["KEY_ID", "KEYID"] }
        if f.contains("TOKEN") { words += ["TOKEN", "BEARER"] }
        if f.contains("API") { words += ["API_KEY", "APIKEY"] }
        return words
    }

    /// Exact env var names to prefer (tried first in owner key folders).
    nonisolated private static func preferredEnvKeys(addOn: String, field: String) -> [String] {
        switch (addOn, field) {
        case ("posthog", "apiKey"): return ["POSTHOG_API_KEY"]
        case ("sentry", "authToken"): return ["SENTRY_AUTH_TOKEN"]
        case ("bing", "apiKey"): return ["BING_WEBMASTER_API_KEY"]
        case ("cloudflare", "apiToken"): return ["CF_ANALYTICS_TOKEN", "CLOUDFLARE_API_TOKEN", "CF_API_TOKEN"]
        case ("youtube", "apiKey"): return ["YOUTUBE_API_KEY", "GOOGLE_API_KEY", "GCP_API_KEY"]
        case ("appstoreconnect", "issuerID"): return ["ASC_ISSUER_ID", "ISSUER_ID"]
        case ("appstoreconnect", "keyID"): return ["ASC_KEY_ID", "KEY_ID"]
        default: return []
        }
    }

    nonisolated private static func envFiles(hints: [String], envKeys: [String]) -> [Match] {
        let home = URL.homeDirectory
        let roots = envRoots()
        let keyFolder = SecretSourceDefaults.keyFolder()?.path
        var out: [Match] = []
        var seen = Set<String>()
        for root in roots {
            if !((try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) {
                out += parseEnv(root, hints: hints, envKeys: envKeys, home: home, rank: preferredRoot(root.path) ? 0 : 1, seen: &seen)
                continue
            }
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsPackageDescendants]) else { continue }
            let shallow = root.path == keyFolder || root.path == home.appending(path: ".config").path
            let maxDepth = shallow ? 2 : 5
            var n = 0
            while let f = e.nextObject() as? URL {
                n += 1
                if n > 5000 { break }
                let name = f.lastPathComponent
                if ["node_modules", ".git", "build", "DerivedData", ".build", "Library", "out", "data"].contains(name) { e.skipDescendants(); continue }
                if e.level > maxDepth { e.skipDescendants(); continue }
                let isEnv = name == ".env" || name.hasSuffix(".env") || name.hasPrefix(".env.")
                let isToml = name == "config.toml"
                guard isEnv || isToml, !seen.contains(f.path) else { continue }
                seen.insert(f.path)
                let rank = preferredRoot(root.path) ? 0 : 1
                if isToml {
                    out += parseToml(f, hints: hints, home: home, rank: rank)
                } else {
                    out += parseEnv(f, hints: hints, envKeys: envKeys, home: home, rank: rank, seen: &seen)
                }
            }
        }
        return out
    }

    nonisolated private static func parseEnv(_ f: URL, hints: [String], envKeys: [String], home: URL, rank: Int, seen: inout Set<String>) -> [Match] {
        guard ((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) < 128_000,
              let text = try? String(contentsOf: f, encoding: .utf8) else { return [] }
        var out: [Match] = []
        let short = f.path.replacingOccurrences(of: home.path, with: "~")
        for line in text.split(whereSeparator: \.isNewline) {
            let l = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "export ", with: "")
            guard !l.hasPrefix("#"), let eq = l.firstIndex(of: "=") else { continue }
            let key = String(l[..<eq])
            let preferred = envKeys.contains(where: { $0.caseInsensitiveCompare(key) == .orderedSame })
            let hinted = hints.contains(where: { h in
                let ku = key.uppercased()
                return h.count <= 3 ? ku.hasPrefix(h) : ku.contains(h)
            })
            guard preferred || hinted else { continue }
            var raw = String(l[l.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if !raw.hasPrefix("\""), !raw.hasPrefix("'"), let hash = raw.range(of: " #") { raw = String(raw[..<hash.lowerBound]) }
            let value = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            guard value.count >= 8 else { continue }
            let dedupe = "\(f.path)|\(key)"
            guard seen.insert(dedupe).inserted else { continue }
            let ref = SecretSourceRef(path: f.path, kind: .envLine, field: key)
            let lineRank = preferred ? min(rank, 0) : rank
            let path = f.path
            out.append(Match(label: "\(key) · \(short)", source: "File", sourceRef: ref, fetch: { SecretFileReader.envValue(path: path, key: key) }, rank: lineRank))
        }
        return out
    }

    nonisolated private static func parseToml(_ f: URL, hints: [String], home: URL, rank: Int) -> [Match] {
        guard ((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) < 64_000,
              let text = try? String(contentsOf: f, encoding: .utf8) else { return [] }
        var out: [Match] = []
        let short = f.path.replacingOccurrences(of: home.path, with: "~")
        let path = f.path
        for line in text.split(whereSeparator: \.isNewline) {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard !l.hasPrefix("#"), let eq = l.firstIndex(of: "=") else { continue }
            let key = String(l[..<eq]).trimmingCharacters(in: .whitespaces)
            let ku = key.uppercased()
            guard hints.contains(where: { h in h.count <= 3 ? ku.hasPrefix(h) : ku.contains(h) }) else { continue }
            guard let value = SecretFileReader.tomlValue(path: path, key: key), value.count >= (key.contains("issuer") ? 8 : 4) else { continue }
            let ref = SecretSourceRef(path: path, kind: .tomlKey, field: key)
            out.append(Match(label: "\(key) · \(short)", source: "config.toml", sourceRef: ref, fetch: { value }, rank: rank))
        }
        return out
    }

    nonisolated private static func p8Files(rank: Int) -> [Match] {
        let home = URL.homeDirectory
        var dirs = userFolders.map(\.path) + [SecretSourceDefaults.hub()?.path].compactMap { $0 } + [
            home.appending(path: "Documents").path,
            home.appending(path: "Downloads").path,
            home.appending(path: "Desktop").path,
            home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs").path,
            home.appending(path: ".appstoreconnect/private_keys").path,
            home.appending(path: "private_keys").path,
        ]
        if let asc = SecretSourceDefaults.ascConfig()?.path,
           let path = SecretFileReader.tomlValue(path: asc, key: "private_key_path"), FileManager.default.fileExists(atPath: path) {
            dirs.insert((path as NSString).deletingLastPathComponent, at: 0)
        }
        var out: [Match] = []
        var seen = Set<String>()
        for d in dirs {
            guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: d), includingPropertiesForKeys: nil, options: [.skipsPackageDescendants]) else { continue }
            var n = 0
            while let f = e.nextObject() as? URL {
                n += 1; if n > 15_000 { break }
                if e.level > 6 { e.skipDescendants(); continue }
                guard f.pathExtension == "p8", f.lastPathComponent.hasPrefix("AuthKey_") else { continue }
                guard seen.insert(f.path).inserted else { continue }
                let path = f.path
                let ref = SecretSourceRef(path: path, kind: .wholeFile, field: "")
                let label = "\(f.lastPathComponent) · \(f.deletingLastPathComponent().path.replacingOccurrences(of: home.path, with: "~"))"
                out.append(Match(label: label, source: "File", sourceRef: ref, fetch: { try? String(contentsOfFile: path, encoding: .utf8) }, rank: rank))
            }
        }
        return out
    }

    /// How a key kept by an older Hmunmawi is listed (the value is never shown).
    nonisolated static func legacyLabel(service: String) -> String { "Keychain · \(service)" }

    /// The same add-on and field saved by an older Hmunmawi (older Keychain service name). Read without a password box
    /// when this copy is allowed to; otherwise picking it asks macOS once, because you chose it.
    nonisolated static func legacyKeychain(addOn: String, field: String, sources: [LegacySecretSource]) -> [Match] {
        let account = "\(addOn)/\(field)"
        return sources.filter { $0.accounts().contains(account) }.map { source in
            Match(label: legacyLabel(service: source.name), source: "Keychain", sourceRef: nil, fetch: {
                switch source.read(account: account) {
                case .value(let v): return v
                case .missing: return nil
                case .unreadable:
                    guard let k = source as? KeychainLegacySource else { return nil }
                    SecKeychainSetUserInteractionAllowed(true)
                    defer { Keychain.neverPrompt() }
                    let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: k.service,
                                            kSecAttrAccount as String: account, kSecReturnData as String: true,
                                            kSecMatchLimit as String: kSecMatchLimitOne]
                    var data: CFTypeRef?
                    guard SecItemCopyMatching(q as CFDictionary, &data) == errSecSuccess, let d = data as? Data else { return nil }
                    return String(data: d, encoding: .utf8)
                }
            }, rank: 0)
        }
    }

    nonisolated private static func keychain(hints: [String], rank: Int) -> [Match] {
        if TestProfile.name != nil { return [] }   // a test profile (and `swift test`) never looks in the real Keychain
        var out: [Match] = []
        for cls in [kSecClassGenericPassword, kSecClassInternetPassword] {
            let q: [String: Any] = [kSecClass as String: cls, kSecMatchLimit as String: kSecMatchLimitAll, kSecReturnAttributes as String: true]
            var result: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]] else { continue }
            for a in items {
                let service = (a[kSecAttrService as String] as? String) ?? (a[kSecAttrServer as String] as? String) ?? ""
                let account = (a[kSecAttrAccount as String] as? String) ?? ""
                let label = (a[kSecAttrLabel as String] as? String) ?? ""
                let text = (service + " " + account + " " + label).uppercased().replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
                let words = "_" + text + "_"
                guard hints.contains(where: { h in
                    let core = h.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
                    return core.count <= 3 ? words.contains("_\(core)_") : text.contains(core)
                }),
                !service.hasPrefix("io.github.priyevsingh.Hmunmawi") else { continue }
                let svc = service, acct = account, internet = (cls == kSecClassInternetPassword)
                out.append(Match(label: [label.isEmpty ? svc : label, acct].filter { !$0.isEmpty }.joined(separator: " · "), source: "Keychain", sourceRef: nil,
                                 fetch: {
                    var q: [String: Any] = [kSecClass as String: internet ? kSecClassInternetPassword : kSecClassGenericPassword, kSecAttrAccount as String: acct, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
                    q[(internet ? kSecAttrServer : kSecAttrService) as String] = svc
                    var data: CFTypeRef?
                    guard SecItemCopyMatching(q as CFDictionary, &data) == errSecSuccess, let d = data as? Data else { return nil }
                    return String(data: d, encoding: .utf8)
                }, rank: rank))
            }
        }
        return out
    }

    nonisolated private static func deduped(_ matches: [Match]) -> [Match] {
        var byLabel: [String: Match] = [:]
        for m in matches {
            if let old = byLabel[m.label], old.rank <= m.rank { continue }
            byLabel[m.label] = m
        }
        return byLabel.values.sorted { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            return a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
        }.prefix(40).map { $0 }
    }
}

extension KeyFinder {
    /// "Issuer ID" from "Issuer ID (from Users and Access)": what VoiceOver and the tooltip say.
    static func shortLabel(_ label: String) -> String {
        let cut = label.split(separator: "(").first.map(String.init) ?? label
        let t = cut.trimmingCharacters(in: .whitespaces)
        return t.count > 40 ? String(t.prefix(40)).trimmingCharacters(in: .whitespaces) + "…" : t
    }
    /// "Keychain, YOUTUBE_API_KEY" or "File, POSTHOG_API_KEY in posthog.env": short, no folder paths read aloud.
    static func spokenLabel(_ m: Match) -> String {
        let parts = m.label.components(separatedBy: " · ")
        let name = parts.first ?? m.label
        let file = parts.count > 1 ? (parts.last.map { ($0 as NSString).lastPathComponent } ?? "") : ""
        return file.isEmpty || file == name ? "\(m.source), \(name)" : "\(m.source), \(name) in \(file)"
    }
}

/// The small "Find my key" button next to a key field, with a picker of what it found.
struct FindKeyButton: View {
    let addOn: String
    let field: String
    let label: String
    var wantsFile = false
    var onSource: ((SecretSourceRef) -> Void)?
    let fill: (String) -> Void
    @State private var matches: [KeyFinder.Match]?
    @State private var busy = false

    var body: some View {
        Button { Task { busy = true; matches = await KeyFinder.find(addOn: addOn, field: field, wantsFile: wantsFile); busy = false } } label: {
            Label(busy ? "Looking" : "Find my key", systemImage: "key.viewfinder")
        }
        .buttonStyle(.pill).disabled(busy)
        .help("Look in your Keychain and key files for \(KeyFinder.shortLabel(label))")
        .accessibilityLabel("Find my key for \(KeyFinder.shortLabel(label))")
        .popover(isPresented: Binding(get: { matches != nil }, set: { if !$0 { matches = nil } })) {
            VStack(alignment: .leading, spacing: 8) {
                Text(matches?.isEmpty == true ? Quips.pick(["No key hiding anywhere obvious. Paste it in and we're friends.",
                                                             "Searched the usual spots: nothing. It's playing hide and seek."])
                     : "Pick the one for \(label)").font(.headline).fixedSize(horizontal: false, vertical: true)
                ForEach(matches ?? []) { m in
                    Button {
                        if let v = m.fetch()?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                            if let ref = m.sourceRef { onSource?(ref) }
                            fill(v)
                        }
                        matches = nil
                    } label: {
                        HStack {
                            Image(systemName: m.source == "Keychain" ? "key.fill" : "doc.text").foregroundStyle(.secondary)
                            Text(m.label).font(.callout).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(KeyFinder.spokenLabel(m))
                }
                Button("Also look in a folder…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
                    panel.message = "Find my key will also look in this folder from now on (Settings keeps the list)."
                    if panel.runModal() == .OK, let url = panel.url {
                        KeyFinder.addFolder(url)
                        Task { busy = true; matches = await KeyFinder.find(addOn: addOn, field: field, wantsFile: wantsFile); busy = false }
                    }
                }
                .buttonStyle(.borderless).font(.callout)
                Text("Values aren't shown. Only the one you pick goes into this field, and it stays in your Keychain.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14).frame(width: 440)
        }
    }
}
