import AppKit
import ApplicationServices
import HmunmawiCore
import ServiceManagement
import SwiftUI
import UserNotifications

/// Every Mac permission Hmunmawi uses, shown in one place at first launch and in Settings → Permissions.
/// Status is re-read without presenting a system prompt. Only a Grant button the person clicks may ask macOS.
@Observable @MainActor
final class Permissions {
    static let shared = Permissions()
    enum State { case granted, notAsked, denied }

    var messages: State = .notAsked
    var openAtLogin: State = .notAsked
    var safari: State = .notAsked
    /// Apple Mail is optional (only when the reply watch reads Apple Mail), so it never holds setup back.
    var mail: State = .notAsked
    /// Whether Hmunmawi can save and read its own keys in the Keychain without any password box (checked with a test item).
    var keychain: State = .notAsked
    /// Calendar is optional (only for routines with "Also put it in my Calendar"), so it never holds setup back.
    var calendar: State = CalendarEvents.state
    var files: State = .notAsked
    var notifications: State = .notAsked
    var fullDiskAccess = false
    /// Set when this launch is signed differently from the last one: which permissions to switch on again.
    var identityChangeNote: String? = UserDefaults.standard.string(forKey: "HMSigningChangeNote")
    var accessibilityTrusted = false
    /// Live catalogue used by Settings, setup, health, the menu bar and job pre-flight.
    var snapshot = MacPermissionSnapshot.empty
    /// Last missing-permission banner shown, so a repeating job does not spam notifications.
    private var lastPermissionBanner: String?
    private(set) var lastRefresh: Date?

    /// Safari is optional (only for "Read using my Safari login"), so it never holds setup back.
    /// Required items (files, Keychain, and Messages when iMessage is on) must be allowed; Open at login is a choice.
    var allGranted: Bool { snapshot.requiredGranted && keychain != .denied }

    /// Needs this routine would exercise, so a missing grant can defer the run before any prompt appears.
    static func macNeeds(for routine: MyRoutine, kind: RoutineKind, tellChannel: String?) -> [MacJobNeed] {
        var needs: [MacJobNeed] = []
        if routine.params?["calendar"] == "1" { needs.append(.calendar) }
        let imessage = tellChannel == "imessage"
        switch kind {
        case .remind, .morningStory, .weeklyDigest:
            if imessage { needs.append(.messages) }
        case .script, .keyWatch:
            needs.append(.files)
        case .outreachReplies:
            switch MailWatch.kind {
            case .appleMail: needs.append(.mail)
            case .zohoSafari: needs.append(.safari)
            default: break
            }
        case .replyIdeas, .unfollowList:
            needs.append(.files)
            if routine.params?["source"] == "safari" { needs.append(.safari) }   // reads X through your Safari login
            if imessage { needs.append(.messages) }
        case .siteWatch, .offerExpiry, .aiBrief, .postDrafts, .followUps, .judge, .macJob:
            break
        }
        if routine.params?["done"] == "1", imessage { needs.append(.messages) }
        return needs
    }

    func preflight(_ needs: [MacJobNeed]) -> MacPreflight {
        snapshot.preflight(needs)
    }

    /// Returns a short note and records a single notification when a job must wait. Does not ask macOS.
    func deferIfNeeded(_ needs: [MacJobNeed]) -> String? {
        let result = preflight(needs)
        guard !result.allowed else { return nil }
        reportDeferred(result)
        return result.banner.map { "\($0). Open Settings → Permissions, then try again." } ?? "A Mac permission is missing."
    }

    func reportDeferred(_ result: MacPreflight) {
        guard let banner = result.banner else { return }
        guard banner != lastPermissionBanner else { return }
        lastPermissionBanner = banner
        MacNotifier.shared.needsPermission(banner)
    }

