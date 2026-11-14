import Foundation
import HmunmawiPluginKit

struct Ntfy: HmunmawiPlugin {
    /// A harmless reachability check: asks ntfy.sh whether it is up (its health page). Publishes nothing, so no
    /// test alert reaches your phone; real sends are recorded by the app as they happen.
    func poll(core: Core) async throws -> [PluginEvent] {
        let response = try await core.http(HTTPRequestSpec(url: "https://ntfy.sh/v1/health"))
        guard (200..<300).contains(response.status) else {
            throw WireError("ntfy_unreachable", "ntfy.sh answered \(response.status); alerts may not get through")
        }
        if let body = response.body, let json = try? JSONValue.parse(body), json[path: "healthy"] == .bool(false) {
            throw WireError("ntfy_unhealthy", "ntfy.sh says it isn't healthy right now; alerts may be delayed")
        }
        return []
    }

    func act(action: String, params: JSONValue, core: Core) async throws -> JSONValue {
        guard action == "notify" else { throw WireError("unknown_action", action) }
        let topic = await core.settings[path: "topic"]?.string ?? ""
        guard topic.wholeMatch(of: /[A-Za-z0-9_-]{1,64}/) != nil else {
            throw WireError("not_set_up", "Set an ntfy topic (letters, digits, - or _) first")
        }
        // Topics are public: anyone who guesses the name reads your alerts. A short one is refused.
        guard topic.count >= 16 else {
            throw WireError("weak_topic", "Use a long, random ntfy topic (16+ letters and digits), for example hm-\(UUID().uuidString.prefix(12).lowercased()); anyone who guesses a short one can read your alerts")
        }
        // ntfy.sh keeps messages 12 hours and doesn't encrypt them end to end: unless you switch details on, only
        // the title goes out (no figures, names, AI text or error details).
        let details = await core.settings[path: "details"].map { $0 == .bool(true) || $0 == .string("true") } ?? false
        let message = details ? (params[path: "message"]?.string ?? "Something happened") : "Open Hmunmawi for the details."
        // The alert's own title ("Hmunmawi · 3 alerts"), one line, short.
        let title = String((params[path: "title"]?.string ?? "Hmunmawi").replacingOccurrences(of: "\n", with: " ").prefix(80))
        var headers = ["Title": title, "Tags": "mountain"]
        // Tapping the alert opens the page it's about, only ever on App Store Connect (built by the app).
        if let click = params[path: "click"]?.string, click.hasPrefix("https://appstoreconnect.apple.com/"),
           click.count < 300, !click.contains(where: { $0 == "\n" || $0 == "\r" }) {
            headers["Click"] = click
        }
        let response = try await core.http(HTTPRequestSpec(
            method: "POST", url: "https://ntfy.sh/\(topic)", headers: headers, body: message))
        guard (200..<300).contains(response.status) else {
            throw WireError("ntfy_failed", "ntfy answered \(response.status)")
        }
        return .object(["sent": .bool(true)])
    }
}

await PluginRuntime.run(Ntfy())
