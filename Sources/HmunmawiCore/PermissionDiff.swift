import CryptoKit
import Foundation

/// What a connection was allowed to do when you last said Allow, kept so that when it changes the screen can say what
/// is different instead of a bare "Allow".
public struct ApprovedPermissions: Codable, Equatable, Sendable {
    public var emits: [String], hosts: [String], secrets: [String], mac: [String]
    public init(emits: [String], hosts: [String], secrets: [String], mac: [String]) {
        self.emits = emits.sorted(); self.hosts = hosts.sorted(); self.secrets = secrets.sorted(); self.mac = mac.sorted()
    }
    public init(_ m: PluginManifest) { self.init(emits: m.emits, hosts: m.permissions.hosts, secrets: m.permissions.secrets, mac: m.permissions.mac) }

    /// Stable across re-signing the same add-on binary; approvals are signed with this, not the code hash.
    public func stableHash() -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = (try? enc.encode(self)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum PermissionDiff {
    /// Plain-words lines for what the connection may do now that it wasn't allowed to do before (and what it dropped).
    /// `old` nil = no record of the earlier allowance. When nothing about the permissions changed, only its program did.
    public static func lines(old: ApprovedPermissions?, new: ApprovedPermissions) -> [String] {
        guard let old else { return ["Its program changed since you last allowed it, so Hmunmawi asks again."] }
        var out: [String] = []
        func added(_ a: [String], _ b: [String]) -> [String] { b.filter { !a.contains($0) } }
        let emits = added(old.emits, new.emits), hosts = added(old.hosts, new.hosts), secrets = added(old.secrets, new.secrets), mac = added(old.mac, new.mac)
        if !emits.isEmpty { out.append("Now also reports: " + emits.joined(separator: ", ")) }
        if !hosts.isEmpty { out.append("Now also contacts: " + hosts.joined(separator: ", ")) }
        if !secrets.isEmpty { out.append("Now also uses the key: " + secrets.joined(separator: ", ")) }
        if !mac.isEmpty { out.append("Now also may use on this Mac: " + mac.joined(separator: ", ")) }
        let dropped = added(new.emits, old.emits) + added(new.hosts, old.hosts)
        if !dropped.isEmpty { out.append("No longer: " + dropped.joined(separator: ", ")) }
        return out.isEmpty ? ["Its program was updated. What it may do is the same as before."] : out
    }
}
