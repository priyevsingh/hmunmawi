import Foundation
import HmunmawiCore
import Observation

/// App-layer manager for opt-in release subscribers: storage, App Store release notes lookup,
/// new-release auto-drafting, incoming mail unsubscribe/bounce handling, and individual batch sends.
@MainActor @Observable
final class ReleaseSubscribers {
    static let shared = ReleaseSubscribers()

    private(set) var book: ReleaseSubscribersBook
    let url: URL

    init(url: URL = URL.hmSupport.appending(path: ReleaseSubscribersStore.fileName)) {
        self.url = url
        self.book = ReleaseSubscribersStore.load(url)
    }

    func reload() {
        book = ReleaseSubscribersStore.load(url)
    }

    private func persist() {
        ReleaseSubscribersStore.save(book, to: url)
    }

    // MARK: - Subscribers & Per-App Config

    func subscribers(forApp app: String?) -> [ReleaseSubscriber] {
        let filtered: [ReleaseSubscriber]
        if let app, !app.isEmpty, app != "all" {
            filtered = book.subscribers.filter { $0.subscribed(toApp: app) }
        } else {
            filtered = book.subscribers
        }
        return filtered.sorted {
            if $0.addedAt != $1.addedAt { return $0.addedAt > $1.addedAt }
            return $0.email.localizedCaseInsensitiveCompare($1.email) == .orderedAscending
        }
    }

    func activeCount(forApp app: String) -> Int {
        subscribers(forApp: app).filter(\.isActive).count
    }

    func config(forApp app: String) -> ReleaseNotifyAppConfig {
        let target = app.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = book.configs[target] { return exact }
        if let match = book.configs.first(where: { $0.key.caseInsensitiveCompare(target) == .orderedSame }) {
            return match.value
        }
        return ReleaseNotifyAppConfig()
    }

    func setConfig(_ cfg: ReleaseNotifyAppConfig, forApp app: String) {
        let target = app.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        for key in book.configs.keys where key != target && key.caseInsensitiveCompare(target) == .orderedSame {
            book.configs.removeValue(forKey: key)
        }
        book.configs[target] = cfg
        persist()
    }

    @discardableResult
    func importCSV(_ raw: String, defaultApps: [String]) -> ReleaseSubscribersStore.UpsertSummary {
        let summary = ReleaseSubscribersStore.upsert(
            book: &book,
            raw: raw,
            defaultApps: defaultApps,
            today: Date.now.localDay
        )
        if summary.added > 0 || summary.updatedApps > 0 || summary.duplicates > 0 {
            persist()
        }
        return summary
    }

    @discardableResult
    func remove(email: String, app: String? = nil) -> Bool {
        let changed = ReleaseSubscribersStore.remove(book: &book, email: email, app: app)
        if changed { persist() }
        return changed
    }

    @discardableResult
    func reactivate(email: String) -> Bool {
        let changed = ReleaseSubscribersStore.reactivate(book: &book, email: email)
        if changed { persist() }
        return changed
    }

    @discardableResult
    func undoMailAction(_ rec: ReleaseMailRecord) -> Bool {
        guard rec.undone != true else { return false }
        if let idx = book.mailActions?.firstIndex(where: { $0.id == rec.id }),
           book.mailActions?[idx].undone == true {
            return false
        }
        guard let subIdx = book.subscribers.firstIndex(where: {
            $0.email.caseInsensitiveCompare(rec.email) == .orderedSame
        }) else {
            return false
        }
        switch rec.kind {
        case .unsubscribe:
            guard book.subscribers[subIdx].unsubscribedAt != nil else { return false }
            book.subscribers[subIdx].unsubscribedAt = nil
        case .bounce:
            guard book.subscribers[subIdx].bouncedAt != nil else { return false }
            book.subscribers[subIdx].bouncedAt = nil
        }
        if let idx = book.mailActions?.firstIndex(where: { $0.id == rec.id }) {
            book.mailActions?[idx].undone = true
        }
        persist()
        return true
    }

    // MARK: - App Metadata & What's New

    func resolveAppID(app: String, model: AppModel) -> String? {
        let target = ComingSoon.shortName(app)
        guard !target.isEmpty else { return nil }
        for kind in ["app.snapshot", "release.snapshot", "icon.snapshot", "offercodes.snapshot"] {
            for snap in model.snapshots(kind) {
                guard let snapApp = snap.app,
                      ComingSoon.shortName(snapApp).caseInsensitiveCompare(target) == .orderedSame else { continue }
                if let raw = snap.payload[path: "app_id"]?.string ?? snap.payload[path: "appID"]?.string,
                   let clean = raw.trimmedNilIfEmpty {
                    return clean
                }
            }
        }
        for appID in OfferCodes.shared.appIDs {
            if ComingSoon.shortName(QuickName.of(appID, model: model)).caseInsensitiveCompare(target) == .orderedSame {
                return appID
            }
        }
        return nil
    }

