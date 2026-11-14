import Foundation
import HmunmawiPluginKit

/// The release-side watchers, read-only: TestFlight feedback, Xcode Cloud builds, per-build performance,
/// certificate and profile expiry, and featuring nominations (read only; this add-on never submits one).
/// Each area reports how it went in "asc.watch", so a failure is shown, never swallowed.
enum Watch {
    typealias Get = @Sendable (String) async throws -> JSONValue
    static let v1 = "https://api.appstoreconnect.apple.com/v1"
    static func ms(_ iso: String?) -> Int64? {
        iso.flatMap { try? Date($0, strategy: .iso8601) }.map { Int64($0.timeIntervalSince1970 * 1000) }
    }

    /// Once per day per key (heavy-ish reads); a mark file in the add-on's temp folder.
    static func dueToday(_ key: String) -> Bool {
        let f = State.file("hm-watch-\(key)")
        return (try? String(contentsOf: f, encoding: .utf8)) != Date.now.formatted(.iso8601.year().month().day())
    }

    /// Once ever (a backfill): a mark file in the add-on's temp folder; if the system clears it the backfill just runs again.
    static func dueOnce(_ key: String) -> Bool {
        (try? String(contentsOf: State.file("hm-once-\(key)"), encoding: .utf8)) != "done"
    }
    static func doneOnce(_ key: String) { Pending.note(State.file("hm-once-\(key)"), "done") }

    /// Marked done only after it worked, so a failure is retried on the next round instead of waiting a day.
    static func doneToday(_ key: String) {
        let f = State.file("hm-watch-\(key)")
        Pending.note(f, Date.now.formatted(.iso8601.year().month().day()))
    }

    /// TestFlight testers' screenshot and crash feedback (last 14 days), one event each.
    static func testflight(appID: String, app: String, get: Get) async throws -> [PluginEvent] {
        var out: [PluginEvent] = []
        let cutoff = Int64(Date.now.addingTimeInterval(-14 * 86_400).timeIntervalSince1970 * 1000)
        for (kind, path) in [("screenshot", "betaFeedbackScreenshotSubmissions"), ("crash", "betaFeedbackCrashSubmissions")] {
            let list = try await get("\(v1)/apps/\(appID)/\(path)?sort=-createdDate&limit=20")[path: "data"]?.array ?? []
            for f in list {
                guard let id = f[path: "id"]?.string, let at = ms(f[path: "attributes.createdDate"]?.string), at > cutoff else { continue }
                let a = f[path: "attributes"] ?? .null
                out.append(PluginEvent(kind: "testflight.feedback", app: app, payload: .object([
                    "type": .string(kind), "comment": a[path: "comment"] ?? .null, "device": a[path: "deviceModel"] ?? .null,
                    "os": a[path: "osVersion"] ?? .null, "build": a[path: "buildBundleVersion"] ?? a[path: "appBuild"] ?? .null,
                    "tester": a[path: "email"] ?? .null]), occurredAt: at, dedupeKey: "tf-\(id)"))
            }
        }
        return out
    }

    /// Xcode Cloud: the latest runs and how they ended. An app without Xcode Cloud simply has none.
    static func xcodeCloud(appID: String, app: String, get: Get) async throws -> [PluginEvent] {
        let products = try await get("\(v1)/ciProducts?filter%5Bapp%5D=\(appID)&limit=5")[path: "data"]?.array ?? []
        var out: [PluginEvent] = []
        for p in products {
            guard let pid = p[path: "id"]?.string else { continue }
            for run in try await get("\(v1)/ciProducts/\(pid)/buildRuns?sort=-number&limit=5")[path: "data"]?.array ?? [] {
                guard let id = run[path: "id"]?.string else { continue }
                let a = run[path: "attributes"] ?? .null
                let progress = a[path: "executionProgress"]?.string ?? ""
                let status = a[path: "completionStatus"]?.string ?? progress
                let at = ms(a[path: "finishedDate"]?.string ?? a[path: "startedDate"]?.string ?? a[path: "createdDate"]?.string) ?? Int64(Date.now.timeIntervalSince1970 * 1000)
                out.append(PluginEvent(kind: "ci.build", app: app, payload: .object([
                    "number": a[path: "number"] ?? .null, "progress": .string(progress), "status": .string(status),
                    "commit": a[path: "sourceCommit.message"] ?? .null, "started": a[path: "startedDate"] ?? .null,
                    "finished": a[path: "finishedDate"] ?? .null]), occurredAt: at, dedupeKey: "ci-\(id)-\(status)"))
            }
        }
        return out
    }

