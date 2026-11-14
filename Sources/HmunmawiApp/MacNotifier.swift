import AppKit
import HmunmawiCore
import UserNotifications

/// Mac notifications: the third way to hear about things, next to iMessage and ntfy. It reads the events the app
/// already stores on each refresh (no extra checks, no network) and lets `NotificationPlanner` decide.
/// - asks quietly first (provisional: they land in Notification Center without a prompt); Settings can ask for banners;
/// - one thread per app; bursts become one notification; quiet hours and the 6-an-hour cap apply;
/// - time-sensitive only for a broken connection or a rejected build;
/// - nothing while the Hmunmawi window is in front, nothing from sample data, private details hidden by default.
@MainActor
final class MacNotifier: NSObject {
    static let shared = MacNotifier()

    /// False in `swift test` and in any process without a bundle: UserNotifications is never touched there.
    nonisolated static var available: Bool { Bundle.main.bundleIdentifier != nil && !TestProfile.runningUnitTests }

    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private var lastSeenID: Int64? = nil
    /// Held for quiet hours or the hourly cap; kept on disk so a quit or restart doesn't lose them.
    private var later: [NotifyCandidate] = (UserDefaults.standard.data(forKey: "HMNotifyLater"))
        .flatMap { try? JSONDecoder().decode([NotifyCandidate].self, from: $0) } ?? [] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(later), forKey: "HMNotifyLater") }
    }
    var heldCount: Int { later.count }
    /// Settings → "Drop held notifications": the backlog is never sent (the events stay in the app).
    func clearHeld() { later = [] }
    private var sent: [Date] = []
    private let seenKey = "HMNotifyLastEventID"
    var onOpen: ((String) -> Void)?

    func start() {
        guard Self.available else { return }
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        let open = UNNotificationAction(identifier: "open", title: "Open", options: [.foreground])
        // With previews hidden (Lock Screen, screen sharing), only this shows.
        let cat = UNNotificationCategory(identifier: "hm", actions: [open], intentIdentifiers: [],
                                         hiddenPreviewsBodyPlaceholder: "New activity in Hmunmawi", options: [])
        c.setNotificationCategories([cat])
        Task {
            // Provisional first: no prompt, delivered quietly. Full permission is asked only when you press the button.
            _ = try? await c.requestAuthorization(options: [.alert, .sound, .badge, .provisional])
            await refreshAuthorization()
        }
    }

    func refreshAuthorization() async {
        guard Self.available else { return }
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// One Hmunmawi notification when a job was deferred for a missing Mac permission. Replaces itself; never a system TCC box.
    func needsPermission(_ banner: String) {
        guard Self.available else { return }
        let content = UNMutableNotificationContent()
        content.title = "Hmunmawi"
        content.body = banner
        content.categoryIdentifier = "hm"
        content.userInfo = ["page": "permissions"]
        content.interruptionLevel = .active
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "hm-permission", content: content, trigger: nil)
        )
    }

    /// Settings → "Send a test notification": one sample, shown even with the window in front, so you see how they look.
    /// Returns what happened in plain words.
    func sendTest() async -> String {
        guard Self.available else { return "Notifications need the app bundle (not a bare build)." }
        await refreshAuthorization()
        if authorization == .denied { return "Notifications are off for Hmunmawi in System Settings → Notifications." }
        let content = UNMutableNotificationContent()
        content.title = "Hmunmawi · test"
        content.body = "This is how a new purchase or review will look."
        content.categoryIdentifier = "hm"
        content.userInfo = ["page": "settings"]
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "hm-test", content: content, trigger: nil))
        } catch { return "Couldn't send it: \(error.localizedDescription)" }
        return authorization == .provisional ? "Sent quietly to Notification Center. Press \u{201C}Show them as banners\u{201D} to see it pop up." : "Sent."
    }

    /// Settings → "Show banners": the one real permission prompt, only when you ask.
    func askForBanners() async {
        guard Self.available else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        await refreshAuthorization()
        if authorization == .denied, let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    var authorizationText: String {
        switch authorization {
        case .authorized: "Banners on"
        case .provisional: "Delivered quietly to Notification Center"
        case .denied: "Off in System Settings → Notifications"
        case .ephemeral: "On for now"
        default: "Not asked yet"
        }
    }

    private static func windowFrontmost() -> Bool {
        NSApp.isActive && NSApp.windows.contains { $0.isKeyWindow && $0.isVisible && $0.identifier?.rawValue.contains("main") == true }
    }

    /// New events since the last look → notifications. The first look after launch only sets the starting point
    /// (nothing already stored is announced again).
    func consider(events: [StoredEvent], model: AppModel) {
        // Sample data never notifies, and its ids must not move the starting point for your real events.
        guard !model.isDemo else { return }
        let newest = events.map(\.id).max() ?? 0
        let saved = Int64(UserDefaults.standard.integer(forKey: seenKey))
        guard let seen = lastSeenID ?? (saved > 0 ? saved : nil) else {
            lastSeenID = newest; UserDefaults.standard.set(Int(newest), forKey: seenKey); return
        }
        let fresh = events.filter { $0.id > seen }
        if newest > seen { lastSeenID = newest; UserDefaults.standard.set(Int(newest), forKey: seenKey) } else { lastSeenID = seen }
        let cands = fresh.sorted { $0.id < $1.id }.compactMap { e in
            NotifyCandidate.from(id: e.id, kind: e.kind, app: e.app, payload: e.payload, amount: Money.shared.amount(e),
                                 text: EventText.describe(e), isSample: model.isDemo || e.source == "demo")
        }
        deliver(cands, model: model)
    }

    /// A connection that was working stops: one urgent notification.
    func healthChanged(from old: HealthTruth, to new: HealthTruth, model: AppModel) {
        guard new.dot == .broken, old.dot == .good || old.dot == .attention, !model.isDemo else { return }
        // Wait 7 minutes before telling (the retry runs within a minute; job states are re-read every 5): a failed Mac job is retried and a connection hiccup often clears itself,
        // so only a problem that is still there gets a notification.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(420))
            guard model.truth.dot == .broken else { return }
            self?.announceBroken(model.truth, model: model)
        }
    }

    private func announceBroken(_ new: HealthTruth, model: AppModel) {
        // The same problems flapping (fixed, broken again on the next run) notify once per 12 hours, not every run.
        let key = new.problems.sorted().joined(separator: "|"), d = UserDefaults.standard
        if d.string(forKey: "HMHealthNotified") == key,
           Date.now.timeIntervalSince1970 - d.double(forKey: "HMHealthNotifiedAt") < 12 * 3600 { return }
        d.set(key, forKey: "HMHealthNotified"); d.set(Date.now.timeIntervalSince1970, forKey: "HMHealthNotifiedAt")
        let broken = model.status.connections.filter { !$0.healthy }.map(\.name)
        // A broken connection names itself ("Sentry stopped working"); a failed check (a Mac job, the website) is not a
        // connection, so it says what needs fixing instead.
        let c = NotifyCandidate(id: Int64(Date.now.timeIntervalSince1970), kind: .connection,
                                app: broken.count == 1 ? broken[0] : broken.isEmpty ? "" : nil,
                                text: new.problems.prefix(3).joined(separator: " · "), urgent: true,
                                page: broken.isEmpty ? "today" : "settings")
        deliver([c], model: model)
    }

    private func deliver(_ cands: [NotifyCandidate], model: AppModel) {
        let all = later + cands
        guard !all.isEmpty else { return }
        sent.removeAll { $0 < Date.now.addingTimeInterval(-3600) }
        let s = MenuBarSettings.shared
        let code = Money.shared.target
        // In front on Today you see them there (dropped); in front on another page they wait until you leave.
        let front = Self.windowFrontmost()
        let onToday = (UserDefaults.standard.string(forKey: "HMPage") ?? "Today") == "Today"
        let ctx = NotificationPlanner.Context(prefs: s.prefs, quiet: model.quietHours, sentLastHour: sent.count,
                                              windowFrontmost: front && onToday, pausedUntil: s.pausedUntil,
                                              money: { v in Money.text(v, code, decimals: abs(v) < 100 ? 2 : 0) })
        var ctx2 = ctx
        ctx2.windowElsewhere = front && !onToday
        let r = NotificationPlanner.plan(all, ctx2)
        later = Array(r.later.suffix(50))
        guard Self.available else { return }
        for n in r.send { post(n) }
    }

    private func post(_ n: PlannedNotification) {
        let content = UNMutableNotificationContent()
        content.title = n.title
        content.body = n.body
        content.threadIdentifier = n.thread
        content.categoryIdentifier = "hm"
        content.userInfo = ["page": n.page]
        content.interruptionLevel = n.timeSensitive ? .timeSensitive : .active
        if n.timeSensitive { content.sound = .default }
        sent.append(.now)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: n.id, content: content, trigger: nil))
    }
}

extension MacNotifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let page = response.notification.request.content.userInfo["page"] as? String ?? "today"
        await MainActor.run { MacNotifier.shared.onOpen?(page) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
