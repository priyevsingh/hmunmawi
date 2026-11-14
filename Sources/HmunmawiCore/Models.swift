import Foundation
@_exported import HmunmawiProtocol

/// Times are Unix milliseconds throughout the core.
public typealias Millis = Int64

public struct Event: Sendable, Equatable {
    public var source: String
    public var kind: String
    public var app: String?
    public var payload: JSONValue
    public var occurredAt: Millis
    /// Same key twice means the same real-world event; the second copy is dropped.
    public var dedupeKey: String

    public init(source: String, kind: String, app: String? = nil, payload: JSONValue = .object([:]),
                occurredAt: Millis, dedupeKey: String) {
        self.source = source
        self.kind = kind
        self.app = app
        self.payload = payload
        self.occurredAt = occurredAt
        self.dedupeKey = dedupeKey
    }
}

public enum JobState: String, Sendable, Equatable {
    case queued
    case running
    case done
    case failed
    case waitingApproval = "waiting_approval"
    case skipped
}

public struct Job: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var kind: String
    /// Jobs sharing a resource never run at the same time.
    public var resource: String
    /// Lower number runs first.
    public var priority: Int
    public var state: JobState
    public var attempts: Int
    public var maxAttempts: Int
    public var runAfter: Millis
    public var owner: String?
    public var ruleID: String?
    public var eventID: Int64?
    public var payload: JSONValue
    public var lastError: String?
    public var updatedAt: Millis = 0
}

public struct AuditEntry: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var at: Millis
    public var actor: String
    public var action: String
    public var subject: String?
    public var detail: JSONValue
    public init(id: Int64, at: Millis, actor: String, action: String, subject: String?, detail: JSONValue) {
        self.id = id; self.at = at; self.actor = actor; self.action = action; self.subject = subject; self.detail = detail
    }
}

public struct IngestResult: Sendable, Equatable {
    public var eventID: Int64?
    public var duplicate: Bool
    public var jobIDs: [Int64]
    public var dryRunRuleIDs: [String]
}

// Whole numbers from outside data (add-ons, feeds, the purchase relay). Swift traps on Int(Double) when the
// value is NaN, infinite or out of range, so a single odd number would crash the app; these clamp instead.
extension Int {
    public init(safe value: Double) {
        guard value.isFinite else { self = 0; return }
        self = value >= Double(Int.max) ? .max : value <= Double(Int.min) ? .min : Int(value)
    }
}

extension Int64 {
    public init(safe value: Double) {
        guard value.isFinite else { self = 0; return }
        self = value >= Double(Int64.max) ? .max : value <= Double(Int64.min) ? .min : Int64(value)
    }
}