    /// Launch time and hang rate for the newest build (Apple's Organizer metrics), once a day per app.
    static func performance(appID: String, app: String, get: Get) async throws -> [PluginEvent] {
        guard let build = try await get("\(v1)/builds?filter%5Bapp%5D=\(appID)&sort=-uploadedDate&limit=1")[path: "data"]?.array?.first,
              let bid = build[path: "id"]?.string else { return [] }
        let metrics: JSONValue
        do { metrics = try await get("\(v1)/builds/\(bid)/perfPowerMetrics") } catch {
            // Apple has no metrics for a build until enough people use it; that's not a failure.
            if String(describing: error).contains("no resource") { return [] }
            throw error
        }
        var values: [String: JSONValue] = [:]
        for cat in metrics[path: "productData"]?.array?.first?[path: "metricCategories"]?.array ?? [] {
            for m in cat[path: "metrics"]?.array ?? [] {
                guard let ident = m[path: "identifier"]?.string, ["launchTime", "hangRate", "memory", "batteryUsage"].contains(ident),
                      let point = m[path: "datasets"]?.array?.first?[path: "points"]?.array?.last,
                      let v = point[path: "value"]?.number else { continue }
                values[ident] = .object(["value": .number(v), "unit": m[path: "unit.displayName"] ?? .null])
            }
        }
        guard !values.isEmpty else { return [] }   // not enough users on this build yet
        return [PluginEvent(kind: "perf.snapshot", app: app, payload: .object(["build": build[path: "attributes.version"] ?? .null,
                                                                                 "metrics": .object(values)]),
                            occurredAt: Int64(Date.now.timeIntervalSince1970 * 1000), dedupeKey: "perf-\(bid)-\(Date.now.formatted(.iso8601.year().month().day()))")]
    }

    /// Certificates and provisioning profiles with their expiry dates (one snapshot a day for the whole team).
    static func expiry(get: Get) async throws -> PluginEvent {
        var items: [JSONValue] = []
        // All pages (a developer can have more than 200 of either), at most 5 pages each.
        func all(_ first: String) async throws -> [JSONValue] {
            var out: [JSONValue] = [], next: String? = first, pages = 0
            while let url = next, pages < 5 {
                pages += 1
                let page = try await get(url)
                out += page[path: "data"]?.array ?? []
                next = page[path: "links.next"]?.string.flatMap { $0.hasPrefix("https://api.appstoreconnect.apple.com/") ? $0 : nil }
            }
            return out
        }
        for c in try await all("\(v1)/certificates?limit=200") {
            items.append(.object(["kind": .string("Certificate"), "name": c[path: "attributes.displayName"] ?? c[path: "attributes.name"] ?? .null,
                                  "type": c[path: "attributes.certificateType"] ?? .null, "expires": c[path: "attributes.expirationDate"] ?? .null]))
        }
        for p in try await all("\(v1)/profiles?limit=200") {
            items.append(.object(["kind": .string("Profile"), "name": p[path: "attributes.name"] ?? .null,
                                  "type": p[path: "attributes.profileType"] ?? .null, "state": p[path: "attributes.profileState"] ?? .null,
                                  "expires": p[path: "attributes.expirationDate"] ?? .null]))
        }
        return PluginEvent(kind: "expiry.snapshot", app: nil, payload: .object(["items": .array(items)]),
                           occurredAt: Int64(Date.now.timeIntervalSince1970 * 1000), dedupeKey: "expiry-\(Date.now.formatted(.iso8601.year().month().day()))")
    }

    /// Featuring nominations you've made (drafts and submitted). Read only.
    static func nominations(get: Get) async throws -> PluginEvent {
        var list: [JSONValue] = []
        for state in ["DRAFT", "SUBMITTED"] {   // the API takes one state per request
            list += try await get("\(v1)/nominations?filter%5Bstate%5D=\(state)&include=relatedApps&limit=50")[path: "data"]?.array ?? []
        }
        let items: [JSONValue] = list.map { n in
            let a = n[path: "attributes"] ?? .null
            return .object(["id": n[path: "id"] ?? .null, "name": a[path: "name"] ?? .null, "type": a[path: "type"] ?? .null,
                            "state": a[path: "state"] ?? .null, "publish_start": a[path: "publishStartDate"] ?? .null,
                            "submitted": a[path: "submittedDate"] ?? .null, "description": a[path: "description"] ?? .null,
                            "notes": a[path: "notes"] ?? .null,
                            "app_ids": .array((n[path: "relationships.relatedApps.data"]?.array ?? []).compactMap { $0[path: "id"] })])
        }
        return PluginEvent(kind: "nominations.snapshot", app: nil, payload: .object(["items": .array(items)]),
                           occurredAt: Int64(Date.now.timeIntervalSince1970 * 1000), dedupeKey: "nominations-\(Date.now.formatted(.iso8601.year().month().day()))")
    }
}

