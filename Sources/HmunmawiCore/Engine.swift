import Foundation

/// When each add-on last started a check, kept across restarts. Without this every launch made every add-on due at once,
/// so an app that restarts (an update, a crash, a login) asked every service again within minutes: 100 App Store Connect
/// requests for one launch, which adds up against a limit of 3,600 an hour, and paid calls (X) for no reason.
public struct PollStamps: Sendable {
    public var read: @Sendable () -> [String: Millis]
    public var write: @Sendable ([String: Millis]) -> Void
    public init(read: @escaping @Sendable () -> [String: Millis], write: @escaping @Sendable ([String: Millis]) -> Void) { self.read = read; self.write = write }
    /// Saved in the app's preferences (a test profile's own domain is shared, so tests pass `PollStamps.memory()`).
    public static let standard = PollStamps(
        read: { (UserDefaults.standard.dictionary(forKey: "HMPollStamps") as? [String: Double])?.mapValues { Millis($0) } ?? [:] },
        write: { UserDefaults.standard.set($0.mapValues { Double($0) }, forKey: "HMPollStamps") })
    public static func memory() -> PollStamps {
        final class Box: @unchecked Sendable { var v: [String: Millis] = [:] }
        let b = Box()
        return PollStamps(read: { b.v }, write: { b.v = $0 })
    }
}

