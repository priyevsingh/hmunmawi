import Foundation
import HmunmawiPluginKit

struct IMessage: HmunmawiPlugin {
    func act(action: String, params: JSONValue, core: Core) async throws -> JSONValue {
        guard action == "notify" else { throw WireError("unknown_action", action) }
        let to = (await core.settings[path: "to"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !to.isEmpty else { throw WireError("not_set_up", "Add your phone number or Apple Account email first") }
        let title = params[path: "title"]?.string ?? "Hmunmawi"
        let message = params[path: "message"]?.string ?? "Something happened"
        return try await core.mac("messages.send", params: .object(["to": .string(to),
                                                                    "text": .string("\(title): \(message)")]))
    }
}

await PluginRuntime.run(IMessage())