    func refresh(from model: AppModel? = nil) async {
        fullDiskAccess = MacPermissionCatalog.hasFullDiskAccess()
        let filesOK = fullDiskAccess || FolderBookmarks.hasAccess()
        files = filesOK ? .granted : .notAsked
        messages = await Self.automationState(ask: false)
        safari = await Self.automationState(ask: false, app: "com.apple.Safari")
        mail = await Self.automationState(ask: false, app: "com.apple.mail")
        calendar = CalendarEvents.state
        notifications = await Self.notificationState()
        accessibilityTrusted = AXIsProcessTrusted()
        keychain = await Task.detached { Self.keychainProbe() }.value
        openAtLogin = switch Self.loginAgent.status {
        case .enabled: .granted
        case .requiresApproval: .denied
        default: .notAsked
        }

        let usesIMessage = model?.addOns.contains { $0.id == "imessage" && $0.approved } ?? false
        let usesSafariLogin = MailWatch.kind == .zohoSafari
        let usesMail = MailWatch.kind == .appleMail
        let usesCalendar = MyRoutines.read().contains { $0.params?["calendar"] == "1" }
        let owner = OwnerConfig.current
        let gate = MacPermissionCatalog.claudeGateURL(ownerPath: owner.isOn ? owner.claudeGateApp : nil)
        // Only a helper you set up needs the permission; the AI pause card just reads a lock file.
        let usesClaude = gate != nil
        let facts = MacPermissionFacts(
            fullDiskAccess: fullDiskAccess,
            filesAndFolders: filesOK,
            messages: map(messages), safari: map(safari), mail: map(mail),
            notifications: map(notifications), calendars: map(calendar),
            accessibility: accessibilityTrusted ? .granted : .notGranted,
            openAtLogin: map(openAtLogin), keychain: map(keychain),
            claudeGateURL: gate, claudeGateHasFDA: gate.flatMap { Self.claudeGateHasFDA($0) },
            usesIMessage: usesIMessage, usesSafariLogin: usesSafariLogin, usesMail: usesMail,
            usesCalendar: usesCalendar, usesClaudeJobs: usesClaude
        )
        var snap = MacPermissionCatalog.snapshot(from: facts)
        snap.items = snap.items.map { item in
            var i = item
            if i.id == .fullDiskAccess { i.revealURL = Bundle.main.bundleURL }
            if i.id == .notifications, let bid = Bundle.main.bundleIdentifier {
                i.settingsURL = "\(MacPermissionCatalog.notificationsURL)?id=\(bid)"
            }
            return i
        }
        snapshot = snap
        lastRefresh = .now
        if snap.requiredMissing.isEmpty { lastPermissionBanner = nil }
    }

    func refreshIfStale(from model: AppModel? = nil, olderThan: TimeInterval = 120) async {
        if let lastRefresh, Date.now.timeIntervalSince(lastRefresh) < olderThan, !snapshot.items.isEmpty { return }
        await refresh(from: model)
    }

    private func map(_ state: State) -> MacPermissionStatus {
        state == .granted ? .granted : .notGranted
    }

