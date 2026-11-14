import Foundation
import HmunmawiPluginKit

/// The script prints JSON: `{"events": [{"kind", "app", "payload", "occurredAt", "dedupeKey"}]}`.
struct ScriptFeed: HmunmawiPlugin {
    func poll(core: Core) async throws -> [PluginEvent] {
        let path = await core.settings[path: "script"]?.string ?? ""
        let result = try await core.mac("script.run", params: .object(["path": .string(path)]))
        let text = result[path: "stdout"]?.string ?? ""
        guard let output = try? JSONValue.parse(text) else {
            throw WireError("bad_output", "The script must print JSON with an \"events\" list")
        }
        // No "events" list (e.g. {} or {"error": …}) is a failure, never an empty success; and times must be in
        // milliseconds (seconds would land in 1970).
        guard let list = output[path: "events"] else {
            throw WireError("bad_output", output[path: "error"]?.string.map { "The script reported: \($0)" } ?? "The script's JSON has no \"events\" list")
        }
        let events = try list.decode([PluginEvent].self)
        if let bad = events.first(where: { $0.occurredAt < 1_000_000_000_000 }) {
            throw WireError("bad_output", "occurredAt must be milliseconds since 1970 (got \(bad.occurredAt) for \(bad.kind))")
        }
        return events
    }
}

await PluginRuntime.run(ScriptFeed())
