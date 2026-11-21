import HmunmawiCore
import SwiftUI

/// Decided once per launch: what the Today card shows (WhatsNew.decide), from the notes bundled with the app.
@MainActor enum WhatsNewState {
    static var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    static let notes: WhatsNew.Notes? = Bundle.main.url(forResource: "WhatsNew", withExtension: "json")
        .flatMap { try? Data(contentsOf: $0) }.flatMap(WhatsNew.decode)

    /// Read before Today writes its first "last looked", so a fresh install is told apart from an update.
    static let initial: WhatsNew.Show = {
        guard let notes else { return .none }
        let store = WhatsNew.Store()
        let show = WhatsNew.decide(notes, lastSeen: store.lastSeen, current: current, freshInstall: LastSeen.isFirstLook)
        if show == .none { store.markSeen(current) }   // nothing to show: this version counts as seen
        return show
    }()
}

/// Today's one-time card: "What's new" after an update (each change with a button to its screen) or "Start here" on
/// a fresh install. Dismissed with Got it; it never comes back for the same version.
struct WhatsNewCard: View {
    @State private var show = WhatsNewState.initial
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        switch show {
        case .none: EmptyView()
        case .whatsNew(let versions):
            card(title: versions.count == 1 ? "What's new in \(versions[0].version)" : "What's new since you last looked",
                 symbol: "sparkles") {
                ForEach(versions, id: \.version) { v in
                    VStack(alignment: .leading, spacing: 10) {
                        if versions.count > 1 { Text(v.version).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                        ForEach(v.items, id: \.title) { row($0) }
                    }
                }
            }
        case .startHere(let items):
            card(title: "Start here", symbol: "hand.wave") { ForEach(items, id: \.title) { row($0) } }
        }
    }

    private func card<Content: View>(title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: symbol).font(.headline)
                Spacer()
                Button("Got it") { dismiss() }.buttonStyle(.pill)
                    .accessibilityIdentifier("whatsnew.dismiss")
            }
            content()
        }
        .padding(20)
        .contentCard(cornerRadius: 22)
    }

    private func row(_ item: WhatsNew.Item) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.body.weight(.semibold))
                Text(item.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let action = item.action, let label = Self.buttonTitle(action) {
                Button(label) { open(action) }.buttonStyle(.pill)
            }
        }
    }

    /// "settings:jobs" -> "Open Jobs"; "page:automations" -> "Open Automations".
    static func buttonTitle(_ action: String) -> String? {
        let parts = action.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "settings": return "Open \(SettingsPane.from(parts[1]).title)"
        case "page": return Page(rawValue: parts[1].capitalized).map { "Open \($0.rawValue)" }
        default: return nil
        }
    }

    private func open(_ action: String) {
        let parts = action.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        if parts[0] == "settings" {
            UserDefaults.standard.set(SettingsPane.from(parts[1]).rawValue, forKey: "HMSettingsTab")
            openWindow(id: "settings")
        } else if parts[0] == "page", let p = Page(rawValue: parts[1].capitalized) {
            UserDefaults.standard.set(p.rawValue, forKey: "HMPage")
        }
    }

    private func dismiss() {
        WhatsNew.Store().markSeen(WhatsNewState.current)
        withAnimation(.snappy) { show = .none }
    }
}
