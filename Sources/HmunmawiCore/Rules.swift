import Foundation

public enum Approval: String, Codable, Sendable {
    case auto
    case ask
    case never
}

public struct Condition: Codable, Sendable, Equatable {
    public enum Op: String, Codable, Sendable {
        case eq = "==", ne = "!=", gt = ">", gte = ">=", lt = "<", lte = "<=", contains, oneOf = "in"
    }

    /// `app` means the event's app; anything else is a dot path into the event payload.
    public var field: String
    public var op: Op
    public var value: JSONValue

    public init(field: String, op: Op, value: JSONValue) {
        self.field = field
        self.op = op
        self.value = value
    }

    func holds(for event: Event) -> Bool {
        let actual: JSONValue? = field == "app" ? event.app.map(JSONValue.string) : event.payload[path: field]
        guard let actual else { return op == .ne }

        switch op {
        case .eq: return actual == value
        case .ne: return actual != value
        case .gt, .gte, .lt, .lte:
            guard let a = actual.number, let b = value.number else { return false }
            switch op {
            case .gt: return a > b
            case .gte: return a >= b
            case .lt: return a < b
            default: return a <= b
            }
        case .oneOf:
            // Matches when the value is one of a list (numbers compare by value; text ignores case).
            guard case .array(let items) = value else { return false }
            if let a = actual.number { return items.contains { $0.number == a } }
            if let a = actual.string { return items.contains { $0.string?.caseInsensitiveCompare(a) == .orderedSame } }
            return false
        case .contains:
            switch actual {
            case .string(let s): return value.string.map { s.localizedCaseInsensitiveContains($0) } ?? false
            case .array(let items): return items.contains(value)
            default: return false
            }
        }
    }
}

public struct RuleAction: Codable, Sendable, Equatable {
    public var action: String
    /// Lock key for the queue; defaults to the action name.
    public var resource: String?
    public var params: JSONValue?

    public init(action: String, resource: String? = nil, params: JSONValue? = nil) {
        self.action = action
        self.resource = resource
        self.params = params
    }
}

public struct Rule: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String?
    /// Event kind to match; a trailing `*` matches a prefix, e.g. `revenue.*`.
    public var when: String
    public var conditions: [Condition]
    public var actions: [RuleAction]
    public var priority: Int
    public var cooldownSeconds: Int
    public var approval: Approval
    public var dryRun: Bool
    public var enabled: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, when, priority, cooldownSeconds, approval, dryRun, enabled
        case conditions = "if"
        case actions = "do"
    }

    public init(id: String, name: String? = nil, when: String, conditions: [Condition] = [],
                actions: [RuleAction], priority: Int = 5, cooldownSeconds: Int = 0,
                approval: Approval = .ask, dryRun: Bool = true, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.when = when
        self.conditions = conditions
        self.actions = actions
        self.priority = priority
        self.cooldownSeconds = cooldownSeconds
        self.approval = approval
        self.dryRun = dryRun
        self.enabled = enabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            name: try c.decodeIfPresent(String.self, forKey: .name),
            when: try c.decode(String.self, forKey: .when),
            conditions: try c.decodeIfPresent([Condition].self, forKey: .conditions) ?? [],
            actions: try c.decode([RuleAction].self, forKey: .actions),
            priority: try c.decodeIfPresent(Int.self, forKey: .priority) ?? 5,
            cooldownSeconds: try c.decodeIfPresent(Int.self, forKey: .cooldownSeconds) ?? 0,
            approval: try c.decodeIfPresent(Approval.self, forKey: .approval) ?? .ask,
            dryRun: try c.decodeIfPresent(Bool.self, forKey: .dryRun) ?? true,
            enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        )
    }

    public func matches(_ event: Event) -> Bool {
        guard enabled else { return false }
        let kindMatches = when.hasSuffix("*") ? event.kind.hasPrefix(when.dropLast()) : event.kind == when
        return kindMatches && conditions.allSatisfy { $0.holds(for: event) }
    }
}