    func liveVersion(app: String, model: AppModel) -> String? {
        let target = ComingSoon.shortName(app)
        guard !target.isEmpty else { return nil }
        for snap in model.snapshots("release.snapshot").sorted(by: { $0.occurredAt > $1.occurredAt }) {
            guard let snapApp = snap.app,
                  ComingSoon.shortName(snapApp).caseInsensitiveCompare(target) == .orderedSame,
                  snap.payload[path: "live"] == .bool(true),
                  let ver = snap.payload[path: "live_version"]?.string?.trimmedNilIfEmpty else { continue }
            return ver
        }
        for snap in model.snapshots("app.snapshot").sorted(by: { $0.occurredAt > $1.occurredAt }) {
            guard let snapApp = snap.app,
                  ComingSoon.shortName(snapApp).caseInsensitiveCompare(target) == .orderedSame,
                  let ver = snap.payload[path: "version"]?.string?.trimmedNilIfEmpty else { continue }
            return ver
        }
        return nil
    }

    func fetchWhatsNew(app: String, appID: String?, model: AppModel) async -> String? {
        let target = ComingSoon.shortName(app)
        if !target.isEmpty {
            for kind in ["release.check", "release.snapshot"] {
                for snap in model.snapshots(kind).sorted(by: { $0.occurredAt > $1.occurredAt }) {
                    guard let snapApp = snap.app,
                          ComingSoon.shortName(snapApp).caseInsensitiveCompare(target) == .orderedSame else { continue }
                    let raw = [
                        snap.payload[path: "live_whats_new"]?.string,
                        snap.payload[path: "whats_new"]?.string,
                        snap.payload[path: "whatsNew"]?.string,
                        snap.payload[path: "releaseNotes"]?.string,
                    ].compactMap { $0?.trimmedNilIfEmpty }.first
                    if let cleaned = ReleaseNotifyTemplate.cleanWhatsNew(raw) {
                        return cleaned
                    }
                }
            }
        }
        guard let cleanID = appID?.trimmedNilIfEmpty else { return nil }
        var comps = URLComponents(string: "https://itunes.apple.com/lookup")
        comps?.queryItems = [URLQueryItem(name: "id", value: cleanID)]
        guard let lookupURL = comps?.url else { return nil }

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 10
        sessionConfig.timeoutIntervalForResource = 10
        let session = URLSession(configuration: sessionConfig)
        defer { session.finishTasksAndInvalidate() }

        guard let (data, response) = try? await session.data(from: lookupURL),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              let notes = results.first?["releaseNotes"] as? String else {
            return nil
        }
        return ReleaseNotifyTemplate.cleanWhatsNew(notes)
    }

    // MARK: - Drafting & Release Detection

