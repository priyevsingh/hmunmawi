import AppKit
import Carbon.HIToolbox
import Observation
import OSLog
import SwiftUI

/// A keyboard shortcut as macOS's hot key API takes it: a virtual key code plus Carbon modifier bits.
struct HotKey: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32
    /// The key's own character ("H"), for showing it.
    var key: String

    /// ⌃⌥H: no system shortcut or common app uses it, and H is the app's own letter.
    static let standard = HotKey(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(controlKey | optionKey), key: "H")

    /// "⌃⌥H", in the order the Mac's menus show modifiers.
    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + key.uppercased()
    }

    /// From a key press in the recorder. A shortcut that works from anywhere needs ⌃, ⌥ or ⌘ (Shift alone would
    /// take the letter away from typing), and a visible key.
    static func from(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) -> HotKey? {
        var m: UInt32 = 0
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        guard m & UInt32(controlKey | optionKey | cmdKey) != 0 else { return nil }
        guard let c = characters?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty else { return nil }
        return HotKey(keyCode: UInt32(keyCode), modifiers: m, key: c.uppercased())
    }
}

/// The shortcut that opens the menu bar panel from anywhere (Settings → Menu bar). On by default; kept in preferences.
@Observable @MainActor
final class PanelShortcut {
    static let shared = PanelShortcut()
    private let d: UserDefaults
    private let registers: Bool

    var enabled: Bool { didSet { d.set(enabled, forKey: "HMPanelShortcutOn"); apply() } }
    var key: HotKey {
        didSet { if let data = try? JSONEncoder().encode(key) { d.set(data, forKey: "HMPanelShortcut") }; apply() }
    }
    /// Why the shortcut isn't working (another app took it), shown in Settings.
    private(set) var problem: String?

    /// The hint shown beside the panel button, nil when the shortcut is off or not working.
    var hint: String? { enabled && problem == nil ? key.display : nil }

    init(defaults: UserDefaults = .standard, registers: Bool = true) {
        d = defaults
        self.registers = registers
        enabled = (defaults.object(forKey: "HMPanelShortcutOn") as? Bool) ?? true
        key = defaults.data(forKey: "HMPanelShortcut").flatMap { try? JSONDecoder().decode(HotKey.self, from: $0) } ?? .standard
    }

    func reset() { key = .standard; enabled = true }

    /// Registers (or removes) the system-wide hot key. Carbon's hot keys need no Accessibility permission.
    func apply() {
        guard registers else { return }
        let status = GlobalHotKey.shared.register(enabled ? key : nil)
        problem = switch status {
        case noErr: nil
        case OSStatus(eventHotKeyExistsErr): "Another app already uses \(key.display). Pick another shortcut."
        default: "Couldn't set \(key.display) (error \(status)). Pick another shortcut."
        }
    }
}

/// One system-wide hot key through Carbon's RegisterEventHotKey (no Accessibility or Input Monitoring needed).
@MainActor final class GlobalHotKey {
    static let shared = GlobalHotKey()
    var action: (@MainActor () -> Void)?
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Task { @MainActor in GlobalHotKey.shared.action?() }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    /// Replaces the current hot key; nil just removes it.
    func register(_ key: HotKey?) -> OSStatus {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        guard let key else { return noErr }
        installHandler()
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(key.keyCode, key.modifiers, EventHotKeyID(signature: OSType(0x484D_4E57), id: 1),
                                         GetApplicationEventTarget(), 0, &newRef)
        ref = newRef
        return status
    }
}

/// Where the panel goes: under the menu bar icon when it's on screen, otherwise at the top right under the menu bar
/// (where the icon would be), so the panel opens even when macOS has tucked the icon behind the notch.
enum PanelAnchor {
    /// AppKit coordinates (origin at the bottom left). `icon` is the icon's frame only when it's really on screen.
    static func origin(panel: CGSize, icon: CGRect?, screen: CGRect, visible: CGRect, margin: CGFloat = 8) -> CGPoint {
        let y = visible.maxY - 6 - panel.height
        if let icon, icon.width > 0, icon.height > 0, screen.contains(CGPoint(x: icon.midX, y: icon.midY)) {
            let x = min(max(icon.midX - panel.width / 2, visible.minX + margin), visible.maxX - panel.width - margin)
            return CGPoint(x: x, y: y)
        }
        return CGPoint(x: visible.maxX - panel.width - margin, y: y)
    }
}

/// Finds this app's menu bar icon, if macOS is showing it.
enum StatusItemProbe {
    static let log = Logger(subsystem: "io.github.priyevsingh.Hmunmawi", category: "panel")

    /// The icon's frame when its window is on screen and not covered (macOS hides icons that don't fit beside the
    /// notch); nil otherwise.
    @MainActor static func visibleFrame() -> CGRect? {
        for w in NSApp.windows where String(describing: type(of: w)).contains("StatusBar") {
            let on = w.isVisible && w.occlusionState.contains(.visible) && w.screen != nil
            log.info("status item window \(String(describing: type(of: w)), privacy: .public) frame=\(NSStringFromRect(w.frame), privacy: .public) visible=\(w.isVisible) occlusionVisible=\(w.occlusionState.contains(.visible)) onScreen=\(w.screen != nil)")
            if on, w.frame.width > 0, NSScreen.screens.contains(where: { $0.frame.intersects(w.frame) }) { return w.frame }
        }
        return nil
    }
}

