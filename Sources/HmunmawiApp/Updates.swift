import HmunmawiCore
import Sparkle
import SwiftUI

/// In-app updates (Sparkle 2): checks the signed feed named in Info.plist (SUFeedURL, signed with SUPublicEDKey) once a
/// day, asks before installing, and only runs in a real app bundle — never in tests or a bare build.
@MainActor
final class Updates: ObservableObject {
    static let shared = Updates()
    let controller: SPUStandardUpdaterController?
    @Published var canCheck = false
    /// True while Sparkle relaunches the app to install an update (the Quit question is skipped then).
    var installing = false
    private let delegate = UpdatesDelegate()

    private init() {
        let usable = Bundle.main.bundleIdentifier != nil && !TestProfile.runningUnitTests
            && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        controller = usable ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil) : nil
        controller?.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
    }

    func check() { controller?.checkForUpdates(nil) }
}

/// Hmunmawi menu → "Check for Updates…" (next to About, as Mac apps do).
struct CheckForUpdatesItem: View {
    @ObservedObject private var updates = Updates.shared
    var body: some View {
        Button("Check for Updates…") { updates.check() }
            .disabled(updates.controller == nil || !updates.canCheck)
    }
}

final class UpdatesDelegate: NSObject, SPUUpdaterDelegate {
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { Updates.shared.installing = true }
    }
}
