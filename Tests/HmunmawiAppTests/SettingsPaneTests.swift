import Foundation
import Testing
@testable import HmunmawiApp

/// Settings is a sidebar of panes (1.4.1): every pane must be listed once, reachable by `hm set settings.tab`,
/// and an unknown remembered value must fall back to General instead of showing nothing.
@Suite struct SettingsPaneTests {
    @Test func everyPaneListedOnceInOrder() {
        #expect(SettingsPane.allCases.map(\.rawValue) ==
                ["general", "menubar", "connections", "projects", "jobs", "rules", "permissions", "publish", "backups", "about"])
        #expect(Set(SettingsPane.allCases.map(\.title)).count == SettingsPane.allCases.count)
        #expect(SettingsPane.allCases.allSatisfy { !$0.title.isEmpty && !$0.symbol.isEmpty })
    }

    @Test func agentsCanOpenEveryPane() {
        for pane in SettingsPane.allCases {
            #expect(AgentSetting.settingsTab.validate(pane.rawValue) == pane.rawValue)
            #expect(AgentSetting.settingsTab.validate(pane.rawValue.uppercased()) == pane.rawValue)
        }
        #expect(AgentSetting.settingsTab.validate("nope") == nil)
    }

    @Test func unknownRememberedTabOpensGeneral() {
        #expect(SettingsPane.from("backups") == .backups)
        #expect(SettingsPane.from("") == .general)
        #expect(SettingsPane.from("old-tab") == .general)
    }

    /// The window can never be narrower than sidebar + pane, so no pane squeezes below the width its forms need.
    @Test func windowMinimumFitsSidebarAndPane() {
        #expect(SettingsView.sidebarWidth >= 180)
        #expect(SettingsView.paneMinWidth >= 760)
    }
}
