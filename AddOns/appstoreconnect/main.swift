import Foundation
import HmunmawiPluginKit

/// Where this add-on remembers what it already read (done days, report totals, check times). A real folder, not
/// the system's temp folder: macOS empties that every few days, which used to make the 70-day sales and 60-day
/// subscription history download again each time.
enum State {
    static let dir: URL = {
        let d = URL.applicationSupportDirectory.appending(path: "Hmunmawi/AddOnState/appstoreconnect", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return d
    }()
    static func file(_ name: String) -> URL { dir.appending(path: name) }
}

/// "Done" notes made during a check, written only when the app confirms it saved that check's events (the
/// "ack" action). If the check is dropped (it ran out of time, the app quit), nothing is marked done and the next
/// check simply reads it again; the app ignores events it already has.
enum Pending {
    nonisolated(unsafe) static var notes: [(URL, String)] = []
    static func note(_ file: URL, _ text: String) { notes.append((file, text)) }
    static func flush() -> Int {
        for (f, t) in notes { StateFile.write(t, to: f) }
        defer { notes = [] }
        return notes.count
    }
}

/// How often an app's builds, versions, TestFlight and Xcode Cloud are read. Busy apps (a version on its way, or a
/// build in the last 3 days) every check; quiet ones (only the live version) every 3 hours. Reviews are read for
/// every app on every check either way.
enum Cadence {
    static let quietSeconds: TimeInterval = 3 * 3600
    static func due(_ appID: String) -> Bool {
        guard let t = try? String(contentsOf: State.file("cadence-\(appID)"), encoding: .utf8) else { return true }
        let parts = t.split(separator: "|")
        guard parts.count == 2, let last = Double(parts[0]) else { return true }
        return parts[1] == "busy" || Date.now.timeIntervalSince1970 - last >= quietSeconds
    }
    static func done(_ appID: String, busy: Bool) {
        Pending.note(State.file("cadence-\(appID)"), "\(Date.now.timeIntervalSince1970)|\(busy ? "busy" : "quiet")")
    }
}

/// How long one check may spend on heavy, postponable work (Rejection Shield, daily reads, backfills). The app
/// stops waiting for a check after 10 minutes and drops its result, so work that doesn't fit stays due and runs in
/// the next hourly check instead. Everything a check must have (builds, release state, reviews, the last week's
/// sales and subscriptions) always runs.
enum Budget {
    nonisolated(unsafe) static var until = Date.distantFuture
    static var left: Bool { Date.now < until }
}

struct AppStoreConnect: HmunmawiPlugin {
    static let base = "https://api.appstoreconnect.apple.com/v1"
    /// This add-on's own folder (the only place its sandbox lets it write).
    static let stateFolder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Hmunmawi/AddOnState/appstoreconnect")
    static let maxAgeDays = 7.0
    static let longestGapDays = 45.0   // after a long gap the window grows to cover it, never past this

    func poll(core: Core) async throws -> [PluginEvent] {
        Budget.until = Date.now.addingTimeInterval(240)
        Pending.notes = []   // a previous check the app never confirmed: its work will be read again
        let apps = try await get("\(Self.base)/apps?limit=200&fields%5Bapps%5D=name,sku", core: core)
        var events: [PluginEvent] = []
        var offerProblem: String?
        var reviewsProblem: String?
        var fullApps: Set<String> = []   // apps read in full this check (see Cadence)
        // What this key can read, step by step, so setup can say exactly which role is missing.
        // Once a day: the key's role rarely changes (two of these reads download whole report files).
        if Watch.dueToday("access") {
            events.append(PluginEvent(kind: "asc.access", app: nil, payload: await access(apps: apps, core: core),
                                      occurredAt: Int64(Date.now.timeIntervalSince1970 * 1000), dedupeKey: "asc-access-\(Self.hour())"))
            Watch.doneToday("access")
        }
        // 7 days normally; after the Mac (or this add-on) was off longer, reach back to the last good read of reviews,
        // so reviews that came in meanwhile are not lost. Reviews already seen are skipped by their dedupe key.
        let stampFile = State.file("hm-reviews-last-ok")
        let lastOK = (try? String(contentsOf: stampFile, encoding: .utf8)).flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0) }
        let reach = max(Self.maxAgeDays, min(Self.longestGapDays, lastOK.map { Date.now.timeIntervalSince($0) / 86_400 + 1 } ?? 0))
        let cutoff = Date.now.addingTimeInterval(-reach * 86_400)
        let dates = ISO8601DateFormatter()

