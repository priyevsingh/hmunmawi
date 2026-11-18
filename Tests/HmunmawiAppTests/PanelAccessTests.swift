import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import HmunmawiApp

@MainActor @Suite struct PanelAccessTests {
    func fresh() -> UserDefaults {
        let name = "hm.panel.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func shortcutDefaultsToControlOptionH() {
        let s = PanelShortcut(defaults: fresh(), registers: false)
        #expect(s.enabled)
        #expect(s.key == .standard)
        #expect(s.key.display == "⌃⌥H")
        #expect(s.hint == "⌃⌥H")
    }

    @Test func shortcutChoicesArePersisted() {
        let d = fresh()
        let s = PanelShortcut(defaults: d, registers: false)
        s.key = HotKey(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(cmdKey | shiftKey), key: "M")
        s.enabled = false
        let again = PanelShortcut(defaults: d, registers: false)
        #expect(again.key.display == "⇧⌘M")
        #expect(!again.enabled)
        #expect(again.hint == nil)
        again.reset()
        #expect(PanelShortcut(defaults: d, registers: false).key == .standard)
    }

    @Test func recorderNeedsARealModifier() {
        #expect(HotKey.from(keyCode: 4, flags: [.shift], characters: "h") == nil)
        #expect(HotKey.from(keyCode: 4, flags: [], characters: "h") == nil)
        #expect(HotKey.from(keyCode: 4, flags: [.control, .option], characters: "h") == .standard)
    }

    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let visible = CGRect(x: 0, y: 0, width: 1512, height: 949)
    let panel = CGSize(width: 340, height: 560)

    @Test func panelSitsUnderTheIconWhenItShows() {
        let icon = CGRect(x: 900, y: 949, width: 30, height: 24)
        let o = PanelAnchor.origin(panel: panel, icon: icon, screen: screen, visible: visible)
        #expect(Double(o.x) == 745)
        #expect(Double(o.y) == 383)
    }

    @Test func hiddenIconFallsBackToTopRight() {
        let o = PanelAnchor.origin(panel: panel, icon: nil, screen: screen, visible: visible)
        #expect(Double(o.x) == 1164)
        #expect(Double(o.y) == 383)
        // An icon frame off every screen counts as hidden too.
        let off = PanelAnchor.origin(panel: panel, icon: CGRect(x: -500, y: 2000, width: 30, height: 24), screen: screen, visible: visible)
        #expect(off == o)
    }

    @Test func panelNeverHangsOffTheEdge() {
        let o = PanelAnchor.origin(panel: panel, icon: CGRect(x: 1490, y: 949, width: 20, height: 24), screen: screen, visible: visible)
        #expect(o.x + panel.width <= visible.maxX - 8)
    }

    @Test func iconIsSlim() {
        #expect(MenuBarIcon.width(symbolWidth: nil) == 16)
        #expect(MenuBarIcon.width(symbolWidth: 12) == 31)
    }

    @Test func newInstallsShowTheIconAlone() {
        let d = fresh()
        #expect(MenuBarSettings(defaults: d).number == .none)
        d.set("sales", forKey: "HMMenuBarNumber")
        #expect(MenuBarSettings(defaults: d).number == .sales)
    }

    @Test func hintNamesTheShortcutOrTheButton() {
        #expect(HiddenIconHint.text(shortcut: "⌃⌥H").contains("Press ⌃⌥H"))
        #expect(HiddenIconHint.text(shortcut: nil).contains("panel button"))
    }
}
