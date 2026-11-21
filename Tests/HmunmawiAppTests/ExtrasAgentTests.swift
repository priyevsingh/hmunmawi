import Foundation
import Testing
@testable import HmunmawiApp
@testable import HmunmawiCore

/// Agents read Your extras with `hm extras` and set the generic ones with `hm set extras.*`; folders and the Zoho
/// reader need the Connections permission; owner-only ones are never settable.
@Suite struct ExtrasAgentTests {
    @Test func settableKeysAndChecks() {
        #expect(AgentSetting(rawValue: "extras.workspace")?.validate("~/work") == "~/work")
        #expect(AgentSetting(rawValue: "extras.workspace")?.validate("relative/path") == nil)
        #expect(AgentSetting(rawValue: "extras.key_folder")?.validate("none") == "none")
        #expect(AgentSetting(rawValue: "extras.ai_pause_card")?.validate("TRUE") == "true")
        #expect(AgentSetting(rawValue: "extras.ai_pause_card")?.validate("yes") == nil)
        #expect(AgentSetting(rawValue: "extras.time_zone")?.validate("europe/berlin") == "Europe/Berlin")
        #expect(AgentSetting(rawValue: "extras.time_zone")?.validate("Mars/Olympus") == nil)
        #expect(AgentSetting(rawValue: "extras.keychain_watcher") == nil)   // owner-only: no settable key
        #expect(AgentSetting(rawValue: "owner.safari_driver") == nil)
    }

    @Test func permissions() {
        for k in ["extras.workspace", "extras.key_folder", "extras.repos_folder", "extras.zoho_mail"] {
            #expect(AgentSetting(rawValue: k)?.action == .connections, "\(k)")
        }
        #expect(AgentSetting(rawValue: "extras.ai_pause_card")?.action == nil)
        #expect(AgentSetting(rawValue: "extras.time_zone")?.action == .routines)   // moves every routine's time
    }

    @Test func everyExtraKeyHasItsOwnDefault() {
        let extras = AgentSetting.allCases.filter(\.isExtra)
        #expect(extras.count == 6)
        #expect(Set(extras.map(\.defaultsKey)).count == 6)
        #expect(extras.allSatisfy { $0.defaultsKey.hasPrefix("HMExtras") })
        // Every settable extra is a row in the section, and the guide lists the read command.
        let ids = Set(Extras(owner: OwnerConfig(), settings: UserExtras()).items().map(\.id))
        #expect(extras.allSatisfy { ids.contains($0.rawValue) })
        #expect(AgentGuide.commands.contains { $0["name"] == "extras" && $0["needs"] == "nothing" })
        #expect(AgentGuide.text.contains("extras.time_zone"))
    }

    @Test func zohoOfferedWhenYourExtrasSayso() {
        #expect(!MailSourceKind.offered(current: .off, owner: OwnerConfig(), extras: false).contains(.zohoSafari))
        #expect(MailSourceKind.offered(current: .off, owner: OwnerConfig(), extras: true).contains(.zohoSafari))
    }
}
