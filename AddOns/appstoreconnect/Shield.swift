import Foundation
import HmunmawiPluginKit

/// Rejection Shield: reads the version you're preparing and lists what Apple would bounce or what's missing,
/// compared with the live version. Read-only; never submits anything. Each item:
/// {id, title, ok, detail, level: "block" | "warn" | "manual"}.
enum Shield {
    typealias Get = @Sendable (String) async throws -> JSONValue
    static let v1 = "https://api.appstoreconnect.apple.com/v1"

    static func check(appID: String, versionID: String, liveID: String?, version: String, state: String, get: @escaping Get) async -> JSONValue {
        var items: [JSONValue] = []
        var unread: [String] = []
        /// Every read goes through here: a failure is recorded and shown, never skipped quietly.
        func read(_ url: String, _ what: String) async -> JSONValue? {
            do { return try await get(url) } catch {
                unread.append("\(what) (\(String(describing: error).prefix(80)))")
                return nil
            }
        }
        func add(_ id: String, _ title: String, ok: Bool, _ detail: String = "", level: String = "block", extra: [String: JSONValue] = [:]) {
            var o: [String: JSONValue] = ["id": .string(id), "title": .string(title), "ok": .bool(ok), "detail": .string(detail), "level": .string(level)]
            o.merge(extra) { a, _ in a }
            items.append(.object(o))
        }
        func localeList(_ list: [JSONValue]) -> [String: JSONValue] {
            ["locales": .array(list.compactMap { $0[path: "attributes.locale"]?.string }.map(JSONValue.string))]
        }

        // 1. Text per language: What's New (not needed on a first release), promotional text, description, keywords.
        let locs = (await read("\(v1)/appStoreVersions/\(versionID)/appStoreVersionLocalizations?limit=50", "Languages"))?[path: "data"]?.array ?? []
        func empty(_ l: JSONValue, _ f: String) -> Bool { (l[path: "attributes.\(f)"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        func codes(_ list: [JSONValue]) -> String { list.compactMap { $0[path: "attributes.locale"]?.string }.joined(separator: ", ") }
        if liveID != nil {
            let noNew = locs.filter { empty($0, "whatsNew") }
            add("whats_new", "What's New in every language", ok: noNew.isEmpty,
                noNew.isEmpty ? "\(locs.count) of \(locs.count) filled" : "Empty in \(noNew.count) of \(locs.count): \(codes(noNew))",
                extra: localeList(noNew).merging(["all_locales": .array(locs.compactMap { $0[path: "attributes.locale"]?.string }.map(JSONValue.string))]) { a, _ in a })
        }
        let noPromo = locs.filter { empty($0, "promotionalText") }
        add("promo", "Promotional text in every language", ok: noPromo.isEmpty,
            noPromo.isEmpty ? "\(locs.count) of \(locs.count) filled" : "Empty in \(noPromo.count): \(codes(noPromo))", level: "warn", extra: localeList(noPromo))
        let noDesc = locs.filter { empty($0, "description") || empty($0, "keywords") }
        add("description", "Description and keywords", ok: noDesc.isEmpty, noDesc.isEmpty ? "All languages" : "Missing in \(codes(noDesc))")

        // 2. Screenshots per language and device size, fully uploaded, and no fewer than the live version has.
        // The live version never changes, so its counts are read once per live version and kept.
        let live = liveID == nil ? nil : await liveCounts(liveID!, get: get)
        let liveCounts = live?.counts ?? [:]
        let now = await screenshotCounts(versionID: versionID, get: get)
        if now.failed + (live?.failed ?? 0) > 0 { unread.append("Screenshots for \(now.failed + (live?.failed ?? 0)) language(s)") }
        var fewer: [String] = []
        for (key, n) in liveCounts where (now.counts[key] ?? 0) < n { fewer.append("\(key): \(now.counts[key] ?? 0) vs \(n)") }
        add("screenshots", "Screenshots in every language and size", ok: fewer.isEmpty && !now.counts.isEmpty,
            now.counts.isEmpty ? "No screenshots found" : fewer.isEmpty ? "\(now.counts.values.reduce(0, +)) screenshots" + (liveID == nil ? " across \(Set(now.counts.keys.map { $0.split(separator: " ").first ?? "" }).count) languages" : ", none missing vs live")
                : "Fewer than live: " + fewer.sorted().prefix(6).joined(separator: "; ") + (fewer.count > 6 ? " and \(fewer.count - 6) more" : ""))
        add("uploads", "Screenshots finished uploading", ok: now.notReady == 0,
            now.notReady == 0 ? "All processed" : "\(now.notReady) still uploading or failed")

        // 3. Build attached, processed, encryption answered.
        if let build = (await read("\(v1)/appStoreVersions/\(versionID)/build", "Build"))?[path: "data"], build != .null {
            let processing = build[path: "attributes.processingState"]?.string ?? ""
            add("build", "Build attached and processed", ok: processing == "VALID",
                "Build \(build[path: "attributes.version"]?.string ?? "") · \(processing.lowercased())")
            add("encryption", "Encryption question answered", ok: build[path: "attributes.usesNonExemptEncryption"] != .null
                && build[path: "attributes.usesNonExemptEncryption"] != nil, "Export compliance for this build")
        } else {
            add("build", "Build attached and processed", ok: false, "No build picked for this version yet")
        }

        // 4. Notes for Apple's reviewer.
        let review = (await read("\(v1)/appStoreVersions/\(versionID)/appStoreReviewDetail", "Reviewer notes"))?[path: "data"]
        let notes = (review?[path: "attributes.notes"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        add("review_notes", "Notes for the reviewer", ok: !notes.isEmpty, notes.isEmpty ? "Empty: say what's new and where to find it" : "\(notes.count) characters", level: "warn")
        let contact = (review?[path: "attributes.contactEmail"]?.string ?? "").isEmpty == false
        add("contact", "Reviewer contact details", ok: contact, contact ? "Filled" : "Add a contact email and phone")

        // 5. Age rating questions (unanswered ones block submission).
        if let infos = (await read("\(v1)/apps/\(appID)/appInfos?limit=5", "App info"))?[path: "data"]?.array,
           let info = infos.first(where: { !["READY_FOR_DISTRIBUTION", "READY_FOR_SALE"].contains($0[path: "attributes.state"]?.string ?? $0[path: "attributes.appStoreState"]?.string ?? "") }) ?? infos.first,
           let infoID = info[path: "id"]?.string,
           let age = (await read("\(v1)/appInfos/\(infoID)/ageRatingDeclaration", "Age rating"))?[path: "data.attributes"], case .object(let fields) = age {
            // Optional fields (overrides, kids band, info link) are not questions; only real questions count.
            let optional = ["override", "kidsageband", "url", "seventeenplus", "grac"]   // GRAC: Korea games only
            let blank = fields.filter { f in f.value == .null && !optional.contains { f.key.lowercased().contains($0) } }.map(\.key).sorted()
            func words(_ k: String) -> String { k.replacing(/([a-z])([A-Z])/) { "\($0.1) \($0.2)" }.lowercased() }
            add("age_rating", "Age rating questions answered", ok: blank.isEmpty,
                blank.isEmpty ? "All answered" : "\(blank.count) unanswered, e.g. " + blank.prefix(3).map(words).joined(separator: ", "))
        }

        // 6. In-app events: both images (card 16:9 and details page 9:16) in every language.
        if let ev = (await read("\(v1)/apps/\(appID)/appEvents?limit=20", "In-app events"))?[path: "data"]?.array {
            var gaps: [String] = []
            // Only events still on their way (published, past and archived ones can't be fixed anymore).
            for e in ev where ["DRAFT", "READY_FOR_REVIEW", "WAITING_FOR_REVIEW", "IN_REVIEW", "REJECTED", "ACCEPTED", "APPROVED"]
                .contains(e[path: "attributes.eventState"]?.string ?? "") {
                guard let eid = e[path: "id"]?.string else { continue }
                let name = e[path: "attributes.referenceName"]?.string ?? "Event"
                for l in (await read("\(v1)/appEvents/\(eid)/localizations?limit=50", "Event languages"))?[path: "data"]?.array ?? [] {
                    guard let lid = l[path: "id"]?.string else { continue }
                    let shots = (await read("\(v1)/appEventLocalizations/\(lid)/appEventScreenshots?limit=10", "Event images"))?[path: "data"]?.array ?? []
                    let clips = (await read("\(v1)/appEventLocalizations/\(lid)/appEventVideoClips?limit=10", "Event videos"))?[path: "data"]?.array ?? []
                    let types = Set((shots + clips).compactMap { $0[path: "attributes.appEventAssetType"]?.string })
                    if !types.contains("EVENT_CARD") || !types.contains("EVENT_DETAILS_PAGE") {
                        gaps.append("\(name) (\(l[path: "attributes.locale"]?.string ?? "?"))")
                    }
                }
            }
            if !ev.isEmpty {
                add("events", "In-app event images (card + details page)", ok: gaps.isEmpty,
                    gaps.isEmpty ? "Every language has both" : "Missing in " + gaps.prefix(5).joined(separator: ", ") + (gaps.count > 5 ? " and \(gaps.count - 5) more" : ""))
            }
        }

        // 7. Accessibility labels declared.
        if let acc = (await read("\(v1)/apps/\(appID)/accessibilityDeclarations?limit=10", "Accessibility labels"))?[path: "data"]?.array {
            add("accessibility", "Accessibility labels declared", ok: !acc.isEmpty, acc.isEmpty ? "None yet (shown on your product page)" : "\(acc.count) device type\(acc.count == 1 ? "" : "s")", level: "warn")
        }

        // 8. Things the API can't see: check by hand.
        add("privacy", "Privacy labels match what the app collects", ok: false, "App Store Connect → App Privacy", level: "manual")
        add("agreements", "Agreements, tax and banking active", ok: false, "App Store Connect → Business", level: "manual")

        if !unread.isEmpty {
            add("unread", "Couldn't check everything this time", ok: false,
                unread.prefix(4).joined(separator: "; ") + (unread.count > 4 ? " and \(unread.count - 4) more" : "") + ". Tries again next round.", level: "warn")
        }
        let blocking = items.filter { $0[path: "ok"] == .bool(false) && $0[path: "level"]?.string == "block" }.count
        return .object(["version": .string(version), "state": .string(state), "version_id": .string(versionID), "app_id": .string(appID), "live_version_id": liveID.map(JSONValue.string) ?? .null,
                        "checked_at": .number(Date.now.timeIntervalSince1970 * 1000),
                        "blocking": .number(Double(blocking)), "items": .array(items)])
    }

    static func liveCounts(_ id: String, get: @escaping Get) async -> (counts: [String: Int], notReady: Int, failed: Int) {
        let f = State.file("shield-live-\(id).json")
        if let d = try? Data(contentsOf: f), let c = try? JSONDecoder().decode([String: Int].self, from: d), !c.isEmpty { return (c, 0, 0) }
        let r = await screenshotCounts(versionID: id, get: get)
        if r.failed == 0, !r.counts.isEmpty { (try? JSONEncoder().encode(r.counts)).map { StateFile.write($0, to: f) } }
        return r
    }

    /// Screenshot counts per "locale · device size", and how many aren't fully processed yet. Languages are read
    /// six at a time so a 20-language app finishes in seconds, well inside the poll's time limit.
    static func screenshotCounts(versionID: String, get: @escaping Get) async -> (counts: [String: Int], notReady: Int, failed: Int) {
        guard let list = try? await get("\(v1)/appStoreVersions/\(versionID)/appStoreVersionLocalizations?limit=50") else { return ([:], 0, 1) }
        let locs = list[path: "data"]?.array ?? []
        let pairs = locs.compactMap { l -> (String, String)? in
            guard let id = l[path: "id"]?.string, let loc = l[path: "attributes.locale"]?.string else { return nil }
            return (id, loc)
        }
        var counts: [String: Int] = [:], notReady = 0, failed = 0
        for chunk in stride(from: 0, to: pairs.count, by: 6).map({ Array(pairs[$0..<min($0 + 6, pairs.count)]) }) {
            await withTaskGroup(of: (String, JSONValue?).self) { group in
                for (lid, locale) in chunk {
                    group.addTask { (locale, try? await get("\(v1)/appStoreVersionLocalizations/\(lid)/appScreenshotSets?include=appScreenshots&limit=50")) }
                }
                for await (locale, sets) in group {
                    if sets == nil { failed += 1; continue }
                    for set in sets?[path: "data"]?.array ?? [] {
                        let type = (set[path: "attributes.screenshotDisplayType"]?.string ?? "?").replacingOccurrences(of: "APP_", with: "")
                        counts["\(locale) · \(type)"] = set[path: "relationships.appScreenshots.data"]?.array?.count ?? 0
                    }
                    notReady += (sets?[path: "included"]?.array ?? []).filter { $0[path: "attributes.assetDeliveryState.state"]?.string != "COMPLETE" }.count
                }
            }
        }
        return (counts, notReady, failed)
    }
}
