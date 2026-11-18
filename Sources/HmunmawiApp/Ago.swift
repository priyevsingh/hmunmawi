import Foundation
import Observation

/// A clock that ticks once a minute. Any view whose body formats an age with `Ago.text` reads it, so SwiftUI redraws
/// that view every minute and "1 minute ago" doesn't stay on screen for a day. (A plain `Text(date, format: .relative)`
/// or a string formatted in `body` is only worked out when the view is drawn for some other reason.)
final class MinuteClock: Observable, @unchecked Sendable {
    static let shared = MinuteClock()

    private let registrar = ObservationRegistrar()
    private let lock = NSLock()
    private var ticks = 0
    private let timer: DispatchSourceTimer

    /// How many minutes have passed since launch; reading it is what ties a view to the clock.
    var minute: Int {
        registrar.access(self, keyPath: \.minute)
        return lock.withLock { ticks }
    }

    private init() {
        timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
    }

    func tick() {
        registrar.withMutation(of: self, keyPath: \.minute) { lock.withLock { ticks += 1 } }
    }
}

/// "21 hours ago", "yesterday", "in 3 hours": one way to say how far a moment is from now, everywhere in the app.
enum Ago {
    /// Measured from `now`. `clampFuture` turns a moment a little in the future (a sender's clock ahead of the Mac's)
    /// into "now" instead of "in 3 seconds"; leave it off for dates that really are ahead (a reset, an expiry).
    static func text(_ date: Date, now: Date, clampFuture: Bool = false, locale: Locale = .current) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = locale
        f.dateTimeStyle = .named
        f.unitsStyle = .full
        return f.localizedString(for: clampFuture ? min(date, now) : date, relativeTo: now)
    }

    /// Measured from this moment, and redrawn every minute when called from a view's body.
    static func text(_ date: Date, clampFuture: Bool = false) -> String {
        _ = MinuteClock.shared.minute
        return text(date, now: .now, clampFuture: clampFuture)
    }

    /// The same for an event's time in milliseconds.
    static func text(millis: Int64, clampFuture: Bool = true) -> String {
        text(Date(timeIntervalSince1970: Double(millis) / 1000), clampFuture: clampFuture)
    }
}
