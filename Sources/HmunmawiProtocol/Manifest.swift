import Foundation

/// `manifest.json` inside a `<name>.hmplugin` folder. Everything an add-on may touch is declared here
/// and shown to the user once for approval.
public struct PluginManifest: Codable, Sendable, Equatable {
    public struct Poll: Codable, Sendable, Equatable {
        public var everySeconds: Int
    }

    public struct Permissions: Codable, Sendable, Equatable {
        /// Exact host names the app may call for this add-on (https only).
        public var hosts: [String]
        /// Secret names stored in the Keychain that may be filled into its requests.
        public var secrets: [String]
        /// Mac abilities run by the signed app, for example `messages.send`.
        public var mac: [String]
        /// Optional: which hosts each secret may go to (a secret not listed may go to any declared host).
        public var secretHosts: [String: [String]]

        public init(hosts: [String] = [], secrets: [String] = [], mac: [String] = [], secretHosts: [String: [String]] = [:]) {
            self.hosts = hosts
            self.secrets = secrets
            self.mac = mac
            self.secretHosts = secretHosts
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(hosts: try c.decodeIfPresent([String].self, forKey: .hosts) ?? [],
                      secrets: try c.decodeIfPresent([String].self, forKey: .secrets) ?? [],
                      mac: try c.decodeIfPresent([String].self, forKey: .mac) ?? [],
                      secretHosts: try c.decodeIfPresent([String: [String]].self, forKey: .secretHosts) ?? [:])
        }
    }

    public struct Setting: Codable, Sendable, Equatable {
        public var key: String
        public var label: String
        /// `text`, `number`, `toggle` or `secret`.
        public var type: String
        public var required: Bool?
    }

    public var id: String
    public var name: String
    public var version: String
    public var protocolVersion: Int
    public var executable: String
    public var summary: String?
    public var actions: [String]
    /// Event types this add-on may send, exact (`crash.daily`), or `*` for any (only for the feed of your own
    /// scripts). Anything else is dropped and noted in the activity log, so an add-on can't pose as another
    /// source's data (security audit, Nov 2026). Missing means it sends none.
    public var emits: [String]
    public var poll: Poll?
    public var permissions: Permissions
    public var settings: [Setting]

    enum CodingKeys: String, CodingKey {
        case id, name, version, executable, summary, actions, emits, poll, permissions, settings
        case protocolVersion = "protocol"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decode(String.self, forKey: .version)
        protocolVersion = try c.decode(Int.self, forKey: .protocolVersion)
        executable = try c.decode(String.self, forKey: .executable)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        actions = try c.decodeIfPresent([String].self, forKey: .actions) ?? []
        emits = try c.decodeIfPresent([String].self, forKey: .emits) ?? []
        poll = try c.decodeIfPresent(Poll.self, forKey: .poll)
        permissions = try c.decodeIfPresent(Permissions.self, forKey: .permissions) ?? Permissions()
        settings = try c.decodeIfPresent([Setting].self, forKey: .settings) ?? []
    }

    /// Whether this add-on may send an event of this type.
    public func mayEmit(_ kind: String) -> Bool { emits.contains("*") || emits.contains(kind) }

    /// Names of the app's own Keychain areas. Never usable as an add-on id.
    public static let reservedIDs = ["hmunmawi", "agent-pending", "agent", "live", "usage", "mail", "hook", "hooks", "trust", "keychain-probe"]

    public func validate() throws {
        func fail(_ message: String) -> WireError { WireError("invalid_manifest", "\(id): \(message)") }

        guard id.wholeMatch(of: /[a-z0-9][a-z0-9.-]{0,63}/) != nil else { throw fail("id must be lowercase letters, digits, dots or dashes") }
        // An add-on's secrets live in the Keychain under "<id>/<name>"; these ids belong to the app's own items (trust key,
        // live-sales and mail keys ...), so no add-on may take them, however its manifest is worded.
        if Self.reservedIDs.contains(where: { id == $0 || id.hasPrefix($0 + ".") || id.hasPrefix($0 + "-") }) {
            throw fail("this id is reserved for the app itself")
        }
        guard protocolVersion == hmunmawiProtocolVersion else { throw fail("needs protocol \(protocolVersion), this app speaks \(hmunmawiProtocolVersion)") }
        guard !executable.isEmpty, !executable.contains("/"), !executable.hasPrefix(".") else {
            throw fail("executable must be a file name inside the add-on folder")
        }
        for host in permissions.hosts {
            guard host.wholeMatch(of: /[a-z0-9-]+(\.[a-z0-9-]+)+/) != nil else { throw fail("“\(host)” is not a plain host name") }
        }
        for secret in permissions.secrets {
            guard secret.wholeMatch(of: /[A-Za-z0-9._-]{1,64}/) != nil else { throw fail("“\(secret)” is not a valid secret name") }
        }
        // "Any event type" is only for the bundled feed of your own scripts; a third-party add-on lists its types.
        if emits.contains("*"), id != "scriptfeed" { throw fail("only the script feed may send any event type (\"*\")") }
        for kind in emits where kind != "*" {
            guard kind.wholeMatch(of: /[a-z0-9_]+(\.[a-z0-9_]+)+/) != nil else { throw fail("“\(kind)” is not an event type") }
        }
        if let poll, poll.everySeconds < 60 { throw fail("poll interval must be at least 60 seconds") }
    }
}