    func draftNotification(
        app: String,
        version: String? = nil,
        whatsNew: String? = nil,
        model: AppModel,
        customSubject: String? = nil,
        customBody: String? = nil
    ) async -> (ok: Bool, note: String, jobID: Int64?) {
        guard let ver = version?.trimmedNilIfEmpty ?? liveVersion(app: app, model: model) else {
            return (false, "No live version found for \(app).", nil)
        }

        let appID = resolveAppID(app: app, model: model)
        let appStoreURL = appID.map { "https://apps.apple.com/app/id\($0)" } ?? "https://escapethematrix.app"

        let recipients = ReleaseSubscribersStore.eligibleRecipients(in: book, app: app, version: ver)
        if recipients.isEmpty {
            return (false, "No active unsent subscribers for \(app) \(ver).", nil)
        }

        if let existing = model.waiting.first(where: { action in
            action.job.kind == "release.notify" &&
            (action.job.payload[path: "app"]?.string ?? "").caseInsensitiveCompare(app) == .orderedSame &&
            (action.job.payload[path: "version"]?.string ?? "") == ver
        }) {
            return (false, "A notification draft for \(app) \(ver) is already waiting in Log → Needs your OK.", existing.id)
        }

        let resolvedWhatsNew: String?
        if let whatsNew {
            resolvedWhatsNew = ReleaseNotifyTemplate.cleanWhatsNew(whatsNew)
        } else {
            resolvedWhatsNew = await fetchWhatsNew(app: app, appID: appID, model: model)
        }

        let cfg = config(forApp: app)
        let explicitSubject = customSubject?.trimmedNilIfEmpty
        let explicitBody = customBody?.trimmedNilIfEmpty
        let hasExplicitOverride = explicitSubject != nil || explicitBody != nil
        let hasCustomConfig = cfg.customSubject?.trimmedNilIfEmpty != nil || cfg.customTemplate?.trimmedNilIfEmpty != nil

        var draft = ReleaseNotifyTemplate.render(
            app: app,
            version: ver,
            whatsNew: resolvedWhatsNew,
            appStoreURL: appStoreURL,
            subscriberName: nil,
            config: cfg
        )
        if let explicitSubject { draft.subject = explicitSubject }
        if let explicitBody { draft.body = explicitBody }

        let versions = currentVersionsMap(model: model)
        let wording = Wording.rules
        if let problem = ReleaseNotifySpamLint.problem(draft.body, subject: draft.subject, wording: wording, versions: versions) {
            if !hasExplicitOverride && hasCustomConfig {
                let fallback = ReleaseNotifyTemplate.render(
                    app: app,
                    version: ver,
                    whatsNew: resolvedWhatsNew,
                    appStoreURL: appStoreURL,
                    subscriberName: nil,
                    config: nil
                )
                if let fallbackProblem = ReleaseNotifySpamLint.problem(fallback.body, subject: fallback.subject, wording: wording, versions: versions) {
                    return (false, fallbackProblem, nil)
                }
                draft = fallback
            } else {
                return (false, problem, nil)
            }
        }

        guard let liveStore = model.liveStore else {
            return (false, "Store isn't ready.", nil)
        }

        var payloadFields: [String: JSONValue] = [
            "app": .string(app),
            "version": .string(ver),
            "app_id": .string(appID ?? ""),
            "app_store_url": .string(appStoreURL),
            "subject": .string(draft.subject),
            "body": .string(draft.body),
            "recipient_count": .number(Double(recipients.count)),
        ]
        if let resolvedWhatsNew {
            payloadFields["whats_new"] = .string(resolvedWhatsNew)
        }

        guard let jobID = try? await liveStore.enqueue(
            kind: "release.notify",
            resource: "mail",
            priority: 3,
            maxAttempts: 1,
            payload: .object(payloadFields),
            needsApproval: true
        ) else {
            return (false, "Couldn't queue release notification.", nil)
        }

        await model.refresh()
        return (true, "Queued \(app) \(ver) release update for \(recipients.count) subscriber(s) in Log → Needs your OK.", jobID)
    }

    func checkNewReleases(model: AppModel) async -> [(app: String, version: String, recipients: Int, jobID: Int64)] {
        var liveByApp: [String: String] = [:]
        for snap in model.snapshots("app.snapshot").sorted(by: { $0.occurredAt < $1.occurredAt }) {
            guard let rawApp = snap.app else { continue }
            let short = ComingSoon.shortName(rawApp)
            guard !short.isEmpty,
                  let ver = snap.payload[path: "version"]?.string?.trimmedNilIfEmpty else { continue }
            liveByApp[short] = ver
        }
        for snap in model.snapshots("release.snapshot").sorted(by: { $0.occurredAt < $1.occurredAt }) {
            guard let rawApp = snap.app else { continue }
            let short = ComingSoon.shortName(rawApp)
            guard !short.isEmpty,
                  snap.payload[path: "live"] == .bool(true),
                  let ver = snap.payload[path: "live_version"]?.string?.trimmedNilIfEmpty else { continue }
            liveByApp[short] = ver
        }

        var baselineChanged = false
        var results: [(app: String, version: String, recipients: Int, jobID: Int64)] = []

        for (app, liveVersion) in liveByApp.sorted(by: { $0.key < $1.key }) {
            guard let previousVersion = book.notifiedVersions[app] else {
                book.notifiedVersions[app] = liveVersion
                baselineChanged = true
                continue
            }
            guard liveVersion != previousVersion else { continue }

            let cfg = config(forApp: app)
            let isPatch = ReleaseSubscribersStore.isPatchUpdate(from: previousVersion, to: liveVersion)
            book.notifiedVersions[app] = liveVersion
            persist()

            let eligible = ReleaseSubscribersStore.eligibleRecipients(in: book, app: app, version: liveVersion)
            if cfg.autoDraftOnRelease, (!isPatch || cfg.allowPatchUpdates), !eligible.isEmpty {
                let drafted = await draftNotification(app: app, version: liveVersion, model: model)
                if drafted.ok, let jobID = drafted.jobID {
                    results.append((app: app, version: liveVersion, recipients: eligible.count, jobID: jobID))
                }
            }
        }

        if baselineChanged {
            persist()
        }
        return results
    }

    // MARK: - Mail Event Processing

    func processMailEvents(model: AppModel) async -> [ReleaseMailRecord] {
        guard let store = model.liveStore else { return [] }
        let since = Millis(Date.now.addingTimeInterval(-60 * 86_400).timeIntervalSince1970 * 1000)
        let events = (try? await store.events(kind: "mail.seen", since: since)) ?? []
        guard !events.isEmpty else { return [] }

        let mail = Outreach.mail(events)
        let actions = ReleaseSubscriberMailMatch.detect(mail: mail, book: book)
        guard !actions.isEmpty else { return [] }

        let applied = ReleaseSubscriberMailMatch.apply(actions, to: &book)
        guard !applied.isEmpty else { return [] }

        persist()
        for rec in applied {
            try? await store.appendAudit(
                actor: "routine:subscribers",
                action: rec.kind == .unsubscribe ? "subscriber.auto_unsubscribe" : "subscriber.auto_bounce",
                subject: rec.email,
                detail: .object(["reason": .string(rec.reason), "mail_id": .string(rec.mailID)])
            )
        }
        return applied
    }

