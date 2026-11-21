import HmunmawiCore
import SwiftUI

/// Settings → Menu bar: the icon, its number, the Dock, what notifies and how much the panel shows.
struct MenuBarSettingsForm: View {
    let model: AppModel
    @State private var s = MenuBarSettings.shared
    @State private var auth = ""

    var body: some View {
        Form {
            MenuBarBasics()
            PanelShortcutSection()
            Section {
                Stepper("Latest moments in the panel: \(s.feedCount)", value: $s.feedCount, in: 3...10)
                Toggle("Show quick numbers (paying subscribers, X, YouTube, visitors)", isOn: $s.showQuickNumbers)
            } header: { Text("Panel") } footer: {
                Text("Numbers that aren't connected are left out, never shown as 0.").font(.footnote).foregroundStyle(.secondary)
            }
            NotificationChoices()
            Section {
                if let p = s.pauseText {
                    LabeledContent(p) { Button("Resume") { s.resume(); model.updateTruth() } }
                } else {
                    HStack {
                        Text("Pause notifications")
                        Spacer()
                        Button("1 hour") { s.pause(.hour); model.updateTruth() }
                        Button("Until tomorrow") { s.pause(.untilTomorrow, quiet: model.quietHours); model.updateTruth() }
                        Button("Until I switch them on") { s.pause(.untilOn); model.updateTruth() }
                    }
                }
            } footer: {
                Text("Quiet hours (Settings → General) and at most 6 alerts an hour apply too. A broken connection or a rejected build still gets through.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Icon, number and Dock (also on the setup step).
struct MenuBarBasics: View {
    @State private var s = MenuBarSettings.shared
    var body: some View {
        Section {
            Toggle("Show Hmunmawi in the menu bar", isOn: $s.showIcon)
            Picker("Number beside the icon", selection: $s.number) {
                ForEach(MenuBarSettings.Number.allCases) { Text($0.title).tag($0) }
            }
            .disabled(!s.showIcon)
            Toggle("Small symbol before the number", isOn: $s.numberSymbol)
                .disabled(!s.showIcon || s.number == .none || s.number == .sales)
            Toggle("Hide the number when it's 0", isOn: $s.hideZero)
                .disabled(!s.showIcon || s.number == .none)
            Toggle("Show in the Dock", isOn: $s.showInDock)
        } header: { Text("Menu bar") } footer: {
            Text("The dot is green when everything works, amber when something needs a look, red when something is broken and grey before anything is connected. With the Dock icon off, Hmunmawi lives in the menu bar only; one of the two always stays on.")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Which moments become Mac notifications, and the one permission button.
struct NotificationChoices: View {
    @State private var s = MenuBarSettings.shared
    @State private var auth = MacNotifier.shared.authorizationText
    @State private var testNote: String?
    @State private var held = 0

    var body: some View {
        Section {
            Toggle("Mac notifications", isOn: $s.prefs.enabled)
            ForEach(NotifyKind.allCases) { k in
                Toggle(k.title, isOn: Binding(get: { s.prefs.kinds.contains(k) },
                                              set: { on in if on { s.prefs.kinds.insert(k) } else { s.prefs.kinds.remove(k) } }))
                    .disabled(!s.prefs.enabled)
            }
            Toggle("Show review text in notifications", isOn: $s.prefs.showDetails).disabled(!s.prefs.enabled)
            LabeledContent("On this Mac", value: auth)
            HStack {
                if MacNotifier.shared.authorization != .authorized {
                    Button("Show them as banners…") {
                        Task { await MacNotifier.shared.askForBanners(); auth = MacNotifier.shared.authorizationText }
                    }
                }
                Button("Send a test notification") { Task { testNote = await MacNotifier.shared.sendTest() } }
                if held > 0 {
                    Button(held == 1 ? "Drop 1 held notification" : "Drop \(held) held notifications") {
                        MacNotifier.shared.clearHeld(); held = 0
                    }
                    .help("Held for quiet hours, the hourly cap or while you were on another page. Dropping them means they are never sent; you still see everything in the app.")
                }
                if let testNote { Text(testNote).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        } header: { Text("Notifications") } footer: {
            Text("A third way to hear about things, next to iMessage and ntfy. They start quietly in Notification Center; press the button to see banners. Several at once become one (\u{201C}3 new purchases\u{201D}), one stack per app, and several kinds at once become one \u{201C}while you were away\u{201D} summary. Nothing while Today is in front (you see it there); on another page they wait until you leave. Sample numbers never notify.")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .task { await MacNotifier.shared.refreshAuthorization(); auth = MacNotifier.shared.authorizationText; held = MacNotifier.shared.heldCount }
    }
}

/// Settings → General, only on an owner Mac: what owner.json switches on (nothing for a normal install).
struct OwnerExtrasSection: View {
    var body: some View {
        let o = OwnerConfig.current
        if o.isOn {
            Section {
                // Only what a normal install can't have; the folders, AI pause card, Zoho reader, X file and time zone
                // it sets show under Your extras below (marked "from your owner settings file").
                let on: [(String, Bool)] = [("Keychain-prompt watcher in your builds", o.wantsKeychainWatcher),
                                            ("Keys also kept in files (~/.config/hmunmawi/keys)", true),
                                            ("Safari steps through your own program", o.safariDriverURL != nil),
                                            ("AI job policy from your own job data", o.jobsDataURL != nil),
                                            ("Wall of Apps shout-outs", o.wantsWallShoutouts)]
                ForEach(on.filter(\.1), id: \.0) { Label($0.0, systemImage: "checkmark") }
            } header: { Text("Owner extras") } footer: {
                Text("From your owner settings file; only one person can have these. New installs don't have this file. What it sets among Your extras is marked there.")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The shortcut that opens the panel from anywhere: on/off, change it by typing a new one, or go back to ⌃⌥H.
struct PanelShortcutSection: View {
    @State private var shortcut = PanelShortcut.shared
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Section {
            Toggle("Open the panel from anywhere with a shortcut", isOn: $shortcut.enabled)
            LabeledContent("Shortcut") {
                HStack {
                    Button(recording ? "Type a shortcut… (Esc cancels)" : shortcut.key.display) { recording ? stop() : record() }
                        .monospaced()
                    Button("Reset to \(HotKey.standard.display)") { stop(); shortcut.reset() }
                        .disabled(shortcut.key == .standard && shortcut.enabled)
                }
            }
            .disabled(!shortcut.enabled)
            if let p = shortcut.problem { Label(p, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Brand.caution) }
        } header: { Text("Panel shortcut") } footer: {
            Text("When the menu bar is full, macOS tucks some icons behind the notch. The shortcut, or the panel button in the window's toolbar, opens the same panel either way. Use ⌃, ⌥ or ⌘ with a key. No extra permission is needed.")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onDisappear { stop() }
    }

    private func record() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil }   // Esc
            if let k = HotKey.from(keyCode: e.keyCode, flags: e.modifierFlags.intersection(.deviceIndependentFlagsMask),
                                   characters: e.charactersIgnoringModifiers) {
                shortcut.key = k
                stop()
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
