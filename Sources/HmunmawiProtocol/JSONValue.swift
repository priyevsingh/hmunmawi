import Foundation

public enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    /// Looks up a dot-separated path such as `"price.amount"`.
    public subscript(path path: String) -> JSONValue? {
        var current: JSONValue? = self
        for key in path.split(separator: ".") {
            guard case .object(let dict) = current else { return nil }
            current = dict[String(key)]
        }
        return current
    }

    public var number: Double? {
        if case .number(let v) = self { return v }
        return nil
    }

    public var array: [JSONValue]? {
        if case .array(let v) = self { return v }
        return nil
    }

    public var string: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    /// Sorted keys, so the same value always produces the same text (the audit hash depends on it).
    public func canonicalText() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    public static func parse(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    /// The same result as `parse`, about 10x faster: Foundation's JSONSerialization, converted to JSONValue.
    /// Booleans stay booleans (only JSON true/false; numbers never become booleans, as with the decoder).
    /// Used for reading stored events; `EquivalenceTests` checks it against `parse` on every stored payload.
    public static func fastParse(_ data: Data) throws -> JSONValue {
        try convert(JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    private static func convert(_ any: Any) throws -> JSONValue {
        switch any {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .number(n.doubleValue)
        case let s as String: return .string(s)
        case let a as [Any]: return .array(try a.map(convert))
        case let d as [String: Any]:
            var out: [String: JSONValue] = [:]
            out.reserveCapacity(d.count)
            for (k, v) in d { out[k] = try convert(v) }
            return .object(out)
        case is NSNull: return .null
        default: throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unsupported JSON value"))
        }
    }
}
