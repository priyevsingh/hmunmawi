import Foundation
import HmunmawiPluginKit

struct YouTube: HmunmawiPlugin {
    static let api = "https://www.googleapis.com/youtube/v3/"

    func poll(core: Core) async throws -> [PluginEvent] {
        let settings = await core.settings
        let channelID = (settings[path: "channelID"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard channelID.wholeMatch(of: /UC[A-Za-z0-9_-]{22}/) != nil else {
            throw WireError("not_set_up", "Add your channel ID (starts with UC, 24 characters) from youtube.com/account_advanced")
        }

        let channels = try await get(core, "channels?part=snippet,statistics,contentDetails&id=\(channelID)")
        guard let channel = channels[path: "items"]?.array?.first else {
            throw WireError("youtube_not_found", "YouTube has no channel with the ID \(channelID)")
        }
        let title = channel[path: "snippet.title"]?.string ?? channelID
        var payload: [String: JSONValue] = [
            "subscribers": .number(Self.count(channel[path: "statistics.subscriberCount"])),
            "views": .number(Self.count(channel[path: "statistics.viewCount"])),
            "videos": .number(Self.count(channel[path: "statistics.videoCount"])),
        ]

        let now = Date()
        if let uploads = channel[path: "contentDetails.relatedPlaylists.uploads"]?.string, !uploads.isEmpty {
            // A channel with no uploads can answer "playlist not found"; that must not lose the subscriber and
            // view counts above, so the video part is simply skipped.
            let items: JSONValue
            do { items = try await get(core, "playlistItems?part=contentDetails&maxResults=15&playlistId=\(uploads)") }
            catch { let t = String(describing: error); if t.contains("404") || t.lowercased().contains("not found") { items = .object([:]) } else { throw error } }
            let ids = (items[path: "items"]?.array ?? []).compactMap { $0[path: "contentDetails.videoId"]?.string }
            if !ids.isEmpty {
                let videos = try await get(core, "videos?part=snippet,statistics&id=\(ids.joined(separator: ","))")
                let recent: [(id: String, title: String, views: Double, published: Date)] =
                    (videos[path: "items"]?.array ?? []).compactMap { video in
                        guard let id = video[path: "id"]?.string,
                              let published = Self.date(video[path: "snippet.publishedAt"]?.string) else { return nil }
                        return (id, video[path: "snippet.title"]?.string ?? id,
                                Self.count(video[path: "statistics.viewCount"]), published)
                    }
                if let latest = recent.map(\.published).max() {
                    payload["last_upload"] = .string(Self.day.string(from: latest))
                }
                let weekAgo = now.addingTimeInterval(-7 * 86_400)
                let lastWeek = recent.filter { $0.published >= weekAgo }
                payload["uploads_7d"] = .number(Double(lastWeek.count))
                if let best = lastWeek.max(by: { $0.views < $1.views }) {
                    payload["best_video_7d"] = .object([
                        "title": .string(best.title), "url": .string("https://youtu.be/\(best.id)"),
                        "views": .number(best.views), "published": .string(Self.day.string(from: best.published)),
                    ])
                }
            }
        }
        if payload["uploads_7d"] == nil { payload["uploads_7d"] = .number(0) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let hour = calendar.component(.hour, from: now)
        return [PluginEvent(kind: "growth.youtube", app: title, payload: .object(payload),
                            occurredAt: Int64(now.timeIntervalSince1970 * 1000),
                            dedupeKey: "growth.youtube-\(channelID)-\(Self.day.string(from: now))-\(hour)")]
    }

    private func get(_ core: Core, _ path: String) async throws -> JSONValue {
        // A Google sign-in (the `signIn` secret) is used when there is one; otherwise the plain API key.
        let response: HTTPResponseSpec
        do {
            response = try await core.http(HTTPRequestSpec(url: Self.api + path, headers: ["Authorization": "Bearer {{google-user-token}}"]))
        } catch {
            guard String(describing: error).contains("missing_secret") else { throw error }
            response = try await core.http(HTTPRequestSpec(url: Self.api + path, headers: ["X-goog-api-key": "{{secret:apiKey}}"]))
        }
        let json = (try? JSONValue.parse(response.body ?? "")) ?? .null
        guard response.status == 200 else {
            let detail = json[path: "error.message"]?.string ?? "status \(response.status)"
            throw WireError("youtube_failed", "YouTube: \(detail)")
        }
        return json
    }

    /// The API sends counts as strings ("12345"); accept plain numbers too.
    static func count(_ value: JSONValue?) -> Double {
        if let n = value?.number { return n }
        return value?.string.flatMap(Double.init) ?? 0
    }

    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let plain = ISO8601DateFormatter()
        if let d = plain.date(from: text) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    static var day: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }
}

await PluginRuntime.run(YouTube())
