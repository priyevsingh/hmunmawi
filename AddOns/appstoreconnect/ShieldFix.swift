import Foundation
import HmunmawiPluginKit

/// The fixes Rejection Shield can make, each small and reversible. Params: {fix, app_id, version_id, ...}.
/// Returns {done: "...", undo: {fix, ...}} where undo restores what was there before.
enum ShieldFix {
    /// The version's own platform (iPhone/iPad, Mac, Apple TV or Vision Pro); IOS when it isn't known.
    static func platform(_ p: String?) -> String { AppStoreConnect.platform(p ?? "") }
    typealias Send = @Sendable (String, String, JSONValue?) async throws -> JSONValue
    typealias Get = @Sendable (String) async throws -> JSONValue
    static let v1 = "https://api.appstoreconnect.apple.com/v1"

    static func run(_ p: JSONValue, send: Send, get: Get) async throws -> JSONValue {
        if let fix = p[path: "fix"]?.string, fix == "review_reply" {
            // Posts a reply to one customer review (only when the person pressed it and confirmed). Apple shows it
            // after a short check; one reply per review (a new one replaces the old).
            guard let rid = p[path: "review_id"]?.string, rid.count < 80, let text = p[path: "text"]?.string,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WireError("bad_fix", "Needs a review and a reply") }
            let made = try await send("POST", "\(v1)/customerReviewResponses", .object(["data": .object([
                "type": .string("customerReviewResponses"), "attributes": .object(["responseBody": .string(String(text.prefix(5900)))]),
                "relationships": .object(["review": .object(["data": .object(["type": .string("customerReviews"), "id": .string(rid)])])])])]))
            return .object(["done": .string("Reply sent; Apple publishes it shortly"),
                            "undo": made[path: "data.id"].map { .object(["fix": .string("review_reply_delete"), "response_id": $0]) } ?? .null])
        }
        if let fix = p[path: "fix"]?.string, fix == "review_reply_delete" {
            guard let id = p[path: "response_id"]?.string, id.count < 80 else { throw WireError("bad_fix", "Missing reply") }
            _ = try await send("DELETE", "\(v1)/customerReviewResponses/\(id)", nil)
            return .object(["done": .string("Reply removed"), "undo": .null])
        }
        if let fix = p[path: "fix"]?.string, fix.hasPrefix("nomination_") {
            return try await nomination(fix, p, send: send, get: get)
        }
        if let fix = p[path: "fix"]?.string, fix == "list_old_builds" || fix == "expire_old_builds" {
            return try await oldBuilds(p, expire: fix == "expire_old_builds", send: send, get: get)
        }
        guard let fix = p[path: "fix"]?.string, let vid = p[path: "version_id"]?.string, vid.count < 80 else {
            throw WireError("bad_fix", "Missing fix or version")
        }
        switch fix {
        case "attach_build":
            // The newest processed, unexpired build for this version number (or the one named).
            let current = try? await get("\(v1)/appStoreVersions/\(vid)/build")
            let before = current?[path: "data.id"]?.string
            var buildID = p[path: "build_id"]?.string
            if buildID == nil {
                guard let a = p[path: "app_id"]?.string, !a.isEmpty, a.allSatisfy(\.isNumber) else {
                    throw WireError("stale", "This version's details are out of date. Wait for the next check (or press Check Now in Settings), then try again.")
                }
                let version = try await get("\(v1)/appStoreVersions/\(vid)")
                let app = p[path: "app_id"]?.string ?? ""
                let number = version[path: "data.attributes.versionString"]?.string ?? ""
                let builds = try await get("\(v1)/builds?filter%5Bapp%5D=\(app)&filter%5BpreReleaseVersion.version%5D=\(number)"
                    + "&filter%5BpreReleaseVersion.platform%5D=\(Self.platform(version[path: "data.attributes.platform"]?.string))&filter%5BprocessingState%5D=VALID&filter%5Bexpired%5D=false&sort=-uploadedDate&limit=1")
                buildID = builds[path: "data"]?.array?.first?[path: "id"]?.string
            }
            guard let buildID else { throw WireError("no_build", "No processed build for this version yet. Upload one from Xcode first.") }
            _ = try await send("PATCH", "\(v1)/appStoreVersions/\(vid)/relationships/build",
                               .object(["data": .object(["type": .string("builds"), "id": .string(buildID)])]))
            return .object(["done": .string("Attached the build"),
                            "undo": before.map { .object(["fix": .string("attach_build"), "version_id": .string(vid), "build_id": .string($0)]) } ?? .null])

        case "set_texts":
            // {field: whatsNew|promotionalText, texts: {locale: text}} -> each language; "copy_live" fills empties from live.
            guard let field = p[path: "field"]?.string, ["whatsNew", "promotionalText"].contains(field) else { throw WireError("bad_field", "Unknown field") }
            let locs = try await get("\(v1)/appStoreVersions/\(vid)/appStoreVersionLocalizations?limit=50")[path: "data"]?.array ?? []
            var texts: [String: String] = [:]
            if case .object(let t)? = p[path: "texts"] { for (k, v) in t { if let s = v.string { texts[k] = s } } }
            if p[path: "copy_live"] == .bool(true), let live = p[path: "live_id"]?.string {
                for l in try await get("\(v1)/appStoreVersions/\(live)/appStoreVersionLocalizations?limit=50")[path: "data"]?.array ?? [] {
                    if let loc = l[path: "attributes.locale"]?.string, let v = l[path: "attributes.\(field)"]?.string, !v.isEmpty, texts[loc] == nil { texts[loc] = v }
                }
            }
            let limit = field == "whatsNew" ? 4000 : 170
            var before: [String: JSONValue] = [:], changed = 0, failedLocs: [String] = [], lastError = ""
            for l in locs {
                guard let lid = l[path: "id"]?.string, let loc = l[path: "attributes.locale"]?.string, let text = texts[loc] else { continue }
                let old = l[path: "attributes.\(field)"]?.string ?? ""
                if p[path: "only_empty"] == .bool(true), !old.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                // One language failing doesn't stop the rest, and the ones already changed keep their undo.
                do {
                    _ = try await send("PATCH", "\(v1)/appStoreVersionLocalizations/\(lid)", .object(["data": .object([
                        "type": .string("appStoreVersionLocalizations"), "id": .string(lid),
                        "attributes": .object([field: .string(String(text.prefix(limit)))])])]))
                    before[loc] = .string(old); changed += 1
                } catch { failedLocs.append(loc); lastError = String(String(describing: error).prefix(80)) }
            }
            if changed == 0, !failedLocs.isEmpty { throw WireError("asc_failed", "No language could be updated: \(lastError)") }
            return .object(["done": .string("Updated \(changed) language\(changed == 1 ? "" : "s")"
                                             + (failedLocs.isEmpty ? "" : "; couldn't update \(failedLocs.sorted().joined(separator: ", ")) (\(lastError))")),
                            "undo": .object(["fix": .string("set_texts"), "version_id": .string(vid), "field": .string(field), "texts": .object(before)])])

        case "set_review":
            // {notes?, copy_contact_from?: live version id} -> the reviewer's notes and contact details.
            let detail = try? await get("\(v1)/appStoreVersions/\(vid)/appStoreReviewDetail")
            let id = detail?[path: "data.id"]?.string
            let old = detail?[path: "data.attributes"] ?? .object([:])
            var attrs: [String: JSONValue] = [:]
            if let notes = p[path: "notes"]?.string { attrs["notes"] = .string(String(notes.prefix(4000))) }
            if let from = p[path: "copy_contact_from"]?.string,
               let src = try? await get("\(v1)/appStoreVersions/\(from)/appStoreReviewDetail")[path: "data.attributes"] {
                for k in ["contactFirstName", "contactLastName", "contactPhone", "contactEmail"] { if let v = src[path: k], v != .null { attrs[k] = v } }
            }
            if case .object(let given)? = p[path: "attributes"] { for (k, v) in given where k.hasPrefix("contact") || k == "notes" { attrs[k] = v } }
            guard !attrs.isEmpty else { throw WireError("nothing", "Nothing to change") }
            if let id {
                _ = try await send("PATCH", "\(v1)/appStoreReviewDetails/\(id)", .object(["data": .object([
                    "type": .string("appStoreReviewDetails"), "id": .string(id), "attributes": .object(attrs)])]))
            } else {
                _ = try await send("POST", "\(v1)/appStoreReviewDetails", .object(["data": .object([
                    "type": .string("appStoreReviewDetails"), "attributes": .object(attrs),
                    "relationships": .object(["appStoreVersion": .object(["data": .object(["type": .string("appStoreVersions"), "id": .string(vid)])])])])]))
            }
            var undo: [String: JSONValue] = [:]
            for k in attrs.keys { undo[k] = old[path: k] ?? .null }
            return .object(["done": .string("Updated the reviewer details"),
                            "undo": .object(["fix": .string("set_review"), "version_id": .string(vid), "attributes": .object(undo)])])

        case "submit":
            // Submit for Review, only when the person pressed it (or approved an agent's request). If any step fails,
            // the half-made submission is cancelled so nothing is left dangling.
            guard let app = p[path: "app_id"]?.string, !app.isEmpty else { throw WireError("stale", "This version's details are out of date; wait for the next check.") }
            let platform = Self.platform((try? await get("\(v1)/appStoreVersions/\(vid)"))?[path: "data.attributes.platform"]?.string)
            let made = try await send("POST", "\(v1)/reviewSubmissions", .object(["data": .object([
                "type": .string("reviewSubmissions"), "attributes": .object(["platform": .string(platform)]),
                "relationships": .object(["app": .object(["data": .object(["type": .string("apps"), "id": .string(app)])])])])]))
            guard let sid = made[path: "data.id"]?.string else { throw WireError("asc_failed", "App Store Connect didn't create the submission.") }
            do {
                _ = try await send("POST", "\(v1)/reviewSubmissionItems", .object(["data": .object([
                    "type": .string("reviewSubmissionItems"),
                    "relationships": .object([
                        "reviewSubmission": .object(["data": .object(["type": .string("reviewSubmissions"), "id": .string(sid)])]),
                        "appStoreVersion": .object(["data": .object(["type": .string("appStoreVersions"), "id": .string(vid)])])])])]))
                _ = try await send("PATCH", "\(v1)/reviewSubmissions/\(sid)", .object(["data": .object([
                    "type": .string("reviewSubmissions"), "id": .string(sid), "attributes": .object(["submitted": .bool(true)])])]))
            } catch {
                _ = try? await send("PATCH", "\(v1)/reviewSubmissions/\(sid)", .object(["data": .object([
                    "type": .string("reviewSubmissions"), "id": .string(sid), "attributes": .object(["canceled": .bool(true)])])]))
                throw error
            }
            return .object(["done": .string("Submitted for review"),
                            "undo": .object(["fix": .string("cancel_submission"), "version_id": .string(vid), "submission_id": .string(sid)])])

        case "cancel_submission":
            guard let sid = p[path: "submission_id"]?.string else { throw WireError("bad_fix", "Missing submission") }
            _ = try await send("PATCH", "\(v1)/reviewSubmissions/\(sid)", .object(["data": .object([
                "type": .string("reviewSubmissions"), "id": .string(sid), "attributes": .object(["canceled": .bool(true)])])]))
            return .object(["done": .string("Pulled it back from review"), "undo": .null])

        default:
            throw WireError("bad_fix", "Unknown fix \(fix)")
        }
    }

    /// TestFlight tidy-up: every unexpired build except the newest one and any build attached to a version
    /// (live or in progress). "list" only reads; "expire" expires exactly the builds named in "ids", which must
    /// all be in the list (so nothing unexpected is touched). Apple can't un-expire a build.
    static func oldBuilds(_ p: JSONValue, expire: Bool, send: Send, get: Get) async throws -> JSONValue {
        guard let app = p[path: "app_id"]?.string, !app.isEmpty, app.allSatisfy(\.isNumber) else { throw WireError("bad_app", "Missing app") }
        let builds = try await get("\(v1)/builds?filter%5Bapp%5D=\(app)&filter%5Bexpired%5D=false&sort=-uploadedDate&limit=200"
            + "&fields%5Bbuilds%5D=version,uploadedDate,appStoreVersion&include=appStoreVersion")[path: "data"]?.array ?? []
        let keep = builds.first?[path: "id"]?.string
        let candidates = builds.dropFirst().filter { b in
            // Builds attached to an App Store version stay.
            b[path: "relationships.appStoreVersion.data"] == nil || b[path: "relationships.appStoreVersion.data"] == .null
        }
        let list: [JSONValue] = candidates.map { b in
            .object(["id": b[path: "id"] ?? .null, "build": b[path: "attributes.version"] ?? .null, "uploaded": b[path: "attributes.uploadedDate"] ?? .null])
        }
        guard expire else {
            return .object(["builds": .array(list), "keep": keep.map(JSONValue.string) ?? .null,
                            "keep_build": builds.first?[path: "attributes.version"] ?? .null])
        }
        let allowed = Set(candidates.compactMap { $0[path: "id"]?.string })
        let ids = (p[path: "ids"]?.array ?? []).compactMap(\.string).filter(allowed.contains)
        var done = 0, failed: [String] = []
        // At most 40 per press, so one press finishes well inside the app's wait; the rest stay listed for the next.
        let batch = Array(ids.prefix(40)), left = ids.count - batch.count
        for id in batch {
            do {
                _ = try await send("PATCH", "\(v1)/builds/\(id)", .object(["data": .object([
                    "type": .string("builds"), "id": .string(id), "attributes": .object(["expired": .bool(true)])])]))
                done += 1
            } catch { failed.append(String(describing: error).prefix(80).description) }
        }
        return .object(["done": .string("Expired \(done) old build\(done == 1 ? "" : "s")" + (failed.isEmpty ? "" : "; \(failed.count) couldn't be: \(failed.first ?? "")")
                                         + (left > 0 ? ". \(left) more to go: press again for the next batch." : "")),
                        "undo": .null])
    }

    /// Featuring nominations. Only ever run when the person pressed the button (or approved an agent's request):
    /// update a draft's text (undoable), create a draft (never submitted), or submit (owner-confirmed).
    static func nomination(_ fix: String, _ p: JSONValue, send: Send, get: Get) async throws -> JSONValue {
        switch fix {
        case "nomination_update":
            guard let id = p[path: "nomination_id"]?.string, id.count < 80 else { throw WireError("bad_fix", "Missing nomination") }
            let old = try? await get("\(v1)/nominations/\(id)")
            var attrs: [String: JSONValue] = [:], undo: [String: JSONValue] = [:]
            for k in ["description", "notes", "name"] {
                if let v = p[path: k]?.string { attrs[k] = .string(String(v.prefix(4000))); undo[k] = old?[path: "data.attributes.\(k)"] ?? .null }
            }
            guard !attrs.isEmpty else { throw WireError("nothing", "Nothing to change") }
            _ = try await send("PATCH", "\(v1)/nominations/\(id)", .object(["data": .object([
                "type": .string("nominations"), "id": .string(id), "attributes": .object(attrs)])]))
            return .object(["done": .string("Updated the nomination draft"),
                            "undo": .object(["fix": .string("nomination_update"), "nomination_id": .string(id)].merging(undo) { a, _ in a })])
        case "nomination_create":
            guard let app = p[path: "app_id"]?.string, !app.isEmpty, let name = p[path: "name"]?.string,
                  let type = p[path: "type"]?.string, ["APP_LAUNCH", "APP_ENHANCEMENTS", "NEW_CONTENT"].contains(type) else {
                throw WireError("bad_fix", "Needs an app, a name and a type")
            }
            var attrs: [String: JSONValue] = ["name": .string(String(name.prefix(60))), "type": .string(type), "submitted": .bool(false),
                                              "description": .string(String((p[path: "description"]?.string ?? "").prefix(4000)))]
            if let start = p[path: "publish_start"]?.string { attrs["publishStartDate"] = .string(start) }
            let made = try await send("POST", "\(v1)/nominations", .object(["data": .object([
                "type": .string("nominations"), "attributes": .object(attrs),
                "relationships": .object(["relatedApps": .object(["data": .array([.object(["type": .string("apps"), "id": .string(app)])])])])])]))
            return .object(["done": .string("Saved a new nomination draft (not submitted)"),
                            "id": made[path: "data.id"] ?? .null, "undo": .null])
        case "nomination_submit":
            guard let id = p[path: "nomination_id"]?.string, id.count < 80 else { throw WireError("bad_fix", "Missing nomination") }
            _ = try await send("PATCH", "\(v1)/nominations/\(id)", .object(["data": .object([
                "type": .string("nominations"), "id": .string(id), "attributes": .object(["submitted": .bool(true)])])]))
            return .object(["done": .string("Nomination sent to Apple"), "undo": .null])
        default:
            throw WireError("bad_fix", "Unknown nomination action")
        }
    }
}