/// The background loop: polls add-ons when due, feeds their events through the rules, and runs queued jobs.
public actor Engine {
    let store: Store
    let host: PluginHost
    let now: @Sendable () -> Millis
    public private(set) var rules: [Rule]
    private var lastPoll: [String: Millis] = [:] { didSet { stamps.write(lastPoll) } }
    private let stamps: PollStamps
    private let startedAt = Millis(Date.now.timeIntervalSince1970 * 1000)
    private var failuresInRow: [String: Int] = [:]      // consecutive failed polls per add-on (back-off)
    private var covered: Set<String> = []
    /// After a restore: events dated before the backup was made are stored but don't run rules (the backup
    /// predates them, so they already alerted once). Events after it alert as usual. Lifts itself once every
    /// add-on has finished one good check since, or after 6 hours at the latest.
    private var quiet: (before: Millis, until: Millis, waiting: Set<String>)?
    public func quietBefore(_ backupTime: Millis, addOns: Set<String>) {
        quiet = (backupTime, now() + 6 * 3_600_000, addOns)
    }
    public var isQuiet: Bool { quiet != nil }
    public func rulesFor(_ e: Event) -> [Rule] {
        guard let q = quiet else { return rules }
        if now() > q.until || q.waiting.isEmpty { quiet = nil; return rules }
        return e.occurredAt < q.before ? [] : rules
    }
    /// New events stored per add-on in the current hour, and add-ons paused for flooding.
    private var volume: [String: (hour: Millis, count: Int)] = [:]
    private var floodedUntil: [String: Millis] = [:]
    static let floodPerHour = 1_500

    /// A buggy add-on (e.g. a key that changes every run) could fill the database; past the hourly limit it's
    /// paused for an hour, and the log says so.
    private func noteVolume(_ id: String, _ added: Int) {
        let hour = now() / 3_600_000
        var v: (hour: Millis, count: Int) = volume[id].flatMap { $0.hour == hour ? $0 : nil } ?? (hour: hour, count: 0)
        v.count += added
        volume[id] = v
        if v.count > Self.floodPerHour, floodedUntil[id].map({ $0 < now() }) ?? true {
            floodedUntil[id] = now() + 3_600_000
            Task { [store] in try? await store.appendAudit(actor: id, action: "plugin.flood",
                                                          detail: .object(["events_this_hour": .number(Double(v.count))])) }
        }
    }                // add-ons whose data arrives another way right now

    /// Add-ons whose numbers currently come from elsewhere (e.g. X through a file your bot writes): their own timed checks
    /// pause, so a paid API isn't called for nothing. "Check now" still works; they resume when the other
    /// source stops (the app updates this set every refresh).
    public func setCovered(_ ids: Set<String>) { covered = ids }
    private var lastHealthCheck: Millis = 0
    static let workerName = "engine"
    /// High enough for a full sales backfill (an add-on marks that work done before the app stores it, so a lower
    /// cap would lose the rest for good); the flood check above still catches a runaway add-on.
    static let maxEventsPerPoll = 10_000

    /// How long the app waits for one check before stopping it. Tests pass a short value.
    let pollTimeout: Duration
    /// Pauses before automatic retries after a check is stopped for taking too long (then one last failure).
    let timeoutRetryDelays: [Duration]
    /// Consecutive timeout retries in the current streak (cleared on success or after the last failure).
    private var timeoutRetries: [String: Int] = [:]
    /// Add-ons whose in-flight check is being stopped so Check Now can run a fresh one (not a real failure).
    private var cancelling: Set<String> = []

    /// Shown in Settings and the activity log when a check is stopped for taking too long.
    public static let pollTimeoutText = "The check took too long and was stopped. Some App Store reports were not published yet, and the check kept waiting. A fresh check will run shortly."

    public init(store: Store, host: PluginHost, rules: [Rule], now: @escaping @Sendable () -> Millis = Store.systemNow,
                stamps: PollStamps = .memory(), pollTimeout: Duration = .seconds(600),
                timeoutRetryDelays: [Duration] = [.seconds(30), .seconds(120), .seconds(480)]) {
        self.stamps = stamps
        self.store = store
        self.host = host
        self.rules = rules
        self.now = now
        self.pollTimeout = pollTimeout
        self.timeoutRetryDelays = timeoutRetryDelays
        self.lastPoll = stamps.read()      // what ran before the restart does not run again at once
    }

    public func setRules(_ rules: [Rule]) { self.rules = rules }

    public func run() async {
        _ = try? await store.recoverInterrupted()
        // Two loops: checks, and alerts/approved actions. A check can take up to 10 minutes; alerts no longer wait
        // behind it (they used to run only between checks). Both stop when the engine's task is cancelled.
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    while await self.runNextJob() {}
                    try? await Task.sleep(for: .seconds(2))
                }
            }
            group.addTask {
                while !Task.isCancelled {
                    await self.pollDuePlugins(parallel: true)
                    if await self.healthCheckDue() {
                        await self.host.healthCheck()
                        _ = try? await self.store.failStuck()
                    }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
        await host.stopAll()
    }

    private func healthCheckDue() -> Bool {
        guard now() - lastHealthCheck > 60_000 else { return false }
        lastHealthCheck = now()
        return true
    }

    /// Runs one ready job; returns false when nothing was ready.
    @discardableResult
    public func runNextJob() async -> Bool {
        guard let job = try? await store.claimNext(owner: Self.workerName) else { return false }
        var batch: [Job] = []
        if job.kind == "notify" {
            // A channel sends at most a few messages an hour; past that, this alert waits and joins the next one.
            if let sent = try? await store.alertsSentLastHour(resource: job.resource), sent >= Store.alertsPerChannelPerHour {
                try? await store.requeue([job.id], after: 15 * 60_000)
                return true
            }
            batch = (try? await store.claimBatch(with: job, owner: Self.workerName)) ?? []
        }
        do {
            guard let plugin = await host.plugin(for: job.kind, preferred: job.resource) else {
                throw WireError("no_plugin", "No add-on can do “\(job.kind)”")
            }
            // Everything the call needs is read first, so nothing waits between getting the add-on and calling it
            // (a check finishing in that gap could stop the add-on as idle).
            var params = job.payload[path: "params"] ?? .object([:])
            if case .object(var fields) = params, let eventID = job.eventID, let event = try await store.event(eventID) {
                fields["title"] = fields["title"] ?? .string("Hmunmawi")
                fields["message"] = fields["message"] ?? .string(EventText.describe(event))
                fields["event"] = .object(["kind": .string(event.kind), "app": event.app.map(JSONValue.string) ?? .null,
                                           "payload": event.payload])
                params = .object(fields)
            }
            // Where tapping the alert goes (ntfy): the page it's about in App Store Connect, from the app's own ID.
            if job.kind == "notify", case .object(var fields) = params, fields["click"] == nil,
               let eventID = job.eventID, let event = try? await store.event(eventID) {
                var appID: String?
                if let name = event.app { appID = try? await store.appStoreID(forApp: name) }
                if let url = Self.clickURL(kind: event.kind, appID: appID) { fields["click"] = .string(url); params = .object(fields) }
            }
            // Several alerts for one channel: one message listing them all.
            if !batch.isEmpty, case .object(var fields) = params {
                var lines: [String] = [fields["message"]?.string ?? ""]
                for other in batch { lines.append(await message(for: other)) }
                fields["title"] = .string("Hmunmawi · \(lines.count) alerts")
                fields["message"] = .string(lines.filter { !$0.isEmpty }.map { "• " + $0 }.joined(separator: "\n"))
                params = .object(fields)
            }
            let process = try await host.process(for: plugin.manifest.id)
            // Same waits as a button press: App Store Connect writes chain slow calls.
            _ = try await process.call("act", params: .object(["action": .string(job.kind), "params": params]),
                                       timeout: job.kind == "asc.fix" ? .seconds(600) : .seconds(120))
            await host.flushHTTP(plugin.manifest.id)
            // A sent alert is a real check of the connection: its row shows when the last one got through.
            if job.kind == "notify" {
                try? await store.appendAudit(actor: plugin.manifest.id, action: "plugin.delivered", subject: "notify",
                                             detail: .object(["alerts": .number(Double(1 + batch.count))]))
            }
            try await store.complete(job.id, detail: .object(["plugin": .string(plugin.manifest.id)]))
            for other in batch { try? await store.completeInBatch(other.id, leader: job.id) }
        } catch {
            if job.kind == "notify", let id = await host.plugin(for: job.kind, preferred: job.resource)?.manifest.id {
                try? await store.appendAudit(actor: id, action: "plugin.delivery_failed", subject: "notify",
                                             detail: .object(["error": .string(String("\(error)".prefix(200)))]))
            }
            try? await store.fail(job.id, error: "\(Self.explain(error, action: job.kind))")
            for other in batch { try? await store.fail(other.id, error: "Sent together with job \(job.id), which failed: \(error)") }
        }
        return true
    }

    /// The App Store Connect page an alert is about (nil when there's no sensible one). Only numeric app IDs.
    static func clickURL(kind: String, appID: String?) -> String? {
        let base = "https://appstoreconnect.apple.com"
        guard let id = appID, !id.isEmpty, id.allSatisfy(\.isNumber) else {
            return kind.hasPrefix("revenue.") || kind == "finance.month" ? "\(base)/trends" : nil
        }
        switch kind {
        case "review.new": return "\(base)/apps/\(id)/distribution/activity/ios/ratingsAndReviews"
        case "testflight.feedback", "ci.build": return "\(base)/apps/\(id)/testflight/ios"
        case let k where k.hasPrefix("revenue."): return "\(base)/trends"
        case "release.check", "story.worry", "story.win", "offercodes.status": return "\(base)/apps/\(id)/distribution"
        default: return nil
        }
    }

    /// One alert's text: the rule's own message, else a description of its event.
    private func message(for job: Job) async -> String {
        if let m = job.payload[path: "params.message"]?.string, !m.isEmpty { return m }
        guard let id = job.eventID, let event = try? await store.event(id) else { return job.kind }
        return EventText.describe(event)
    }

    /// A write that timed out may still finish inside the add-on: say so, so nobody runs it twice blindly.
    static func explain(_ error: any Error, action: String) -> any Error {
        guard let w = error as? WireError, w.code == "timeout", action == "asc.fix" else { return error }
        return WireError("timeout", "\(w.message). It may still have gone through: check App Store Connect before running it again.")
    }

    /// Runs one action now and returns its result (e.g. a Rejection Shield fix and how to undo it). Every attempt is
    /// in the audit log, with the error when it fails.
    public func perform(_ action: String, resource: String, params: JSONValue) async throws -> JSONValue {
        guard let plugin = await host.plugin(for: action, preferred: resource) else {
            throw WireError("no_plugin", "No add-on can do \(action)")
        }
        do {
            let process = try await host.process(for: plugin.manifest.id)
            // App Store Connect fixes can chain several slow writes (submit is 3 calls, each up to 60 s); a
            // shorter wait reported "failed" while the add-on carried on and did it anyway.
            let wait: Duration = action == "asc.fix" ? .seconds(600) : .seconds(120)
            let result = try await process.call("act", params: .object(["action": .string(action), "params": params]), timeout: wait)
            await host.flushHTTP(plugin.manifest.id)
            try? await store.appendAudit(actor: plugin.manifest.id, action: "act.done", subject: action, detail: result)
            return result
        } catch {
            let error = Self.explain(error, action: action)
            try? await store.appendAudit(actor: plugin.manifest.id, action: "act.failed", subject: action,
                                         detail: .object(["error": .string("\(error)")]))
            throw error
        }
    }

    /// `parallel`: each due add-on's check runs on its own (the background loop), so one slow add-on (up to 10 min)
    /// never holds up the others. Off for callers that need the checks finished before going on (after a wake, tests).
    public func pollDuePlugins(parallel: Bool = false) async {
        for plugin in await host.plugins {
            guard let schedule = plugin.manifest.poll else { continue }
            let id = plugin.manifest.id
            if covered.contains(id) { continue }
            if let until = floodedUntil[id], now() < until { continue }
            let t = now()
            // Back off while an add-on keeps failing (e.g. an API out of credits): each failure in a row doubles
            // the wait, up to 8x its own interval but never past 2 hours (a slow add-on's 6 h check isn't pushed
            // to 2 days by one network outage); the first success resets it.
            let every = Millis(schedule.everySeconds) * 1000
            let wait = min(every << Millis(min(failuresInRow[id] ?? 0, 3)), max(every, 2 * 3_600_000))
            if let last = lastPoll[id], t >= last, t - last < wait { continue }   // a stamp from the future (clock change) counts as due
            guard (try? await host.isApproved(id)) == true else { continue }
            lastPoll[id] = t
            if polling.contains(id) { lastPoll[id] = nil; continue }   // already being checked: try again next round
            if parallel {
                Task { await self.checkAndRest(id, every: schedule.everySeconds) }
            } else {
                await checkAndRest(id, every: schedule.everySeconds)
            }
            // At launch everything is due at once: start one add-on per loop (2 s apart) instead of all together.
            if t - startedAt < 120_000 { return }
        }
    }

    /// One check, then the memory-saving stop for add-ons that check every 3 hours or less often (never while
    /// it's in the middle of an action: that would cut it off). Hourly and more frequent ones stay running.
    private func checkAndRest(_ id: String, every seconds: Int) async {
        await poll(id)
        if seconds >= 10_800, !polling.contains(id) { await host.restartIfIdle(id) }
    }

    /// Checks every add-on now, regardless of its timer (used after the Mac wakes).
    /// Add-ons whose last checks failed, with how many in a row (a success clears it).
    public func failing() -> [String: Int] { failuresInRow }
    /// When each add-on's last check succeeded (ms), this session.
    public func succeeded() -> [String: Millis] { lastSuccess }
    private var lastSuccess: [String: Millis] = [:]

    public func pollEverything() async {
        // After a wake everything is checked again, except add-ons that are backing off after failures.
        lastPoll = lastPoll.filter { (failuresInRow[$0.key] ?? 0) > 0 }
        await pollDuePlugins()
    }

    /// Add-ons with a poll running now. A second poll of the same add-on (e.g. "Fetch everything again" during the
    /// launch round) waits its turn instead of running alongside, which used to let one poll's memory-saving
    /// restart kill the other mid-way.
    private var polling: Set<String> = []

    public func isPolling(_ id: String) -> Bool { polling.contains(id) }

    /// Checks one add-on. `preempt` is for Check Now: if a check is already running it is stopped first so the
    /// button does not spin until the leftover work finishes, and two checks cannot run on the same add-on.
    public func poll(_ id: String, preempt: Bool = false) async {
        if polling.contains(id) {
            guard preempt else { return }
            cancelling.insert(id)
            await host.restart(id)
            for _ in 0..<100 where polling.contains(id) {
                try? await Task.sleep(for: .milliseconds(20))
            }
            cancelling.remove(id)
            guard !polling.contains(id) else { return }
        }
        polling.insert(id)
        defer { polling.remove(id) }
        do {
            let process = try await host.process(for: id)
            // Generous: an add-on marks some daily work done before the app stores its events, so a poll cut off
            // by this timeout would lose that day's data. The longest round (sales backfill + Shield) fits well inside.
            let result = try await process.call("poll", timeout: pollTimeout)
            let events = try result[path: "events"]?.decode([PluginEvent].self) ?? []
            if events.count > Self.maxEventsPerPoll {
                // Never drop quietly: say how many were left out.
                try? await store.appendAudit(actor: id, action: "plugin.events_capped",
                                             detail: .object(["sent": .number(Double(events.count)), "kept": .number(Double(Self.maxEventsPerPoll))]))
            }
            var added = 0
            defer { noteVolume(id, added) }
            let manifest = await host.installedPlugin(id)?.manifest
            var refused: [String: Int] = [:]
            for event in events.prefix(Self.maxEventsPerPoll) {
                guard manifest?.mayEmit(event.kind) == true else { refused[String(event.kind.prefix(80)), default: 0] += 1; continue }
                // Source and key are set by the app, so an add-on can't pose as another one.
                // Never in the future (a date ahead would slip past "too old" checks and sit on top of every list).
                let latest = Int64(Date.now.timeIntervalSince1970 * 1000) + 300_000
                let stored = Event(source: id, kind: event.kind, app: event.app, payload: event.payload ?? .object([:]),
                                   occurredAt: min(event.occurredAt, latest), dedupeKey: "\(id):\(event.dedupeKey)")
                if try await store.ingest(stored, rules: rulesFor(stored)).duplicate == false { added += 1 }
            }
            if !refused.isEmpty {
                try? await store.appendAudit(actor: id, action: "plugin.events_refused",
                                             detail: .object(Dictionary(uniqueKeysWithValues: refused.prefix(20).map { ($0.key, JSONValue.number(Double($0.value))) })))
            }
            // Everything from this check is saved: an add-on that asks for it is told so, and only then marks its
            // daily work done. Never when the check was cut off at the limit (the rest would be lost).
            if events.count <= Self.maxEventsPerPoll, await host.installedPlugin(id)?.manifest.actions.contains("ack") == true {
                do { _ = try await process.call("act", params: .object(["action": .string("ack"), "params": .object([:])]), timeout: .seconds(30)) }
                catch {
                    // Without the acknowledgement the add-on repeats its daily work, so say so instead of failing silently.
                    try? await store.appendAudit(actor: id, action: "plugin.ack_failed", detail: .object(["error": .string(String("\(error)".prefix(200)))]))
                }
            }
            failuresInRow[id] = nil
            timeoutRetries[id] = nil
            lastSuccess[id] = now()
            if quiet != nil { quiet?.waiting.remove(id); if quiet?.waiting.isEmpty == true { quiet = nil } }
            await host.flushHTTP(id)
        } catch {
            await host.flushHTTP(id)
            // Check Now stopped this run to start a fresh one: not a failure, and no retry of the cancelled work.
            if cancelling.contains(id) { return }
            let timedOut = (error as? WireError)?.code == "timeout"
            if timedOut { await host.restart(id) }
            if timedOut {
                let n = (timeoutRetries[id] ?? 0) + 1
                timeoutRetries[id] = n
                let detail: JSONValue = .object([
                    "error": .string(Self.pollTimeoutText),
                    "attempt": .number(Double(n)),
                    "max": .number(Double(timeoutRetryDelays.count)),
                ])
                if n <= timeoutRetryDelays.count {
                    try? await store.appendAudit(actor: id, action: "plugin.poll_retry", detail: detail)
                    lastPoll[id] = nil
                    let delay = timeoutRetryDelays[n - 1]
                    Task { [weak self] in
                        try? await Task.sleep(for: delay)
                        await self?.poll(id)
                    }
                } else {
                    timeoutRetries[id] = nil
                    failuresInRow[id, default: 0] += 1
                    try? await store.appendAudit(actor: id, action: "plugin.poll_failed", detail: detail)
                }
            } else {
                failuresInRow[id, default: 0] += 1
                try? await store.appendAudit(actor: id, action: "plugin.poll_failed",
                                             detail: .object(["error": .string("\(error)")]))
            }
        }
    }
}

