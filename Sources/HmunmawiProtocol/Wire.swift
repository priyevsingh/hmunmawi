import Foundation

public let hmunmawiProtocolVersion = 1

public struct WireError: Error, Codable, Sendable, Equatable, CustomStringConvertible {
    public var code: String
    public var message: String

    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { "\(code): \(message)" }
}

/// One line of JSON on stdin/stdout. Requests have `id` + `method`, notifications only `method`,
/// responses only `id` plus `result` or `error`.
public struct WireMessage: Codable, Sendable, Equatable {
    public var id: String?
    public var method: String?
    public var params: JSONValue?
    public var result: JSONValue?
    public var error: WireError?

    public init(id: String? = nil, method: String? = nil, params: JSONValue? = nil,
                result: JSONValue? = nil, error: WireError? = nil) {
        self.id = id
        self.method = method
        self.params = params
        self.result = result
        self.error = error
    }

    public var isRequest: Bool { id != nil && method != nil }
    public var isNotification: Bool { id == nil && method != nil }
    public var isResponse: Bool { id != nil && method == nil }

    public func line() throws -> Data {
        var data = try JSONEncoder().encode(self)
        data.append(0x0A)
        return data
    }

    public static func decode(_ line: String) throws -> WireMessage {
        try JSONDecoder().decode(WireMessage.self, from: Data(line.utf8))
    }
}

/// Header and body text may contain `{{secret:NAME}}`; the app fills it in, so the add-on never sees the value.
public struct HTTPRequestSpec: Codable, Sendable, Equatable {
    public var method: String
    public var url: String
    public var headers: [String: String]
    public var body: String?
    public var bodyBase64: String?

    public init(method: String = "GET", url: String, headers: [String: String] = [:],
                body: String? = nil, bodyBase64: String? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.bodyBase64 = bodyBase64
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(method: try c.decodeIfPresent(String.self, forKey: .method) ?? "GET",
                  url: try c.decode(String.self, forKey: .url),
                  headers: try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:],
                  body: try c.decodeIfPresent(String.self, forKey: .body),
                  bodyBase64: try c.decodeIfPresent(String.self, forKey: .bodyBase64))
    }
}

/// `body` is set for text responses, `bodyBase64` for binary ones (for example gzip reports).
public struct HTTPResponseSpec: Codable, Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: String?
    public var bodyBase64: String?

    public init(status: Int, headers: [String: String] = [:], body: String? = nil, bodyBase64: String? = nil) {
        self.status = status
        self.headers = headers
        self.body = body
        self.bodyBase64 = bodyBase64
    }
}

public struct PluginEvent: Codable, Sendable, Equatable {
    public var kind: String
    public var app: String?
    public var payload: JSONValue?
    /// Unix milliseconds.
    public var occurredAt: Int64
    public var dedupeKey: String

    public init(kind: String, app: String? = nil, payload: JSONValue? = nil, occurredAt: Int64, dedupeKey: String) {
        self.kind = kind
        self.app = app
        self.payload = payload
        self.occurredAt = occurredAt
        self.dedupeKey = dedupeKey
    }
}

extension JSONValue {
    public init(encoding value: some Encodable) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(self))
    }
}