    /// Check the signed helper without prompting. It is started through `open` so macOS judges the helper's own
    /// identity (a direct child would be judged as Hmunmawi). It writes "1" (Full Disk Access) or "0" to a temp file.
    /// nil = could not tell (old helper without --fda-check, or no answer within 5 s).
    nonisolated static func claudeGateHasFDA(_ app: URL) -> Bool? {
        let exe = app.appending(path: "Contents/MacOS/ClaudeGate")
        guard FileManager.default.isExecutableFile(atPath: exe.path) else { return nil }
        let out = FileManager.default.temporaryDirectory.appending(path: "hm-claudegate-fda-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-g", "-n", app.path, "--args", "--fda-check", "--out", out.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { return nil }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let text = try? String(contentsOf: out, encoding: .utf8) {
                switch text.trimmingCharacters(in: .whitespacesAndNewlines) {
                case "1": return true
                case "0": return false
                default: break
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return nil
    }

    func askMessages() async {
        messages = await Self.automationState(ask: true)
        await refresh()
    }

    /// Apple Mail: only used when you choose it as the mail source for the outreach reply watch.
    func askMail() async {
        await Self.openQuietly(bundleID: "com.apple.mail")
        mail = await Self.automationState(ask: true, app: "com.apple.mail")
        await refresh()
    }

    /// macOS can only ask "allow Hmunmawi to control X?" while X is running (otherwise the check answers "not running"
    /// and no question appears), so the app is opened in the background first, without taking the screen.
    nonisolated static func openQuietly(bundleID: String) async {
        let running = await MainActor.run { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }
        if running { return }
        guard let url = await MainActor.run(body: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.hides = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
    }

    /// Safari: only used when you choose "Read using my Safari login" for a page no key can read.
    func askSafari() async {
        await Self.openQuietly(bundleID: "com.apple.Safari")
        safari = await Self.automationState(ask: true, app: "com.apple.Safari")
        await refresh()
    }

    /// Saves, reads and removes one test item with Hmunmawi's own Keychain service. No password box can appear (they are
    /// switched off for the whole app); if the read fails, something saved by a differently signed copy is in the way.
    nonisolated static func keychainProbe() -> State {
        let store = KeychainSecretStore()
        let value = UUID().uuidString
        defer { store.deleteSecret(plugin: "hmunmawi", name: "keychain-probe") }
        do {
            try store.setSecret(value, plugin: "hmunmawi", name: "keychain-probe")
            return try store.secret(plugin: "hmunmawi", name: "keychain-probe") == value ? .granted : .denied
        } catch { return .denied }
    }

    /// Calendar: lets a routine put its message into a "Hmunmawi" calendar too. Asked here, in setup, never mid-use.
    func askCalendar() async {
        _ = await CalendarEvents.ask()
        calendar = CalendarEvents.state
        await refresh()
    }

    func askNotifications() async {
        await MacNotifier.shared.askForBanners()
        await refresh()
    }

    /// Files: lets "Find CSV files" look in iCloud Drive, Downloads, Documents and Desktop. macOS asks once per folder,
    /// so all four are asked here together, in setup, never in the middle of using the app. Check again never lists them.
    func askFiles() async {
        // Off the main thread: macOS holds each read while its "allow access" box is up, and the window must stay live.
        let urls = await Task.detached(priority: .userInitiated) { () -> [URL] in
            let home = URL.homeDirectory
            return ["Library/Mobile Documents/com~apple~CloudDocs", "Downloads", "Documents", "Desktop"].compactMap { rel in
                let url = home.appending(path: rel)
                guard (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil else { return nil }
                return url
            }
        }.value
        FolderBookmarks.save(urls)
        files = (fullDiskAccess || !urls.isEmpty) ? .granted : .denied
        await refresh()
    }

    /// A launchd agent rather than a plain login item, so macOS also relaunches Hmunmawi if it crashes.
    static let loginAgent = SMAppService.agent(plistName: "io.github.priyevsingh.Hmunmawi.agent.plist")

    func askOpenAtLogin() async {
        if SMAppService.mainApp.status == .enabled { try? await SMAppService.mainApp.unregister() }
        try? Self.loginAgent.register()
        if Self.loginAgent.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        await refresh()
    }

    func grant(_ id: MacPermissionID) async {
        switch id {
        case .filesAndFolders: await askFiles()
        case .automationMessages: await askMessages()
        case .automationSafari: await askSafari()
        case .automationMail: await askMail()
        case .calendars: await askCalendar()
        case .notifications: await askNotifications()
        case .openAtLogin: await askOpenAtLogin()
        case .keychain: await refresh()
        case .fullDiskAccess, .claudeGateFDA, .accessibility:
            if let item = snapshot.item(id) { Self.openSettings(item.settingsURL) }
        }
    }

    func openPrivacySettings() {
        Self.openSettings(MacPermissionCatalog.automationURL)
    }

    static func openSettings(_ urlString: String) {
        let fallback = urlString.replacingOccurrences(of: MacPermissionCatalog.modernBase, with: MacPermissionCatalog.legacyBase)
        for s in [urlString, fallback] {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Checks (or asks for) permission to send Apple Events to Messages. Runs off the main thread because asking blocks.
    /// Check again always passes ask=false so a box never appears mid-refresh.
    private nonisolated static func automationState(ask: Bool, app: String = "com.apple.MobileSMS") async -> State {
        let status: OSStatus = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let target = NSAppleEventDescriptor(bundleIdentifier: app)
                continuation.resume(returning: AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask))
            }
        }
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        default: return .notAsked
        }
    }

    private static func notificationState() async -> State {
        guard MacNotifier.available else { return .notAsked }
        await MacNotifier.shared.refreshAuthorization()
        switch MacNotifier.shared.authorization {
        case .authorized, .provisional, .ephemeral: return .granted
        case .denied: return .denied
        default: return .notAsked
        }
    }
}

/// Security-scoped bookmarks for Documents / Desktop / Downloads / iCloud, so Check again can confirm access
/// without listing those folders (a listing can present a Files and Folders prompt).
enum FolderBookmarks {
    static var file: URL { URL.hmSupport.appending(path: "folder-bookmarks.plist") }

    static func save(_ urls: [URL]) {
        let blobs: [Data] = urls.compactMap {
            try? $0.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: blobs, format: .xml, options: 0) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    static func hasAccess() -> Bool {
        guard let data = try? Data(contentsOf: file),
              let blobs = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [Data]
        else { return false }
        for blob in blobs {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: blob, options: [.withSecurityScope, .withoutUI],
                                     relativeTo: nil, bookmarkDataIsStale: &stale)
            else { continue }
            if url.startAccessingSecurityScopedResource() {
                url.stopAccessingSecurityScopedResource()
                return true
            }
        }
        return false
    }
}

struct PermissionsList: View {
    let permissions: Permissions
    var showsRefresh = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsRefresh {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Mac permissions").font(.headline)
                        Text("Grant each one once and it stays on, also after updates. If a routine needs one that's off, it waits and Hmunmawi tells you.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("Check again") { Task { await permissions.refresh() } }.buttonStyle(.pill)
                }
            }
            if let note = permissions.identityChangeNote {
                VStack(alignment: .leading, spacing: 6) {
                    Text(note).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    Button("Got it") {
                        permissions.identityChangeNote = nil
                        UserDefaults.standard.removeObject(forKey: "HMSigningChangeNote")
                    }.buttonStyle(.pill)
                }
                .padding(10).background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            ForEach(visibleItems) { item in
                row(item)
            }
        }
        .task { await permissions.refreshIfStale(olderThan: 30) }
    }

    private var visibleItems: [MacPermissionItem] {
        permissions.snapshot.items.filter { $0.status != .notNeeded || $0.id == .accessibility }
    }

    private func symbol(_ id: MacPermissionID) -> String {
        switch id {
        case .fullDiskAccess, .claudeGateFDA: "externaldrive.fill"
        case .filesAndFolders: "folder.fill"
        case .automationMessages: "message.fill"
        case .automationSafari: "safari.fill"
        case .automationMail: "envelope.fill"
        case .notifications: "bell.fill"
        case .calendars: "calendar"
        case .accessibility: "accessibility"
        case .openAtLogin: "power"
        case .keychain: "key.fill"
        }
    }

    private func row(_ item: MacPermissionItem) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol(item.id))
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 40)
                .background(Color.secondary.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.title).font(.headline)
                    if !item.required && item.status != .notNeeded {
                        Text("Optional").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(item.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let url = item.revealURL {
                    Text(PathField.short(url.path)).font(.caption).foregroundStyle(.secondary).help(url.path)
                    Button("Reveal in Finder") { Permissions.reveal(url) }.buttonStyle(.pill)
                }
            }
            Spacer(minLength: 12)
            statusControl(item)
        }
        .padding(16)
        .contentCard(cornerRadius: 20)
    }

    @ViewBuilder private func statusControl(_ item: MacPermissionItem) -> some View {
        switch item.status {
        case .granted:
            Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(Brand.good).labelStyle(.titleAndIcon)
        case .notNeeded:
            Text("Not needed").font(.callout).foregroundStyle(.secondary)
        case .notGranted:
            VStack(alignment: .trailing, spacing: 6) {
                if item.canPrompt {
                    Button("Grant") { Task { await permissions.grant(item.id) } }.buttonStyle(.pillProminent)
                    Button("Open Settings") { Permissions.openSettings(item.settingsURL) }.buttonStyle(.pill)
                } else {
                    Button("Open Settings") { Permissions.openSettings(item.settingsURL) }.buttonStyle(.pill)
                }
            }
        }
    }
}
