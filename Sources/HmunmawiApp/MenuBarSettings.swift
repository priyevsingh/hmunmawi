import AppKit
import HmunmawiCore
import Observation

/// Menu bar and notification choices (Settings → Menu bar). Kept in preferences; every change redraws only what reads it.
@Observable @MainActor
final class MenuBarSettings {
    static let shared = MenuBarSettings()
    private let d: UserDefaults

    /// The one number beside the icon.
    enum Number: String, CaseIterable, Identifiable, Sendable {
        case none, sales, downloads, reviews, waiting, problems
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: "Nothing (icon only)"
            case .sales: "Today's sales"
            case .downloads: "Downloads (latest day)"
            case .reviews: "New reviews today"
            case .waiting: "Things waiting for you"
            case .problems: "Things to fix or look at"
            }
        }
    }

    /// A small symbol before the number, so it's clear what it counts.
    var numberSymbol: Bool { didSet { d.set(numberSymbol, forKey: "HMMenuBarNumberSymbol") } }
    /// Hide the number when it is 0.
    var hideZero: Bool { didSet { d.set(hideZero, forKey: "HMMenuBarHideZero") } }

    var showIcon: Bool { didSet { d.set(showIcon, forKey: "HMMenuBarIcon"); if !showIcon && !showInDock { showInDock = true } } }
    var number: Number { didSet { d.set(number.rawValue, forKey: "HMMenuBarNumber") } }
    var showInDock: Bool { didSet { d.set(showInDock, forKey: "HMShowInDock"); if !showInDock && !showIcon { showIcon = true }; applyDock() } }
    var feedCount: Int { didSet { d.set(feedCount, forKey: "HMMenuBarFeedCount") } }
    var showQuickNumbers: Bool { didSet { d.set(showQuickNumbers, forKey: "HMMenuBarNumbers") } }
    var prefs: NotifyPrefs { didSet { if let data = try? JSONEncoder().encode(prefs) { d.set(data, forKey: "HMNotifyPrefs") } } }
    /// Notifications are held until then (distantFuture = until you switch them on again).
    var pausedUntil: Date? { didSet { d.set(pausedUntil?.timeIntervalSince1970, forKey: "HMNotifyPausedUntil") } }

    init(defaults: UserDefaults = .standard) {
        d = defaults
        showIcon = (d.object(forKey: "HMMenuBarIcon") as? Bool) ?? true
        // New installs: things to fix, hidden at 0, so the icon says something useful from day one.
        number = d.string(forKey: "HMMenuBarNumber").map { Number(rawValue: $0) ?? .none } ?? .problems
        numberSymbol = (d.object(forKey: "HMMenuBarNumberSymbol") as? Bool) ?? true
        hideZero = (d.object(forKey: "HMMenuBarHideZero") as? Bool) ?? true
        showInDock = (d.object(forKey: "HMShowInDock") as? Bool) ?? true
        feedCount = min(10, max(3, (d.object(forKey: "HMMenuBarFeedCount") as? Int) ?? 5))
        showQuickNumbers = (d.object(forKey: "HMMenuBarNumbers") as? Bool) ?? true
        prefs = (d.data(forKey: "HMNotifyPrefs")).flatMap { try? JSONDecoder().decode(NotifyPrefs.self, from: $0) } ?? NotifyPrefs()
        let p = d.double(forKey: "HMNotifyPausedUntil")
        pausedUntil = p > 0 ? Date(timeIntervalSince1970: p) : nil
    }

    var notificationsPaused: Bool { pausedUntil.map { $0 > .now } ?? false }

    enum Pause { case hour, untilTomorrow, untilOn }
    /// "Until tomorrow" ends when your quiet hours end (08:00 without quiet hours).
    func pause(_ p: Pause, quiet: QuietHours? = nil, now: Date = .now, calendar: Calendar = .current) {
        switch p {
        case .hour: pausedUntil = now.addingTimeInterval(3600)
        case .untilTomorrow:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
            pausedUntil = quiet?.end(after: tomorrow, calendar: calendar)
                ?? calendar.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow)
        case .untilOn: pausedUntil = .distantFuture
        }
    }
    func resume() { pausedUntil = nil }

    var pauseText: String? {
        guard let u = pausedUntil, u > .now else { return nil }
        if u == .distantFuture { return "Notifications paused until you switch them on" }
        return "Notifications paused until \(u.formatted(date: Calendar.current.isDateInToday(u) ? .omitted : .abbreviated, time: .shortened))"
    }

    /// Dock icon on or off (menu bar only). Never both off.
    func applyDock() {
        guard NSApp != nil, Bundle.main.bundleIdentifier != nil else { return }
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
    }
}
