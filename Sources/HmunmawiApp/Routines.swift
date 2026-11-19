import AppKit
import CryptoKit
import Foundation
import HmunmawiCore

/// What a routine Hmunmawi runs can do (Phase 1: the ones that only read and tell you; nothing here changes,
/// sends to others or publishes anything, so there is nothing to approve).
enum RoutineKind: String, CaseIterable, Identifiable {
    case remind = "remind"                // a message at set times
    case siteWatch = "site-watch"         // checks a web address; tells you when it's down and when it's back
    case offerExpiry = "offer-expiry"     // warns before App Store offer codes expire
    case morningStory = "morning-story"   // the app's morning story (once a day after 8 am)
    case weeklyDigest = "weekly-digest"   // the weekly digest (day and hour in Settings → General)
    case aiBrief = "ai-brief"             // asks your AI about your own data and tells you its answer
    case postDrafts = "post-drafts"       // a few post drafts a day from your bank (AI refills it when it runs low)
    case followUps = "follow-ups"         // tells you which outreach follow-ups are due
    case keyWatch = "key-watch"           // tells you when a connection stops accepting its key or login
    case judge = "judge-changes"          // after a change has had time, says keep, improve or undo
    case script = "run-script"            // runs your own script (Try out: with its dry-run argument, records only)
    case outreachReplies = "outreach-replies" // matches mail to your outreach; each change waits for your tap
    case macJob = "mac-job"               // starts one of your own Mac jobs (LaunchAgents) on this schedule
    case replyIdeas = "reply-ideas"       // one ready X reply per run, from Grok Bot's targets or a Safari search
    case unfollowList = "unfollow-list"   // a short daily list of accounts that don't follow back, to unfollow by hand
    var id: String { rawValue }

    var title: String {
        switch self {
        case .remind: "Remind me"
        case .siteWatch: "Watch a website"
        case .offerExpiry: "Warn before offer codes expire"
        case .morningStory: "Morning story"
        case .weeklyDigest: "Weekly digest"
        case .aiBrief: "Ask AI about my numbers"
        case .postDrafts: "Post drafts from my bank"
        case .followUps: "Follow-up reminders"
        case .keyWatch: "Warn when a key stops working"
        case .judge: "Judge my changes"
        case .script: "Run my script"
        case .outreachReplies: "Watch outreach replies"
        case .macJob: "Run one of my Mac jobs"
        case .replyIdeas: "X reply ideas"
        case .unfollowList: "X unfollow list"
        }
    }

    /// Built into the app's own refresh: their timing stays exactly as it was; the routine only switches them on or off.
    var builtIn: Bool { self == .morningStory || self == .weeklyDigest }
}

/// Routines Hmunmawi runs itself: the clock, the runs, and what each kind does. Routines live in the same job list
/// as the ones you only list (joblists/my-routines.json), so agents and the Automations map see one list.
@MainActor
final class Routines {
    static let shared = Routines()
    weak var model: AppModel?
    private var loop: Task<Void, Never>?
    private var activity: NSObjectProtocol?
    private var claimed: Set<String> = []           // run keys started this session (the store also refuses repeats)
    private var lastStart: [String: Date] = [:]     // for the 10-minute guard on runs not started by the clock or you
    private var running: Set<String> = []

    // MARK: Signing (a routine edited outside the app never runs until you approve it here)