private struct PanelCloseKey: EnvironmentKey { static let defaultValue: (@MainActor () -> Void)? = nil }
extension EnvironmentValues {
    /// Set when the menu bar panel is shown in its own floating panel (shortcut or the window's button).
    var panelClose: (@MainActor () -> Void)? {
        get { self[PanelCloseKey.self] }
        set { self[PanelCloseKey.self] = newValue }
    }
}

/// The menu bar panel in a floating panel of its own: opened by the shortcut or the window's button, closed by the
/// same shortcut, Esc, or clicking elsewhere. It shows the same view as the menu bar icon's panel.
@MainActor final class PanelController {
    static let shared = PanelController()
    private var panel: NSPanel?

    var isOpen: Bool { panel?.isVisible == true }

    /// The click on the window's panel button closes the panel first (click outside); that same click mustn't reopen it.
    private var closedAt = Date.distantPast
    func toggle() {
        if isOpen { close() } else if Date.now.timeIntervalSince(closedAt) > 0.4 { show() }
    }

    func show() {
        guard let model = AppDelegate.model else { return }
        let panel = self.panel ?? make()
        let host = NSHostingView(rootView: MenuBarPanel(model: model).environment(\.panelClose, { [weak self] in self?.close() }))
        host.safeAreaRegions = []   // the hidden title bar mustn't push the content down and cut off the buttons
        host.frame.size = host.fittingSize
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.state = .active
        effect.addSubview(host)
        host.frame.origin = .zero
        effect.frame.size = host.fittingSize
        panel.contentView = effect
        panel.setContentSize(host.fittingSize)
        let screen = NSScreen.main ?? NSScreen.screens.first
        if let screen {
            let icon = StatusItemProbe.visibleFrame()
            let origin = PanelAnchor.origin(panel: panel.frame.size, icon: icon, screen: screen.frame, visible: screen.visibleFrame)
            StatusItemProbe.log.info("panel open at \(NSStringFromPoint(origin), privacy: .public) icon=\(icon.map(NSStringFromRect) ?? "hidden", privacy: .public)")
            panel.setFrameOrigin(origin)
        }
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        watchClicks()
        StatusItemProbe.log.info("panel shown frame=\(NSStringFromRect(panel.frame), privacy: .public) onScreen=\(panel.isOnActiveSpace)")
    }

    func close() {
        if isOpen { closedAt = .now }
        panel?.orderOut(nil)
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
    }

    /// A click anywhere outside closes it, like the menu bar's own panel. Watching mouse clicks needs no permission
    /// (only key watching does), and unlike losing key focus it doesn't fire the moment the panel opens from another app.
    private var monitors: [Any] = []
    private func watchClicks() {
        guard monitors.isEmpty else { return }
        let kinds: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: kinds, handler: { _ in Task { @MainActor in PanelController.shared.close() } }) {
            monitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: kinds, handler: { e in
            if e.window !== PanelController.shared.panel { PanelController.shared.close() }
            return e
        }) { monitors.append(l) }
    }

    private func make() -> NSPanel {
        let p = KeyPanel(contentRect: .zero, styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { p.standardWindowButton($0)?.isHidden = true }
        p.isFloatingPanel = true   // before the level: it sets its own (floating)
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.title = "Hmunmawi panel"
        return p
    }
}

/// A panel that takes keys (Esc closes it) without bringing the whole app forward.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { PanelController.shared.close() }
}

/// The window's way to the panel, with the shortcut as a hint.
struct PanelButton: View {
    @State private var shortcut = PanelShortcut.shared
    var body: some View {
        Button { PanelController.shared.toggle() } label: {
            Label("Menu bar panel", systemImage: "menubar.arrow.down.rectangle")
        }
        .help("Open the menu bar panel" + (shortcut.hint.map { " (\($0) from anywhere)" } ?? ""))
    }
}

/// Once, when macOS has hidden the menu bar icon (menu bar full beside the notch): how to reach the panel anyway.
struct HiddenIconHint: View {
    @State private var shortcut = PanelShortcut.shared
    @State private var settings = MenuBarSettings.shared
    @AppStorage("HMPanelHintShown") private var shown = false
    @State private var hidden = false

    static func text(shortcut: String?) -> String {
        "macOS has tucked Hmunmawi's menu bar icon away because the menu bar is full. "
            + (shortcut.map { "Press \($0) to open its panel from anywhere, or " } ?? "Use the panel button in the toolbar, or ")
            + "hold ⌘ and drag the icon to the right of the notch."
    }

    var body: some View {
        Group {
            if hidden && !shown && settings.showIcon {
                HStack(spacing: 10) {
                    Image(systemName: "menubar.arrow.down.rectangle").foregroundStyle(.secondary)
                    Text(Self.text(shortcut: shortcut.hint)).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Open panel") { PanelController.shared.show() }
                    Button("Got it") { shown = true }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(.bar)
            }
        }
        .task {
            guard !shown else { return }
            try? await Task.sleep(for: .seconds(6))   // the icon settles into the menu bar first
            hidden = StatusItemProbe.visibleFrame() == nil
        }
    }
}
