import AppKit
import CryptoKit
import HmunmawiCore
import HmunmawiProtocol
import Synchronization
import SwiftUI

@main
struct HmunmawiApp: App {
    @State private var model: AppModel
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        if Self.handleRebindSecrets() { exit(0) }
        if Self.handleVerifySecrets() { exit(0) }
        if Self.handleHookRelayProbe() { exit(0) }
        // Test helpers for development builds only: a release build never approves or writes keys from the command line.
        #if DEBUG
        Self.handleSetSecret()
        Self.handleApprove()
        #endif
        Self.ensureSingleInstance()
        Keychain.neverPrompt()
        // Checks, routines and alerts start with the app, not with the window: opened at login with no window
        // (or the window closed before it drew), Hmunmawi still watches in the background.
        let m = AppModel()
        _model = State(initialValue: m)
        AppDelegate.model = m
        Task { @MainActor in await m.load() }
        Task { @MainActor in
            MacNotifier.shared.onOpen = { page in WindowOpener.show(page: page) }
            MacNotifier.shared.start()
        }
        ReleaseSnapshots.scheduleIfAsked(model: m)
    }

    /// Only one Hmunmawi runs at a time: a second launch (from login, Finder or Spotlight) hands over to the
    /// running one and exits cleanly, which also tells launchd not to relaunch it.
    /// See `SingleInstance`: same bundle id anywhere on disk hands over; a test copy needs an explicit override.
    private static func ensureSingleInstance() {
        let me = NSRunningApplication.current
        let running = NSWorkspace.shared.runningApplications.compactMap { app -> SingleInstance.Running? in
            guard let id = app.bundleIdentifier, id.hasPrefix(SingleInstance.family) else { return nil }
            return SingleInstance.Running(pid: app.processIdentifier, bundleID: id)
        }
        guard let target = SingleInstance.handOverTo(
            myPID: me.processIdentifier, myBundleID: Bundle.main.bundleIdentifier ?? "", running: running,
            testProfile: TestProfile.name != nil,
            overrideAsked: ProcessInfo.processInfo.environment[SingleInstance.overrideKey] == "1"),
              let app = NSRunningApplication(processIdentifier: target.pid) else { return }
        app.activate()
        FileHandle.standardError.write(Data("Hmunmawi is already running (pid \(target.pid)); bringing it to the front.\n".utf8))
        exit(0)
    }

    /// `Hmunmawi --approve-addon <id> [<id> …]` approves installed add-ons (recorded in the activity log) and exits.
    private static func handleApprove() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--approve-addon") else { return }
        let ids = Array(args[(index + 1)...])
        let support = AppModel.defaultSupportDirectory()
        let roots = [Bundle.main.resourceURL?.appending(path: "Add-ons"), support.appending(path: "Add-ons")].compactMap { $0 }
        let done = DispatchSemaphore(value: 0)
        let failed = Mutex(false)
        Task.detached {
            do {
                let store = try Store(path: support.appending(path: "hmunmawi.sqlite").path)
                // Approvals are signed with the app's own key (Keychain), so they count like ones made in the app.
                // Only an existing key is used: none yet means the app hasn't run, and nothing can be approved.
                guard let s = try KeychainSecretStore().secret(plugin: "hmunmawi", name: "trust-key"),
                      let d = Data(base64Encoded: s), d.count == 32 else {
                    FileHandle.standardError.write(Data("open Hmunmawi once first, then approve\n".utf8))
                    failed.withLock { $0 = true }
                    done.signal()
                    return
                }
                await store.setTrustKey(SymmetricKey(data: d))
                for id in ids {
                    guard let plugin = roots.lazy.compactMap({ try? InstalledPlugin.load(from: $0.appending(path: "\(id).hmplugin")) }).first else {
                        FileHandle.standardError.write(Data("no add-on called \(id)\n".utf8))
                        failed.withLock { $0 = true }
                        continue
                    }
                    // Signed on its permissions, like an approval in Settings, so a re-signed build still counts.
                    try await store.approvePlugin(id: id, fingerprint: plugin.fingerprint,
                                                  permissionsHash: ApprovedPermissions(plugin.manifest).stableHash(), by: "you (command line)")
                    print("approved \(id)")
                }
            } catch {
                FileHandle.standardError.write(Data("\(error)\n".utf8))
                failed.withLock { $0 = true }
            }
            done.signal()
        }
        done.wait()
        exit(failed.withLock { $0 } ? 1 : 0)
    }

    /// `Hmunmawi --hook-relay-probe` fingerprints the hook relay key and syncs the worker on 401.
    private static func handleHookRelayProbe() -> Bool {
        guard CommandLine.arguments.contains("--hook-relay-probe") else { return false }
        let done = DispatchSemaphore(value: 0)
        let code = Mutex<Int32>(1)
        Task { @MainActor in
            let result = await LivePurchases.shared.probeHookRelay { print($0) }
            code.withLock { $0 = result }
            done.signal()
        }
        for _ in 0..<600 where done.wait(timeout: .now()) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }
        exit(code.withLock { $0 })
    }

    /// `Hmunmawi --verify-secrets` prints ok/fail per connection secret (never the value).
    private static func handleVerifySecrets() -> Bool {
        guard CommandLine.arguments.contains("--verify-secrets") else { return false }
        KeychainSecretStore.catalogURL = AppModel.defaultSupportDirectory().appending(path: SecretSourceCatalog.fileName)
        let store = KeychainSecretStore()
        Keychain.neverPrompt()
        let pairs: [(String, String)] = [
            ("appstoreconnect", "issuerID"), ("appstoreconnect", "keyID"), ("appstoreconnect", "privateKey"),
            ("posthog", "apiKey"), ("sentry", "authToken"), ("bing", "apiKey"),
            ("cloudflare", "apiToken"), ("searchconsole", "serviceAccount"), ("youtube", "apiKey"),
            ("live", "hookRelayKey"), ("live", "hookCloudflareToken"),
        ]
        var failed = false
        for (p, n) in pairs {
            let ok = (try? store.peekSecret(plugin: p, name: n))?.isEmpty == false
            print("\(p)/\(n) \(ok ? "ok" : "fail")")
            if !ok { failed = true }
        }
        exit(failed ? 1 : 0)
    }

    /// `Hmunmawi --rebind-secrets` re-imports connection keys from saved file paths (no UI).
    private static func handleRebindSecrets() -> Bool {
        guard CommandLine.arguments.contains("--rebind-secrets") else { return false }
        let support = AppModel.defaultSupportDirectory()
        let catalog = SecretSourceCatalog(url: support.appending(path: SecretSourceCatalog.fileName))
        KeychainSecretStore.catalogURL = catalog.fileURL
        let store = KeychainSecretStore()
        // Older Keychain names first, with password boxes still off: an item saved by a differently signed copy is
        // reported, never asked about.
        Keychain.neverPrompt()
        let r = LegacySecretMigrator.migrateKeychain(into: store)
        FileHandle.standardError.write(Data("legacy: copied \(r.copied.count) [\(r.copied.joined(separator: ", "))], already there \(r.alreadyThere.count), needs one OK \(r.needsOK.count) [\(r.needsOK.keys.sorted().joined(separator: ", "))], failed \(r.failed.count)\n".utf8))
        SecKeychainSetUserInteractionAllowed(true)
        defer { Keychain.neverPrompt() }
        let n = SecretRebinder.rebindAll(store: store, catalog: catalog)
        FileHandle.standardError.write(Data("rebound \(n) secrets\n".utf8))
        return true
    }

    /// `Hmunmawi --set-secret <add-on> <name>` stores the value read from stdin in the Keychain and exits.
    /// The app writes the item itself, so it can read it later without a Keychain prompt.
    private static func handleSetSecret() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--set-secret") else { return }
        guard index + 2 < args.count else {
            FileHandle.standardError.write(Data("usage: Hmunmawi --set-secret <add-on> <name> < value\n".utf8))
            exit(2)
        }
        // The app's own items (trust key, pending agent keys, live and usage keys) can never be set from outside.
        let owner = args[index + 1].lowercased()
        if PluginManifest.reservedIDs.contains(where: { owner == $0 || owner.hasPrefix($0 + "/") }) {
            FileHandle.standardError.write(Data("that name is reserved for the app\n".utf8))
            exit(2)
        }
        let value = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            FileHandle.standardError.write(Data("no value on stdin\n".utf8))
            exit(1)
        }
        do {
            try KeychainSecretStore().setSecret(value, plugin: args[index + 1], name: args[index + 2])
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }

    @State private var menuBar = MenuBarSettings.shared

    var body: some Scene {
        // Closing the window leaves Hmunmawi running in the background (see AppDelegate), so checks and alerts carry
        // on; the menu bar icon (Settings → Menu bar) shows how things are without a window. ⌘Q or Quit stops it.
        Window("Hmunmawi", id: "main") {
            MainView(model: model)
                .tint(Color(nsColor: .labelColor))
                // A solid, calm page (Apple's window background, light grey / near-black in dark mode) so every
                // colour reads clearly; glass stays on the toolbar and controls only.
                .containerBackground(Color(nsColor: .windowBackgroundColor), for: .window)
                // Narrow enough for a half screen, wide enough that the toolbar (spaces, status, buttons) never
                // folds into an overflow menu and hides the navigation.
                .frame(minWidth: 1180, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 780)

        // After the main window: SwiftUI opens the first scene at launch, so the window must come first.
        MenuBarExtra(isInserted: Binding(get: { menuBar.showIcon }, set: { menuBar.showIcon = $0 })) {
            MenuBarPanel(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        // About Hmunmawi: a short film about the name, Mizoram and why the app exists.
        Window("About Hmunmawi", id: "about") {
            AboutStory()
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 980, height: 620)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(replacing: .appInfo) { AboutMenuItem(); CheckForUpdatesItem() }
            CommandGroup(replacing: .appSettings) { SettingsMenuItem() }
        }

        // A regular window, so Settings resizes like any Mac window (⌘, still opens it).
        Window("Settings", id: "settings") {
            SettingsView(model: model)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 900, height: 640)
        .restorationBehavior(.disabled)   // opens when you ask for it, never by itself at launch
    }
}

private struct AboutMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View { Button("About Hmunmawi") { openWindow(id: "about") } }
}