    /// The signed fields as JSON (an array, so field and value boundaries can't be shifted by what's inside them).
    /// `off`, `last`, `title` and `detail` aren't signed: they never change what runs.
    nonisolated static func canonical(_ r: MyRoutine) -> String {
        let params: [[String]] = (r.params ?? [:]).sorted { $0.key < $1.key }.map { [$0.key, $0.value] }
        let fields: [Any] = [r.id, r.who, r.does ?? "", params, r.tell ?? "", r.mode ?? "", r.at, r.every ?? "",
                             r.days, r.catchUp ?? -1, r.elsewhere ?? ""]
        let data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Signatures carry a version prefix; "2:" is the JSON form above.
    nonisolated static let sigVersion = "2:"

    /// A job another runner does (a bot's or cloud job, no `does`): its whole text is pasted into that bot, so
    /// title, detail and proof file are signed too ("b:"). Edited outside the app, it's left out of the bot's
    /// message until you save it in the app (security audit, Nov 2026).
    nonisolated static func isListedJob(_ r: MyRoutine) -> Bool { r.does == nil && r.who != "mac" }
    nonisolated static func listedCanonical(_ r: MyRoutine, withOff: Bool = true) -> String {
        var fields: [Any] = [r.id, r.who, r.title, r.detail, r.proof ?? "", r.at, r.every ?? "", r.days, r.elsewhere ?? "",
                             (r.params ?? [:]).sorted { $0.key < $1.key }.map { [$0.key, $0.value] }]
        if withOff { fields.append(r.off == true) }   // on/off is signed too, so a paused job can't be switched on from outside
        let data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated static func signature(_ r: MyRoutine, key: SymmetricKey) -> String {
        if isListedJob(r) {
            return "c:" + HMAC<SHA256>.authenticationCode(for: Data(listedCanonical(r).utf8), using: key).map { String(format: "%02x", $0) }.joined()
        }
        return sigVersion + HMAC<SHA256>.authenticationCode(for: Data(canonical(r).utf8), using: key).map { String(format: "%02x", $0) }.joined()
    }

    /// The first form (fields joined with "|"), kept only to carry routines signed before 4 Nov 2026 over once.
    nonisolated static func legacySignature(_ r: MyRoutine, key: SymmetricKey) -> String {
        let params = (r.params ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        let text = [r.id, r.who, r.does ?? "", params, r.tell ?? "", r.mode ?? "", r.at, r.every ?? "",
                    r.days.joined(separator: ","), String(r.catchUp ?? -1), r.elsewhere ?? ""].joined(separator: "|")
        return HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: key).map { String(format: "%02x", $0) }.joined()
    }

    /// The signing key, read from the Keychain at most every 10 minutes: every list, row and tick checks each
    /// routine's signature, and a Keychain read per check stalled the window when many routines were due at once.
    private var cachedKey: (key: SymmetricKey, at: Date)?
    private var key: SymmetricKey? {
        if let c = cachedKey, Date.now.timeIntervalSince(c.at) < 600 { return c.key }
        guard let k = AppModel.trustKey(KeychainSecretStore()) else { return nil }
        cachedKey = (k, .now)
        return k
    }

    /// An id made only of the allowed characters (no "|" or other separators).
    nonisolated static func cleanID(_ id: String) -> Bool { !id.isEmpty && InputRule.identifier.clean(id) == id }

    /// True when the app signed this routine as it is now.
    func trusted(_ r: MyRoutine) -> Bool { Self.isTrusted(r, key: key) }

    nonisolated static func isTrusted(_ r: MyRoutine, key: SymmetricKey?) -> Bool {
        guard let sig = r.sig, sig.hasPrefix(isListedJob(r) ? "c:" : sigVersion), cleanID(r.id), let key else { return false }
        return sig == signature(r, key: key)
    }

    /// Re-signs, once, routines the app signed in the first form. Only ones that check out under that form and have
    /// a clean id (a forged one needs "|" in its id), so nothing edited outside the app becomes trusted.
    func upgradeSignatures() {
        guard let key else { return }
        var list = MyRoutines.read(), changed = false
        // Bot and cloud jobs signed in the first form (before `off` was covered): carried over once if they check out.
        for i in list.indices where Self.isListedJob(list[i]) && Self.cleanID(list[i].id) {
            guard let sig = list[i].sig, sig.hasPrefix("b:") else { continue }
            let old = "b:" + HMAC<SHA256>.authenticationCode(for: Data(Self.listedCanonical(list[i], withOff: false).utf8), using: key).map { String(format: "%02x", $0) }.joined()
            list[i].sig = sig == old ? Self.signature(list[i], key: key) : nil
            changed = true
        }
        // Once: the bot and cloud jobs listed today are trusted as they are (signing them started 5 Nov 2026).
        if !TrustFlags.isSet("listed-jobs-signed", legacyDefaultsKey: "HMListedJobsSigned") {
            for i in list.indices where Self.isListedJob(list[i]) && Self.cleanID(list[i].id) && list[i].sig == nil {
                list[i].sig = Self.signature(list[i], key: key); changed = true
            }
            TrustFlags.set("listed-jobs-signed")
        }
        for i in list.indices {
            guard let sig = list[i].sig, !sig.hasPrefix(Self.sigVersion), !sig.hasPrefix("b:"), list[i].does != nil else { continue }
            if Self.cleanID(list[i].id), sig == Self.legacySignature(list[i], key: key) {
                list[i].sig = Self.signature(list[i], key: key)
            } else {
                list[i].sig = nil   // stays "changed outside the app" until you approve it
            }
            changed = true
        }
        if changed { MyRoutines.write(list) }
    }

    func signed(_ r: MyRoutine) -> MyRoutine {
        var r = r
        if let key { r.sig = Self.signature(r, key: key) }
        return r
    }

    // MARK: State shown in the list

    enum State: Equatable { case on, off, elsewhere(String), needs(String), changedOutside, listed }

    func state(_ r: MyRoutine) -> State {
        guard let kindRaw = r.does else { return Self.isListedJob(r) && !trusted(r) && (r.elsewhere ?? "").isEmpty ? .changedOutside : .listed }
        if let e = r.elsewhere, !e.isEmpty { return .elsewhere(e) }
        guard let kind = RoutineKind(rawValue: kindRaw) else { return .needs("a newer Hmunmawi (unknown kind “\(kindRaw)”)") }
        // Checked before "off", so an edited routine that's switched off still shows it needs your approval.
        if !kind.builtIn, !trusted(r) { return .changedOutside }
        if r.off == true { return .off }
        if let need = needs(kind, r) { return .needs(need) }
        return .on
    }

    func needs(_ kind: RoutineKind, _ r: MyRoutine) -> String? {
        switch kind {
        case .siteWatch: (r.params?["url"]).flatMap(InputCheck.httpsURL) == nil ? "a website address" : nil
        case .remind: (r.params?["text"] ?? "").trimmingCharacters(in: .whitespaces).isEmpty ? "the reminder's words" : nil
        case .aiBrief:
            !AISettings.shared.hasKey ? "an AI key (Settings → General)"
                : (r.params?["brief"] ?? "").trimmingCharacters(in: .whitespaces).isEmpty ? "what to ask the AI" : nil
        case .postDrafts:
            Bankfile.read(r.params?["bank"] ?? "posts").isEmpty && !AISettings.shared.hasKey
                ? "posts in its bank (hm bank-add) or an AI key to write some" : nil
        case .script: ScriptRunner.executable(r.params?["command"] ?? "") == nil ? "a script this Mac can run (full path)" : nil
        case .offerExpiry, .morningStory, .weeklyDigest, .followUps, .keyWatch, .judge: nil
        case .outreachReplies: Outreach.items().isEmpty ? "an outreach list (Outreach → Setup)" : nil
        case .macJob: MacJobRoutine.plist(r.params?["label"] ?? "") == nil ? "one of your Mac jobs (its name)" : nil
        case .replyIdeas:
            ReplyIdeas.fromSafari(r)
                ? (XSafariReader.shared.enabled && XNative.validHandle(XSafariReader.shared.handle) != nil
                    ? (ReplyIdeas.topics(r).isEmpty ? "your topics" : nil)
                    : "Read via your Safari login, with your X handle (Settings → General → X numbers)")
                : FileManager.default.fileExists(atPath: ReplyIdeas.folder(r).path) ? nil
                    : "a folder where Grok Bot saves reply targets (\(ReplyIdeas.folder(r).path))"
        case .unfollowList:
            UnfollowList.fromSafari(r)
                ? (XSafariReader.shared.enabled && XNative.validHandle(XSafariReader.shared.handle) != nil ? nil
                    : "Read via your Safari login, with your X handle (Settings → General → X numbers)")
                : FileManager.default.fileExists(atPath: UnfollowList.file(r).path) ? nil
                    : "the list Grok Bot saves of accounts that don't follow back (\(UnfollowList.file(r).path))"
        }
    }

    /// Whether a built-in routine (morning story, weekly digest) is on. No routine for it yet = on, as before.
    nonisolated static func builtInOn(_ kind: RoutineKind) -> Bool {
        !MyRoutines.read().contains { $0.does == kind.rawValue && ($0.off == true || !($0.elsewhere ?? "").isEmpty) }
    }

    // MARK: First launch

    /// Adds the starter routines once. A brand-new install gets the safe ones on (they only write to the Log until you connect iMessage or ntfy); an install that
    /// already has data (a Mac with its own schedulers) gets them off, so nothing new ever runs beside them.
    func seedIfNeeded(freshInstall: Bool) {
        // Seed versions: 1 = Phase 1 starters, 2 = AI, 3 = drafts and follow-ups, 4 = key watch, 5 = judge. Each
        // version is added once (a starter you removed stays removed); on an install with data, new ones arrive off.
        let d = UserDefaults.standard
        let done = d.object(forKey: "HMRoutinesSeedVersion") as? Int ?? (d.bool(forKey: "HMRoutinesSeeded") ? 1 : 0)
        guard done < 6 else { return }
        var list = MyRoutines.read()
        func add(_ id: String, _ title: String, _ kind: RoutineKind, at: String = "09:00", every: String? = nil,
                 params: [String: String]? = nil, catchUp: Int, detail: String, on: Bool) {
            guard !list.contains(where: { $0.id == id }) else { return }
            var r = MyRoutine(id: id, title: title, who: "mac", at: at, days: [], detail: detail)
            r.does = kind.rawValue; r.params = params; r.every = every; r.catchUp = catchUp; r.mode = "hands-on"
            r.off = on ? nil : true
            list.append(signed(r))
        }
        if done < 1 {
        add("morning-story", "Morning story", .morningStory, at: "08:00", catchUp: 16 * 60,
            detail: "Once a day after 8 am: what you won, what to worry about and the next step.", on: true)
        add("weekly-digest", "Weekly digest", .weeklyDigest, at: "09:00", catchUp: 16 * 60,
            detail: "The week's numbers, at the day and hour set in Settings → General.", on: true)
        add("site-watch", "Watch your website", .siteWatch, every: "30 min", params: ["url": ""], catchUp: 30,
            detail: "Checks your site every 30 minutes; tells you when it's down twice in a row, and when it's back.", on: freshInstall)
        add("offer-expiry", "Offer codes about to expire", .offerExpiry, at: "09:00", params: ["days": "30,7,1"], catchUp: 12 * 60,
            detail: "Tells you 30, 7 and 1 day before an App Store offer code expires.", on: freshInstall)
        }
        // AI starters (Phase 2): each reads one kind of data and says nothing (and costs nothing) when there's nothing new.
        // AI routines start off everywhere: switching one on first shows exactly what it sends (owner, 4 Nov 2026).
        let onAI = false
        if done < 2 {
        add("weekly-pulse", "Weekly pulse", .aiBrief, at: "10:17",
            params: ["input": "numbers", "cap": "2", "brief": "Write my weekly pulse for my apps: what grew, what fell, and the one thing to do next week."],
            catchUp: 12 * 60, detail: "Sundays 10:17: the week in a few lines, written by your AI from your own numbers.", on: onAI)
        if let i = list.firstIndex(where: { $0.id == "weekly-pulse" }), list[i].days.isEmpty { list[i].days = ["Sun"]; list[i] = signed(list[i]) }
        add("site-ideas", "Search ideas", .aiBrief, at: "06:15",
            params: ["input": "search", "cap": "2", "brief": "From my Google search numbers, suggest one change to my website that would bring more visitors, and why."],
            catchUp: 6 * 60, detail: "Each morning: one website change worth making, from what people search for.", on: onAI)
        add("crash-review", "Crash review", .aiBrief, at: "09:30",
            params: ["input": "crashes", "cap": "2", "brief": "Look at my apps' crashes this week. Say which app and day needs attention first, and what to check."],
            catchUp: 6 * 60, detail: "Each morning when there were crashes: which one to look at first.", on: onAI)
        }
        // Phase 3: drafts from a bank, and follow-up reminders.
        if done < 3 {
        add("post-drafts", "Post drafts", .postDrafts, every: "60 min", params: ["bank": "posts", "per_day": "3", "gap": "3", "max": "280", "cap": "2"],
            catchUp: 60, detail: "Up to 3 post drafts a day, 3 hours apart, from your bank (AI writes more when it runs low). You post them yourself.", on: freshInstall)
        add("follow-ups", "Follow-up reminders", .followUps, at: "09:30", catchUp: 6 * 60,
            detail: "Each morning: which outreach follow-ups are due (one per outlet).", on: freshInstall)
        }
        // v4: keys that stop working. Nothing else watches the app's own connections, so it's useful everywhere;
        // still off on an install that already has data, like every new starter.
        if done < 4 {
        add("key-watch", "Keys that stop working", .keyWatch, every: "60 min", catchUp: 60,
            detail: "Every hour: tells you once when a connection stops accepting its key or login, and when it works again.", on: freshInstall)
        }
        // v5: judging changes. It only acts on changes you register, so nothing runs twice beside another scheduler.
        if done < 5 {
        add("judge-changes", "Judge my changes", .judge, at: "09:15", catchUp: 12 * 60,
            detail: "Each morning: any change you asked it to watch that has had its time (28 days) gets a verdict: keep, improve or undo. It only suggests.", on: freshInstall)
        }
        // v6: outreach replies. Only suggests (each change waits for your tap), so nothing runs twice beside another tool.
        if done < 6 {
        add("outreach-replies", "Outreach replies", .outreachReplies, every: "30 min", catchUp: 30,
            detail: "Every 30 minutes: mail that answers your pitches and listings, bounces, auto-replies and follow-ups you sent, as suggestions you apply with one tap.", on: freshInstall)
        }
        MyRoutines.write(list)
        d.set(true, forKey: "HMRoutinesSeeded")
        d.set(6, forKey: "HMRoutinesSeedVersion")
    }

    // MARK: The clock

    func start(model: AppModel) {
        self.model = model
        guard loop == nil else { return }
        upgradeSignatures()
        // Runs must start on the minute even while the window is closed (no App Nap delay); sleep is still allowed.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                         reason: "Hmunmawi routines run on time")
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                // Wake at the start of the next minute (a few seconds in, so "08:37" has begun everywhere).
                let now = Date.now.timeIntervalSince1970
                let wait = 60 - now.truncatingRemainder(dividingBy: 60) + 2
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    func tick(now: Date = .now) async {
        guard let model, !model.isDemo, model.liveStore != nil else { return }
        await noteMissed(now: now)
        await model.retryTrustKey()
        // The Wall of Apps list, about twice a day, only when wanted (switched on, waiting for your app, maintainer).
        if Int(now.timeIntervalSince1970 / 60) % 60 == 7 { await WallCommunity.shared.refreshIfDue() }
        // About every 10 minutes: remember the newest log entry, so a cut-off tail shows at the next launch.
        if Int(now.timeIntervalSince1970 / 60) % 10 == 0 { await model.saveAuditHead() }
        // Code marks another tracker dropped off (e.g. the portal's, copied by a Mac job): applied within a minute.
        OfferCodes.shared.importPendingPortalFile()
        // Without the signing key every routine looks "changed outside the app"; handing your Mac jobs back to
        // their own timers then would make them run twice once the key is readable again. Wait for the key.
        if key != nil { await MacJobRoutine.reconcile(MyRoutines.read(), state: { self.state($0) }) }
        // Only switching a routine off resets it: states that pass during a restart (the Keychain not read yet) must
        // not, or slots due right after the restart would count as "before the takeover" and be skipped.
        for r in MyRoutines.read() {
            if state(r) == .off { UserDefaults.standard.removeObject(forKey: "HMRoutineOnSince.\(r.id)") }
            else if state(r) == .on { _ = Self.onSince(r.id, now: now) }   // noted each minute, before any slot is due
        }
        for r in MyRoutines.read() where r.who == "mac" {
            guard state(r) == .on, let kind = RoutineKind(rawValue: r.does ?? ""), !kind.builtIn else { continue }
            guard let slot = dueSlot(r, now: now) else { continue }
            // A Mac job that had its own timer until this routine took over: slots from before the takeover
            // belonged to that timer (it may already have run them), so they are not caught up.
            if kind == .macJob, r.params?["takeover"] == "1", slot < Self.onSince(r.id, now: now).addingTimeInterval(-90) { continue }
            // An AI routine waits (unclaimed, retried each minute inside its window) while another AI job holds the lock.
            if kind == .aiBrief, Self.aiLockHeld() { continue }
            // Each run on its own task: a slow script (up to 10 minutes) never holds up the others or the clock.
            // `running` and the slot claims keep one routine from overlapping itself.
            Task { await self.run(r, kind: kind, slot: slot, by: "clock") }
        }
        // Problems your bot wrote down (a login expired, a site was down): told once each.
        let problems = BotSetup.newProblems(now: now)
        if !problems.isEmpty, BotSetup.problemsToldToday() < 10 {
            let r = MyRoutine(id: "bot-problems", title: "\(BotName.current) problem", who: "bot", at: "00:00", days: [], detail: "")
            let shown = problems.prefix(5)
            let more = problems.count > 5 ? "\n…and \(problems.count - 5) more in \(BotSetup.folder)" : ""
            let text = shown.map { "\($0.name): \($0.text.isEmpty ? "(empty)" : $0.text)" }.joined(separator: "\n") + more
            let sent = await tell(r, text: "\(BotName.current) couldn't do a job:\n\(text)", key: "bot-problems@\(Int(now.timeIntervalSince1970))", urgent: false)
            if sent.ok { BotSetup.markSeen(problems.map(\.id)) }   // only once told; a failed send tries again next minute
        }
        // A bot's (or cloud job's) file that should be there by now but isn't: told once that day.
        for r in MyRoutines.read() {
            guard let due = BotSetup.lateSince(r, now: now) else { continue }
            let key = "late-\(r.id)@\(now.localDay)"
            guard !claimed.contains(key) else { continue }
            claimed.insert(key)
            let who = r.who == "bot" ? BotName.current : (MyRoutines.whoNames[r.who] ?? r.who)
            let file = InputRule.path.clean(r.proof ?? "").replacingOccurrences(of: "{date}", with: now.localDay)
            _ = await tell(r, text: "\(who) hasn't written today's file for “\(r.title)” (expected by \(due.formatted(date: .omitted, time: .shortened))): \(file)",
                           key: key, urgent: false)
        }
    }

    /// Once after a gap (Hmunmawi closed or quit, the Mac off or asleep): which timed routines' whole catch-up window
    /// passed meanwhile, so they didn't run, told once. Repeating ones (every N min) just carry on and aren't listed.
    private var aliveChecked = false
    private func noteMissed(now: Date) async {
        // The "last alive" time lives in the Keychain (a preference could be edited to fake a notice); written every 5 minutes.
        let stored = Double(TrustFlags.text("alive-at") ?? "") ?? 0
        if Int(now.timeIntervalSince1970 / 60) % 5 == 0 || !aliveChecked { TrustFlags.setText("alive-at", String(Int(now.timeIntervalSince1970))) }
        guard !aliveChecked else { return }
        aliveChecked = true
        let last = stored
        guard last > 0 else { return }
        let alive = Date(timeIntervalSince1970: last)
        guard now.timeIntervalSince(alive) > 15 * 60 else { return }
        let from = max(alive, now.addingTimeInterval(-7 * 86_400))
        var missed: [String] = []
        for r in MyRoutines.read() where r.who == "mac" && r.every == nil {
            // Built-in ones (morning story, weekly digest) keep their own timing and catch up by themselves.
            guard state(r) == .on, let kind = RoutineKind(rawValue: r.does ?? ""), !kind.builtIn else { continue }
            let catchUp = TimeInterval(min(max(r.catchUp ?? 120, 1), 24 * 60) * 60)
            let gone = RoutineSchedule.slots(at: r.at, everyMinutes: nil, days: r.days, after: from,
                                             upTo: now.addingTimeInterval(-catchUp), calendar: .current, limit: 50)
            if !gone.isEmpty { missed.append(gone.count > 1 ? "\(r.title) (×\(gone.count))" : r.title) }
        }
        guard !missed.isEmpty else { return }
        let since = alive.formatted(date: .abbreviated, time: .shortened)
        let text = "While Hmunmawi wasn't running (since \(since)), these didn't run: \(missed.prefix(8).joined(separator: ", ")). They run again at their next time; use Run now for any you need today."
        try? await model?.liveStore?.appendAudit(actor: "routine", action: "routine.missed", subject: since,
                                                 detail: .object(["routines": .array(missed.map(JSONValue.string))]))
        let r = MyRoutine(id: "missed-runs", title: "Missed while closed", who: "mac", at: "00:00", days: [], detail: "")
        _ = await tell(r, text: text, key: "missed@\(Int(now.timeIntervalSince1970))", urgent: false)
    }

    /// When this routine was first seen on (remembered across restarts, cleared when it's off, deleted or not approved).
    nonisolated static func onSince(_ id: String, now: Date) -> Date {
        let k = "HMRoutineOnSince.\(id)", d = UserDefaults.standard
        if d.object(forKey: k) == nil { d.set(now.timeIntervalSince1970, forKey: k) }
        return Date(timeIntervalSince1970: d.double(forKey: k))
    }

    /// The clock slot this routine is in right now (its time has passed and it's still inside its catch-up window), or nil.
    private func dueSlot(_ r: MyRoutine, now: Date) -> Date? {
        let minutes = r.every.flatMap { Int($0.prefix { $0.isNumber }) }
        // Catch-up is at most a day (a hand-edited huge value would otherwise overflow the time maths).
        let catchUp = min(max(r.catchUp ?? (minutes ?? 120), 1), 24 * 60)
        return RoutineSchedule.due(at: minutes == nil ? r.at : nil, everyMinutes: minutes, days: r.days, now: now,
                                   catchUpMinutes: catchUp, calendar: .current)
    }

    /// A lock file another program holds while its AI job runs (set HMAILockFile; on a Mac with such a queue,
    /// e.g. a queue's .running file). A lock older than an hour counts as stale, so it can't block forever.
    nonisolated static func aiLockHeld() -> Bool {
        guard let path = UserDefaults.standard.string(forKey: "HMAILockFile"), !path.isEmpty,
              let date = fileModified((path as NSString).expandingTildeInPath) else { return false }
        return Date.now.timeIntervalSince(date) < 3600
    }

    enum Starter { case clock, you, agent }

    /// Runs one routine now (Run now, or an agent). Agents (and anything else not the clock or you) wait 10 minutes
    /// between runs of the same routine, so nothing can start it in a loop.
    func runNow(_ id: String, by: Starter) async -> String {
        guard let r = MyRoutines.read().first(where: { $0.id == id }) else { return "No routine with that id." }
        guard let kind = RoutineKind(rawValue: r.does ?? "") else { return "“\(r.title)” is only listed; another scheduler runs it." }
        switch state(r) {
        case .on: break
        case .off: return "“\(r.title)” is off."
        case .elsewhere(let e): return "“\(r.title)” runs elsewhere (\(e))."
        case .needs(let n): return "“\(r.title)” needs \(n) first."
        case .changedOutside: return "“\(r.title)” was changed outside the app; approve it in Automations → Your routines first."
        case .listed: return "“\(r.title)” is only listed."
        }
        if kind.builtIn { return "“\(r.title)” runs on its own schedule." }
        if running.contains(id) { return "“\(r.title)” is running now; its result shows when it ends." }
        if by == .agent, let last = lastStart[id], Date.now.timeIntervalSince(last) < 600 {
            return "“\(r.title)” ran less than 10 minutes ago; try again later."
        }
        if let note = Permissions.shared.deferIfNeeded(Permissions.macNeeds(for: r, kind: kind, tellChannel: channel(for: r))) {
            return note
        }
        await run(r, kind: kind, slot: .now, by: by == .you ? "you" : "agent")
        return MyRoutines.read().first { $0.id == id }?.last?["status"].map { "Ran “\(r.title)”: \($0)." } ?? "Ran “\(r.title)”."
    }

    private func run(_ r: MyRoutine, kind: RoutineKind, slot: Date, by: String) async {
        guard let model, let store = model.liveStore, !running.contains(r.id) else { return }
        // Check silently before claiming the slot, so a missing grant can be retried after it is allowed.
        if Permissions.shared.deferIfNeeded(Permissions.macNeeds(for: r, kind: kind, tellChannel: channel(for: r))) != nil {
            return
        }
        let key = by == "clock" ? RoutineSchedule.key(r.id, slot, calendar: .current) : "\(r.id)@\(by)-\(Int(slot.timeIntervalSince1970))"
        guard !claimed.contains(key) else { return }
        claimed.insert(key)
        // Claim the run in the store first: a restart, a second window or a crash can never run (and send) it twice.
        let claim = Event(source: "routine", kind: "routine.run", app: nil,
                          payload: .object(["routine": .string(r.id), "title": .string(r.title), "slot": .string(key), "by": .string(by)]),
                          occurredAt: Millis(Date.now.timeIntervalSince1970 * 1000), dedupeKey: "routine-run:\(key)")
        let result: IngestResult
        do { result = try await store.ingest(claim, rules: []) } catch {
            claimed.remove(key)   // the store was busy: try this slot again next minute
            return
        }
        guard !result.duplicate, !running.contains(r.id) else { return }
        // A manual run inside a clock slot counts as that slot's run, so the clock doesn't start it again a minute later.
        if by != "clock", let due = dueSlot(r, now: slot) {
            let slotKey = RoutineSchedule.key(r.id, due, calendar: .current)
            claimed.insert(slotKey)
            let mark = Event(source: "routine", kind: "routine.run", app: nil,
                             payload: .object(["routine": .string(r.id), "title": .string(r.title), "slot": .string(slotKey), "by": .string(by)]),
                             occurredAt: Millis(Date.now.timeIntervalSince1970 * 1000), dedupeKey: "routine-run:\(slotKey)")
            _ = try? await store.ingest(mark, rules: [])
        }
        running.insert(r.id); defer { running.remove(r.id) }
        lastStart[r.id] = .now
        let outcome: (ok: Bool, note: String)
        switch kind {
        // You chose this time yourself, so it is delivered then (quiet hours hold automatic alerts, not your own reminders).
        case .remind: outcome = await tell(r, text: r.params?["text"] ?? "", key: key, urgent: true)
        case .siteWatch: outcome = await siteWatch(r, key: key)
        case .offerExpiry: outcome = await offerExpiry(r)
        case .aiBrief: outcome = await aiBrief(r, key: key)
        case .postDrafts: outcome = await postDrafts(r, key: key)
        case .followUps: outcome = await followUps(r)
        case .keyWatch: outcome = await keyWatch(r, key: key)
        case .judge: outcome = await judgeChanges(r, key: key)
        case .script: outcome = await runScript(r)
        case .outreachReplies: outcome = await outreachReplies(r, key: key)
        case .macJob: outcome = await MacJobRoutine.start(r.params?["label"] ?? "")
        case .replyIdeas: outcome = await replyIdeas(r, key: key)
        case .unfollowList: outcome = await unfollowList(r, key: key)
        case .morningStory, .weeklyDigest: outcome = (true, "")
        }
        record(r.id, ok: outcome.ok)
        // "Tell me each time it runs": a short note even when there was nothing to say (never twice for one run).
        // Try out records only: no note then either.
        if outcome.ok, r.params?["done"] == "1", !(kind == .script && r.params?["try"] == "1"),
           !outcome.note.hasPrefix("Sent"), !outcome.note.hasPrefix("Saved in Log") {
            // A script's own output stays in its log (it can hold anything); the message says only that it ran.
            let what = kind == .script ? "finished fine" : outcome.note
            _ = await tell(r, text: "“\(r.title)” ran: \(what)", key: key + "-done", urgent: false)
        }
        if !outcome.ok, !(kind == .script && r.params?["try"] == "1") {
            // A failed routine is a failed Mac job: shown on Today and sent by any job-failed rule, as for launchd jobs.
            let failed = Event(source: "routine", kind: "job.failed", app: r.title,
                               payload: .object(["routine": .string(r.id), "error": .string(outcome.note)]),
                               occurredAt: Millis(Date.now.timeIntervalSince1970 * 1000), dedupeKey: "routine-failed:\(key)")
            _ = try? await store.ingest(failed, rules: await model.rulesFor(failed))
        }
        if outcome.ok, !(kind == .script && r.params?["try"] == "1") {
            // A success is recorded too, so a failure of this routine is cleared by any later successful run.
            let done = Event(source: "routine", kind: "job.finished", app: r.title,
                             payload: .object(["routine": .string(r.id)]),
                             occurredAt: Millis(Date.now.timeIntervalSince1970 * 1000), dedupeKey: "routine-ok:\(key)")
            _ = try? await store.ingest(done, rules: [])
        }
        try? await store.appendAudit(actor: by == "agent" ? "agent" : by == "you" ? "owner" : "routine",
                                     action: outcome.ok ? "routine.ran" : "routine.failed", subject: r.id,
                                     detail: .object(["note": .string(outcome.note)]))
    }

    /// A problem outside a run (e.g. a Mac job's timer couldn't be taken over): in the activity log, once an hour.
    private var noted: [String: Date] = [:]
    func note(_ r: MyRoutine, _ text: String) {
        if let t = noted[r.id], Date.now.timeIntervalSince(t) < 3600 { return }
        noted[r.id] = .now
        Task { try? await model?.liveStore?.appendAudit(actor: "routine", action: "routine.problem", subject: r.id, detail: .object(["note": .string(text)])) }
    }

    /// Writes the last run's status into the list, for the Automations map and the routine list.
    private func record(_ id: String, ok: Bool) {
        var list = MyRoutines.read()
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        list[i].last = ["date": Date.now.localDay, "status": ok ? "ran" : "failed"]
        MyRoutines.write(list)   // `last` isn't part of the signature, so the routine stays trusted
    }

    // MARK: Agents: banks and outreach (data only; nothing here sends or runs anything)

    func agentData(_ command: String, _ args: [String: String], dryRun: Bool = false) -> [String: Any] {
        func fail(_ m: String) -> [String: Any] { ["ok": false, "error": m] }
        let today = Date.now.localDay
        switch command {
        case "bank-list":
            let bank = InputRule.identifier.clean(args["bank"] ?? "posts")
            let items = Bankfile.read(bank)
            return ["ok": true, "result": ["bank": bank, "available": Bank.available(items, today: today),
                                           "items": items.map { ["id": $0.id, "text": $0.text, "used_on": $0.used_on ?? ""] as [String: String] }]]
        case "bank-add":
            let bank = InputRule.identifier.clean(args["bank"] ?? "posts")
            let text = InputRule.text(1000).clean(args["text"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bank.isEmpty, !text.isEmpty else { return fail("Give text=<the draft> (and bank=<name>, default posts).") }
            var items = Bankfile.read(bank)
            guard items.count < 2000 else { return fail("That bank is full (2,000 items).") }
            items.append(BankItem(id: UUID().uuidString.prefix(8).lowercased(), text: text, tag: args["tag"].map { InputRule.identifier.clean($0) }))
            if !dryRun { Bankfile.write(bank, items) }
            return ["ok": true, "result": "Added to \(bank) (\(Bank.available(items, today: today)) ready)."]
        case "change-list":
            return ["ok": true, "result": Changesfile.read().map { c -> [String: Any] in
                ["id": c.id, "what": c.what, "metric": c.metric, "metric_name": c.metricName ?? NSNull(), "date": c.date, "days": c.days,
                 "better": c.better ?? NSNull(), "verdict": c.verdict ?? "watching", "note": c.note ?? NSNull(), "judged_on": c.judgedOn ?? NSNull()] }]
        case "change-remove":
            let id = InputRule.identifier.clean(args["id"] ?? "")
            var l = Changesfile.read()
            guard let i = l.firstIndex(where: { $0.id == id }) else { return fail("No watched change with that id.") }
            let what = l.remove(at: i).what
            if !dryRun { Changesfile.write(l) }
            return ["ok": true, "result": "Stopped watching “\(what)”."]
        case "outreach-list":
            return ["ok": true, "result": Outreachfile.read().map { e -> [String: Any] in
                ["outlet": e.outlet, "app": e.app, "type": e.type, "status": e.status, "date": e.date,
                 "follow_up": e.follow_up ?? NSNull(), "followed_up": e.followed_up ?? false, "due": e.due(today: today)] }]
        default:   // outreach-add, outreach-followed-up
            let outlet = InputRule.name.clean(args["outlet"] ?? ""), app = InputRule.name.clean(args["app"] ?? "")
            guard !outlet.isEmpty, !app.isEmpty else { return fail("Give outlet=<name> and app=<app name>.") }
            var list = Outreachfile.read()
            let i = list.firstIndex { $0.outlet == outlet && $0.app == app }
            if command == "outreach-followed-up" {
                guard let i else { return fail("No outreach to \(outlet) for \(app).") }
                list[i].followed_up = true; list[i].follow_up = nil
                if !dryRun { Outreachfile.write(list) }
                return ["ok": true, "result": "Marked the follow-up to \(outlet) as sent."]
            }
            for d in [args["date"], args["follow_up"]].compactMap({ $0 }) where DayNumber.of(d) == nil { return fail("Dates are YYYY-MM-DD.") }
            // At most one follow-up per outlet (whatever the app is spelled as): once it's sent, a new date is refused.
            if args["follow_up"] != nil,
               list.contains(where: { $0.outlet.caseInsensitiveCompare(outlet) == .orderedSame && $0.followed_up == true }) {
                return fail("A follow-up to \(outlet) was already sent; one per outlet.")
            }
            if let i {
                if let st = args["status"] { list[i].status = InputRule.identifier.clean(st) }
                if let f = args["follow_up"] { list[i].follow_up = f }
            } else {
                list.append(OutreachEntry(outlet: outlet, app: app, type: InputRule.name.clean(args["type"] ?? "press pitch"),
                                          status: InputRule.identifier.clean(args["status"] ?? "submitted"),
                                          date: args["date"] ?? today, follow_up: args["follow_up"]))
            }
            if !dryRun { Outreachfile.write(list) }
            return ["ok": true, "result": "Saved outreach to \(outlet) for \(app)."]
        }
    }

    // MARK: Agents (hm routine-…): the same list and checks as the routine form; changes are signed by the app

    func agentChange(_ command: String, _ args: [String: String], dryRun: Bool = false) -> [String: Any] {
        var list = MyRoutines.read()
        let id = InputRule.identifier.clean(args["id"] ?? "")
        let index = list.firstIndex { $0.id == id }
        func fail(_ m: String) -> [String: Any] { ["ok": false, "error": m] }
        /// A job Hmunmawi only lists (a bot's, cloud or manual one): when it runs and, optionally, the file it
        /// leaves (`proof`) and how late that file may be before you're told (`late`, minutes). Not signed: it never runs here.
        func listed(_ r: inout MyRoutine) -> [String: Any] {
            if let at = args["at"] {
                guard RoutineSchedule.time(at) != nil else { return fail("at must be a 24-hour time like 08:22.") }
                r.at = at
            }
            if let d = args["days"] {
                let days = d.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces).prefix(3)).capitalized }
                guard days.allSatisfy(RoutineSchedule.weekdays.contains) else { return fail("days are Mon,Tue,…,Sun (empty = every day).") }
                r.days = days.count == 7 ? [] : days
            }
            if let p = args["proof"] { let c = InputRule.path.clean(p); r.proof = c.isEmpty ? nil : c }
            var params = r.params ?? [:]
            if let l = args["late"] {
                guard l.isEmpty || l == "0" || (Int(l).map { (15...720).contains($0) } ?? false) else { return fail("late is minutes after its time, 15 to 720 (0 = don't tell me).") }
                params["late"] = l.isEmpty || l == "0" ? nil : l
            }
            if params["late"] != nil, r.proof == nil { return fail("late needs proof=<the file the job writes>.") }
            r.params = params.isEmpty ? nil : params
            guard !r.title.isEmpty else { return fail("Give the routine a title.") }
            if index == nil, list.count >= 200 { return fail("The list is full (200 routines); remove one first.") }
            // A listed job (no does=) comes through the app and its agent permissions, so it's signed here; one
            // that runs something waits for your OK in the app.
            r.sig = nil
            if Self.isListedJob(r) { r = signed(r) }
            if let i = index { list[i] = r } else { list.append(r) }
            if !dryRun { MyRoutines.write(list) }
            let bot = r.who == "bot" ? " Your bot's message changed: copy it again in Automations → Your routines → Set up your bot." : ""
            return ["ok": true, "result": "Saved “\(r.title)” (id \(r.id)), listed for \(MyRoutines.whoNames[r.who] ?? r.who).\(bot)"]
        }
        switch command {
        case "routine-pause", "routine-resume":
            guard let i = index else { return fail("No routine with that id.") }
            // `off` isn't signed, so pausing or resuming never signs (and so never approves) anything.
            let wasTrusted = Self.isListedJob(list[i]) && trusted(list[i])
            list[i].off = command == "routine-pause" ? true : nil
            if wasTrusted { list[i] = signed(list[i]) }   // pausing a trusted bot job keeps it trusted
            if !dryRun { MyRoutines.write(list) }
            return ["ok": true, "result": "“\(list[i].title)” is \(command == "routine-pause" ? "off" : "on")."]
        case "routine-remove":
            guard let i = index else { return fail("No routine with that id.") }
            if RoutineKind(rawValue: list[i].does ?? "")?.builtIn == true { return fail("Built-in routines can only be switched off (routine-pause).") }
            let title = list[i].title
            let removed = list.remove(at: i)
            if !dryRun { DeletedRoutines.add(removed); MyRoutines.write(list) }
            return ["ok": true, "result": "Removed “\(title)” (kept 30 days in Your routines → Recently deleted)."]
        default:   // routine-add, routine-set
            var r: MyRoutine
            if command == "routine-set" {
                guard let i = index else { return fail("No routine with that id.") }
                r = list[i]
                // Signing it again would approve whatever was edited into the file; only the owner approves that.
                if let k = RoutineKind(rawValue: r.does ?? ""), !k.builtIn, !trusted(r) {
                    return fail("“\(r.title)” was changed outside the app; the owner must approve it in Automations → Your routines first.")
                }
            } else {
                guard index == nil else { return fail("A routine with that id exists; use routine-set.") }
                r = MyRoutine(id: id.isEmpty ? UUID().uuidString : String(id.prefix(64)), title: "", who: "mac", at: "09:00", days: [], detail: "")
            }
            if let t = args["title"] { r.title = InputRule.name.clean(t) }
            if r.does == RoutineKind.script.rawValue || args["does"] == RoutineKind.script.rawValue {
                return fail("Only the owner can add or change a script routine, in the app (agents may run or pause it).")
            }
            if let d = args["does"] {
                guard let k = RoutineKind(rawValue: d), !k.builtIn else {
                    return fail("does must be one of: " + RoutineKind.allCases.filter { !$0.builtIn }.map(\.rawValue).joined(separator: ", "))
                }
                r.does = k.rawValue
                r.who = "mac"   // a routine Hmunmawi runs is always this Mac's
            }
            if let w = args["who"] {
                guard ["mac", "bot", "cloud", "you"].contains(w) else { return fail("who is mac, bot, cloud or you.") }
                guard r.does == nil || w == "mac" else { return fail("Routines Hmunmawi runs are who=mac; a bot's job is added without does=.") }
                r.who = w
            }
            if let d = args["detail"] { r.detail = InputRule.text(600).clean(d) }
            guard let kind = RoutineKind(rawValue: r.does ?? "") else { return listed(&r) }
            if kind == .morningStory, let v = args["ai"] {
                guard ["0", "1"].contains(v) else { return fail("ai is 1 (add one line from your AI) or 0.") }
                var p = r.params ?? [:]; p["ai"] = v == "1" ? "1" : nil; r.params = p.isEmpty ? nil : p
            }
            if kind.builtIn, args.keys.contains(where: { !["id", "title", "ai", "cap"].contains($0) }) {
                return fail("The \(kind.title.lowercased())'s timing is set in Settings → General; only its title can change here.")
            }
            if let at = args["at"] {
                // One time or several: "08:37" or "04:00,10:00,16:00,22:00".
                let times = RoutineSchedule.times(at)
                guard !times.isEmpty, times.count == at.split(separator: ",").count else {
                    return fail("at is a 24-hour time like 08:37, or several like 04:00,10:00,16:00.")
                }
                r.at = times.map { String(format: "%02d:%02d", $0.hour, $0.minute) }.joined(separator: ","); r.every = nil
            }
            if let e = args["every"] {
                guard let n = Int(e.prefix { $0.isNumber }), [1, 5, 15, 30, 60].contains(n) else { return fail("every must be 1, 5, 15, 30 or 60 (minutes).") }
                r.every = "\(n) min"; r.catchUp = n
            }
            if let d = args["days"] {
                let days = d.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces).prefix(3)).capitalized }
                guard days.allSatisfy(RoutineSchedule.weekdays.contains) else { return fail("days are Mon,Tue,…,Sun (empty = every day).") }
                r.days = days.count == 7 ? [] : days
            }
            var p = r.params ?? [:]
            if let t = args["text"] { p["text"] = InputRule.text(900).clean(t) }
            if let u = args["url"] {
                guard InputCheck.httpsURL(u) != nil else { return fail("url must be a full https:// address.") }
                p["url"] = u
            }
            if let b = args["brief"] { p["brief"] = InputRule.text(1500).clean(b) }
            if let b = args["bank"] {
                let name = InputRule.identifier.clean(b)
                guard !name.isEmpty else { return fail("bank is a short name like posts.") }
                p["bank"] = name
            }
            for (k, range) in [("per_day", 1...12), ("gap", 0...24), ("max", 50...5000)] {
                if let v = args[k] {
                    guard let n = Int(v), range.contains(n) else { return fail("\(k) must be a whole number from \(range.lowerBound) to \(range.upperBound).") }
                    p[k] = String(n)
                }
            }
            if let f = args["folder"] {
                let path = (f as NSString).expandingTildeInPath
                var dir: ObjCBool = false
                guard f.count < 400, FileManager.default.fileExists(atPath: path, isDirectory: &dir), dir.boolValue else { return fail("folder must be an existing folder on this Mac.") }
                p["folder"] = path
            }
            if let t = args["topics"] {
                let words = t.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                guard words.count <= 20, words.allSatisfy({ $0.count <= 40 }) else { return fail("topics is up to 20 comma-separated words or phrases.") }
                p["topics"] = words.joined(separator: ",")
            }
            if let src = args["source"] {
                guard ["bot", "safari"].contains(src.lowercased()) else { return fail("source is bot (Grok Bot's files) or safari (Hmunmawi through your Safari login).") }
                p["source"] = src.lowercased()
            }
            if let d = args["drafts"] {
                guard ["auto", "ondevice", "ai", "none"].contains(d.lowercased()) else { return fail("drafts is auto, ondevice (Apple's on-device model), ai (your AI key) or none.") }
                p["drafts"] = d.lowercased()
            }
            if let a = args["about"] {
                guard a.count <= 200, !a.contains("\n") else { return fail("about is one short line (up to 200 characters) on what you work on.") }
                p["about"] = a.trimmingCharacters(in: .whitespaces)
            }
            if let k = args["keep"] {
                let handles = k.split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " @")) }.filter { !$0.isEmpty }
                guard handles.count <= 500, handles.allSatisfy({ XNative.validHandle($0) != nil }) else { return fail("keep is a comma-separated list of X handles.") }
                p["keep"] = handles.joined(separator: ",")
            }
            if let f = args["file"] {
                let path = (f as NSString).expandingTildeInPath
                guard f.count < 400, FileManager.default.fileExists(atPath: path) else { return fail("file must be an existing file on this Mac.") }
                p["file"] = path
            }
            if let b = args["best_hours"] {
                guard b == "0" || b == "1" else { return fail("best_hours is 1 (send at your best hours from your X posts) or 0 (the routine's own times).") }
                p["best_hours"] = b
            }
            if let f = args["follow_x"] {
                guard f == "0" || f == "1" else { return fail("follow_x is 1 (follow X's published algorithm) or 0 (built-in weights).") }
                p["follow_x"] = f
            }
            if let i = args["input"] {
                guard ["numbers", "search", "crashes"].contains(i) else { return fail("input is numbers, search or crashes.") }
                p["input"] = i
            }
            if let c = args["cap"] {
                guard let v = Double(c), (0...100).contains(v) else { return fail("cap is a monthly limit in USD, 0 to 100.") }
                p["cap"] = String(v)
            }
            if let l = args["label"] {
                guard MacJobRoutine.plist(l) != nil else { return fail("label must be one of your Mac jobs; hm status lists them.") }
                p["label"] = l
            }
            if let v = args["takeover"] {
                guard ["0", "1"].contains(v) else { return fail("takeover is 1 (Hmunmawi owns the job's schedule; its own timer is backed up and removed) or 0.") }
                p["takeover"] = v == "1" ? "1" : nil
            }
            if let w = args["warn"] {
                let n = w.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                guard !n.isEmpty, n.allSatisfy({ (0...365).contains($0) }) else { return fail("warn is days before expiry, like 30,7,1.") }
                p["days"] = n.map(String.init).joined(separator: ",")
            }
            r.params = p.isEmpty ? nil : p
            if let v = args["done"] {
                guard ["0", "1", "true", "false"].contains(v) else { return fail("done is 1 (tell me each time it runs) or 0.") }
                p["done"] = v == "1" || v == "true" ? "1" : nil
                r.params = p.isEmpty ? nil : p
            }
            if let v = args["calendar"] {
                guard ["0", "1", "true", "false"].contains(v) else { return fail("calendar is 1 (also put it in my Calendar) or 0.") }
                p["calendar"] = v == "1" || v == "true" ? "1" : nil
                r.params = p.isEmpty ? nil : p
            }
            if let c = args["tell"] {
                guard ["imessage", "ntfy", ""].contains(c) else { return fail("tell is imessage or ntfy.") }
                r.tell = c.isEmpty ? nil : c
            }
            guard !r.title.isEmpty else { return fail("Give the routine a title.") }
            if r.mode == nil { r.mode = "hands-on" }
            if command == "routine-add", kind == .keyWatch || kind == .postDrafts, args["every"] == nil, args["at"] == nil { r.every = "60 min"; r.catchUp = 60 }
            if r.catchUp == nil { r.catchUp = 120 }
            if index == nil, list.count >= 200 { return fail("The list is full (200 routines); remove one first.") }
            r = signed(r)
            if let i = index { list[i] = r } else { list.append(r) }
            if !dryRun { MyRoutines.write(list) }
            let need = needs(kind, r).map { " It needs \($0) before it runs." } ?? ""
            return ["ok": true, "result": "Saved “\(r.title)” (id \(r.id)).\(need)"]
        }
    }

    // MARK: Telling you (through the same path as rules: quiet hours, limits per channel, the activity log)

    /// The channel for a routine: its own choice when that connection is allowed, else iMessage, else ntfy.
    func channel(for r: MyRoutine) -> String? {
        let allowed = Set(model?.addOns.filter(\.approved).map(\.id) ?? [])
        if let c = r.tell, allowed.contains(c) { return c }
        return ["imessage", "ntfy"].first(where: allowed.contains)
    }

    private func tell(_ r: MyRoutine, text: String, key: String, urgent: Bool) async -> (ok: Bool, note: String) {
        guard let model, let store = model.liveStore else { return (false, "The app isn't ready.") }
        let words = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(900))
        guard !words.isEmpty else { return (false, "Nothing to say.") }
        let event = Event(source: "routine", kind: "routine.tell", app: nil,
                          payload: .object(["routine": .string(r.id), "title": .string(r.title), "text": .string(words)]),
                          occurredAt: Millis(Date.now.timeIntervalSince1970 * 1000), dedupeKey: "routine-tell:\(key)")
        var rules: [Rule] = []
        if let channel = channel(for: r) {
            // Urgent news (a site down) goes out in quiet hours too, like other priority-1 alerts.
            rules = [Rule(id: "routine-\(r.id)", name: r.title, when: "routine.tell",
                          conditions: [Condition(field: "routine", op: .eq, value: .string(r.id))],
                          actions: [RuleAction(action: "notify", resource: channel)],
                          priority: urgent ? 1 : 3, cooldownSeconds: 0, approval: .auto, dryRun: false)]
        }
        let calNote = r.params?["calendar"] == "1" ? " " + CalendarEvents.add(title: r.title, notes: words, key: key) : ""
        do {
            _ = try await store.ingest(event, rules: rules)
            if !urgent, !rules.isEmpty, let until = await store.quietHours.end(after: .now) {
                return (true, "Held until \(until.formatted(date: .omitted, time: .shortened)) (quiet hours)." + calNote)
            }
            return (true, (rules.isEmpty ? "Saved in Log (no iMessage or ntfy connected)." : "Sent.") + calNote)
        } catch { return (false, "\(error)") }
    }

    // MARK: Watch a website

    /// Whether an answer means the site is up: any normal page, or one that asks for a login or slows you down.
    nonisolated static func siteAnswers(_ status: Int?) -> Bool {
        guard let status else { return false }
        return (200..<400).contains(status) || [401, 403, 405, 429].contains(status)
    }

    /// True when a well-known page answers, so "no answer from your site" can be told apart from "this Mac is offline".
    nonisolated static func internetIsUp() async -> Bool {
        for host in ["https://www.apple.com/library/test/success.html", "https://www.cloudflare.com/cdn-cgi/trace"] {
            guard let url = URL(string: host) else { continue }
            var req = URLRequest(url: url, timeoutInterval: 8)
            req.setValue("Hmunmawi site watch", forHTTPHeaderField: "User-Agent")
            if let r = (try? await URLSession(configuration: .ephemeral).data(for: req))?.1 as? HTTPURLResponse, r.statusCode < 500 { return true }
        }
        return false
    }

    private func siteWatch(_ r: MyRoutine, key: String) async -> (ok: Bool, note: String) {
        guard let url = (r.params?["url"]).flatMap(InputCheck.httpsURL) else { return (false, "No website address.") }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Hmunmawi site watch", forHTTPHeaderField: "User-Agent")
        let status = ((try? await URLSession(configuration: .ephemeral).data(for: req))?.1 as? HTTPURLResponse)?.statusCode
        // A site that answers is up, even when it asks for a login (401, 403) or slows you down (429).
        let up = Self.siteAnswers(status)
        // No answer at all can be this Mac's own connection (Wi-Fi off, asleep, VPN): check one big, reliable page
        // first, and if that fails too, skip this check instead of counting the site as down (and waking you up).
        if status == nil, await !Self.internetIsUp() { return (true, "No internet on this Mac; check skipped.") }
        let failsKey = "HMRoutineFails-\(r.id)", alertedKey = "HMRoutineAlerted-\(r.id)"
        let d = UserDefaults.standard
        let host = url.host ?? url.absoluteString
        if up {
            d.set(0, forKey: failsKey)
            if d.bool(forKey: alertedKey) {
                // Cleared only once you've been told, so a failed send tries again on the next check.
                let sent = await tell(r, text: "\(host) is back up.", key: key + "-up", urgent: false)
                if sent.ok { d.set(false, forKey: alertedKey) }
                return sent
            }
            return (true, "Up (\(status ?? 0)).")
        }
        let fails = d.integer(forKey: failsKey) + 1
        d.set(fails, forKey: failsKey)
        // Two checks in a row, so one slow answer never wakes you.
        guard fails >= 2, !d.bool(forKey: alertedKey) else { return (true, "Down check \(fails) (\(status.map(String.init) ?? "no answer")).") }
        let sent = await tell(r, text: "\(host) is down: \(status.map { "it answered \($0)" } ?? "no answer") on two checks in a row.",
                              key: key + "-down", urgent: true)
        if sent.ok { d.set(true, forKey: alertedKey) }
        return sent
    }

    // MARK: Ask AI about my numbers

    /// The data an AI routine reads ("numbers", "search", "crashes"); empty means nothing new, so no AI call is made.
    func context(_ input: String) -> String {
        guard let model else { return "" }
        switch input {
        case "search":
            guard let p = model.snapshots("growth.search").first?.payload, let text = try? p.canonicalText() else { return "" }
            return "Google Search Console, last 28 days (JSON):\n" + String(text.prefix(6000))
        case "crashes":
            let since = Millis(Date.now.addingTimeInterval(-7 * 86_400).timeIntervalSince1970 * 1000)
            let rows = AppModel.oneSourcePerDay(model.events.filter { $0.kind == "crash.daily" && $0.occurredAt >= since })
                .filter { ($0.payload[path: "crashed"]?.number ?? 0) > 0 }
                .map { "\($0.app ?? "?") \($0.payload[path: "day"]?.string ?? ""): \(Int($0.payload[path: "crashed"]?.number ?? 0)) crashed\($0.payload[path: "sessions"]?.number.map { " of \(Int($0)) sessions" } ?? "")" }
            return rows.isEmpty ? "" : "Crashes in the last 7 days:\n" + rows.prefix(60).joined(separator: "\n")
        default:
            return model.weeklyDigestText(allFindings: model.findings) ?? ""
        }
    }

    /// The most one call can cost: the prompt (about 3.5 characters a token) plus the full 4,000-token answer.
    /// Checked before a call, so a routine's monthly cap is never passed, not even by one call.
    static func worstCost(_ prompt: String) -> Double {
        guard let (i, o) = AISettings.shared.prices else { return 0 }
        return Double(prompt.count) / 3.5 / 1e6 * i + 4000 / 1e6 * o
    }

    /// Spend per routine this month (USD), from the app's own AI usage before and after each call.
    static func spent(_ id: String) -> Double {
        let d = UserDefaults.standard.dictionary(forKey: "HMRoutineAI-\(id)") ?? [:]
        return d["month"] as? String == AISettings.monthKey() ? (d["usd"] as? Double ?? 0) : 0
    }

    private func aiBrief(_ r: MyRoutine, key: String) async -> (ok: Bool, note: String) {
        let input = r.params?["input"] ?? "numbers"
        let data = context(input)
        // Nothing new: no AI call and no message (bank first, AI last; cost only when there's something to say).
        guard !data.isEmpty else { return (true, "Nothing new to ask about.") }
        let cap = Self.cap(r, 2)
        guard Self.spent(r.id) < cap else { return (true, "This routine's AI cap ($\(cap) a month) is used up.") }
        let brief = r.params?["brief"] ?? ""
        let prompt = """
        \(brief)

        Answer in plain words, under 900 characters, no headings or markdown. Use only the numbers below; never invent one. \
        If nothing is worth saying, answer exactly: NOTHING.

        \(data)
        """
        guard Self.spent(r.id) + Self.worstCost(prompt) <= cap else { return (true, "This call could pass this routine's AI cap ($\(cap) a month); skipped.") }
        let before = AISettings.shared.usdThisMonth
        do {
            let answer = try await AIWriter.draft(prompt).trimmingCharacters(in: .whitespacesAndNewlines)
            let cost = max(0, AISettings.shared.usdThisMonth - before)
            UserDefaults.standard.set(["month": AISettings.monthKey(), "usd": Self.spent(r.id) + cost], forKey: "HMRoutineAI-\(r.id)")
            guard !answer.isEmpty, answer.uppercased() != "NOTHING" else { return (true, "AI found nothing worth saying.") }
            // A summary sent only to you is its own preview: nothing else changes until you act on it.
            return await tell(r, text: "\(r.title) (AI): \(answer)", key: key, urgent: false)
        } catch {
            return (false, (error as? WireError)?.message ?? "\(error)")
        }
    }

    /// The morning story's optional AI line (its routine's "ai" = "1"): one sentence from your numbers, within the
    /// routine's own monthly cap (default $1), never while another AI job runs. nil = no line today.
    func morningLine() async -> String? {
        // Signed like any routine that spends: an "ai" switched on by editing the file outside the app is ignored.
        guard let r = MyRoutines.read().first(where: { $0.does == RoutineKind.morningStory.rawValue }), r.params?["ai"] == "1", trusted(r),
              AISettings.shared.hasKey, AISettings.shared.budgetLeft, !Self.aiLockHeld(),
              Self.spent(r.id) < Self.cap(r, 1) else { return nil }
        let data = context("numbers")
        guard !data.isEmpty else { return nil }
        let prompt = """
        In one short sentence (under 200 characters), the single most useful thing for me to know or do today about my \
        apps. Use only the numbers below; never invent one. No markdown. If nothing stands out, answer exactly: NOTHING.

        \(data)
        """
        guard Self.spent(r.id) + Self.worstCost(prompt) <= Self.cap(r, 1) else { return nil }
        let before = AISettings.shared.usdThisMonth
        guard let answer = try? await AIWriter.draft(prompt).trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        UserDefaults.standard.set(["month": AISettings.monthKey(), "usd": Self.spent(r.id) + max(0, AISettings.shared.usdThisMonth - before)],
                                  forKey: "HMRoutineAI-\(r.id)")
        guard !answer.isEmpty, answer.uppercased() != "NOTHING" else { return nil }
        return "\(Byline.ai(AISettings.shared.provider.name)): \(String(answer.prefix(240)))"
    }

    // MARK: Post drafts from a bank (bank first, AI last)

    private func postDrafts(_ r: MyRoutine, key: String) async -> (ok: Bool, note: String) {
        guard let model else { return (false, "The app isn't ready.") }
        let bank = r.params?["bank"] ?? "posts"
        let perDay = Int(r.params?["per_day"] ?? "") ?? 3
        let gapHours = min(max(Self.finite(r.params?["gap"]) ?? 3, 0), 24)
        let maxLength = Int(r.params?["max"] ?? "") ?? 280
        let today = Date.now.localDay
        let stateKey = "HMRoutineDrafts-\(r.id)"
        var st = UserDefaults.standard.dictionary(forKey: stateKey) ?? [:]
        if st["date"] as? String != today { st = ["date": today, "count": 0, "last": 0.0] }
        let count = st["count"] as? Int ?? 0
        let last = st["last"] as? Double ?? 0
        guard count < perDay else { return (true, "Today's \(perDay) drafts are done.") }
        guard Date.now.timeIntervalSince1970 - last >= gapHours * 3600 else { return (true, "Next draft after the \(Int(gapHours)) h gap.") }
        // At your best hours, from your own X posts (when an X file is there and best_hours isn't 0).
        if r.params?["best_hours"] != "0", let hours = Self.bestHours(perDay: perDay, gap: Int(gapHours)) {
            let now = Calendar.current.component(.hour, from: .now)
            guard hours.contains(now) else {
                let next = hours.first { $0 > now } ?? hours.first ?? now
                return (true, String(format: "Next draft at your best hour, %02d:00 (from your X posts: %@).", next,
                                     hours.map { String(format: "%02d", $0) }.joined(separator: ", ")))
            }
        }
        var items = Bankfile.read(bank)
        // Running low: ask the AI for a few more (only when a key is set and this routine's cap allows).
        if Bank.available(items, today: today) < perDay * 2, AISettings.shared.hasKey,
           Self.spent(r.id) < Self.cap(r, 2), !Self.aiLockHeld() {
            _ = await refill(r, bank: bank, maxLength: maxLength)
            items = Bankfile.read(bank)   // re-read: refill saved its drafts, and an agent may have added some meanwhile
        }
        var versions: [String: String] = [:]
        for snap in model.snapshots("app.snapshot") { if let a = snap.app, let v = snap.payload[path: "version"]?.string { versions[a] = v } }
        // Follow X's published ranking (daily check, off with follow_x=0), then skip weak drafts and send the best first.
        let tuned = r.params?["follow_x"] == "0" ? nil : await XRules.checkIfDue()
        if let tuned { try? await model.liveStore?.appendAudit(actor: "routine:\(r.id)", action: "x.rules_tuned", detail: .object(["note": .string(tuned)])) }
        let rules = XRules.current
        var refused: [String] = []
        guard let item = Bank.next(items, today: today, allowed: { i in
            if let why = DraftGuard.problem(i.text, versions: versions, maxLength: maxLength) { refused.append("\(i.id): \(why)"); return false }
            if let why = PostQuality.problem(i.text, rules: rules) { refused.append("\(i.id): \(why)"); return false }
            return true
        }, score: { PostQuality.score($0.text, rules: rules) }) else { return (true, refused.isEmpty ? "The bank is empty." : "Every unused draft was refused: " + refused.prefix(3).joined(separator: "; ")) }
        // A draft only: you post it yourself (nothing is ever posted on its own). Marked used only once it reached you.
        let sent = await tell(r, text: "Draft to post (\(count + 1) of \(perDay) today):\n\(item.text)", key: key, urgent: false)
        guard sent.ok else { return sent }
        var fresh = Bankfile.read(bank)   // re-read: an agent or the editor may have changed it while sending
        if let i = fresh.firstIndex(where: { $0.id == item.id }) { fresh[i].used_on = today; Bankfile.write(bank, fresh) }
        st["count"] = count + 1; st["last"] = Date.now.timeIntervalSince1970
        UserDefaults.standard.set(st, forKey: stateKey)
        return sent
    }

    /// One reply per run (the routine's times are the reply slots), from today's file of reply targets your bot saved.
    /// Skips posts older than 48 hours, off your topics, already sent, or naming an app version that isn't current.
    private func replyIdeas(_ r: MyRoutine, key: String) async -> (ok: Bool, note: String) {
        guard let model else { return (false, "The app isn't ready.") }
        let today = Date.now.localDay
        let stateKey = "HMReplyIdeas-\(r.id)"
        var st = UserDefaults.standard.dictionary(forKey: stateKey) ?? [:]
        if st["date"] as? String != today { st = ["date": today, "sent": [String]()] }
        var sent = Set(st["sent"] as? [String] ?? [])
        let perDay = Int(r.params?["per_day"] ?? "") ?? 4
        guard sent.count < perDay else { return (true, "Today's \(perDay) reply ideas are done.") }
        if ReplyIdeas.fromSafari(r), ReplyIdeas.load(r, day: today) == nil {
            // First run of the day: search X through your Safari login and (with an AI key) draft the replies.
            let keyOK = AISettings.shared.hasKey && AISettings.shared.budgetLeft && AISettings.shared.prices != nil && !Self.aiLockHeld()
            let drafter = XSafariFinds.drafter(choice: r.params?["drafts"], onDevice: OnDeviceAI.status.available, aiKey: keyOK)
            let note = await XSafariReader.shared.findReplies(topics: ReplyIdeas.topics(r), count: perDay, about: r.params?["about"] ?? "",
                                                              day: today, drafter: drafter)
            if ReplyIdeas.load(r, day: today) == nil { return (true, note) }
        }
        guard let targets = ReplyIdeas.load(r, day: today) else {
            return (true, "No reply targets from Grok Bot for today yet (\(ReplyIdeas.folder(r).appending(path: today + ".json").path)).")
        }
        var versions: [String: String] = [:]
        for snap in model.snapshots("app.snapshot") { if let a = snap.app, let v = snap.payload[path: "version"]?.string { versions[a] = v } }
        let topics = ReplyIdeas.topics(r)
        var skipped: [String] = []
        for t in targets where !sent.contains(t.url) {
            if let why = ReplyIdeas.problem(t, topics: topics, versions: versions, now: .now) { skipped.append(why); sent.insert(t.url); continue }
            let n = sent.count + 1
            let who = t.author.map { "@" + $0.trimmingCharacters(in: CharacterSet(charactersIn: "@")) } ?? "the author"
            let text = t.reply.isEmpty
                ? "X reply \(n) of \(perDay)\n\nA fresh post on your topics, worth a reply from you:\n\(t.url)\n\n\(who): \(t.tweet.prefix(200))\n\nAdd something real: an experience, a number, a sharp question. No link in the reply."
                : "X reply \(n) of \(perDay)\n\n1. Open \(who)'s post:\n\(t.url)\n\n2. Copy this reply:\n———\n\(t.reply)\n———\n\nPost it by hand, in your own words if you change it. No link in the reply."
            let out = await tell(r, text: text, key: key, urgent: false)
            guard out.ok else { return out }
            sent.insert(t.url); st["sent"] = Array(sent); UserDefaults.standard.set(st, forKey: stateKey)
            return out
        }
        st["sent"] = Array(sent); UserDefaults.standard.set(st, forKey: stateKey)
        return (true, skipped.isEmpty ? "Every reply target for today was sent." : "No usable target left: " + skipped.prefix(3).joined(separator: "; "))
    }

    /// Today's handful of accounts to unfollow by hand (at most once a day). Hmunmawi never touches X: you unfollow.
    private func unfollowList(_ r: MyRoutine, key: String) async -> (ok: Bool, note: String) {
        let today = Date.now.localDay, stateKey = "HMUnfollowList-\(r.id)"
        var st = UserDefaults.standard.dictionary(forKey: stateKey) ?? [:]
        guard st["date"] as? String != today else { return (true, "Today's list was already sent.") }
        var refreshNote: String?
        if UnfollowList.fromSafari(r) { refreshNote = await XSafariReader.shared.refreshUnfollow(to: UnfollowList.file(r)) }
        guard let all = UnfollowList.load(r) else {
            return (true, refreshNote ?? "No list from Grok Bot yet (\(UnfollowList.file(r).path)).")
        }
        let perDay = min(max(Int(r.params?["per_day"] ?? "") ?? 10, 1), 25)
        let keep = Set((r.params?["keep"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " @")).lowercased() })
        // Handles already sent are remembered, so a list that changes every day (Safari) never repeats one.
        let done = Set(st["sent"] as? [String] ?? [])
        let batch = UnfollowList.pick(all, count: perDay, keep: keep, sent: done)
        guard !batch.isEmpty else { return (true, "The list is done: every account on it has been sent.") }
        let lines = batch.map { "• @\($0) — https://x.com/\($0)" }.joined(separator: "\n")
        let text = "X: \(batch.count) accounts that don't follow you back, to unfollow by hand today (open each, tap Following → Unfollow):\n\(lines)\n\nSpread them through the day. Hmunmawi never unfollows for you."
        let out = await tell(r, text: text, key: key, urgent: false)
        guard out.ok else { return out }
        UserDefaults.standard.set(["date": today, "sent": Array((Array(done) + batch.map { $0.lowercased() }).suffix(3000))], forKey: stateKey)
        return out
    }

    /// Your best posting hours (local time) from the X file's own original posts, or nil when there's no file or too
    /// few posts to tell.
    /// A number from a routine's saved settings, or nil when it isn't finite ("inf", "nan" parse as Doubles).
    nonisolated static func finite(_ s: String?) -> Double? { Double(s ?? "").flatMap { $0.isFinite ? $0 : nil } }
    /// A routine's monthly AI cap in USD, never unlimited: 0…1000, else the default.
    nonisolated static func cap(_ r: MyRoutine, _ fallback: Double) -> Double { min(max(finite(r.params?["cap"]) ?? fallback, 0), 1000) }

    static func bestHours(perDay: Int, gap: Int) -> [Int]? {
        let path = XFileFeed.shared.path
        guard !path.isEmpty, let d = try? Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let list = o["posts"] as? [[String: Any]] else { return nil }
        let iso = ISO8601DateFormatter(), frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func int(_ v: Any?) -> Int { (v as? Int) ?? Int((v as? String) ?? "") ?? 0 }
        let posts: [PostingHours.Post] = list.compactMap { p in
            guard (p["type"] as? String ?? "post") == "post", let raw = p["created_at"] as? String,
                  let t = iso.date(from: raw) ?? frac.date(from: raw) else { return nil }
            return .init(hour: Calendar.current.component(.hour, from: t), likes: int(p["likes"]), replies: int(p["replies"]),
                         reposts: int(p["reposts"]), quotes: int(p["quotes"]), views: int(p["impressions"]))
        }
        return PostingHours.best(posts, count: perDay, gap: gap, rules: XRules.current)
    }

    /// Five new drafts from your own numbers, added to the bank (still drafts: each goes to you before anything else).
    private func refill(_ r: MyRoutine, bank: String, maxLength: Int) async -> [BankItem] {
        let data = context("numbers")
        guard !data.isEmpty else { return [] }
        let prompt = """
        Write 5 short social posts (each under \(maxLength) characters, no links, no hashtags) about my apps, from the \
        numbers below. Only facts from these numbers. One post per line, nothing else.

        \(data)
        """
        guard Self.spent(r.id) + Self.worstCost(prompt) <= Self.cap(r, 2) else { return [] }
        let before = AISettings.shared.usdThisMonth
        guard let answer = try? await AIWriter.draft(prompt) else { return [] }
        let cost = max(0, AISettings.shared.usdThisMonth - before)
        UserDefaults.standard.set(["month": AISettings.monthKey(), "usd": Self.spent(r.id) + cost], forKey: "HMRoutineAI-\(r.id)")
        let new = answer.split(separator: "\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " -•*0123456789.)").union(.whitespaces)) }
            .filter { !$0.isEmpty && $0.count <= maxLength }.prefix(5)
            .map { BankItem(id: "ai-" + UUID().uuidString.prefix(8), text: String($0), tag: "ai") }
        var items = Bankfile.read(bank); items += new; Bankfile.write(bank, items)
        return Array(new)
    }

    // MARK: Keys and logins that stopped working

    /// A connection that failed twice in a row with an error that reads like a refused, expired or revoked key:
    /// told once, with where to fix it; told again when it works again. Outages (timeouts, server errors) are not.
    private func keyWatch(_ r: MyRoutine, key: String) async -> (ok: Bool, note: String) {
        guard let model, let store = model.liveStore else { return (false, "The app isn't ready.") }
        let failing = await model.failingConnections()
        let succeeded = await model.succeededConnections()
        let d = UserDefaults.standard
        // id -> when you were told (ms). "Works again" only after a check that really succeeded since then: right
        // after a restart nothing has been checked yet, so silence is not good news.
        var told = (d.dictionary(forKey: "HMKeyWatchTold") as? [String: Double]) ?? [:]
        let current = Set(model.addOns.filter(\.approved).map(\.id))
        told = told.filter { current.contains($0.key) }
        var lines: [String] = []
        for row in model.addOns where row.approved {
            let inRow = failing[row.id] ?? 0
            if let at = told[row.id] {
                if let ok = succeeded[row.id], Double(ok) > at { told[row.id] = nil; lines.append("\(row.manifest.name) works again.") }
                continue
            }
            // The connection's own latest failure, however many other entries came after it.
            guard inRow >= 2,
                  let err = (try? await store.latestAudit(actor: row.id, action: "plugin.poll_failed"))??.detail[path: "error"]?.string,
                  KeyTrouble.isKeyProblem(err) else { continue }
            told[row.id] = Date.now.timeIntervalSince1970 * 1000
            let plain = err.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? err
            lines.append("\(row.manifest.name) stopped accepting its key or login (\(String(plain.prefix(160)))). Reconnect it in Settings → Connections.")
        }
        guard !lines.isEmpty else {
            d.set(told, forKey: "HMKeyWatchTold")
            return (true, failing.isEmpty ? "Every connection works." : "Failures look like outages, not keys.")
        }
        // Remembered only once you've been told; a failed send tells you on the next run.
        let sent = await tell(r, text: lines.joined(separator: "\n"), key: key, urgent: false)
        if sent.ok { d.set(told, forKey: "HMKeyWatchTold") }
        return sent
    }

    // MARK: Outreach replies (suggestions only; each change waits for your tap)

    private func outreachReplies(_ r: MyRoutine, key: String) async -> (ok: Bool, note: String) {
        guard let model, let store = model.liveStore else { return (false, "The app isn't ready.") }
        let items = Outreach.items()
        guard !items.isEmpty else { return (true, "No outreach list yet.") }
        // A built-in mail source (Apple Mail or IMAP), when one is chosen in Settings, is read first.
        _ = await MailWatch.refresh(model: model)
        let since = Millis(Date.now.addingTimeInterval(-60 * 86_400).timeIntervalSince1970 * 1000)
        let events = (try? await store.events(kind: "mail.seen", since: since)) ?? []
        var versions: [String: String] = [:]
        for snap in model.snapshots("app.snapshot") { if let a = snap.app, let v = snap.payload[path: "version"]?.string { versions[a] = v } }
        let apps = Array(Set(APPName.known + items.flatMap { $0.app.split(separator: "+").map(String.init) }))
        // Matching 60 days of mail is real work: off the main thread, so the window never stalls on the half hour.
        let day = Date.now.localDay
        let fixedVersions = versions
        let (mail, suggested) = await Task.detached(priority: .utility) {
            let mail = Outreach.mail(events)
            return (mail, Outreach.suggest(items: items, mail: mail, apps: apps, today: day, versions: fixedVersions))
        }.value
        var found = suggested
        let before = Outreach.side()
        // Replies the rules couldn't place: Apple's on-device model has a go (a "maybe" you confirm).
        let knownIDs = Set(before.suggestions.map(\.id))
        for n in found.indices where found[n].thread == ThreadState.unclear.rawValue && !knownIDs.contains(found[n].id) {
            guard let text = mail.first(where: { found[n].id.hasSuffix("|" + $0.id) })?.text, let (st, ev) = await OnDeviceAI.read(text) else { continue }
            found[n].thread = st.rawValue; found[n].why = "“\(ev)” (on-device AI)"; found[n].sure = false
            if st == .declined, found[n].status != nil { found[n].status = "rejected" }
        }
        // Coverage watch: once a day, for conversations where they answered or promised something (90 days).
        let today = Date.now.localDay, t = DayNumber.of(today) ?? 0
        var feeds = before.feeds ?? [:]
        for i in items where i.isEmail && (i.status == "replied" || ["promised", "scheduled"].contains(before.threads?[i.id]?.state ?? "")) {
            var f = feeds[i.id]
            if f == nil, let url = await Outreach.discoverFeed(i) { f = Outreach.Feed(url: url, checked: nil, until: DayNumber.day(t + 90)) }
            guard var feed = f, feed.checked != today, t <= (DayNumber.of(feed.until) ?? 0) else { continue }
            if let hit = await Outreach.coverage(feed: feed.url, app: i.app, since: i.date) {
                var s = OSuggestion(id: "\(i.id)|covered|\(hit.link)", entry: i.id, outlet: i.outlet, app: i.app, kind: "covered",
                                    why: hit.title, day: today, sure: false)
                s.link = hit.link
                found.append(s)
            }
            feed.checked = today
            feeds[i.id] = feed
        }
        var fresh: [OSuggestion] = []
        Outreach.changeSide { side in
            let known = Set(side.suggestions.map(\.id))
            fresh = found.filter { !known.contains($0.id) }
            side.suggestions += fresh
            side.feeds = feeds
            for (a, v) in versions { side.versions[a] = v }   // the first run only remembers today's versions
        }
        guard !fresh.isEmpty else { return (true, mail.isEmpty ? "No mail list yet (it comes from your mail watch)." : "Nothing new in \(mail.count) messages.") }
        let words: [String: String] = ["replied": "answered", "approved": "approved", "live": "is live", "rejected": "declined",
                                       "bounced": "bounced (address failed)", "verify": "wants you to confirm your email",
                                       "followed up": "your follow-up went out", "auto-reply": "is away (auto-reply)",
                                       "no reply": "no answer after your follow-up", "launch": "follow-up should wait for the launch",
                                       "thank": "covered you: say thanks", "repitch": "worth telling about the new version",
                                       "thread": "wrote again", "answer": "waiting for your answer", "check in": "time for one friendly check-in",
                                       "covered": "may have covered you"]
        let lines = fresh.prefix(4).map { "\($0.outlet) (\($0.app)): \(words[$0.kind] ?? $0.kind)\($0.sure ? "" : "?")" }
        let more = fresh.count > 4 ? "\n…and \(fresh.count - 4) more" : ""
        return await tell(r, text: "Outreach:\n" + lines.joined(separator: "\n") + more + "\nApply or dismiss in Hmunmawi → Log → Outreach.", key: key, urgent: false)
    }

    // MARK: Run my script

    private func runScript(_ r: MyRoutine) async -> (ok: Bool, note: String) {
        guard let exe = ScriptRunner.executable(r.params?["command"] ?? "") else { return (false, "The script isn't there or can't be run.") }
        let tryOut = r.params?["try"] == "1"
        var args = ScriptRunner.split(r.params?["args"] ?? "")
        if tryOut { args += ScriptRunner.split(r.params?["try_arg"] ?? "--dry-run") }
        // Time limit: 10 minutes unless the routine says otherwise (1–60).
        let limit = min(max(Int(r.params?["limit_min"] ?? "") ?? 10, 1), 60)
        let res = await ScriptRunner.run(exe, args: args, folder: r.params?["folder"], routine: r.id, timeout: TimeInterval(limit * 60),
                                            envFile: r.params?["env"])
        let ok = !res.timedOut && (res.exit == 0 || res.exit == 75)
        // A failed run names the line that explains it, not just the last line of output.
        let last = ok ? (res.output.split(separator: "\n").last.map { String($0.prefix(160)) } ?? "") : JobFailures.errorLine(res.output)
        let what = res.timedOut ? "stopped after \(limit) minutes" : "exit \(res.exit)"
        ScriptRunner.log(r.id, header: "\(Date.now.formatted(.iso8601)) \(what)\(tryOut ? " (Try out)" : "")", output: res.output)
        // 75 is "not due yet" for scripts that keep their own clock; it counts as fine.
        return (ok, "\(what)\(tryOut ? ", Try out" : "")\(last.isEmpty ? "" : ": \(last)")")
    }

    // MARK: Judge my changes (it only suggests; nothing is undone on its own)

    private func judgeChanges(_ r: MyRoutine, key: String) async -> (ok: Bool, note: String) {
        guard let model else { return (false, "The app isn't ready.") }
        var list = Changesfile.read()
        guard let today = DayNumber.of(Date.now.localDay) else { return (false, "No date.") }
        let due = list.indices.filter { list[$0].verdict == nil && (list[$0].dueDay ?? .max) <= today }
        guard !due.isEmpty else { return (true, "Nothing to judge today.") }
        let metrics = await model.historyMetrics()
        // Numbers not loaded yet (the first refresh after opening the app hasn't finished): try again next run
        // rather than calling every change "unclear" for good.
        guard !metrics.isEmpty else { return (true, "Numbers not loaded yet; judging on the next run.") }
        var lines: [String] = []
        var judgedIDs: [String] = []
        for i in due {
            let c = list[i]
            let name = c.metricName ?? c.metric
            guard let m = metrics.first(where: { $0.key == c.metric }) else {
                // A connection may be missing for a day: wait up to a week before giving up on it.
                guard today > (c.dueDay ?? today) + 7 else { continue }
                list[i].verdict = "unclear"; list[i].note = "its number (\(name)) isn't in the last 60 days"
                lines.append("Can't judge “\(c.what)”: \(list[i].note!)."); list[i].judgedOn = Date.now.localDay
                judgedIDs.append(c.id)
                continue
            }
            judgedIDs.append(c.id)
            let up = c.better.map { $0 != "down" } ?? (m.better != .down)
            let res = Judge.judge(m.points, changeDay: c.date, days: c.days, betterUp: up, calendar: .current,
                                  saved: c.before.map { ($0, c.beforeDays ?? 0) })
            let fmt: (Double) -> String = { v in m.isMoney ? String(format: "%.2f", v) : abs(v) < 10 ? String(format: "%.1f", v) : String(format: "%.0f", v) }
            let pct = String(format: "%+.0f%%", res.change * 100)
            let figures = "\(name): \(fmt(res.before)) → \(fmt(res.after)) a day (\(pct)) over \(c.days) days"
            switch res.verdict {
            case .keep: lines.append("Keep “\(c.what)”. \(figures).")
            case .improve: lines.append("“\(c.what)” made no clear difference. \(figures). Try a stronger version, or keep it if it costs nothing.")
            case .undo: lines.append("Think about undoing “\(c.what)”. \(figures).")
            case .unclear: break
            }
            var note = figures
            if res.verdict == .unclear {
                // No base to compare with, or too few days: say which, without a misleading percentage.
                note = res.before == 0 && res.daysBefore * 2 >= c.days
                    ? "\(name) was 0 before the change, so there's nothing to compare with"
                    : "\(name) has \(res.daysBefore) days of data before and \(res.daysAfter) after; it needs \((c.days + 1) / 2) of each"
                lines.append("Not enough data to judge “\(c.what)”: \(note).")
            }
            list[i].verdict = res.verdict.rawValue; list[i].note = note; list[i].judgedOn = Date.now.localDay
        }
        // The list may have changed while the numbers were worked out (an agent or the editor): merge verdicts by id.
        // (A hand-edited file may repeat an id: the first one wins instead of stopping the app.)
        let ids = Set(judgedIDs)
        let judged = Dictionary(due.filter { ids.contains(list[$0].id) }.map { (list[$0].id, list[$0]) }, uniquingKeysWith: { a, _ in a })
        guard !judged.isEmpty else { return (true, "Waiting for a number that isn't loaded yet.") }
        Changesfile.write(Changesfile.read().map { judged[$0.id] ?? $0 })
        return await tell(r, text: lines.joined(separator: "\n"), key: key, urgent: false)
    }

    /// Numbers a change can be judged on: every metric with at least 14 days in the last 60, named for people.
    /// `better` is the number's own direction ("up" or "down"), nil when its source doesn't say (then you choose).
    func judgeableMetrics() async -> [(key: String, name: String, better: String?)] {
        guard let model else { return [] }
        var out: [(key: String, name: String, better: String?)] = []
        let today = DayNumber.of(Date.now.localDay) ?? 0
        // At least 14 of the last 28 days, so a change going live today has a "before" to compare with.
        for m in await model.historyMetrics() where Judge.average(m.points, from: today - 28, to: today, calendar: .current).days >= 14 {
            let name: String = m.app.map { app in "\(m.name) · \(ComingSoon.shortName(app))" } ?? m.name
            out.append((key: m.key, name: name, better: m.better.map { $0 == .down ? "down" : "up" }))
        }
        return out.sorted { a, b in a.name.localizedStandardCompare(b.name) == .orderedAscending }
    }

    /// Adds a change to watch (from the editor or an agent), checked the same way for both.
    func addChange(what raw: String, metric: String, date: String?, days: Int?, better: String?, dryRun: Bool = false) async -> (ok: Bool, message: String) {
        let what = InputRule.text(200).clean(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !what.isEmpty else { return (false, "Say what changed (what=…).") }
        let day = date ?? Date.now.localDay
        guard let d = DayNumber.of(day), let today = DayNumber.of(Date.now.localDay), d <= today, d >= today - 60 else {
            return (false, "date is the day it went live, YYYY-MM-DD, within the last 60 days.")
        }
        let n = days ?? 28
        guard (7...28).contains(n) else { return (false, "days is 7 to 28.") }
        if let better, !["up", "down"].contains(better) { return (false, "better is up or down.") }
        guard let model, let m = await model.historyMetrics().first(where: { $0.key == metric }) else {
            return (false, "Unknown number; pick one from metric-list.")
        }
        guard better != nil || m.better != nil else {
            return (false, "Say whether \(m.name) is better when it goes up or down (better=up or better=down).")
        }
        // The "before" days must exist now (they're saved, since some numbers keep only a month of history).
        let before = Judge.average(m.points, from: d - n, to: d, calendar: .current)
        guard before.days * 2 >= n else {
            return (false, "That number has only \(before.days) days of data in the \(n) days before \(day); it needs \((n + 1) / 2).")
        }
        let label = m.app.map { app in "\(m.name) · \(ComingSoon.shortName(app))" } ?? m.name
        var l = Changesfile.read()
        guard l.filter({ $0.verdict == nil }).count < 100 else { return (false, "Already watching 100 changes.") }
        if dryRun { return (true, "OK") }
        var change = WatchedChange(id: String(UUID().uuidString.prefix(8)).lowercased(), what: what, metric: m.key, metricName: label,
                                   date: DayNumber.day(d), days: n, better: better)
        change.before = before.avg; change.beforeDays = before.days
        l.append(change)
        Changesfile.write(l)
        let due = (change.dueDay ?? d + n + 1) - today   // the same day the editor shows (a partial today never counts)
        return (true, "Watching “\(what)” on \(label); verdict in \(max(0, due)) days.")
    }

    // MARK: Follow-up reminders

    private func followUps(_ r: MyRoutine) async -> (ok: Bool, note: String) {
        let today = Date.now.localDay
        let due = Outreachfile.read().filter { $0.due(today: today) }
        guard !due.isEmpty else { return (true, "No follow-ups due.") }
        let lines = due.prefix(10).map { "\($0.outlet) (\($0.app), \($0.type)), due \($0.follow_up ?? "")" }
        let text = "\(due.count == 1 ? "1 follow-up is" : "\(due.count) follow-ups are") due:\n" + lines.joined(separator: "\n")
            + (due.count > 10 ? "\n…and \(due.count - 10) more" : "")
        return await tell(r, text: text, key: "\(r.id)@\(today)", urgent: false)
    }

    // MARK: Offer codes about to expire

    private func offerExpiry(_ r: MyRoutine) async -> (ok: Bool, note: String) {
        guard let model else { return (false, "The app isn't ready.") }
        let warnDays = Set((r.params?["days"] ?? "30,7,1").split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
        let today = DayNumber.of(Date.now.localDay) ?? 0
        var lines: [String] = []
        for snap in model.snapshots("offercodes.snapshot") {
            let app = snap.app.map(ComingSoon.shortName) ?? "An app"
            for offer in snap.payload[path: "offers"]?.array ?? [] {
                let name = offer[path: "name"]?.string ?? "Offer"
                var ends: [(String, String)] = []
                for c in offer[path: "custom"]?.array ?? [] { if let e = c[path: "expires"]?.string { ends.append((c[path: "code"]?.string ?? name, e)) } }
                for b in offer[path: "batches"]?.array ?? [] { if let e = b[path: "expires"]?.string { ends.append((name + " one-time codes", e)) } }
                for (label, day) in ends {
                    guard let n = DayNumber.of(String(day.prefix(10))) else { continue }
                    let left = n - today
                    if warnDays.contains(left) {
                        lines.append("\(app): \(label) expires in \(left == 1 ? "1 day" : "\(left) days") (\(String(day.prefix(10)))).")
                    }
                }
            }
        }
        guard !lines.isEmpty else { return (true, "Nothing expiring on a warning day.") }
        let day = Date.now.localDay
        return await tell(r, text: Array(Set(lines)).sorted().joined(separator: "\n"), key: "\(r.id)@\(day)", urgent: false)
    }
}


/// Bank files: ~/Library/Application Support/Hmunmawi/banks/<name>.json.
enum Bankfile {
    static let folder = URL.hmSupport.appending(path: "banks")
    private struct File: Codable { var items: [BankItem] }
    static func read(_ name: String) -> [BankItem] {
        let url = folder.appending(path: InputRule.identifier.clean(name) + ".json")
        guard let d = try? Data(contentsOf: url), d.count < 2_000_000, let f = try? JSONDecoder().decode(File.self, from: d) else { return [] }
        return f.items
    }
    static func write(_ name: String, _ items: [BankItem]) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(File(items: items)).write(to: folder.appending(path: InputRule.identifier.clean(name) + ".json"), options: .atomic)
    }
}

/// Changes being watched: ~/Library/Application Support/Hmunmawi/changes.json.
enum Changesfile {
    static let url = URL.hmSupport.appending(path: "changes.json")
    private struct File: Codable { var changes: [WatchedChange] }
    static func read() -> [WatchedChange] {
        guard let d = try? Data(contentsOf: url), d.count < 2_000_000, let f = try? JSONDecoder().decode(File.self, from: d) else { return [] }
        return f.changes
    }
    static func write(_ changes: [WatchedChange]) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(File(changes: Array(changes.suffix(1000)))).write(to: url, options: .atomic)
    }
}

/// The outreach list: ~/Library/Application Support/Hmunmawi/outreach.json.
enum Outreachfile {
    static let url = URL.hmSupport.appending(path: "outreach.json")
    private struct File: Codable { var entries: [OutreachEntry] }
    static func read() -> [OutreachEntry] {
        guard let d = try? Data(contentsOf: url), d.count < 2_000_000, let f = try? JSONDecoder().decode(File.self, from: d) else { return [] }
        return f.entries
    }
    static func write(_ entries: [OutreachEntry]) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(File(entries: Array(entries.prefix(5000)))).write(to: url, options: .atomic)
    }
}