        for app in apps[path: "data"]?.array ?? [] {
            guard let appID = app[path: "id"]?.string else { continue }
            let name = app[path: "attributes.name"]?.string ?? appID
            let full = Cadence.due(appID)
            if full { fullApps.insert(appID) }
            let build = full ? try? await latestBuild(appID: appID, core: core) : nil
            if full, let release = try? await releaseState(appID: appID, build: build, core: core) {
                // Heavy (every language, both versions), so only for versions you're still preparing or that wait for
                // review, and at most every 6 hours: this key may be shared with your other tools' rate limit.
                let shieldStates: Set<String> = ["PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED",
                                                 "READY_FOR_REVIEW", "WAITING_FOR_REVIEW", "INVALID_BINARY"]
                // UTC, like today() below, so the 6-hour slot and its date never disagree around midnight.
                var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
                let slot = utc.component(.hour, from: .now) / 6
                // Parked versions (no build or change for 30+ days) aren't checked until work starts again.
                let active = [release[path: "build_uploaded"]?.string, release[path: "version_created"]?.string]
                    .compactMap { $0.flatMap { try? Date($0, strategy: .iso8601) } }.max().map { Date.now.timeIntervalSince($0) < 30 * 86_400 } ?? false
                if let vid = release[path: "version_id"]?.string, shieldStates.contains(release[path: "state"]?.string ?? ""),
                   active || release[path: "state"]?.string != "PREPARE_FOR_SUBMISSION",
                   Budget.left, Self.shieldDue(vid, slot: slot) {
                    // Rejection Shield: everything Apple would bounce, checked before you submit.
                    let report = await Shield.check(appID: appID, versionID: vid, liveID: release[path: "live_version_id"]?.string,
                                                    version: release[path: "version"]?.string ?? "", state: release[path: "state"]?.string ?? "",
                                                    get: { try await get($0, core: core) })
                    // Only a complete check counts for this slot; one that couldn't read everything tries again
                    // next round (as its own message says), and its dedupe key lets the retry through.
                    let complete = !(report[path: "items"]?.array ?? []).contains { $0[path: "id"]?.string == "unread" }
                    // At most 3 tries per slot: a read this key is never allowed (403) would otherwise run the
                    // heavy check every hour. What couldn't be read stays listed in the result.
                    if complete || Self.shieldTry(vid, slot: slot) >= 3 { Self.shieldDone(vid, slot: slot) }
                    events.append(PluginEvent(kind: "release.check", app: name, payload: report,
                                              occurredAt: Int64(Date.now.timeIntervalSince1970 * 1000),
                                              dedupeKey: "shield-\(appID)-\(vid)-\(Self.today())-\(slot)" + (complete ? "" : "-\(Self.hour())")))
                }
                // Busy: a version on its way that isn't parked, or a build in the last 3 days.
                let recentBuild = build?[path: "attributes.uploadedDate"]?.string.flatMap { try? Date($0, strategy: .iso8601) }
                    .map { Date.now.timeIntervalSince($0) < 3 * 86_400 } ?? false
                let onItsWay = release[path: "version_id"]?.string != nil && (active || release[path: "state"]?.string != "PREPARE_FOR_SUBMISSION")
                Cadence.done(appID, busy: onItsWay || recentBuild)
                // Where the app is on its way to the App Store: version, review state and the newest TestFlight build.
                events.append(PluginEvent(kind: "release.snapshot", app: name, payload: release,
                                          occurredAt: Int64(Date.now.timeIntervalSince1970 * 1000),
                                          dedupeKey: "release-\(appID)-\(Self.hour())"))
            }
            if let icon = build.flatMap(iconURL) {
                // The real App Store icon, from the newest build; sent once a day so the app always has it.
                events.append(PluginEvent(kind: "icon.snapshot", app: name,
                                          payload: .object(["url": .string(icon), "appID": .string(appID)]),
                                          occurredAt: Int64(Date.now.timeIntervalSince1970 * 1000),
                                          dedupeKey: "icon-\(appID)-\(Self.today())"))
            }
            if Watch.dueToday("offercodes-\(appID)") {
                // Once a day, as promised (each read is 1 + 2 per code calls); a failure is shown, then retried.
                do {
                    let codes = try await offerCodes(appID: appID, core: core)
                    Watch.doneToday("offercodes-\(appID)")
                    if !(codes[path: "offers"]?.array ?? []).isEmpty {
                // Offer codes on the app's in-app purchases (names, kind, expiry, custom codes, one-time batches),
                // once a day. Apple never says which codes were redeemed, so "shared" stays the user's own mark.
                events.append(PluginEvent(kind: "offercodes.snapshot", app: name, payload: codes,
                                          occurredAt: Int64(Date.now.timeIntervalSince1970 * 1000),
                                          dedupeKey: "offercodes-\(appID)-\(Self.today())"))
                    }
                } catch { offerProblem = String(String(describing: error).prefix(120)) }
            }
            // Newest first, page by page until reviews are older than the window (at most 4 pages = 200), so a
            // busy week isn't cut at 50. One app's reviews failing must not drop every other app's events,
            // but the failure is shown in the run status, never swallowed.
            var page: String? = "\(Self.base)/apps/\(appID)/customerReviews?sort=-createdDate&limit=50"
            var collected: [JSONValue] = [], pages = 0
            while let url = page, pages < 4, Budget.left {
                pages += 1
                guard let reviews = try? await get(url, core: core) else { reviewsProblem = "couldn't read reviews for \(name)"; break }
                let batch = reviews[path: "data"]?.array ?? []
                collected += batch
                let oldest = batch.last?[path: "attributes.createdDate"]?.string.flatMap(dates.date(from:))
                page = (oldest.map { $0 > cutoff } ?? false) ? reviews[path: "links.next"]?.string.flatMap { $0.hasPrefix(Self.base) ? $0 : nil } : nil
            }
            for review in collected {
                guard let id = review[path: "id"]?.string,
                      let created = review[path: "attributes.createdDate"]?.string.flatMap(dates.date(from:)),
                      created > cutoff
                else { continue }
                let a = review[path: "attributes"] ?? .null
                events.append(PluginEvent(
                    kind: "review.new", app: name,
                    payload: .object(["review_id": .string(id), "rating": a[path: "rating"] ?? .null, "title": a[path: "title"] ?? .null,
                                      "body": a[path: "body"] ?? .null, "territory": a[path: "territory"] ?? .null]),
                    occurredAt: Int64(created.timeIntervalSince1970 * 1000), dedupeKey: "review-\(id)"))
            }
            // Every version of the app and where it stands (read only, newest 20): the release timeline's backbone. Apple's
            // version list gives no go-live date, so Hmunmawi notes that itself when it sees the live version change.
            if let list = try? await get("\(Self.base)/apps/\(appID)/appStoreVersions?limit=20", core: core) {
                let versions: [JSONValue] = (list[path: "data"]?.array ?? []).compactMap { v in
                    guard let id = v[path: "id"]?.string, let number = v[path: "attributes.versionString"]?.string else { return nil }
                    let state = v[path: "attributes.appVersionState"]?.string ?? v[path: "attributes.appStoreState"]?.string
                    return .object(["id": .string(id), "version": .string(number), "state": state.map(JSONValue.string) ?? .null,
                                    "created": v[path: "attributes.createdDate"] ?? .null, "release_type": v[path: "attributes.releaseType"] ?? .null])
                }
                let sig = versions.map { "\($0[path: "id"]?.string ?? "")=\($0[path: "state"]?.string ?? "")" }.joined(separator: ",")
                // A new snapshot whenever the list differs from the last one sent, even when it goes back to an earlier
                // state (rejected -> waiting for review again after a resubmission); the same list is not sent twice.
                let mark = Self.stateFolder.appending(path: "versions-\(appID).sig")
                if (try? String(contentsOf: mark, encoding: .utf8)) != sig {
                    let now = Int64(Date.now.timeIntervalSince1970 * 1000)
                    try? FileManager.default.createDirectory(at: Self.stateFolder, withIntermediateDirectories: true)
                    let remembered = StateFile.write(sig, to: mark)
                    // Without a writable folder it can't remember, so it falls back to "each list once".
                    let key = remembered ? "verlist-\(appID)-\(sig.hashValueStable)-\(now)" : "verlist-\(appID)-\(sig.hashValueStable)"
                    events.append(PluginEvent(kind: "versions.snapshot", app: name,
                                              payload: .object(["app_id": .string(appID), "versions": .array(versions)]),
                                              occurredAt: now, dedupeKey: key))
                }
            }
            // Reviews with no published reply, whatever their age (Apple's own filter, read only): one newest-first page
            // per app. Written as a snapshot so the inbox always shows what is open now; a reply made in App Store
            // Connect drops a review out of it on the next check.
            if let open = try? await get("\(Self.base)/apps/\(appID)/customerReviews?exists%5BpublishedResponse%5D=false&sort=-createdDate&limit=50", core: core) {
                let rows: [JSONValue] = (open[path: "data"]?.array ?? []).compactMap { r in
                    guard let id = r[path: "id"]?.string else { return nil }
                    let a = r[path: "attributes"] ?? .null
                    let at = a[path: "createdDate"]?.string.flatMap(dates.date(from:)).map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
                    return .object(["review_id": .string(id), "rating": a[path: "rating"] ?? .null, "title": a[path: "title"] ?? .null,
                                    "body": a[path: "body"] ?? .null, "territory": a[path: "territory"] ?? .null,
                                    "nickname": a[path: "reviewerNickname"] ?? .null, "created": .number(Double(at))])
                }
                let more = open[path: "links.next"]?.string != nil
                let idList = rows.compactMap { $0[path: "review_id"]?.string }
                let ids = "\(idList.count)-\(idList.first ?? "")-\(idList.last ?? "")"   // stable across runs: a new event only when the open list changes
                events.append(PluginEvent(
                    kind: "reviews.snapshot", app: name,
                    payload: .object(["app_id": .string(appID), "count": .number(Double(rows.count)), "more": .bool(more), "reviews": .array(rows)]),
                    occurredAt: Int64(Date.now.timeIntervalSince1970 * 1000), dedupeKey: "reviews-open-\(appID)-\(ids)"))
            }
        }
        if reviewsProblem == nil { StateFile.write(String(Date.now.timeIntervalSince1970), to: stampFile) }
        // Release watchers. Each area's result goes in "asc.watch" (ok / reason), so nothing fails quietly.
        var watch: [String: JSONValue] = [:]
        if let offerProblem { watch["offer_codes"] = .string(offerProblem) }
        if let reviewsProblem { watch["reviews"] = .string(reviewsProblem) }
        let g: Watch.Get = { try await get($0, core: core) }
        func note(_ area: String, _ error: Error) {
            let text = String(describing: error)
            // 403/404: the key's role or the account doesn't have it (e.g. no Xcode Cloud). Said plainly.
            watch[area] = .string(text.contains("403") || text.contains("FORBIDDEN") ? "needs a wider key role"
                                  : text.contains("404") || text.contains("NOT_FOUND") ? "not used" : String(text.prefix(120)))
        }
        for app in apps[path: "data"]?.array ?? [] {
            guard let appID = app[path: "id"]?.string else { continue }
            let name = app[path: "attributes.name"]?.string ?? appID
            if fullApps.contains(appID) {
                do { events += try await Watch.testflight(appID: appID, app: name, get: g); watch["testflight"] = watch["testflight"] ?? .string("ok") } catch { note("testflight", error) }
                do { events += try await Watch.xcodeCloud(appID: appID, app: name, get: g); watch["xcode_cloud"] = watch["xcode_cloud"] ?? .string("ok") } catch { note("xcode_cloud", error) }
            }
            if Budget.left, Watch.dueToday("pagetests-\(appID)") {
                do { if let e = try await Watch.pageTests(appID: appID, app: name, get: g) { events.append(e) }
                     watch["page_tests"] = watch["page_tests"] ?? .string("ok"); Watch.doneToday("pagetests-\(appID)") }
                catch { note("page_tests", error) }
            }
            if Budget.left, Watch.dueToday("suboffers-\(appID)") {
                do { if let e = try await Watch.subscriptionOffers(appID: appID, app: name, get: g) { events.append(e) }
                     watch["subscription_offers"] = watch["subscription_offers"] ?? .string("ok"); Watch.doneToday("suboffers-\(appID)") }
                catch { note("subscription_offers", error) }
            }
            if Budget.left, Watch.dueToday("perf-\(appID)") {
                do { events += try await Watch.performance(appID: appID, app: name, get: g); watch["performance"] = watch["performance"] ?? .string("ok"); Watch.doneToday("perf-\(appID)") } catch { note("performance", error) }
            }
        }
        // Apple's official monthly finance reports (published ~1 week after a fiscal month ends). Months are named like
        // Apple's payments page ("2026-09" = September 2026) and asked for by Apple's fiscal period number (September =
        // "2026-12"; see Sales.reportDate). Daily: this month and the 3 before (a month not out yet answers 404); once:
        // the 8 before those, so the whole year is there. Earlier versions asked for the calendar name and stored June's
        // report as September's: those events have no "report_date" and the app ignores them.
        if Budget.left, Watch.dueToday("finance2"), let vendor = await core.settings[path: "vendorNumber"]?.string?.trimmingCharacters(in: .whitespaces), !vendor.isEmpty {
            do {
                let backfill = Watch.dueOnce("finance2-backfill")
                for back in 0...(backfill ? 11 : 3) {
                    let name = Calendar(identifier: .gregorian).date(byAdding: .month, value: -back, to: .now)!.formatted(.iso8601.year().month())
                    guard let report = Sales.reportDate(forFiscalName: name),
                          let totals = try await Sales.finance(vendor: vendor, month: report, core: core) else { continue }
                    events.append(PluginEvent(kind: "finance.month", app: nil,
                                              payload: .object(["month": .string(name), "report_date": .string(report),
                                                                "totals": .object(totals.mapValues { .number(($0 * 100).rounded() / 100) })]),
                                              occurredAt: Int64(Date.now.timeIntervalSince1970 * 1000), dedupeKey: "finance2-\(name)-\(Self.today())"))
                }
                if backfill { Watch.doneOnce("finance2-backfill") }
                watch["finance"] = .string("ok"); Watch.doneToday("finance2")
            } catch { note("finance", error) }
        }
        if Budget.left, Watch.dueToday("expiry") { do { events.append(try await Watch.expiry(get: g)); watch["expiry"] = .string("ok"); Watch.doneToday("expiry") } catch { note("expiry", error) } }
        if Budget.left, Watch.dueToday("nominations") { do { events.append(try await Watch.nominations(get: g)); watch["nominations"] = .string("ok"); Watch.doneToday("nominations") } catch { note("nominations", error) } }
        events.append(PluginEvent(kind: "asc.watch", app: nil, payload: .object(watch),
                                  occurredAt: Int64(Date.now.timeIntervalSince1970 * 1000), dedupeKey: "asc-watch-\(Int(Date.now.timeIntervalSince1970) / 600)"))   // one per 10 minutes: fresh enough, without a row every run
        // Daily sales need the vendor number; without it the add-on simply skips them.
        if let vendor = await core.settings[path: "vendorNumber"]?.string?.trimmingCharacters(in: .whitespaces),
           !vendor.isEmpty {
            events += await Sales.events(vendor: vendor, apps: apps[path: "data"]?.array ?? [], core: core)
            events += await Subscriptions.events(vendor: vendor, apps: apps[path: "data"]?.array ?? [], core: core)
            events += await SubEvents.events(vendor: vendor, apps: apps[path: "data"]?.array ?? [], core: core)
        }
        return events
    }

    /// Apple's platform values (IOS covers iPhone, iPad and Apple Watch: Apple counts watch-only apps as iOS). Anything else -> IOS.
    static func platform(_ p: String) -> String { ["IOS", "MAC_OS", "TV_OS", "VISION_OS"].contains(p) ? p : "IOS" }

    /// Versions of every platform, iPhone/iPad first, then Mac, Apple TV and Vision Pro, each newest first as Apple
    /// sends them. So an iOS app keeps its old behaviour and a Mac-, TV- or visionOS-only app is tracked too.
    static func byPlatform(_ list: [JSONValue]) -> [JSONValue] {
        let order = ["IOS": 0, "MAC_OS": 1, "TV_OS": 2, "VISION_OS": 3]
        return list.enumerated().sorted {
            let a = order[$0.element[path: "attributes.platform"]?.string ?? "IOS"] ?? 0
            let b = order[$1.element[path: "attributes.platform"]?.string ?? "IOS"] ?? 0
            return a != b ? a < b : $0.offset < $1.offset
        }.map(\.element)
    }

    /// The newest build with its TestFlight state (internal and external testing).
    private func latestBuild(appID: String, version: String? = nil, platform: String = "IOS", core: Core) async throws -> JSONValue? {
        let only = version.flatMap { $0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) }
            .map { "&filter%5BpreReleaseVersion.version%5D=\($0)&filter%5BpreReleaseVersion.platform%5D=\(Self.platform(platform))" } ?? ""
        let url = "\(Self.base)/builds?filter%5Bapp%5D=\(appID)\(only)&sort=-uploadedDate&limit=1"
            + "&fields%5Bbuilds%5D=version,uploadedDate,processingState,iconAssetToken,buildBetaDetail&include=buildBetaDetail"
            + "&fields%5BbuildBetaDetails%5D=internalBuildState,externalBuildState"
        let body = try await get(url, core: core)
        guard var build = body[path: "data"]?.array?.first, case .object(var o) = build else { return nil }
        if let beta = body[path: "included"]?.array?.first?[path: "attributes"] { o["beta"] = beta }
        build = .object(o)
        return build
    }

    /// The icon Apple rendered for a build, as a 256-pixel PNG link.
    private func iconURL(_ build: JSONValue) -> String? {
        guard let template = build[path: "attributes.iconAssetToken.templateUrl"]?.string else { return nil }
        return template.replacingOccurrences(of: "{w}", with: "256").replacingOccurrences(of: "{h}", with: "256")
            .replacingOccurrences(of: "{f}", with: "png")
    }

    /// The live version (if any) and the newest version still on its way, with raw App Store states.
    private func releaseState(appID: String, build: JSONValue?, core: Core) async throws -> JSONValue {
        let versions = try await get("\(Self.base)/apps/\(appID)/appStoreVersions?limit=20"
            + "&fields%5BappStoreVersions%5D=versionString,appStoreState,appVersionState,createdDate,platform", core: core)
        let list = Self.byPlatform(versions[path: "data"]?.array ?? [])
        let liveStates: Set<String> = ["READY_FOR_SALE", "READY_FOR_DISTRIBUTION"]
        let doneStates: Set<String> = ["REPLACED_WITH_NEW_VERSION", "REMOVED_FROM_SALE", "DEVELOPER_REMOVED_FROM_SALE"]
        func state(_ v: JSONValue) -> String { v[path: "attributes.appVersionState"]?.string ?? v[path: "attributes.appStoreState"]?.string ?? "" }
        let live = list.first { liveStates.contains(state($0)) }
        let next = list.first { !liveStates.contains(state($0)) && !doneStates.contains(state($0)) }
        var out: [String: JSONValue] = ["live": .bool(live != nil)]
        if let live {
            out["live_version"] = live[path: "attributes.versionString"] ?? .null
            out["live_version_id"] = live[path: "id"] ?? .null
            if let liveID = live[path: "id"]?.string {
                let cache = State.file("live-copy-\(appID)-\(liveID).json")
                if let data = try? Data(contentsOf: cache),
                   let cached = try? JSONDecoder().decode([String: String].self, from: data),
                   !(cached["description"] ?? "").isEmpty || !(cached["whats_new"] ?? "").isEmpty {
                    if let desc = cached["description"], !desc.isEmpty { out["live_description"] = .string(desc) }
                    if let wn = cached["whats_new"], !wn.isEmpty { out["live_whats_new"] = .string(wn) }
                } else if let body = try? await get("\(Self.base)/appStoreVersions/\(liveID)/appStoreVersionLocalizations?limit=20&fields%5BappStoreVersionLocalizations%5D=locale,description,whatsNew", core: core) {
                    let locs = body[path: "data"]?.array ?? []
                    let picked = locs.first { $0[path: "attributes.locale"]?.string == "en-US" }
                        ?? locs.first { ($0[path: "attributes.locale"]?.string ?? "").hasPrefix("en") }
                        ?? locs.first { !($0[path: "attributes.description"]?.string ?? "").isEmpty }
                    let desc = String((picked?[path: "attributes.description"]?.string ?? "").prefix(4000))
                    let wn = String((picked?[path: "attributes.whatsNew"]?.string ?? "").prefix(2000))
                    var copy: [String: String] = [:]
                    if !desc.isEmpty { copy["description"] = desc; out["live_description"] = .string(desc) }
                    if !wn.isEmpty { copy["whats_new"] = wn; out["live_whats_new"] = .string(wn) }
                    if !copy.isEmpty, let data = try? JSONEncoder().encode(copy) { StateFile.write(data, to: cache) }
                }
            }
        }
        if let next {
            out["version_id"] = next[path: "id"] ?? .null
            out["version"] = next[path: "attributes.versionString"] ?? .null
            out["state"] = .string(state(next))
            out["version_created"] = next[path: "attributes.createdDate"] ?? .null
        }
        if let p = (next ?? live)?[path: "attributes.platform"]?.string { out["platform"] = .string(Self.platform(p)) }
        // The build that belongs to the version on its way (not the live version's build); none yet → no TestFlight claim.
        let build = next == nil ? build
            : (try? await latestBuild(appID: appID, version: next?[path: "attributes.versionString"]?.string,
                                    platform: next?[path: "attributes.platform"]?.string ?? "IOS", core: core)) ?? nil
        if let build {
            out["build"] = build[path: "attributes.version"] ?? .null
            out["build_uploaded"] = build[path: "attributes.uploadedDate"] ?? .null
            out["build_processing"] = build[path: "attributes.processingState"] ?? .null
            out["testflight_internal"] = build[path: "beta.internalBuildState"] ?? .null
            out["testflight_external"] = build[path: "beta.externalBuildState"] ?? .null
        }
        return .object(out)
    }

    /// Active offer codes on this app's in-app purchases. Chain (no "by name" endpoint exists):
    /// app -> inAppPurchasesV2 -> offerCodes -> customCodes / oneTimeUseCodes. Only active codes; an inactive
    /// code can share a name on an old purchase, so we never match by name alone.
    private func offerCodes(appID: String, core: Core) async throws -> JSONValue {
        let root = "https://api.appstoreconnect.apple.com"
        let iaps = try await get("\(root)/v1/apps/\(appID)/inAppPurchasesV2?limit=50&fields%5BinAppPurchases%5D=name,productId,state", core: core)
        var offers: [JSONValue] = []
        for iap in iaps[path: "data"]?.array ?? [] {
            guard let iapID = iap[path: "id"]?.string else { continue }
            guard let codes = try? await get("\(root)/v2/inAppPurchases/\(iapID)/offerCodes?limit=50", core: core) else { continue }
            for code in codes[path: "data"]?.array ?? [] where code[path: "attributes.active"] != .bool(false) {
                guard let codeID = code[path: "id"]?.string else { continue }
                var o: [String: JSONValue] = [
                    "id": .string(codeID), "name": code[path: "attributes.name"] ?? .null,
                    "product": iap[path: "attributes.name"] ?? .null, "product_id": iap[path: "attributes.productId"] ?? .null,
                    "iap_id": .string(iapID), "app_id": .string(appID),
                ]
                if let custom = try? await get("\(root)/v1/inAppPurchaseOfferCodes/\(codeID)/customCodes?limit=20", core: core) {
                    o["custom"] = .array((custom[path: "data"]?.array ?? []).filter { $0[path: "attributes.active"] != .bool(false) }.map { c in
                        .object(["code": c[path: "attributes.customCode"] ?? .null, "count": c[path: "attributes.numberOfCodes"] ?? .null,
                                 "expires": c[path: "attributes.expirationDate"] ?? .null])
                    })
                }
                if let batches = try? await get("\(root)/v1/inAppPurchaseOfferCodes/\(codeID)/oneTimeUseCodes?limit=50", core: core) {
                    o["batches"] = .array((batches[path: "data"]?.array ?? []).filter { $0[path: "attributes.active"] != .bool(false) }.map { b in
                        .object(["id": b[path: "id"] ?? .null, "count": b[path: "attributes.numberOfCodes"] ?? .null,
                                 "expires": b[path: "attributes.expirationDate"] ?? .null,
                                 "environment": b[path: "attributes.environment"] ?? .null])
                    })
                }
                offers.append(.object(o))
            }
        }
        return .object(["app_id": .string(appID), "offers": .array(offers)])
    }

    /// One cheap read per area; the status code says whether the key's role allows it (403 = role too narrow).
    private func access(apps: JSONValue, core: Core) async -> JSONValue {
        let list = apps[path: "data"]?.array ?? []
        var out: [String: JSONValue] = ["key": .string("ok"), "apps": .number(Double(list.count))]
        func status(_ url: String) async -> String {
            guard let r = try? await core.http(HTTPRequestSpec(url: url, headers: ["Authorization": "Bearer {{asc-jwt}}"])) else { return "error" }
            return r.status == 200 ? "ok" : r.status == 403 ? "role" : r.status == 404 ? "ok" : "error"
        }
        if let id = list.first?[path: "id"]?.string {
            out["reviews"] = .string(await status("\(Self.base)/apps/\(id)/customerReviews?limit=1"))
            out["offer_codes"] = .string(await status("\(Self.base)/apps/\(id)/inAppPurchasesV2?limit=1"))
        }
        if let vendor = await core.settings[path: "vendorNumber"]?.string?.trimmingCharacters(in: .whitespaces), !vendor.isEmpty {
            let day = Date.now.addingTimeInterval(-3 * 86_400).formatted(.iso8601.year().month().day())
            out["sales"] = .string(await status("\(Self.base)/salesReports?filter%5Bfrequency%5D=DAILY"
                + "&filter%5BreportType%5D=SALES&filter%5BreportSubType%5D=SUMMARY&filter%5BvendorNumber%5D=\(vendor)&filter%5BreportDate%5D=\(day)"))
            let month = Calendar(identifier: .gregorian).date(byAdding: .month, value: -2, to: .now)!.formatted(.iso8601.year().month())
            out["finance"] = .string(await status("\(Self.base)/financeReports?filter%5BregionCode%5D=ZZ&filter%5BreportType%5D=FINANCIAL"
                + "&filter%5BvendorNumber%5D=\(vendor)&filter%5BreportDate%5D=\(month)"))
        } else {
            out["sales"] = .string("no_vendor"); out["finance"] = .string("no_vendor")
        }
        return .object(out)
    }

    /// Remembers which version was checked in which 6-hour slot (in the add-on's own temp folder), so a manual
    /// "Check now" in between doesn't repeat the heavy read.
    /// Read only: is this version's check still to do in this 6-hour slot?
    static func shieldDue(_ versionID: String, slot: Int) -> Bool {
        let f = State.file("hm-shield-\(versionID)")
        return (try? String(contentsOf: f, encoding: .utf8)) != "\(today())-\(slot)"
    }

    /// Counts this slot's tries (1 on the first).
    static func shieldTry(_ versionID: String, slot: Int) -> Int {
        let f = State.file("hm-shield-try-\(versionID)")
        let key = "\(today())-\(slot)"
        let parts = ((try? String(contentsOf: f, encoding: .utf8)) ?? "").split(separator: ":")
        let n = (parts.count == 2 && String(parts[0]) == key ? Int(parts[1]) ?? 0 : 0) + 1
        StateFile.write("\(key):\(n)", to: f)
        return n
    }

    /// Marks the slot done, only after a check that read everything (or its last try).
    static func shieldDone(_ versionID: String, slot: Int) {
        let f = State.file("hm-shield-\(versionID)")
        Pending.note(f, "\(today())-\(slot)")
    }

    static func hour() -> String { Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).prefix(13).description }

    static func today() -> String {
        Date.now.formatted(.iso8601.year().month().day())
    }

    /// Rejection Shield fixes. Each returns what was there before, so the app can undo it.
    func act(action: String, params: JSONValue, core: Core) async throws -> JSONValue {
        // The app saved this check's events: now its "done" notes are written.
        if action == "ack" { return .object(["written": .number(Double(Pending.flush()))]) }
        guard action == "asc.fix" else { throw WireError("unknown_action", "No action \(action)") }
        return try await ShieldFix.run(params, send: { method, url, body in try await send(method, url, body, core: core) },
                                       get: { try await get($0, core: core) })
    }

    /// A write to App Store Connect (PATCH/POST/DELETE); a role or validation error comes back in plain words.
    func send(_ method: String, _ url: String, _ body: JSONValue?, core: Core) async throws -> JSONValue {
        let text = try body.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        let response = try await core.http(HTTPRequestSpec(method: method, url: url,
                                                           headers: ["Authorization": "Bearer {{asc-jwt}}", "Content-Type": "application/json"],
                                                           body: text))
        let parsed = (try? JSONValue.parse(response.body ?? "")) ?? .null
        guard (200..<300).contains(response.status) else {
            if response.status == 403 { throw WireError("asc_role", "Your App Store Connect key's role can't change this. Use an Admin or App Manager key.") }
            let detail = parsed[path: "errors"]?.array?.first?[path: "detail"]?.string ?? "status \(response.status)"
            throw WireError("asc_failed", "App Store Connect said: \(detail)")
        }
        return parsed
    }

    func get(_ url: String, core: Core) async throws -> JSONValue {
        let response = try await core.http(HTTPRequestSpec(url: url, headers: ["Authorization": "Bearer {{asc-jwt}}"]))
        let body = (try? JSONValue.parse(response.body ?? "")) ?? .null
        if response.status == 429 {
            // Apple limits requests per key per hour, and this key may also be used by other tools: name it, don't call it a failure.
            throw WireError("asc_rate_limited", "App Store Connect: this key has reached its hourly request limit (shared with any other tool using it). Hmunmawi tries again on the next check.")
        }
        guard response.status == 200 else {
            // Which reads come back "not found" (each still counts as a request): logged so they can be skipped.
            if response.status == 404 { core.log("404 \(url.split(separator: "?").first.map(String.init) ?? url)") }
            let detail = body[path: "errors"]?.array?.first?[path: "detail"]?.string ?? "status \(response.status)"
            throw WireError("asc_failed", "App Store Connect: \(detail)")
        }
        return body
    }
}

await PluginRuntime.run(AppStoreConnect())


private extension String {
    /// The same number on every run (Swift's hashValue changes per launch, which would make every check a new event).
    var hashValueStable: String { String(utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }, radix: 36) }
}
