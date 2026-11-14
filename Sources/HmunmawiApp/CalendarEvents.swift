import EventKit
import Foundation

/// Puts a routine's message into the Mac's Calendar as well, in a calendar called "Hmunmawi", so it also shows on the
/// iPhone and Watch. Only runs for routines that have "Also put it in my Calendar" on, and only after the one Calendar
/// permission was given in setup (never asked in the middle of using the app).
@MainActor
enum CalendarEvents {
    static let calendarName = "Hmunmawi"
    private static let store = EKEventStore()

    static var state: Permissions.State {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .writeOnly: .granted
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    /// Asks macOS once. Full access is requested because Hmunmawi also looks for its own events (to avoid doubles).
    static func ask() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// The "Hmunmawi" calendar, created on first use next to the default calendar (same account, so it syncs).
    private static func calendar() -> EKCalendar? {
        if let existing = store.calendars(for: .event).first(where: { $0.title == calendarName && $0.allowsContentModifications }) {
            return existing
        }
        let c = EKCalendar(for: .event, eventStore: store)
        c.title = calendarName
        c.source = store.defaultCalendarForNewEvents?.source
            ?? store.sources.first(where: { $0.sourceType == .local })
            ?? store.sources.first
        guard c.source != nil else { return nil }
        do { try store.saveCalendar(c, commit: true); return c } catch { return nil }
    }

    /// Adds one event starting now (15 minutes, with an alert at the start). `key` makes a repeat of the same message
    /// a no-op, so a retried routine never fills the Calendar with doubles. Returns a short note for the log.
    @discardableResult
    static func add(title: String, notes: String, key: String, now: Date = .now) -> String {
        guard state == .granted else { return "Calendar not allowed yet (Settings → Permissions)." }
        let marker = "HMCal-\(key)"
        if UserDefaults.standard.bool(forKey: marker) { return "Already in Calendar." }
        guard let cal = calendar() else { return "Couldn't open the Hmunmawi calendar." }
        let e = EKEvent(eventStore: store)
        e.calendar = cal
        e.title = String(title.prefix(120))
        e.notes = String(notes.prefix(900))
        e.startDate = now
        e.endDate = now.addingTimeInterval(15 * 60)
        e.addAlarm(EKAlarm(relativeOffset: 0))
        do {
            try store.save(e, span: .thisEvent, commit: true)
            UserDefaults.standard.set(true, forKey: marker)
            return "Added to Calendar."
        } catch { return "Calendar said: \(error.localizedDescription)" }
    }
}
