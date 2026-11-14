import HmunmawiCore
import SwiftUI

/// The one answer to "is everything all right?", used by the toolbar pill, its popover, Today's Health line, the
/// menu bar dot and notifications, so they can never disagree. Nothing connected is never "Healthy".
struct HealthTruth: Equatable, Sendable {
    enum Dot: String, Sendable { case good, attention, broken, idle }
    var dot: Dot
    /// Short, for the pill and menu bar ("All good", "1 needs a look", "Not connected yet").
    var headline: String
    /// One plain sentence for Today and the panel.
    var sentence: String
    var problems: [String] = []

    static func make(connected: Int, brokenConnections: [String], badChecks: [String], cautionChecks: [String],
                     recovering: Bool, isDemo: Bool, paused: Bool = false) -> HealthTruth {
        if connected == 0 || isDemo {
            return HealthTruth(dot: .idle, headline: "Not connected yet",
                               sentence: "Nothing is connected yet, so there is nothing to check. Connect App Store Connect in Settings → Connections; until then you see sample numbers.")
        }
        let broken = brokenConnections + badChecks
        if !broken.isEmpty {
            return HealthTruth(dot: .broken, headline: broken.count == 1 ? "1 needs fixing" : "\(broken.count) need fixing",
                               sentence: broken.joined(separator: " · "), problems: broken)
        }
        if !cautionChecks.isEmpty || recovering {
            let list = cautionChecks.isEmpty ? ["Recovering from a hiccup"] : cautionChecks
            return HealthTruth(dot: .attention, headline: list.count == 1 ? "1 needs a look" : "\(list.count) need a look",
                               sentence: list.joined(separator: " · "), problems: list)
        }
        if paused {
            return HealthTruth(dot: .idle, headline: "All good · alerts paused",
                               sentence: "Every connection is working. Notifications are paused.")
        }
        return HealthTruth(dot: .good, headline: "All good",
                           sentence: connected == 1 ? "Your connection is working." : "All \(connected) connections are working.")
    }

    @MainActor static func make(_ model: AppModel, paused: Bool = false) -> HealthTruth {
        let checks = model.healthChecks
        return make(connected: model.status.connections.count,
                    brokenConnections: model.status.connections.filter { !$0.healthy }.map { "\($0.name) isn't working" },
                    badChecks: checks.filter { $0.level == .bad }.map { "\($0.title): \($0.value)" },
                    cautionChecks: checks.filter { $0.level == .caution }.map { "\($0.title): \($0.value)" },
                    recovering: model.status.level == .caution, isDemo: model.isDemo, paused: paused)
    }

    var color: Color {
        switch dot {
        case .good: Brand.good
        case .attention: Brand.caution
        case .broken: Brand.bad
        case .idle: Color.secondary
        }
    }
    var symbol: String {
        switch dot {
        case .good: "checkmark.seal.fill"
        case .attention: "exclamationmark.circle.fill"
        case .broken: "bandage.fill"
        case .idle: "circle.dashed"
        }
    }
}
