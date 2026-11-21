import Foundation
import Testing
@testable import HmunmawiCore

/// Your extras (1.5.0): anyone can switch on what owner.json used to switch on for one Mac only, from Settings or the
/// workspace file; an owner settings file still wins, so an owner Mac stays exactly as it was.
@Suite struct ExtrasTests {
    private func tmp() -> URL {
        let u = FileManager.default.temporaryDirectory.appending(path: "extras-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: u.appending(path: "config"), withIntermediateDirectories: true)
        return u
    }

    @Test func newInstallHasNothingOn() {
        let e = Extras(owner: OwnerConfig(), settings: UserExtras())
        #expect(e.workspace.url == nil && e.keyFolder.url == nil && e.reposFolder.url == nil)
        #expect(!e.aiPauseCard.on && !e.zohoMail.on && e.fixedZone == nil && !e.keychainWatcher.on)
        #expect(e.zone == .current)
        #expect(e.items().allSatisfy { !$0.on && $0.source == .none })
        #expect(e.items().map(\.id) == ["extras.workspace", "extras.key_folder", "extras.repos_folder", "extras.ai_pause_card",
                                        "extras.zoho_mail", "x.file", "extras.time_zone", "extras.keychain_watcher"])
    }

    @Test func settingsSwitchThemOn() {
        let s = UserExtras(workspace: "/w", keyFolder: "~/keys", reposFolder: "/r", aiPauseCard: true, zohoMail: true, timeZone: "Europe/Berlin")
        let e = Extras(owner: OwnerConfig(), settings: s)
        #expect(e.workspace.url?.path == "/w" && e.workspace.source == .settings)
        #expect(e.keyFolder.url?.path == URL.homeDirectory.appending(path: "keys").path)
        #expect(e.reposFolder.source == .settings)
        #expect(e.aiPauseCard == (true, .settings) && e.zohoMail.on)
        #expect(e.zone.identifier == "Europe/Berlin" && e.fixedZone?.source == .settings)
        #expect(!e.items().contains { $0.ownerOnly && $0.id != "extras.keychain_watcher" })
    }

    @Test func workspaceFileFillsWhatSettingsLeaveOpen() throws {
        let ws = tmp()
        try Data(#"{"key_folder":"secrets","ai_pause_card":true,"zoho_mail":true,"x_file":"data/x.json","time_zone":"Asia/Tokyo","repos_folder":"/code"}"#.utf8)
            .write(to: ws.appending(path: UserExtras.workspaceFileName))
        let (f, state) = UserExtras.load(ws.appending(path: UserExtras.workspaceFileName))
        #expect(state == .ok)
        // Settings switched the Zoho reader off on purpose: that wins over the file.
        let e = Extras(owner: OwnerConfig(), settings: UserExtras(workspace: ws.path, zohoMail: false), file: f, fileState: state)
        #expect(e.keyFolder.url?.path == ws.appending(path: "secrets").path && e.keyFolder.source == .workspace)
        #expect(e.reposFolder.url?.path == "/code")
        #expect(e.aiPauseCard == (true, .workspace))
        #expect(!e.zohoMail.on)
        #expect(e.workspaceXFile?.path == ws.appending(path: "data/x.json").path)
        #expect(e.fixedZone?.zone.identifier == "Asia/Tokyo" && e.fixedZone?.source == .workspace)
        #expect(e.items().first { $0.id == "x.file" }?.source == .workspace)
        // A path typed in Settings wins over the file's.
        #expect(e.items(xFileSetting: "/mine.json").first { $0.id == "x.file" }?.value == "/mine.json")
    }

    @Test func brokenOrMissingFileSwitchesNothingOn() throws {
        let ws = tmp()
        #expect(UserExtras.load(ws.appending(path: UserExtras.workspaceFileName)).1 == .missing)
        try Data("{not json".utf8).write(to: ws.appending(path: UserExtras.workspaceFileName))
        let (f, state) = UserExtras.load(ws.appending(path: UserExtras.workspaceFileName))
        #expect(f == UserExtras())
        if case .unreadable = state {} else { Issue.record("expected unreadable, got \(state)") }
        try Data(#"{"ai_pause_card":"yes"}"#.utf8).write(to: ws.appending(path: UserExtras.workspaceFileName))
        if case .unreadable(let why) = UserExtras.load(ws.appending(path: UserExtras.workspaceFileName)).1 {
            #expect(why.contains("ai_pause_card"))
        } else { Issue.record("expected a type error") }
    }

    @Test func unknownZoneAndRelativePathsWithoutWorkspaceAreIgnored() {
        let e = Extras(owner: OwnerConfig(), settings: UserExtras(timeZone: "Mars/Olympus"),
                       file: UserExtras(keyFolder: "secrets", timeZone: "Nowhere/City"), fileState: .ok)
        #expect(e.fixedZone == nil && e.keyFolder.url == nil)
    }

    /// An owner Mac keeps exactly what owner.json says, whatever this Mac's settings or a workspace file hold.
    @Test func ownerSettingsFileWins() {
        var o = OwnerConfig(enabled: true)
        o.hubRoot = "/hub"; o.keyFolder = "/ownerkeys"; o.reposFolder = "/ownerrepos"; o.aiPause = true; o.zohoMail = true
        o.timeZone = "Asia/Kolkata"; o.keychainWatcher = true; o.xFileFeed = true
        let s = UserExtras(workspace: "/other", keyFolder: "/k", reposFolder: "/r", aiPauseCard: false, zohoMail: false, timeZone: "Europe/Berlin")
        let e = Extras(owner: o, settings: s, file: UserExtras(timeZone: "Asia/Tokyo"), fileState: .ok)
        #expect(e.workspace.url?.path == "/hub" && e.workspace.source == .owner)
        #expect(e.keyFolder.url?.path == "/ownerkeys" && e.reposFolder.url?.path == "/ownerrepos")
        #expect(e.aiPauseCard == (true, .owner) && e.zohoMail == (true, .owner))
        #expect(e.zone.identifier == "Asia/Kolkata" && e.zone == o.zone)
        #expect(e.keychainWatcher == (true, .owner))
        let items = e.items()
        for id in ["extras.workspace", "extras.key_folder", "extras.repos_folder", "extras.ai_pause_card", "extras.zoho_mail", "extras.time_zone"] {
            #expect(items.first { $0.id == id }?.ownerOnly == true, "\(id)")
        }
        #expect(items.first { $0.id == "x.file" }?.source == .owner)
        // Same six things the old Owner extras section listed are on.
        #expect(items.filter(\.on).count == 8)
    }

    /// owner.json present but switched off behaves like a new install.
    @Test func disabledOwnerFileIsIgnored() {
        var o = OwnerConfig(enabled: false); o.hubRoot = "/hub"; o.aiPause = true; o.timeZone = "Asia/Kolkata"
        let e = Extras(owner: o, settings: UserExtras())
        #expect(e.workspace.url == nil && !e.aiPauseCard.on && e.fixedZone == nil)
    }

    @Test func keychainWatcherOnlyFromABuildOrOwner() {
        #expect(Extras(owner: OwnerConfig(), settings: UserExtras(), watcherBundled: true).keychainWatcher == (true, .build))
        #expect(Extras(owner: OwnerConfig(), settings: UserExtras()).items().last?.ownerOnly == true)
    }

    @Test func switchFileFoundInTheWorkspace() throws {
        let ws = tmp()
        #expect(SwitchFile.locate(chosen: nil, owner: OwnerConfig(), workspace: ws) == nil)
        try Data("{}".utf8).write(to: ws.appending(path: "config/hmunmawi-switches.json"))
        #expect(SwitchFile.locate(chosen: nil, owner: OwnerConfig(), workspace: ws)?.lastPathComponent == "hmunmawi-switches.json")
        #expect(SwitchFile.locate(chosen: nil, owner: OwnerConfig(), workspace: nil) == nil)
    }

    @Test func fileKeysAreSnakeCase() throws {
        let data = try JSONEncoder().encode(UserExtras(keyFolder: "a", aiPauseCard: true, timeZone: "UTC"))
        let s = String(decoding: data, as: UTF8.self)
        #expect(s.contains("key_folder") && s.contains("ai_pause_card") && s.contains("time_zone"))
    }
}
