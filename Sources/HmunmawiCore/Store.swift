import CryptoKit
import Foundation

/// Owns the database. All event, queue and audit writes go through here so each step is one transaction.
public actor Store {
    public static let systemNow: @Sendable () -> Millis = { Millis(Date().timeIntervalSince1970 * 1000) }
    static let genesisHash = String(repeating: "0", count: 64)
    static let retryBaseMillis: Millis = 30_000
    static let retryCapMillis: Millis = 3_600_000
    /// Events older than this never send an alert (see ingest).
    static let alertMaxAgeMillis: Millis = 48 * 3_600_000

    let db: SQLiteConnection
    let now: @Sendable () -> Millis
    /// Where the database lives (":memory:" for a throwaway one).
    public nonisolated let path: String
    /// Goes up whenever stored events are deleted (prune). Event ids can then be handed out again, so in-memory
    /// windows that read "everything after id N" must load again (see EventWindow).
    public private(set) var eventsEpoch = 0
    /// Alerts (notify jobs) of non-urgent rules made during these hours wait until they end.
    public private(set) var quietHours = QuietHours(enabled: false)   // the app sets your setting at launch
    public func setQuietHours(_ q: QuietHours) { quietHours = q }
    /// Most alert messages one channel sends in an hour; the rest are merged into the next message.
    public static let alertsPerChannelPerHour = 6
    /// The app's signing key for add-on approvals (nil: approvals aren't signed or checked, e.g. tests and tools).
    var trustKey: SymmetricKey?
    /// Set by the app: with no signing key (the Keychain didn't answer), no approval counts, instead of every approval
    /// counting unchecked. Off for tools and tests that open a store without a key.
    var requireSignedApprovals = false
    public func setRequireSignedApprovals(_ on: Bool) { requireSignedApprovals = on }
    var reportedForged: Set<String> = []
    public func setTrustKey(_ key: SymmetricKey?) {
        trustKey = key
        guard key != nil, !pendingAudit.isEmpty else { return }
        let held = pendingAudit; pendingAudit = []
        for e in held { try? db.transaction { try audit(actor: e.actor, action: e.action, subject: e.subject, detail: e.detail, at: e.at) } }
    }

    /// Pass `":memory:"` for a throwaway database.
    public init(path: String, now: @escaping @Sendable () -> Millis = Store.systemNow) throws {
        let connection = try SQLiteConnection(path: path)
        try Schema.migrate(connection)
        self.db = connection
        self.now = now
        self.path = path
    }

    // MARK: Events and rules

    /// Same test as SQL `json_type(payload, '$.days' / '$.day') IS NOT NULL`: the top-level key is there (even
    /// as null), exactly what the insight extractor's `payload[path: "day"] == nil` checks.
    static func hasDay(_ payload: JSONValue) -> Bool {
        guard case .object(let o) = payload else { return false }
        return o["days"] != nil || o["day"] != nil
    }

    public func ingest(_ event: Event, rules: [Rule]) throws -> IngestResult {
        try db.transaction {
            let t = now()
            try db.execute("""
                INSERT OR IGNORE INTO events (source, kind, app, payload, occurred_at, received_at, dedupe_key, has_day)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, [.text(event.source), .text(event.kind), event.app.map(SQLValue.text) ?? .null,
                      .text(try event.payload.canonicalText()), .integer(event.occurredAt), .integer(t),
                      .text(event.dedupeKey), .integer(Self.hasDay(event.payload) ? 1 : 0)])
            guard db.changes > 0 else {
                return IngestResult(eventID: nil, duplicate: true, jobIDs: [], dryRunRuleIDs: [])
            }
            let eventID = db.lastInsertID
            try audit(actor: event.source, action: "event.received", subject: "event:\(eventID)",
                      detail: .object(["kind": .string(event.kind), "key": .string(event.dedupeKey)]))

            var jobIDs: [Int64] = []
            var dryRuns: [String] = []
            for rule in rules where rule.matches(event) {
                let cooldownKey = Self.cooldownKey(rule: rule.id, app: event.app, payload: event.payload)
                if try inCooldown(cooldownKey, seconds: rule.cooldownSeconds, at: t) {
                    try audit(actor: "rules", action: "rule.cooldown", subject: "rule:\(rule.id)")
                    continue
                }
                if rule.dryRun {
                    dryRuns.append(rule.id)
                    try audit(actor: "rules", action: "rule.dry_run", subject: "rule:\(rule.id)",
                              detail: .object(["event": .number(Double(eventID)),
                                               "would_do": .array(rule.actions.map { .string($0.action) })]))
                    continue
                }
                if rule.approval == .never {
                    try audit(actor: "rules", action: "rule.blocked", subject: "rule:\(rule.id)")
                    continue
                }
                // Alerts are about now: an event that happened over 2 days ago (a backfill, a first connection,
                // history fetched again) is stored and counted, but texts nobody. Other actions still queue.
                let tooOld = event.occurredAt < t - Self.alertMaxAgeMillis
                let actions = tooOld ? rule.actions.filter { $0.action != "notify" } : rule.actions
                if actions.isEmpty {
                    try audit(actor: "rules", action: "rule.too_old", subject: "rule:\(rule.id)",
                              detail: .object(["event": .number(Double(eventID))]))
                    continue
                }
                // The cooldown starts only when something is really queued: a "Try out" or blocked rule must not
                // mute the first real alert after it.
                try db.execute("INSERT OR REPLACE INTO rule_fires (cooldown_key, fired_at) VALUES (?, ?)",
                               [.text(cooldownKey), .integer(t)])
                for action in actions {
                    // App Store Connect writes always wait for the owner, whatever the rule says; and once
                    // approved they run once (a retried write could e.g. submit twice).
                    let ascWrite = action.action == "asc.fix"
                    // An alert is tried once: a slow send that timed out may still arrive, and a retry would text twice.
                    let sendsOnce = ascWrite || action.action == "notify"
                    let state: JobState = rule.approval == .auto && !ascWrite ? .queued : .waitingApproval
                    let payload: JSONValue = .object(["params": action.params ?? .object([:]),
                                                      "event": .number(Double(eventID))])
                    // Quiet hours: a non-urgent alert waits until they end (and is then sent together with the rest).
                    let wait: Millis? = action.action == "notify" && rule.priority > 1
                        ? quietHours.end(after: Date(timeIntervalSince1970: Double(t) / 1000)).map { Millis($0.timeIntervalSince1970 * 1000) }
                        : nil
                    jobIDs.append(try insertJob(kind: action.action, resource: action.resource ?? action.action,
                                                priority: rule.priority, state: state, maxAttempts: sendsOnce ? 1 : 3,
                                                ruleID: rule.id, eventID: eventID, payload: payload, at: t, runAfter: wait))
                }
            }
            return IngestResult(eventID: eventID, duplicate: false, jobIDs: jobIDs, dryRunRuleIDs: dryRuns)
        }
    }

    /// Per rule and app, and per thing the alert is about (a usage service, an expiring item, an offer code), so two
    /// different ones never mute each other.
    static func cooldownKey(rule: String, app: String?, payload: JSONValue) -> String {
        let subject = ["service", "name", "offer"].lazy.compactMap { payload[path: $0]?.string }.first
        return "\(rule)|\(app ?? "")" + (subject.map { "|" + $0 } ?? "")
    }

    private func inCooldown(_ key: String, seconds: Int, at t: Millis) throws -> Bool {
        guard seconds > 0,
              let last = try db.query("SELECT fired_at FROM rule_fires WHERE cooldown_key = ?", [.text(key)])
                .first?.int("fired_at")
        else { return false }
        return t - last < Millis(seconds) * 1000
    }

    // MARK: Queue

    @discardableResult
    public func enqueue(kind: String, resource: String, priority: Int = 5, maxAttempts: Int = 3,
                        payload: JSONValue = .object([:]), needsApproval: Bool = false) throws -> Int64 {
        try db.transaction {
            try insertJob(kind: kind, resource: resource, priority: priority,
                          state: needsApproval ? .waitingApproval : .queued, maxAttempts: maxAttempts,
                          ruleID: nil, eventID: nil, payload: payload, at: now())
        }
    }

    private func insertJob(kind: String, resource: String, priority: Int, state: JobState, maxAttempts: Int,
                           ruleID: String?, eventID: Int64?, payload: JSONValue, at t: Millis, runAfter: Millis? = nil) throws -> Int64 {
        try db.execute("""
            INSERT INTO jobs (kind, resource, priority, state, max_attempts, run_after, rule_id, event_id,
                              payload, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [.text(kind), .text(resource), .integer(Int64(priority)), .text(state.rawValue),
                  .integer(Int64(maxAttempts)), .integer(runAfter ?? t), ruleID.map(SQLValue.text) ?? .null,
                  eventID.map(SQLValue.integer) ?? .null, .text(try payload.canonicalText()), .integer(t), .integer(t)])
        let id = db.lastInsertID
        try audit(actor: "queue", action: "job.created", subject: "job:\(id)",
                  detail: .object(["kind": .string(kind), "state": .string(state.rawValue)]))
        return id
    }

    /// Takes the most urgent ready job whose resource is free, and marks it running for `owner`.
    public func claimNext(owner: String) throws -> Job? {
        try db.transaction {
            let t = now()
            guard let id = try db.query("""
                SELECT id FROM jobs j
                WHERE state = 'queued' AND run_after <= ?
                  AND NOT EXISTS (SELECT 1 FROM jobs r WHERE r.state = 'running' AND r.resource = j.resource)
                ORDER BY priority ASC, id ASC LIMIT 1
                """, [.integer(t)]).first?.int("id") else { return nil }
            try db.execute("""
                UPDATE jobs SET state = 'running', owner = ?, attempts = attempts + 1, updated_at = ?
                WHERE id = ? AND state = 'queued'
                """, [.text(owner), .integer(t), .integer(id)])
            try audit(actor: owner, action: "job.claimed", subject: "job:\(id)")
            return try job(id)
        }
    }

    /// Other alerts for the same channel that are ready now, claimed together with one already running, so they
    /// go out as one message (a burst of 50 sales is one text, not 50).
    public func claimBatch(with job: Job, owner: String, limit: Int = 30) throws -> [Job] {
        try db.transaction {
            let t = now()
            let ids = try db.query("""
                SELECT id FROM jobs WHERE state = 'queued' AND kind = ? AND resource = ? AND run_after <= ? AND id != ?
                ORDER BY id LIMIT ?
                """, [.text(job.kind), .text(job.resource), .integer(t), .integer(job.id), .integer(Int64(limit))]).compactMap { $0.int("id") }
            for id in ids {
                try db.execute("UPDATE jobs SET state = 'running', owner = ?, attempts = attempts + 1, updated_at = ? WHERE id = ? AND state = 'queued'",
                               [.text(owner), .integer(t), .integer(id)])
            }
            return try ids.compactMap { try self.job($0) }
        }
    }

    /// Alert messages a channel sent in the last hour (one per finished batch: the batch's first job).
    public func alertsSentLastHour(resource: String) throws -> Int {
        Int(try db.query("""
            SELECT COUNT(DISTINCT COALESCE(json_extract(payload, '$.batch_of'), id)) AS n FROM jobs
            WHERE kind = 'notify' AND resource = ? AND state = 'done' AND updated_at > ?
            """, [.text(resource), .integer(now() - 3_600_000)]).first?.int("n") ?? 0)
    }

    /// Puts running jobs back in the queue for later without counting the try (used when a channel is at its
    /// hourly limit: nothing was sent).
    public func requeue(_ ids: [Int64], after ms: Millis) throws {
        try db.transaction {
            for id in ids {
                try db.execute("""
                    UPDATE jobs SET state = 'queued', owner = NULL, attempts = MAX(0, attempts - 1), run_after = ?, updated_at = ?
                    WHERE id = ? AND state = 'running'
                    """, [.integer(now() + ms), .integer(now()), .integer(id)])
            }
        }
    }

    /// Marks a job that went out inside another job's message (batch_of = that job).
    public func completeInBatch(_ jobID: Int64, leader: Int64) throws {
        try db.transaction {
            try db.execute("UPDATE jobs SET payload = json_set(payload, '$.batch_of', ?) WHERE id = ?", [.integer(leader), .integer(jobID)])
            try setState(jobID, .done, from: [.running])
            try audit(actor: try ownerOf(jobID), action: "job.done", subject: "job:\(jobID)", detail: .object(["batch_of": .number(Double(leader))]))
        }
    }

    public func complete(_ jobID: Int64, detail: JSONValue = .object([:])) throws {
        try db.transaction {
            try setState(jobID, .done, from: [.running])
            try audit(actor: try ownerOf(jobID), action: "job.done", subject: "job:\(jobID)", detail: detail)
        }
    }

    /// Retries with exponential backoff until `maxAttempts`, then marks the job failed.
    public func fail(_ jobID: Int64, error: String) throws {
        try db.transaction {
            guard let current = try job(jobID), current.state == .running else { return }
            let t = now()
            if current.attempts < current.maxAttempts {
                let delay = min(Self.retryBaseMillis << Millis(current.attempts - 1), Self.retryCapMillis)
                try db.execute("""
                    UPDATE jobs SET state = 'queued', run_after = ?, last_error = ?, owner = NULL, updated_at = ?
                    WHERE id = ?
                    """, [.integer(t + delay), .text(error), .integer(t), .integer(jobID)])
                try audit(actor: current.owner ?? "queue", action: "job.retry", subject: "job:\(jobID)",
                          detail: .object(["error": .string(error), "retry_in_ms": .number(Double(delay))]))
            } else {
                try db.execute("UPDATE jobs SET state = 'failed', last_error = ?, updated_at = ? WHERE id = ?",
                               [.text(error), .integer(t), .integer(jobID)])
                try audit(actor: current.owner ?? "queue", action: "job.failed", subject: "job:\(jobID)",
                          detail: .object(["error": .string(error)]))
                // A rule's alert that never went out mustn't keep the rule quiet: lift its cooldown, unless
                // another of its alerts for the same event went out (or still will): the next event would then
                // alert again on that channel inside the cooldown.
                let siblings = try db.query("""
                    SELECT COUNT(*) AS n FROM jobs WHERE rule_id = ? AND event_id IS ? AND id != ?
                      AND state IN ('done', 'running', 'queued')
                    """, [current.ruleID.map(SQLValue.text) ?? .null, current.eventID.map(SQLValue.integer) ?? .null,
                          .integer(jobID)]).first?.int("n") ?? 0
                if let rule = current.ruleID, siblings == 0 {
                    let ev = try current.eventID.flatMap { try event($0) }
                    try db.execute("DELETE FROM rule_fires WHERE cooldown_key = ?",
                                   [.text(Self.cooldownKey(rule: rule, app: ev?.app, payload: ev?.payload ?? .object([:])))])
                }
            }
        }
    }

    /// An approved request the app ran itself (an agent's request): straight from waiting to done or failed,
    /// with the result in the audit log, so it never sits under "waiting" after it ran.
    public func resolveApproved(_ jobID: Int64, ok: Bool, by person: String, detail: JSONValue) throws {
        try db.transaction {
            try setState(jobID, ok ? .done : .failed, from: [.waitingApproval])
            try audit(actor: person, action: ok ? "job.done" : "job.failed", subject: "job:\(jobID)", detail: detail)
        }
    }

    public func approve(_ jobID: Int64, by person: String) throws {
        try db.transaction {
            try setState(jobID, .queued, from: [.waitingApproval])
            try audit(actor: person, action: "job.approved", subject: "job:\(jobID)")
        }
    }

    public func skip(_ jobID: Int64, by person: String) throws {
        try db.transaction {
            try setState(jobID, .skipped, from: [.waitingApproval, .queued])
            try audit(actor: person, action: "job.skipped", subject: "job:\(jobID)")
        }
    }

    /// Call at startup: jobs left running by a crash go back to the queue, except ones that act on the outside
    /// world (an alert, an App Store Connect change) or are out of tries: they may already have happened, so
    /// they're marked failed ("may have run") for the owner to look at instead of happening twice.
    @discardableResult
    public func recoverInterrupted() throws -> Int {
        try db.transaction {
            try db.execute("""
                UPDATE jobs SET state = 'failed', owner = NULL, last_error = 'Interrupted (the app stopped); it may have run. Check before running it again.', updated_at = ?
                WHERE state = 'running' AND (kind IN ('asc.fix', 'notify') OR attempts >= max_attempts)
                """, [.integer(now())])
            let unsafe = db.changes
            try db.execute("UPDATE jobs SET state = 'queued', owner = NULL, updated_at = ? WHERE state = 'running'",
                           [.integer(now())])
            let count = db.changes + unsafe
            if count > 0 {
                try audit(actor: "queue", action: "job.recovered", detail: .object(["count": .number(Double(count))]))
            }
            return count
        }
    }

    /// Jobs left "running" far past the longest wait (10 min, plus start-up and a check ahead of it) — saving the result failed, e.g. disk full — are
    /// marked failed ("may have run"), so they stop blocking every later job for the same channel until a relaunch.
    @discardableResult
    public func failStuck(olderThan ms: Millis = 20 * 60_000) throws -> Int {
        try db.transaction {
            try db.execute("""
                UPDATE jobs SET state = 'failed', owner = NULL, updated_at = ?,
                  last_error = 'Stopped answering while running; it may have run. Check before running it again.'
                WHERE state = 'running' AND updated_at < ?
                """, [.integer(now()), .integer(now() - ms)])
            let n = db.changes
            if n > 0 { try audit(actor: "queue", action: "job.stuck", detail: .object(["count": .number(Double(n))])) }
            return n
        }
    }

    public func jobs(in state: JobState) throws -> [Job] {
        try db.query("SELECT * FROM jobs WHERE state = ? ORDER BY priority, id", [.text(state.rawValue)])
            .map(Self.makeJob)
    }

    public func job(_ id: Int64) throws -> Job? {
        try db.query("SELECT * FROM jobs WHERE id = ?", [.integer(id)]).first.map(Self.makeJob)
    }

    private func setState(_ jobID: Int64, _ state: JobState, from allowed: [JobState]) throws {
        let placeholders = allowed.map { _ in "?" }.joined(separator: ",")
        try db.execute("UPDATE jobs SET state = ?, updated_at = ? WHERE id = ? AND state IN (\(placeholders))",
                       [.text(state.rawValue), .integer(now()), .integer(jobID)] + allowed.map { .text($0.rawValue) })
        guard db.changes == 1 else { throw StoreError.invalidTransition(jobID: jobID, to: state) }
    }

    private func ownerOf(_ jobID: Int64) throws -> String {
        try job(jobID)?.owner ?? "queue"
    }

    private static func makeJob(_ row: Row) -> Job {
        Job(id: row.int("id") ?? 0,
            kind: row.string("kind") ?? "",
            resource: row.string("resource") ?? "",
            priority: Int(row.int("priority") ?? 5),
            state: JobState(rawValue: row.string("state") ?? "") ?? .failed,
            attempts: Int(row.int("attempts") ?? 0),
            maxAttempts: Int(row.int("max_attempts") ?? 1),
            runAfter: row.int("run_after") ?? 0,
            owner: row.string("owner"),
            ruleID: row.string("rule_id"),
            eventID: row.int("event_id"),
            payload: (try? JSONValue.parse(row.string("payload") ?? "{}")) ?? .null,
            lastError: row.string("last_error"),
            updatedAt: row.int("updated_at") ?? 0)
    }

    // MARK: Audit log

    public func appendAudit(actor: String, action: String, subject: String? = nil,
                            detail: JSONValue = .object([:])) throws {
        try db.transaction { try audit(actor: actor, action: action, subject: subject, detail: detail) }
    }

    /// Entries that couldn't be signed because the Keychain key was unavailable while the log already holds signed
    /// ones: held here (up to 500) and written, signed, once the key is back. Writing them unsigned would look like tampering.
    private var pendingAudit: [(at: Millis, actor: String, action: String, subject: String?, detail: JSONValue)] = []
    public var pendingAuditCount: Int { pendingAudit.count }

    func audit(actor: String, action: String, subject: String? = nil,
                       detail: JSONValue = .object([:]), at stamp: Millis? = nil) throws {
        if trustKey == nil, stamp == nil,
           try db.query("SELECT hash FROM audit ORDER BY id DESC LIMIT 1").first?.string("hash")?.hasPrefix("h:") == true {
            if pendingAudit.count < 500 { pendingAudit.append((now(), actor, action, subject, detail)) }
            return
        }
        let prev = try db.query("SELECT hash FROM audit ORDER BY id DESC LIMIT 1").first?.string("hash")
            ?? Self.genesisHash
        let at = stamp ?? now()
        let detailText = try detail.canonicalText()
        let hash = try Self.auditHash(prev: prev, at: at, actor: actor, action: action, subject: subject,
                                      detail: detailText, key: trustKey)
        try db.execute("""
            INSERT INTO audit (at, actor, action, subject, detail, prev_hash, hash) VALUES (?, ?, ?, ?, ?, ?, ?)
            """, [.integer(at), .text(actor), .text(action), subject.map(SQLValue.text) ?? .null,
                  .text(detailText), .text(prev), .text(hash)])
    }

    /// With the trust key (Keychain, only Hmunmawi has it) the entry is signed ("h:" + HMAC), so someone who can
    /// edit the database can't rewrite the log and recompute the chain. Without it, a plain SHA-256 link.
    static func auditHash(prev: String, at: Millis, actor: String, action: String, subject: String?,
                          detail: String, key: SymmetricKey? = nil) throws -> String {
        let fields = [prev, String(at), actor, action, subject ?? "", detail]
        let canonical = try JSONEncoder().encode(fields)
        if let key {
            return "h:" + HMAC<SHA256>.authenticationCode(for: canonical, using: key).map { String(format: "%02x", $0) }.joined()
        }
        return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    }

    /// Returns the id of the first entry that was changed, removed or reordered, or nil if the chain is intact.
    /// `requireSigned`: the log has been signed before (the app remembers), so its newest entry must be signed
    /// too; otherwise someone could rewrite everything as plain unsigned links. Once one entry is signed, every
    /// later one must be. Signed entries are only checked when the key is at hand.
    public func firstBrokenAuditEntry(requireSigned: Bool = false) throws -> Int64? {
        // After old entries are pruned, the chain continues from the hash of the last pruned entry.
        var expectedPrev = try db.query("SELECT prev_hash FROM audit_anchor WHERE id = 1").first?.string("prev_hash") ?? Self.genesisHash
        var sawSigned = false, lastID: Int64?, lastSigned = false
        for row in try db.query("SELECT * FROM audit ORDER BY id") {
            let id = row.int("id") ?? 0
            let stored = row.string("hash") ?? ""
            let signed = stored.hasPrefix("h:")
            if sawSigned && !signed { return id }
            let fields = (prev: row.string("prev_hash") ?? "", at: row.int("at") ?? 0, actor: row.string("actor") ?? "",
                          action: row.string("action") ?? "", subject: row.string("subject"), detail: row.string("detail") ?? "")
            if row.string("prev_hash") != expectedPrev { return id }
            if !signed || trustKey != nil {
                let recomputed = try Self.auditHash(prev: fields.prev, at: fields.at, actor: fields.actor, action: fields.action,
                                                    subject: fields.subject, detail: fields.detail, key: signed ? trustKey : nil)
                if recomputed != stored { return id }
            }
            sawSigned = sawSigned || signed
            expectedPrev = stored; lastID = id; lastSigned = signed
        }
        if requireSigned, let lastID, !lastSigned { return lastID }
        return nil
    }

    public func auditHead() throws -> (id: Int64, hash: String)? {
        guard let row = try db.query("SELECT id, hash FROM audit ORDER BY id DESC LIMIT 1").first,
              let id = row.int("id"), let hash = row.string("hash") else { return nil }
        return (id, hash)
    }

    /// Whether the entry with this id and hash is still in the log (entries pruned by the app's own trimming count as there).
    public func auditEntryExists(id: Int64, hash: String) throws -> Bool {
        let pruned = try db.query("SELECT pruned_through FROM audit_anchor WHERE id = 1").first?.int("pruned_through") ?? 0
        if id <= pruned { return true }
        return try db.query("SELECT hash FROM audit WHERE id = ?", [.integer(id)]).first?.string("hash") == hash
    }

    /// The newest audit entry by one actor for one action (e.g. a connection's last failed check), or nil.
    public func latestAudit(actor: String, action: String) throws -> AuditEntry? {
        try db.query("SELECT * FROM audit WHERE actor = ? AND action = ? ORDER BY id DESC LIMIT 1",
                     [.text(actor), .text(action)]).first.map { row in
            AuditEntry(id: row.int("id") ?? 0, at: row.int("at") ?? 0, actor: row.string("actor") ?? "",
                       action: row.string("action") ?? "", subject: row.string("subject"),
                       detail: (try? JSONValue.parse(row.string("detail") ?? "{}")) ?? .null)
        }
    }

    public func recentAudit(limit: Int = 100) throws -> [AuditEntry] {
        try db.query("SELECT * FROM audit ORDER BY id DESC LIMIT ?", [.integer(Int64(limit))]).map { row in
            AuditEntry(id: row.int("id") ?? 0, at: row.int("at") ?? 0, actor: row.string("actor") ?? "",
                       action: row.string("action") ?? "", subject: row.string("subject"),
                       detail: (try? JSONValue.parse(row.string("detail") ?? "{}")) ?? .null)
        }
    }

    /// Keeps the database from growing forever. Removes, older than `days`: finished jobs, routine snapshots
    /// and statuses (sales, purchases and reviews are kept for good: they're small and feed lifetime figures),
    /// and the oldest stretch of the audit log. The audit chain stays verifiable: the hash of the last removed
    /// entry becomes the new starting point, and a "audit.pruned" entry records what went.
    @discardableResult
    public func prune(olderThanDays days: Int = 90, auditDays: Int = 365) throws -> (audit: Int, events: Int, jobs: Int) {
        let result: (audit: Int, events: Int, jobs: Int) = try db.transaction {
            let cutoff = now() - Millis(days) * 86_400_000
            let auditCutoff = now() - Millis(auditDays) * 86_400_000
            try db.execute("DELETE FROM jobs WHERE state IN ('done','skipped','failed') AND updated_at < ?", [.integer(cutoff)])
            let jobs = db.changes
            try db.execute("""
                DELETE FROM events WHERE occurred_at < ? AND id NOT IN (SELECT event_id FROM jobs WHERE event_id IS NOT NULL)
                  AND kind NOT LIKE 'revenue.%' AND kind NOT LIKE 'review.%' AND kind NOT IN ('finance.month', 'finance.forecast', 'subscription.mrr', 'subscription.events')
                """, [.integer(cutoff)])
            let events = db.changes
            guard let last = try db.query("SELECT id, hash FROM audit WHERE at < ? ORDER BY id DESC LIMIT 1", [.integer(auditCutoff)]).first,
                  let lastID = last.int("id"), let lastHash = last.string("hash") else { return (0, events, jobs) }
            try db.execute("DELETE FROM audit WHERE id <= ?", [.integer(lastID)])
            let audit = db.changes
            try db.execute("INSERT OR REPLACE INTO audit_anchor (id, prev_hash, pruned_through) VALUES (1, ?, ?)",
                           [.text(lastHash), .integer(lastID)])
            try self.audit(actor: "app", action: "audit.pruned", detail: .object([
                "audit": .number(Double(audit)), "events": .number(Double(events)), "jobs": .number(Double(jobs)), "days": .number(Double(days))]))
            return (audit, events, jobs)
        }
        // Give the space back once a quarter or more of the file is free (rows trimmed above); otherwise leave it.
        let free = try db.query("PRAGMA freelist_count").first?.int("freelist_count") ?? 0
        let pages = try db.query("PRAGMA page_count").first?.int("page_count") ?? 1
        if pages > 0, Double(free) / Double(pages) > 0.25 { try db.execute("VACUUM") }
        if result.events > 0 { eventsEpoch += 1 }
        return result
    }

    // Test hook for simulating tampering.
    func rawExecute(_ sql: String) throws { try db.execute(sql) }
}

public enum StoreError: Error, Equatable, Sendable {
    case invalidTransition(jobID: Int64, to: JobState)
}

enum Schema {
    static let migrations: [String] = [
        """
        CREATE TABLE events (
            id INTEGER PRIMARY KEY,
            source TEXT NOT NULL,
            kind TEXT NOT NULL,
            app TEXT,
            payload TEXT NOT NULL,
            occurred_at INTEGER NOT NULL,
            received_at INTEGER NOT NULL,
            dedupe_key TEXT NOT NULL UNIQUE
        );
        CREATE INDEX events_kind_time ON events (kind, occurred_at);

        CREATE TABLE jobs (
            id INTEGER PRIMARY KEY,
            kind TEXT NOT NULL,
            resource TEXT NOT NULL,
            priority INTEGER NOT NULL,
            state TEXT NOT NULL CHECK (state IN ('queued','running','done','failed','waiting_approval','skipped')),
            attempts INTEGER NOT NULL DEFAULT 0,
            max_attempts INTEGER NOT NULL,
            run_after INTEGER NOT NULL,
            owner TEXT,
            rule_id TEXT,
            event_id INTEGER REFERENCES events (id),
            payload TEXT NOT NULL,
            last_error TEXT,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        );
        CREATE INDEX jobs_ready ON jobs (state, run_after, priority);
        CREATE INDEX jobs_resource ON jobs (resource, state);

        CREATE TABLE rule_fires (
            cooldown_key TEXT PRIMARY KEY,
            fired_at INTEGER NOT NULL
        );

        CREATE TABLE audit (
            id INTEGER PRIMARY KEY,
            at INTEGER NOT NULL,
            actor TEXT NOT NULL,
            action TEXT NOT NULL,
            subject TEXT,
            detail TEXT NOT NULL,
            prev_hash TEXT NOT NULL,
            hash TEXT NOT NULL
        );
        """,
        """
        CREATE TABLE plugin_approvals (
            plugin_id TEXT PRIMARY KEY,
            manifest_sha TEXT NOT NULL,
            approved_at INTEGER NOT NULL,
            approved_by TEXT NOT NULL
        );
        """,
        """
        CREATE INDEX audit_action ON audit (action, at);
        CREATE TABLE audit_anchor (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            prev_hash TEXT NOT NULL,
            pruned_through INTEGER NOT NULL
        );
        """,
        // 4: reads by time ("the last 8 days") use an index instead of scanning every event.
        """
        CREATE INDEX events_time ON events (occurred_at);
        """,
        // 5: insights read 60 days without touching payloads (stored before occurred_at, so a table scan reads
        // every payload): a flag for "payload has a top-level days/day" set when stored, and a covering index.
        """
        ALTER TABLE events ADD COLUMN has_day INTEGER NOT NULL DEFAULT 0;
        UPDATE events SET has_day = 1 WHERE json_valid(payload)
            AND (json_extract(payload, '$.days') IS NOT NULL OR json_extract(payload, '$.day') IS NOT NULL);
        CREATE INDEX events_time_cover ON events (occurred_at, kind, has_day, id, source, app);
        DROP INDEX events_time;
        """,
        // 6: a "day"/"days" key that is present but null also counts (the extractor treats it as present).
        """
        UPDATE events SET has_day = 1 WHERE has_day = 0 AND payload LIKE '%"day%' AND json_valid(payload)
            AND (json_type(payload, '$.days') IS NOT NULL OR json_type(payload, '$.day') IS NOT NULL);
        """,
        // 7: add-on approvals are signed by the app (see Store.isPluginApproved).
        """
        ALTER TABLE plugin_approvals ADD COLUMN signature TEXT;
        """,
        // 8: approvals are tied to permission shape, not the add-on code signature (re-sign friendly).
        """
        ALTER TABLE plugin_approvals ADD COLUMN permissions_sha TEXT;
        """,
    ]

    /// The version a fully upgraded database has.
    static var latestVersion: Int { migrations.count }

    /// The version stored in a database file (0 for a new or unreadable one).
    static func version(of connection: SQLiteConnection) -> Int {
        Int((try? connection.query("PRAGMA user_version").first?.int("user_version")) ?? 0)
    }

    static func migrate(_ db: SQLiteConnection) throws {
        let current = Int(try db.query("PRAGMA user_version").first?.int("user_version") ?? 0)
        for (index, script) in migrations.enumerated() where index >= current {
            try db.transaction {
                // Re-read under the write lock: another connection (the CLI, a second window) may have just done it.
                let now = Int(try db.query("PRAGMA user_version").first?.int("user_version") ?? 0)
                guard now == index else { return }
                try db.executeScript(script)
                try db.execute("PRAGMA user_version = \(index + 1)")
            }
        }
    }
}

/// How often a rule has fired and when it last did (jobs it created, plus its tried-out runs).
public struct RuleStat: Sendable {
    public let count: Int
    public let last: Millis
}

extension Store {
    public func ruleStats() throws -> [String: RuleStat] {
        var out: [String: RuleStat] = [:]
        for row in try db.query("SELECT rule_id, COUNT(*) AS c, MAX(created_at) AS m FROM jobs WHERE rule_id IS NOT NULL GROUP BY rule_id") {
            guard let id = row.string("rule_id") else { continue }
            out[id] = RuleStat(count: Int(row.int("c") ?? 0), last: row.int("m") ?? 0)
        }
        for row in try db.query("SELECT subject, COUNT(*) AS c, MAX(at) AS m FROM audit WHERE action = 'rule.dry_run' GROUP BY subject") {
            guard let subject = row.string("subject"), subject.hasPrefix("rule:") else { continue }
            let id = String(subject.dropFirst(5)), prev = out[id]
            out[id] = RuleStat(count: (prev?.count ?? 0) + Int(row.int("c") ?? 0), last: max(prev?.last ?? 0, row.int("m") ?? 0))
        }
        return out
    }
}

extension Store {
    /// The latest self-healing entry for each problem kind ("heal.disk.low" -> its newest entry).
    public func latestHeals() throws -> [String: AuditEntry] {
        let rows = try db.query("""
            SELECT a.* FROM audit a JOIN (SELECT action, MAX(id) AS id FROM audit WHERE action GLOB 'heal.*' GROUP BY action) m
            ON a.id = m.id
            """)
        var out: [String: AuditEntry] = [:]
        for row in rows {
            let e = AuditEntry(id: row.int("id") ?? 0, at: row.int("at") ?? 0, actor: row.string("actor") ?? "",
                               action: row.string("action") ?? "", subject: row.string("subject"),
                               detail: (try? JSONValue.parse(row.string("detail") ?? "{}")) ?? .null)
            out[String(e.action.dropFirst("heal.".count))] = e
        }
        return out
    }
}
