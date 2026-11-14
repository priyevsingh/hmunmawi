import Foundation
import Testing
@testable import HmunmawiCore

@Test func fdaProbePathsNeverTouchDocumentsFolders() {
    let paths = MacPermissionCatalog.defaultFDAProbePaths(home: URL(fileURLWithPath: "/Users/example"))
    #expect(!paths.isEmpty)
    for path in paths {
        #expect(!path.contains("/Documents"), "FDA probe must not list Documents (that can prompt): \(path)")
        #expect(!path.contains("/Desktop"), "FDA probe must not list Desktop: \(path)")
        #expect(!path.contains("/Downloads"), "FDA probe must not list Downloads: \(path)")
    }
}

@Test func fdaGrantedWhenAnyExistingPathIsReadable() {
    let paths = ["/tmp/missing-fda-1", "/tmp/fda-readable", "/tmp/fda-blocked"]
    #expect(MacPermissionCatalog.hasFullDiskAccess(probePaths: paths, exists: { $0.hasSuffix("readable") || $0.hasSuffix("blocked") }, readable: { $0.hasSuffix("readable") }))
    #expect(!MacPermissionCatalog.hasFullDiskAccess(probePaths: paths, exists: { $0.hasSuffix("blocked") }, readable: { _ in false }))
    #expect(!MacPermissionCatalog.hasFullDiskAccess(probePaths: paths, exists: { _ in false }, readable: { _ in true }))
}

@Test func privacyDeepLinksUseSystemPreferencesScheme() {
    for url in [
        MacPermissionCatalog.fullDiskAccessURL,
        MacPermissionCatalog.filesAndFoldersURL,
        MacPermissionCatalog.automationURL,
        MacPermissionCatalog.accessibilityURL,
        MacPermissionCatalog.calendarsURL,
    ] {
        #expect(url.hasPrefix("x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?"))
    }
    #expect(MacPermissionCatalog.fullDiskAccessURL.contains("Privacy_AllFiles"))
    #expect(MacPermissionCatalog.filesAndFoldersURL.contains("Privacy_FilesAndFolders"))
    #expect(MacPermissionCatalog.automationURL.contains("Privacy_Automation"))
    #expect(MacPermissionCatalog.accessibilityURL.contains("Privacy_Accessibility"))
    #expect(MacPermissionCatalog.calendarsURL.contains("Privacy_Calendars"))
    #expect(MacPermissionCatalog.notificationsURL.hasPrefix("x-apple.systempreferences:com.apple.Notifications-Settings.extension"))
}

@Test func preflightBlocksMissingAutomationAndAllowsWhenGranted() {
    var facts = MacPermissionFacts(usesIMessage: true, usesSafariLogin: true)
    var snap = MacPermissionCatalog.snapshot(from: facts)
    let blocked = snap.preflight([.safari])
    #expect(!blocked.allowed)
    #expect(blocked.missing == [.automationSafari])
    #expect(blocked.banner == "Needs permission: Safari — Fix")

    facts.safari = .granted
    snap = MacPermissionCatalog.snapshot(from: facts)
    #expect(snap.preflight([.safari]).allowed)

    facts.messages = .notGranted
    snap = MacPermissionCatalog.snapshot(from: facts)
    let msg = snap.preflight([.messages])
    #expect(!msg.allowed)
    #expect(msg.banner == "Needs permission: Messages — Fix")
}

@Test func filesAndFoldersSatisfiedByFullDiskAccess() {
    let facts = MacPermissionFacts(fullDiskAccess: true, filesAndFolders: false)
    let snap = MacPermissionCatalog.snapshot(from: facts)
    #expect(snap.item(.filesAndFolders)?.status == .granted)
    #expect(snap.preflight([.files]).allowed)
    #expect(snap.item(.fullDiskAccess)?.status == .granted)
}

@Test func unusedMailSafariCalendarAreNotNeededAndNotRequired() {
    let snap = MacPermissionCatalog.snapshot(from: MacPermissionFacts())
    #expect(snap.item(.automationMail)?.status == .notNeeded)
    #expect(snap.item(.automationMail)?.required == false)
    #expect(snap.item(.automationSafari)?.status == .notNeeded)
    #expect(snap.item(.automationMessages)?.status == .notNeeded)
    #expect(snap.item(.calendars)?.status == .notNeeded)
    #expect(snap.item(.accessibility)?.status == .notNeeded)
    #expect(snap.item(.accessibility)?.required == false)
    #expect(snap.items.contains { $0.id == .filesAndFolders && $0.required })
}

@Test func claudeGateHiddenUnlessInstalledOrOwnerUsesIt() {
    let hidden = MacPermissionCatalog.snapshot(from: MacPermissionFacts())
    #expect(hidden.item(.claudeGateFDA)?.status == .notNeeded)
    #expect(hidden.item(.claudeGateFDA)?.required == false)

    let url = URL(fileURLWithPath: "/tmp/ClaudeGate.app")
    let shown = MacPermissionCatalog.snapshot(from: MacPermissionFacts(claudeGateURL: url, claudeGateHasFDA: false, usesClaudeJobs: true))
    #expect(shown.item(.claudeGateFDA)?.status == .notGranted)
    #expect(shown.item(.claudeGateFDA)?.required == true)
    #expect(shown.item(.claudeGateFDA)?.revealURL == url)
    #expect(shown.preflight([.claude]).banner == "Needs permission: Claude helper (all files) — Fix")

    let granted = MacPermissionCatalog.snapshot(from: MacPermissionFacts(filesAndFolders: true, keychain: .granted, claudeGateURL: url, claudeGateHasFDA: true, usesClaudeJobs: true))
    #expect(granted.item(.claudeGateFDA)?.status == .granted)
    #expect(granted.requiredMissing.isEmpty)
}

@Test func claudeGateURLComesOnlyFromTheOwnerPath() {
    let home = URL(fileURLWithPath: "/Users/example")
    let custom = URL(fileURLWithPath: "/opt/helpers/ClaudeGate.app")
    #expect(MacPermissionCatalog.claudeGateURL(ownerPath: "/opt/helpers/ClaudeGate.app", home: home, exists: { $0 == custom }) == custom)
    #expect(MacPermissionCatalog.claudeGateURL(ownerPath: nil, home: home, exists: { _ in true }) == nil)
    #expect(MacPermissionCatalog.claudeGateURL(ownerPath: "/opt/helpers/ClaudeGate.app", home: home, exists: { _ in false }) == nil)
}

@Test func ownerConfigReadsClaudeGatePathOnlyWhenEnabled() throws {
    let json = """
    {"enabled": true, "claudeGateApp": "~/Library/Application Support/my-jobs/ClaudeGate.app"}
    """
    let c = try JSONDecoder().decode(OwnerConfig.self, from: Data(json.utf8))
    #expect(c.claudeGateURL?.lastPathComponent == "ClaudeGate.app")
    var off = c
    off.enabled = false
    #expect(off.claudeGateURL == nil)
}

@Test func catalogHasNoContactsOrRemindersRows() {
    let ids = Set(MacPermissionCatalog.snapshot(from: MacPermissionFacts()).items.map(\.id))
    #expect(!ids.contains { "\($0)".localizedCaseInsensitiveContains("contact") })
    #expect(!ids.contains { "\($0)".localizedCaseInsensitiveContains("remind") })
}

@Test func missingRequiredItemsMakeCautionLines() {
    let snap = MacPermissionCatalog.snapshot(from: MacPermissionFacts())
    #expect(!snap.requiredGranted)
    #expect(snap.cautionLines.contains { $0.contains("Files in Documents") })
}
