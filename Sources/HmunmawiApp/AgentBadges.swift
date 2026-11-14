import CryptoKit
import Foundation
import HmunmawiCore

/// A name badge for one agent: a secret code the owner makes in Settings → Rules → Agents and pastes into that
/// agent's setup (`HM_AGENT_TOKEN`). A request that carries it is shown in the activity log under the badge's own
/// name; a request without one is shown as "(unverified)" once any badge exists. Only a fingerprint (SHA-256) of each
/// code is kept, in the Keychain, so the code itself can't be read back from the Mac. Removing a badge switches that
/// agent's identity off at once.
///
/// This tells agents apart and lets the owner cut one off. It does not stop other programs running as the same Mac
/// user from reading an agent's setup; the approval rules remain the real gate for risky actions.
struct AgentBadges: Sendable {
    /// Where the {name: fingerprint} list lives. Defaults to the Keychain; tests pass memory.
    var read: @Sendable () -> String?
    var write: @Sendable (String) throws -> Void

    static let keychain: AgentBadges = {
        let store = KeychainSecretStore()
        return AgentBadges(read: { (try? store.secret(plugin: "hmunmawi", name: "agent-badges")) ?? nil },
                           write: { try store.setSecret($0, plugin: "hmunmawi", name: "agent-badges") })
    }()

    private func all() -> [String: String] {
        guard let text = read(), let d = text.data(using: .utf8),
              let m = try? JSONDecoder().decode([String: String].self, from: d) else { return [:] }
        return m
    }
    private func save(_ m: [String: String]) throws {
        try write(String(decoding: try JSONEncoder().encode(m), as: UTF8.self))
    }
    private static func fingerprint(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var names: [String] { all().keys.sorted() }
    var isEmpty: Bool { all().isEmpty }

    /// Makes a badge and returns its code (shown once; only its fingerprint is kept). Nil for a bad or taken name.
    func create(name raw: String) throws -> String? {
        let name = InputRule.name.clean(raw).trimmingCharacters(in: .whitespaces)
        var m = all()
        guard !name.isEmpty, name.count <= 40, m[name] == nil, m.count < 20 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let token = "hmb_" + Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        m[name] = Self.fingerprint(token)
        try save(m)
        return token
    }

    func remove(name: String) throws {
        var m = all(); m[name] = nil; try save(m)
    }

    /// The badge's name when the code is genuine, else nil.
    func verify(_ token: String) -> String? {
        let f = Self.fingerprint(token)
        return all().first { $0.value == f }?.key
    }
}
