import Foundation
import HmunmawiPluginKit

/// How many times the app confirmed a saved check ("ack").
nonisolated(unsafe) var acks = 0

/// A tiny add-on used only by the tests.
struct TestPlugin: HmunmawiPlugin {
    func poll(core: Core) async throws -> [PluginEvent] {
        if case .bool(true) = await core.settings[path: "hangPoll"] {
            try await Task.sleep(for: .seconds(3600))
        }
        return [PluginEvent(kind: "test.ping", app: "Test App", payload: .object(["n": .number(1)]),
                     occurredAt: 1_000, dedupeKey: "ping-1")]
    }

    func act(action: String, params: JSONValue, core: Core) async throws -> JSONValue {
        switch action {
        case "echo":
            return params
        case "fetch":
            let response = try await core.http(HTTPRequestSpec(
                url: params[path: "url"]?.string ?? "",
                headers: ["Authorization": params[path: "auth"]?.string ?? "Bearer {{secret:token}}"]))
            return .object(["status": .number(Double(response.status)), "body": .string(response.body ?? "")])
        case "crash":
            exit(3)
        case "hang":
            try await Task.sleep(for: .seconds(3600))
            return .null
        case "fail":
            throw WireError("asked_to_fail", "This action always fails")
        case "ack":
            acks += 1; return .null
        case "acks":
            return .number(Double(acks))
        default:
            throw WireError("unknown_action", action)
        }
    }
}

await PluginRuntime.run(TestPlugin())
