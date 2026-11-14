import AppKit
import Foundation
import HmunmawiCore
import MetricKit

/// Knowing when the app crashes or freezes, instead of guessing. Two sources:
/// - Apple's own crash and hang reports (MetricKit), delivered at a later launch;
/// - a freeze watchdog: if the main thread doesn't answer for more than 0.25 s, the freeze is logged.
/// Both go to the activity log (shown in the status pill) and ~/Library/Logs/Hmunmawi/app.log.
final class Diagnostics: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = Diagnostics()
    private var store: Store?
    private var lastHangLog = Date.distantPast
    private let queue = DispatchQueue(label: "hmunmawi.watchdog", qos: .utility)

    func start(store: Store) {
        self.store = store
        MXMetricManager.shared.add(self)
        watch()
    }

    // MARK: Apple's reports

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for p in payloads {
            for c in p.crashDiagnostics ?? [] {
                record("app.crash_report", "Hmunmawi crashed (\(c.exceptionType.map { "exception \($0)" } ?? c.signal.map { "signal \($0)" } ?? "unknown cause"))")
            }
            for h in p.hangDiagnostics ?? [] {
                record("app.hang_report", "Hmunmawi stopped responding for \(h.hangDuration.formatted())")
            }
        }
    }

    // MARK: Freeze watchdog

    private func watch() {
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            // Uptime clock: stops while the Mac sleeps, so a sleep never counts as a freeze.
            let sent = DispatchTime.now().uptimeNanoseconds
            let answered = DispatchSemaphore(value: 0)
            let active = Flag()
            DispatchQueue.main.async { active.value = NSApplication.shared.isActive; answered.signal() }
            if answered.wait(timeout: .now() + 0.25) == .timedOut {
                answered.wait()   // how long the freeze really lasted
                let seconds = Double(DispatchTime.now().uptimeNanoseconds - sent) / 1e9
                // Only while you're using the app: in the background macOS slows idle apps (App Nap) on purpose.
                if active.value, Date().timeIntervalSince(lastHangLog) > 60 {   // at most one entry a minute
                    lastHangLog = Date()
                    record("app.freeze", String(format: "The window froze for %.2f s", seconds))
                }
            }
            watch()
        }
    }

    private final class Flag: @unchecked Sendable { var value = false }

    private func record(_ action: String, _ text: String) {
        AppModel.logStartup(text)
        let store = store
        Task { try? await store?.appendAudit(actor: "app", action: action, subject: text) }
    }
}
