import CryptoKit
import Foundation
import Testing
@testable import HmunmawiCore
@testable import HmunmawiProtocol

@Suite struct SecurityRecheckTests {
    private func manifest(_ json: String) throws -> PluginManifest {
        try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
    }

    @Test func onlyTheScriptFeedMayEmitAnything() throws {
        let other = try manifest(#"{"id":"evil","name":"E","version":"1","protocol":1,"executable":"x","emits":["*"]}"#)
        #expect(throws: (any Error).self) { try other.validate() }
        let feed = try manifest(#"{"id":"scriptfeed","name":"S","version":"1","protocol":1,"executable":"x","emits":["*"]}"#)
        try feed.validate()
        #expect(feed.mayEmit("anything.at_all"))
        let listed = try manifest(#"{"id":"ok","name":"O","version":"1","protocol":1,"executable":"x","emits":["crash.daily"]}"#)
        try listed.validate()
        #expect(listed.mayEmit("crash.daily") && !listed.mayEmit("job.failed"))
    }

    @Test func noAddOnMayTakeAnIdOfTheAppsOwnKeychainAreas() throws {
        for id in ["hmunmawi", "live", "mail", "usage", "agent-pending", "hooks", "live.x", "mail-extra"] {
            let m = try manifest(#"{"id":"\#(id)","name":"E","version":"1","protocol":1,"executable":"x","permissions":{"secrets":["relayKey"]}}"#)
            #expect(throws: (any Error).self, "\(id) must be refused") { try m.validate() }
        }
        try manifest(#"{"id":"mailchimp","name":"M","version":"1","protocol":1,"executable":"x"}"#).validate()
        try manifest(#"{"id":"cloudflare","name":"C","version":"1","protocol":1,"executable":"x"}"#).validate()
    }

    @Test func withoutASigningKeyNoApprovalCountsOnceTheAppAsksForSignatures() async throws {
        let store = try Store(path: ":memory:")
        try await store.approvePlugin(id: "a", fingerprint: "sha-a", by: "you")
        #expect(try await store.isPluginApproved(id: "a", fingerprint: "sha-a"))      // tools and tests: no key, no requirement
        await store.setRequireSignedApprovals(true)                                   // the app: Keychain silent = nothing counts
        #expect(try await !store.isPluginApproved(id: "a", fingerprint: "sha-a"))
    }

    @Test func aCutOffLogTailIsNoticed() async throws {
        let store = try Store(path: ":memory:")
        await store.setTrustKey(SymmetricKey(size: .bits256))
        for i in 1...3 { try await store.appendAudit(actor: "app", action: "a\(i)") }
        let head = try #require(try await store.auditHead())
        #expect(try await store.auditEntryExists(id: head.id, hash: head.hash))
        try await store.rawExecute("DELETE FROM audit WHERE id = \(head.id)")
        #expect(try await store.auditEntryExists(id: head.id, hash: head.hash) == false)
        try await store.rawExecute("DELETE FROM audit")
        #expect(try await store.auditEntryExists(id: head.id, hash: head.hash) == false)
    }

    @Test func aLinkOutOfTheFolderIsRefused() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hm-\(UUID().uuidString)/x.hmplugin")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: dir.appending(path: "plugin"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appending(path: "plugin").path)
        try Data(#"{"id":"x","name":"X","version":"1","protocol":1,"executable":"plugin"}"#.utf8).write(to: dir.appending(path: "manifest.json"))
        _ = try InstalledPlugin.load(from: dir)
        try FileManager.default.createSymbolicLink(at: dir.appending(path: "out"), withDestinationURL: URL(filePath: "/etc/hosts"))
        #expect(throws: (any Error).self) { _ = try InstalledPlugin.load(from: dir) }
    }

    /// Runs `tool` under the real add-on profile and returns its exit status.
    private func underSandbox(_ tool: String, _ args: [String]) throws -> Int32 {
        let id = "sandbox-test-\(UUID().uuidString.prefix(8))"
        let state = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Hmunmawi/AddOnState/\(id)")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: state) }
        let profile = PluginProcess.sandboxProfile(executable: URL(filePath: tool), directory: URL(filePath: "/private/var/empty"), id: id)
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/sandbox-exec")
        p.arguments = ["-p", profile, tool] + args.map { $0.replacingOccurrences(of: "$STATE", with: state.path) }
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        return p.terminationStatus
    }

    @Test func theSandboxWritesOnlyToItsOwnState() throws {
        #expect(try underSandbox("/usr/bin/touch", ["$STATE/ok"]) == 0)
        #expect(try underSandbox("/usr/bin/touch", ["/private/tmp/hm-sandbox-\(UUID().uuidString)"]) != 0)
        #expect(try underSandbox("/usr/bin/touch", [NSHomeDirectory() + "/hm-sandbox-probe"]) != 0)
    }

    @Test func theSandboxReadsNoHomeFiles() throws {
        let probe = NSHomeDirectory() + "/.hm-sandbox-read-probe"
        try Data("x".utf8).write(to: URL(filePath: probe))
        defer { try? FileManager.default.removeItem(atPath: probe) }
        #expect(try underSandbox("/bin/cat", [probe]) != 0)
        #expect(try underSandbox("/bin/cat", ["/System/Volumes/Data" + probe]) != 0)
    }

    @Test func entriesDuringAKeychainOutageAreHeldThenSigned() async throws {
        let store = try Store(path: ":memory:")
        let key = SymmetricKey(size: .bits256)
        await store.setTrustKey(key)
        try await store.appendAudit(actor: "app", action: "before")
        await store.setTrustKey(nil)
        try await store.appendAudit(actor: "app", action: "during")
        #expect(await store.pendingAuditCount == 1)
        #expect(try await store.recentAudit().count == 1)                      // not written unsigned
        await store.setTrustKey(key)
        #expect(await store.pendingAuditCount == 0)
        #expect(try await store.recentAudit().count == 2)
        #expect(try await store.firstBrokenAuditEntry(requireSigned: true) == nil)
    }

    @Test func aPluginRunsFromALockedCopyThatMatchesTheApproval() async throws {
        let src = try pluginFolder()
        let installed = try InstalledPlugin.load(from: src)
        let stage = FileManager.default.temporaryDirectory.appending(path: "hm-stage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stage) }
        let host = PluginHost(store: try Store(path: ":memory:"), gate: NetworkGate(secrets: MemorySecretStore([:])))
        await host.setStagingDirectory(stage)
        let copy = try await host.stagedCopy(of: installed)
        #expect(copy.path.hasPrefix(stage.path))
        #expect(try InstalledPlugin.load(from: copy).fingerprint == installed.fingerprint)
        let attrs = try FileManager.default.attributesOfItem(atPath: copy.appending(path: "manifest.json").path)
        #expect((attrs[.posixPermissions] as? Int ?? 0o777) & 0o222 == 0)     // read-only
    }

    private func pluginFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hm-\(UUID().uuidString)/s.hmplugin")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: dir.appending(path: "plugin"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appending(path: "plugin").path)
        try Data(#"{"id":"s","name":"S","version":"1","protocol":1,"executable":"plugin"}"#.utf8).write(to: dir.appending(path: "manifest.json"))
        return dir
    }

    @Test func aBundledStyleAddOnWithALinkedProgramStagesToo() async throws {
        let outside = FileManager.default.temporaryDirectory.appending(path: "hm-helpers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(filePath: "/bin/echo"), to: outside.appending(path: "prog"))
        let dir = FileManager.default.temporaryDirectory.appending(path: "hm-\(UUID().uuidString)/l.hmplugin")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: dir.appending(path: "prog"), withDestinationURL: outside.appending(path: "prog"))
        try Data(#"{"id":"l","name":"L","version":"1","protocol":1,"executable":"prog"}"#.utf8).write(to: dir.appending(path: "manifest.json"))
        let installed = try InstalledPlugin.load(from: dir)
        let stage = FileManager.default.temporaryDirectory.appending(path: "hm-stage-\(UUID().uuidString)")
        let host = PluginHost(store: try Store(path: ":memory:"), gate: NetworkGate(secrets: MemorySecretStore([:])))
        await host.setStagingDirectory(stage)
        let copy = try await host.stagedCopy(of: installed)
        let staged = try InstalledPlugin.load(from: copy)
        #expect(staged.fingerprint == installed.fingerprint)
    }
}

/// Database errors the owner can actually act on.
@Suite struct SQLiteErrorWordsTests {
    @Test func aFullDiskIsSaidInPlainWords() {
        #expect(SQLiteError(code: 13, message: "database or disk is full").plain.contains("disk is full"))
        #expect(SQLiteError(code: 10, message: "disk I/O error").plain.contains("Free some space"))
        #expect(SQLiteError(code: 522, message: "short read").plain.contains("Free some space"))   // extended code of disk I/O
        #expect(SQLiteError(code: 5, message: "locked").plain.contains("Retry"))
        #expect(SQLiteError(code: 1, message: "SQL logic error").plain == "SQLite error 1: SQL logic error")
    }
}

/// Keys are blanked from echoed responses even when the body isn't text, and in their JSON-escaped form.
@Suite struct ScrubBytesTests {
    @Test func nonTextEchoLosesTheKey() {
        let key = "abcd/efgh1234"
        var body = Data([0xFF, 0xFE])
        body.append(Data("Authorization: Bearer \(key) and \(key)".utf8))
        let out = NetworkGate.scrub(body, [key])
        #expect(out.range(of: Data(key.utf8)) == nil)
        #expect(out.range(of: Data("[key hidden]".utf8)) != nil)
    }

    @Test func jsonEscapedKeyIsBlankedInText() {
        let key = "abcd/efgh1234"
        #expect(!NetworkGate.scrub(#"{"echo":"abcd\/efgh1234"}"#, [key]).contains("efgh1234"))
    }
}
