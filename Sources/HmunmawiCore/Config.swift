import Foundation

/// `config.json`: plain settings per add-on and the rules. Secrets never go here; they live in the Keychain.
/// Hours when alerts wait until morning (urgent rules, priority 1, still go out). Local time; may cross midnight.
public struct QuietHours: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var startHour: Int   // 0-23, e.g. 22
    public var endHour: Int     // 0-23, e.g. 7
    public init(enabled: Bool = true, startHour: Int = 22, endHour: Int = 7) {
        self.enabled = enabled; self.startHour = startHour; self.endHour = endHour
    }
    public static let standard = QuietHours()

    /// When the quiet stretch around `t` ends, or nil when `t` isn't inside one.
    public func end(after t: Date, calendar: Calendar = .current) -> Date? {
        guard enabled, startHour != endHour, (0...23).contains(startHour), (0...23).contains(endHour) else { return nil }
        let h = calendar.component(.hour, from: t)
        let inside = startHour < endHour ? (h >= startHour && h < endHour) : (h >= startHour || h < endHour)
        guard inside else { return nil }
        var end = calendar.date(bySettingHour: endHour, minute: 0, second: 0, of: t)!
        if end <= t { end = calendar.date(byAdding: .day, value: 1, to: end)! }
        return end
    }
}

public struct AppConfig: Codable, Sendable, Equatable {
    public var plugins: [String: [String: String]]
    public var rules: [Rule]
    /// The currency every amount is shown in (ISO code); nil means the Mac's own currency.
    public var displayCurrency: String? = nil
    /// Self-healing: an event kind and the script that fixes it, e.g. "disk.low" -> a disk clean-up script.
    public var healScripts: [String: String]? = nil
    /// Alerts wait during these hours (nil = the standard 22:00-07:00).
    public var quietHours: QuietHours? = nil
    /// Add-ons run in a macOS sandbox (no network, no reading your files; nil = on).
    public var sandboxAddOns: Bool? = nil

    public static let defaultRules: [Rule] = [
        // Off until iMessage is set up (the app switches it on once when iMessage is connected); refunds still show
        // as Mac notifications and on Today.
        Rule(id: "refund-alert", name: "Tell me about refunds", when: "revenue.refund",
             actions: [RuleAction(action: "notify", resource: "imessage")],
             priority: 2, cooldownSeconds: 6 * 3600, approval: .ask, dryRun: true, enabled: false),
        Rule(id: "low-review-alert", name: "Alert on 1 and 2 star reviews", when: "review.new",
             conditions: [Condition(field: "rating", op: .lte, value: .number(2))],
             actions: [RuleAction(action: "notify", resource: "ntfy")],
             priority: 3, cooldownSeconds: 3600, approval: .auto, dryRun: true),
    ]

    public init(plugins: [String: [String: String]] = [:], rules: [Rule] = AppConfig.defaultRules) {
        self.plugins = plugins
        self.rules = rules
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        plugins = try c.decodeIfPresent([String: [String: String]].self, forKey: .plugins) ?? [:]
        rules = try c.decodeIfPresent([Rule].self, forKey: .rules) ?? Self.defaultRules
        displayCurrency = try c.decodeIfPresent(String.self, forKey: .displayCurrency)
        healScripts = try c.decodeIfPresent([String: String].self, forKey: .healScripts)
        quietHours = try c.decodeIfPresent(QuietHours.self, forKey: .quietHours)
        sandboxAddOns = try c.decodeIfPresent(Bool.self, forKey: .sandboxAddOns)
    }

    public static func load(from url: URL) throws -> AppConfig {
        guard FileManager.default.fileExists(atPath: url.path) else { return AppConfig() }
        return try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public func settingsJSON(for plugin: String) -> JSONValue {
        .object((plugins[plugin] ?? [:]).mapValues(JSONValue.string))
    }
}