/// ⌘, opens the resizable Settings window.
struct SettingsMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View { Button("Settings…") { openWindow(id: "settings") }.keyboardShortcut(",", modifiers: .command) }
}

/// Opens Settings from anywhere in the app (replaces SettingsLink, which only opens the built-in scene).
struct OpenSettingsButton<Label: View>: View {
    @Environment(\.openWindow) private var openWindow
    @ViewBuilder let label: Label
    var body: some View { Button { openWindow(id: "settings") } label: { label } }
}

/// Closing the window doesn't quit: Hmunmawi keeps watching in the background (add-on checks, rules, alerts).
/// Clicking the Dock icon brings the window back.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Quitting stops routines until Hmunmawi opens again (at the next login at the latest), so a Quit you chose
    /// asks first when routines are on. Logging out, restarting, shutting down and installing an update never ask.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Updates.shared.installing { return .terminateNow }
        if let reason = NSAppleEventManager.shared().currentAppleEvent?.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)),
           reason.typeCodeValue != 0 { return .terminateNow }   // logout / restart / shutdown
        let on = MyRoutines.read().filter { $0.who == "mac" && $0.does != nil && $0.off != true && ($0.elsewhere ?? "").isEmpty }
        guard !on.isEmpty, !TestProfile.runningUnitTests else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit Hmunmawi?"
        alert.informativeText = "\(on.count) routine\(on.count == 1 ? "" : "s") stop until Hmunmawi opens again (it opens by itself at your next login). Close the window instead to keep them running."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MenuBarSettings.shared.applyDock()
    }

    /// Clicking the Dock icon with no window open brings the main window back (and the app forward).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WindowOpener.show() }
        return true
    }

    /// Right-click on the Dock icon: the same quick actions as the menu bar, for when its icon is hidden.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        do {
            let menu = NSMenu()
            let headline = Self.model?.truth.headline ?? "Starting…"
            let status = NSMenuItem(title: headline, action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
            menu.addItem(.separator())
            menu.addItem(DockItem("Open Hmunmawi") { WindowOpener.show(page: "today") })
            menu.addItem(DockItem("Check all now") { Task { await AppDelegate.model?.checkAll() } })
            let s = MenuBarSettings.shared
            if s.notificationsPaused {
                menu.addItem(DockItem("Resume notifications") { s.resume(); AppDelegate.model?.updateTruth() })
            } else {
                menu.addItem(DockItem("Pause notifications for 1 hour") { s.pause(.hour); AppDelegate.model?.updateTruth() })
                menu.addItem(DockItem("Pause notifications until tomorrow") { s.pause(.untilTomorrow, quiet: AppDelegate.model?.quietHours); AppDelegate.model?.updateTruth() })
            }
            menu.addItem(DockItem("Settings…") { WindowOpener.show(page: "settings") })
            return menu
        }
    }

    /// The appearance picked in Settings → General ("system", "light" or "dark"), applied before the first window
    /// shows. `open Hmunmawi.app --args -HMAppearance dark` does the same for one launch without saving it.
    func applicationWillFinishLaunching(_ notification: Notification) {
        umask(0o077)  // files the app creates are readable by this user only, even if moved out of the 0700 folder
        // A fixed time zone in owner.json is the app's own: every "today", day group and date follows it, not the
        // Mac's zone while travelling. Without it nothing changes.
        if OwnerConfig.current.timeZone != nil { NSTimeZone.default = OwnerConfig.current.zone }
        Self.applyAppearance(UserDefaults.standard.string(forKey: Self.appearanceKey) ?? "system")
    }

    static let appearanceKey = "HMAppearance"

    /// Light or dark for Hmunmawi only, whatever the Mac uses; "system" follows the Mac again.
    @MainActor static func applyAppearance(_ choice: String) {
        switch choice {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: NSApp.appearance = nil
        }
    }
}

/// A Dock menu item that runs a closure.
@MainActor private final class DockItem: NSMenuItem {
    private let run: @MainActor () -> Void
    init(_ title: String, _ run: @escaping @MainActor () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}