extension Watch {
    /// Every subscription's offers in one place: introductory, promotional, win-back and offer codes. Once a day.
    static func subscriptionOffers(appID: String, app: String, get: Get) async throws -> PluginEvent? {
        let groups = try await get("\(v1)/apps/\(appID)/subscriptionGroups?limit=20")[path: "data"]?.array ?? []
        var subs: [JSONValue] = []
        for g in groups {
            guard let gid = g[path: "id"]?.string else { continue }
            for s in try await get("\(v1)/subscriptionGroups/\(gid)/subscriptions?limit=50")[path: "data"]?.array ?? [] {
                guard let sid = s[path: "id"]?.string else { continue }
                func count(_ path: String) async -> JSONValue {
                    guard let list = try? await get("\(v1)/subscriptions/\(sid)/\(path)?limit=50")[path: "data"]?.array else { return .null }
                    return .number(Double(list.count))
                }
                let intro = (try? await get("\(v1)/subscriptions/\(sid)/introductoryOffers?limit=5"))?[path: "data"]?.array?.first
                subs.append(.object([
                    "name": s[path: "attributes.name"] ?? .null, "product_id": s[path: "attributes.productId"] ?? .null,
                    "period": s[path: "attributes.subscriptionPeriod"] ?? .null, "state": s[path: "attributes.state"] ?? .null,
                    "intro_mode": intro?[path: "attributes.offerMode"] ?? .null, "intro_duration": intro?[path: "attributes.duration"] ?? .null,
                    "promotional": await count("promotionalOffers"), "win_back": await count("winBackOffers"), "offer_codes": await count("offerCodes")]))
            }
        }
        guard !subs.isEmpty else { return nil }
        return PluginEvent(kind: "suboffers.snapshot", app: app, payload: .object(["app_id": .string(appID), "subscriptions": .array(subs)]),
                           occurredAt: Int64(Date.now.timeIntervalSince1970 * 1000), dedupeKey: "suboffers-\(appID)-\(Date.now.formatted(.iso8601.year().month().day()))")
    }
}

extension Watch {
    /// Product page tests (A/B experiments) and custom product pages for one app. Read only.
    static func pageTests(appID: String, app: String, get: Get) async throws -> PluginEvent? {
        // A failed read is an error (shown, retried next round), not an empty "no tests" that's marked done for the day.
        // Only "not found" means the account simply doesn't use it.
        func read(_ url: String) async throws -> [JSONValue] {
            do { return try await get(url)[path: "data"]?.array ?? [] }
            catch { let t = String(describing: error); if t.contains("404") || t.contains("NOT_FOUND") { return [] }; throw error }
        }
        // Apple lists an app's (v2) experiments under /v1/apps/{id}/appStoreVersionExperimentsV2; the /v2/apps path
        // answered "not found" for every app, so page tests never showed.
        let tests = try await read("\(v1)/apps/\(appID)/appStoreVersionExperimentsV2?limit=20")
        let pages = try await read("\(v1)/apps/\(appID)/appCustomProductPages?limit=50")
        guard !tests.isEmpty || !pages.isEmpty else { return nil }
        let t: [JSONValue] = tests.map { x in .object(["name": x[path: "attributes.name"] ?? .null, "state": x[path: "attributes.state"] ?? .null,
                                                      "started": x[path: "attributes.startDate"] ?? .null, "ended": x[path: "attributes.endDate"] ?? .null,
                                                      "traffic": x[path: "attributes.trafficProportion"] ?? .null]) }
        let p: [JSONValue] = pages.map { x in .object(["name": x[path: "attributes.name"] ?? .null, "visible": x[path: "attributes.visible"] ?? .null,
                                                      "url": x[path: "attributes.url"] ?? .null]) }
        return PluginEvent(kind: "pagetests.snapshot", app: app, payload: .object(["app_id": .string(appID), "tests": .array(t), "pages": .array(p)]),
                           occurredAt: Int64(Date.now.timeIntervalSince1970 * 1000), dedupeKey: "pagetests-\(appID)-\(Date.now.formatted(.iso8601.year().month().day()))")
    }
}