    // MARK: - Batch Sending

    func sendBatchJob(
        _ job: Job,
        model: AppModel,
        delayRangeMs: ClosedRange<UInt64> = 400...1200
    ) async -> (ok: Bool, note: String, sent: Int, skipped: Int, failed: Int) {
        let app = job.payload[path: "app"]?.string?.trimmedNilIfEmpty ?? ""
        let version = job.payload[path: "version"]?.string?.trimmedNilIfEmpty ?? ""
        let subject = job.payload[path: "subject"]?.string?.trimmedNilIfEmpty ?? ""
        let body = job.payload[path: "body"]?.string?.trimmedNilIfEmpty ?? ""
        guard !app.isEmpty, !version.isEmpty, !subject.isEmpty, !body.isEmpty else {
            return (false, "Release notification job is missing app, version, subject, or body.", 0, 0, 0)
        }

        let wording = Wording.rules
        if let problem = wording.problem(subject)
            ?? wording.problem(body)
            ?? ReleaseNotifySpamLint.problem(body, subject: subject, wording: wording) {
            return (false, "Blocked: \(problem)", 0, 0, 0)
        }

        let recipients = ReleaseSubscribersStore.eligibleRecipients(in: book, app: app, version: version)
        let skipped = max(0, subscribers(forApp: app).count - recipients.count)

        if recipients.isEmpty {
            if skipped > 0 {
                return (true, "All eligible subscribers for \(app) \(version) were already notified (\(skipped) skipped).", 0, skipped, 0)
            }
            return (false, "No active unsent subscribers for \(app) \(version).", 0, 0, 0)
        }

        if MailSender.modeDescription == "Mail app (mailto:)" {
            return (false, "Configure SMTP or Zoho Mail (Safari) in Outreach → Setup to send subscriber release batches.", 0, skipped, 0)
        }

        var sent = 0
        var failed = 0
        var lastVia = MailSender.modeDescription
        var lastError: String?
        let today = Date.now.localDay

        for (index, sub) in recipients.enumerated() {
            let personalBody = ReleaseNotifyTemplate.personalizeBody(body, subscriberName: sub.name)
            let res = await MailSender.send(to: sub.email, subject: subject, body: personalBody)
            lastVia = res.via
            if res.ok {
                sent += 1
                ReleaseSubscribersStore.recordSent(book: &book, app: app, version: version, email: sub.email, today: today)
                persist()
            } else {
                failed += 1
                lastError = res.note
                ReleaseSubscribersStore.recordFailure(book: &book, app: app, version: version, email: sub.email, error: res.note)
                persist()
            }
            let remaining = recipients.count - index - 1
            if remaining > 0, delayRangeMs.upperBound > 0 {
                let ms = UInt64.random(in: delayRangeMs)
                if ms > 0 {
                    try? await Task.sleep(for: .milliseconds(Int64(clamping: ms)))
                }
            }
        }

        try? await model.liveStore?.appendAudit(
            actor: "you",
            action: "release.notified",
            subject: "\(app) \(version)",
            detail: .object([
                "app": .string(app),
                "version": .string(version),
                "sent": .number(Double(sent)),
                "failed": .number(Double(failed)),
                "via": .string(lastVia),
            ])
        )

        let ok = failed == 0 || sent > 0
        let summary: String
        if sent > 0 && failed == 0 {
            summary = "Sent \(app) \(version) update to \(sent) subscriber(s)\(skipped > 0 ? " (\(skipped) skipped)" : "")."
        } else if sent > 0 && failed > 0 {
            summary = "Sent \(app) \(version) update to \(sent) subscriber(s); \(failed) failed\(skipped > 0 ? ", \(skipped) skipped" : "")."
        } else {
            let errPart = lastError.map { " (\($0))" } ?? ""
            summary = "Couldn't send \(app) \(version) update (\(failed) failed)\(errPart)."
        }
        return (ok, summary, sent, skipped, failed)
    }

    // MARK: - Helpers

    private func currentVersionsMap(model: AppModel) -> [String: String] {
        var versions: [String: String] = [:]
        for snap in model.snapshots("app.snapshot") {
            if let a = snap.app, let v = snap.payload[path: "version"]?.string?.trimmedNilIfEmpty {
                versions[a] = v
            }
        }
        return versions
    }
}

extension String {
    var trimmedNilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
