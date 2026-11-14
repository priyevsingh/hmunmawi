import Foundation
import Synchronization
import Testing
@testable import HmunmawiCore

final class FakeTransport: HTTPTransport {
    let requests = Mutex<[URLRequest]>([])

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.withLock { $0.append(request) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data("ok".utf8), response)
    }
}

private let testPluginBinary = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: ".build/debug/hm-test-plugin")

private func makePluginFolder(hosts: [String] = ["api.example.com"], secrets: [String] = ["token"],
                              executable: String = "plugin", ack: Bool = false,
                              emits: [String] = ["test.ping"]) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "hm-\(UUID().uuidString)/test.hmplugin")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let manifest: JSONValue = .object([
        "id": .string("test"), "name": .string("Test"), "version": .string("1.0.0"), "protocol": .number(1),
        "executable": .string(executable),
        "emits": .array(emits.map(JSONValue.string)),
        "actions": .array((["echo", "fetch", "crash", "hang", "fail", "acks"] + (ack ? ["ack"] : [])).map(JSONValue.string)),
        "poll": .object(["everySeconds": .number(60)]),
        "permissions": .object(["hosts": .array(hosts.map(JSONValue.string)),
                                "secrets": .array(secrets.map(JSONValue.string))]),
    ])
    try Data(try manifest.canonicalText().utf8).write(to: dir.appending(path: "manifest.json"))
    try FileManager.default.copyItem(at: testPluginBinary, to: dir.appending(path: "plugin"))
    return dir
}

private struct Rig {
    let store: Store
    let host: PluginHost
    let transport: FakeTransport

    init(approve: Bool = true, folder: URL? = nil) async throws {
        store = try Store(path: ":memory:")
        transport = FakeTransport()
        let gate = NetworkGate(secrets: MemorySecretStore(["test/token": "s3cret"]), transport: transport)
        host = PluginHost(store: store, gate: gate)
        await host.register(try InstalledPlugin.load(from: try folder ?? makePluginFolder()))
        if approve {
            await store.setTrustKey(SymmetricKey(size: .bits256))
            await store.setRequireSignedApprovals(true)
            try await host.approve("test", by: "tester")
        }
    }
}

@Suite struct ManifestTests {
    @Test func rejectsExecutableOutsideFolder() throws {
        let json = #"{"id":"x","name":"X","version":"1","protocol":1,"executable":"../evil"}"#
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        #expect(throws: WireError.self) { try manifest.validate() }
    }

    @Test func rejectsHostWithScheme() throws {
        let json = #"{"id":"x","name":"X","version":"1","protocol":1,"executable":"x","permissions":{"hosts":["https://a.com"]}}"#
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        #expect(throws: WireError.self) { try manifest.validate() }
    }
}

@Suite struct GateTests {
    private func manifest() throws -> PluginManifest {
        let json = #"{"id":"t","name":"T","version":"1","protocol":1,"executable":"x","permissions":{"hosts":["api.example.com"],"secrets":["token"]}}"#
        return try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
    }

    private let gate = NetworkGate(secrets: MemorySecretStore(["t/token": "s3cret"]), transport: FakeTransport())

    @Test func fillsDeclaredSecret() throws {
        let request = try gate.buildRequest(HTTPRequestSpec(url: "https://api.example.com/x",
                                                            headers: ["Authorization": "Bearer {{secret:token}}"]),
                                            for: try manifest())
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer s3cret")
    }

    @Test(arguments: ["https://evil.example.org/x", "http://api.example.com/x", "https://u:p@api.example.com/",
                      "https://api.example.com:8443/"])
    func blocksUnapprovedAddresses(url: String) throws {
        #expect(throws: WireError.self) { try gate.buildRequest(HTTPRequestSpec(url: url), for: try manifest()) }
    }

    @Test func blocksUndeclaredSecret() throws {
        let spec = HTTPRequestSpec(url: "https://api.example.com/x", headers: ["X": "{{secret:other}}"])
        #expect(throws: WireError.self) { try gate.buildRequest(spec, for: try manifest()) }
    }
}

@Suite(.serialized) struct PluginProcessTests {
    @Test func unapprovedPluginIsRefused() async throws {
        let rig = try await Rig(approve: false)
        await #expect(throws: WireError.self) { try await rig.host.process(for: "test") }
    }

    @Test func changedPluginNeedsApprovalAgain() async throws {
        let folder = try makePluginFolder()
        let rig = try await Rig(folder: folder)
        #expect(try await rig.host.isApproved("test"))
        let manifestURL = folder.appending(path: "manifest.json")
        let changed = try String(contentsOf: manifestURL, encoding: .utf8)
            .replacingOccurrences(of: "api.example.com", with: "api.example.com\",\"other.example.com")
        try changed.write(to: manifestURL, atomically: true, encoding: .utf8)
        await rig.host.register(try InstalledPlugin.load(from: folder))
        #expect(try await !rig.host.isApproved("test"))
    }

    @Test func addOnSwappedOnDiskAfterApprovalIsNotStarted() async throws {
        let folder = try makePluginFolder()
        let rig = try await Rig(folder: folder)
        // Replaced after approval, without the app re-reading it (no register): must not start.
        let manifestURL = folder.appending(path: "manifest.json")
        try (try String(contentsOf: manifestURL, encoding: .utf8) + " ").write(to: manifestURL, atomically: true, encoding: .utf8)
        await #expect(throws: WireError.self) { try await rig.host.process(for: "test") }
    }

    @Test func ownAddOnCannotTakeABuiltInID() async throws {
        let builtIn = try makePluginFolder().deletingLastPathComponent()
        let mine = try makePluginFolder(hosts: ["evil.example.com"]).deletingLastPathComponent()
        let host = PluginHost(store: try Store(path: ":memory:"), gate: NetworkGate(secrets: MemorySecretStore([:]), transport: FakeTransport()))
        let problems = await host.discover(in: [builtIn, mine])
        #expect(problems.count == 1)
        #expect(await host.plugins.first?.manifest.permissions.hosts == ["api.example.com"])
    }

    @Test func actRoundTrip() async throws {
        let rig = try await Rig()
        let process = try await rig.host.process(for: "test")
        let result = try await process.call("act", params: .object(["action": .string("echo"),
                                                                    "params": .object(["hello": .string("world")])]))
        #expect(result == .object(["hello": .string("world")]))
        await rig.host.stopAll()
    }

    @Test func webCallsGoThroughTheGateWithSecrets() async throws {
        let rig = try await Rig()
        let process = try await rig.host.process(for: "test")
        let result = try await process.call("act", params: .object([
            "action": .string("fetch"), "params": .object(["url": .string("https://api.example.com/sales")])]))
        #expect(result[path: "status"] == .number(200))
        let sent = rig.transport.requests.withLock { $0 }
        #expect(sent.first?.value(forHTTPHeaderField: "Authorization") == "Bearer s3cret")

        await #expect(throws: WireError.self) {
            _ = try await process.call("act", params: .object([
                "action": .string("fetch"), "params": .object(["url": .string("https://evil.example.org/")])]))
        }
        #expect(try await rig.store.recentAudit().contains { $0.action == "plugin.http_blocked" })
        await rig.host.stopAll()
    }

    @Test func timeoutAndCrashThenRestart() async throws {
        let rig = try await Rig()
        let process = try await rig.host.process(for: "test")
        await #expect(throws: WireError.self) {
            _ = try await process.call("act", params: .object(["action": .string("hang")]), timeout: .seconds(1))
        }
        // A timed-out call stops the add-on so leftover work cannot block the next check.
        #expect(await process.isRunning == false)
        let restarted = try await rig.host.process(for: "test")
        do {
            _ = try await restarted.call("act", params: .object(["action": .string("crash")]))
            Issue.record("crash should throw")
        } catch let error as WireError {
            #expect(error.code == "crashed")
        }
        let again = try await rig.host.process(for: "test")
        let result = try await again.call("act", params: .object(["action": .string("echo"), "params": .number(7)]))
        #expect(result == .number(7))
        await rig.host.stopAll()
    }

    @Test func timedOutPollIsCancelledRetriedAndRowRecovers() async throws {
        let rig = try await Rig()
        await rig.host.setSettings(.object(["hangPoll": .bool(true)]), for: "test")
        await rig.host.restart("test")
        let engine = Engine(store: rig.store, host: rig.host, rules: [],
                            pollTimeout: .seconds(1),
                            timeoutRetryDelays: [.milliseconds(300)])
        await engine.poll("test")
        let first = try await rig.store.recentAudit()
        #expect(first.contains { $0.action == "plugin.poll_retry" && $0.actor == "test" })
        #expect(!first.contains { $0.action == "plugin.poll_failed" && $0.actor == "test" })
        // Settings should say the row is being checked again, not left failed.
        let display = ConnectionAudit.display(audit: first, actor: "test", approved: true, missing: false)
        #expect(display.label == "Checking again")
        #expect(display.tone == .caution)
        #expect(display.detail == Engine.pollTimeoutText)
        // Lift the hang before the scheduled retry starts, so the row recovers by itself.
        await rig.host.setSettings(.object(["hangPoll": .bool(false)]), for: "test")
        for _ in 0..<40 {
            if try await rig.store.countEvents(kind: "test.ping") >= 1 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(try await rig.store.countEvents(kind: "test.ping") >= 1)
        #expect(await engine.failing()["test"] == nil)
        let after = try await rig.store.recentAudit()
        #expect(!after.contains { $0.action == "plugin.poll_failed" && $0.actor == "test" })
        await rig.host.stopAll()
    }

    @Test func pollTimeoutExhaustsRetriesThenFailsOnce() async throws {
        let rig = try await Rig()
        await rig.host.setSettings(.object(["hangPoll": .bool(true)]), for: "test")
        await rig.host.restart("test")
        let engine = Engine(store: rig.store, host: rig.host, rules: [],
                            pollTimeout: .seconds(1),
                            timeoutRetryDelays: []) // no automatic retries: first timeout is the last
        await engine.poll("test")
        let audit = try await rig.store.recentAudit()
        #expect(audit.contains { $0.action == "plugin.poll_failed" && $0.actor == "test" })
        #expect(!audit.contains { $0.action == "plugin.poll_retry" && $0.actor == "test" })
        #expect(await engine.failing()["test"] == 1)
        let display = ConnectionAudit.display(audit: audit, actor: "test", approved: true, missing: false)
        #expect(display.label == "Last check failed")
        #expect(display.tone == .bad)
        #expect(display.detail == Engine.pollTimeoutText)
        await rig.host.stopAll()
    }

    @Test func healthCheckStopsAPollPastItsDeadline() async throws {
        let rig = try await Rig()
        let process = try await rig.host.process(for: "test")
        let hang = Task {
            _ = try? await process.call("act", params: .object(["action": .string("hang")]), timeout: .seconds(1))
        }
        // Before the timeout fires, the add-on is busy but not past its deadline.
        try await Task.sleep(for: .milliseconds(100))
        #expect(await process.isBusy)
        #expect(await process.hasCallPastDeadline == false)
        await rig.host.healthCheck()
        #expect(await process.isRunning) // still within its wait
        // After the deadline the process is stopped even if it can still answer ping.
        try await Task.sleep(for: .seconds(1.2))
        // timedOut already stops the process; health check is the backstop if a deadline is missed.
        if await process.isRunning {
            await rig.host.healthCheck()
        }
        #expect(await process.isRunning == false)
        _ = await hang.value
        await rig.host.stopAll()
    }

    @Test func checkNowStopsAnInFlightPollInsteadOfStacking() async throws {
        let rig = try await Rig()
        await rig.host.setSettings(.object(["hangPoll": .bool(true)]), for: "test")
        await rig.host.restart("test")
        let engine = Engine(store: rig.store, host: rig.host, rules: [],
                            pollTimeout: .seconds(5),
                            timeoutRetryDelays: [])
        let first = Task { await engine.poll("test") }
        try await Task.sleep(for: .milliseconds(150))
        #expect(await engine.isPolling("test"))
        // Lift the hang so the pre-empted fresh check can succeed.
        await rig.host.setSettings(.object(["hangPoll": .bool(false)]), for: "test")
        await engine.poll("test", preempt: true)
        #expect(try await rig.store.countEvents(kind: "test.ping") >= 1)
        _ = await first.value
        let audit = try await rig.store.recentAudit()
        #expect(!audit.contains { $0.action == "plugin.poll_failed" && $0.actor == "test" })
        await rig.host.stopAll()
    }

    @Test func refetchNeverAlertsOnOldEventsAgain() async throws {
        let rig = try await Rig()
        let clock = TestClock()
        let rule = Rule(id: "r", when: "review.*", actions: [RuleAction(action: "notify", resource: "imessage")],
                        priority: 1, cooldownSeconds: 0, approval: .auto, dryRun: false)
        let engine = Engine(store: rig.store, host: rig.host, rules: [rule], now: { clock.now })
        let old = Event(source: "t", kind: "review.new", occurredAt: clock.now - 1000, dedupeKey: "o")
        let new = Event(source: "t", kind: "review.new", occurredAt: clock.now + 1000, dedupeKey: "n")
        #expect(await engine.rulesFor(old).count == 1)
        await engine.quietBefore(clock.now, addOns: ["test"])   // a backup made "now"
        #expect(await engine.rulesFor(old).isEmpty)        // before the backup: stored, no alert
        #expect(await engine.rulesFor(new).count == 1)     // after the backup: alerts as usual
        clock.advance(seconds: 3 * 3600)
        #expect(await engine.rulesFor(old).isEmpty)        // still quiet: "test" hasn't finished a check yet
        await engine.poll("test")                          // one good check from every add-on lifts it
        #expect(!(await engine.isQuiet))
        #expect(await engine.rulesFor(old).count == 1)
        await engine.quietBefore(clock.now, addOns: ["never-answers"])
        clock.advance(seconds: 6 * 3600 + 1)
        #expect(await engine.rulesFor(old).count == 1)     // 6-hour cap
        await rig.host.stopAll()
    }

    @Test func savedCheckIsConfirmedOnlyToAddOnsThatAsk() async throws {
        // Asks for it: told once per saved check.
        let rig = try await Rig(folder: try makePluginFolder(ack: true))
        let engine = Engine(store: rig.store, host: rig.host, rules: [])
        await engine.poll("test")
        let p = try await rig.host.process(for: "test")
        #expect(try await p.call("act", params: .object(["action": .string("acks")])) == .number(1))
        #expect(try await rig.store.countEvents(kind: "test.ping") == 1)
        await rig.host.stopAll()
        // Doesn't ask: never called.
        let rig2 = try await Rig()
        await Engine(store: rig2.store, host: rig2.host, rules: []).poll("test")
        let p2 = try await rig2.host.process(for: "test")
        #expect(try await p2.call("act", params: .object(["action": .string("acks")])) == .number(0))
        await rig2.host.stopAll()
    }

    @Test func engineRunsJobsAndPolls() async throws {
        let rig = try await Rig()
        let engine = Engine(store: rig.store, host: rig.host, rules: [])
        let ok = try await rig.store.enqueue(kind: "echo", resource: "test")
        let bad = try await rig.store.enqueue(kind: "fail", resource: "test")
        #expect(await engine.runNextJob())
        #expect(await engine.runNextJob())
        #expect(try await rig.store.job(ok)?.state == .done)
        let failed = try #require(try await rig.store.job(bad))
        #expect(failed.state == .queued)
        #expect(failed.lastError?.contains("asked_to_fail") == true)

        await engine.pollDuePlugins()
        let events = try await rig.store.events(since: 0)
        #expect(events.count == 1)
        #expect(events.first?.source == "test")
        await rig.host.stopAll()
    }

    @Test func anyChangedFileInTheFolderNeedsANewApproval() throws {
        let dir = try makePluginFolder()
        let before = try InstalledPlugin.load(from: dir).fingerprint
        try Data("x = 1".utf8).write(to: dir.appending(path: "helper.py"))
        let added = try InstalledPlugin.load(from: dir).fingerprint
        try Data("x = 2".utf8).write(to: dir.appending(path: "helper.py"))
        let changed = try InstalledPlugin.load(from: dir).fingerprint
        #expect(before != added)
        #expect(added != changed)
        #expect(try InstalledPlugin.load(from: dir).fingerprint == changed)
    }

    @Test func eventsOutsideTheDeclaredTypesAreDropped() async throws {
        let rig = try await Rig(folder: try makePluginFolder(emits: ["other.kind"]))
        await Engine(store: rig.store, host: rig.host, rules: []).poll("test")
        #expect(try await rig.store.events(since: 0).isEmpty)
        let refused = try await rig.store.recentAudit().first { $0.action == "plugin.events_refused" }
        #expect(refused != nil)
        await rig.host.stopAll()
    }
}

import CryptoKit
@Suite struct TrustSigningTests {
    @Test func onlyApprovalsSignedByTheAppCount() async throws {
        let store = try Store(path: ":memory:")
        let key = SymmetricKey(size: .bits256)
        // Before signing is on: an existing approval, trusted once when signing starts.
        try await store.approvePlugin(id: "old", fingerprint: "sha-old", by: "you")
        await store.setTrustKey(key)
        #expect(try await !store.isPluginApproved(id: "old", fingerprint: "sha-old"))   // unsigned: not yet
        #expect(try await store.signUnsignedApprovals() == 1)
        #expect(try await store.isPluginApproved(id: "old", fingerprint: "sha-old"))
        // Approved in the app: signed and valid.
        try await store.approvePlugin(id: "a", fingerprint: "sha-a", by: "you")
        #expect(try await store.isPluginApproved(id: "a", fingerprint: "sha-a"))
        // Written into the database by something else (an agent with a shell): ignored, and logged once.
        try await store.rawExecute("INSERT INTO plugin_approvals (plugin_id, manifest_sha, approved_at, approved_by) VALUES ('evil', 'sha-e', 1, 'agent')")
        #expect(try await !store.isPluginApproved(id: "evil", fingerprint: "sha-e"))
        // A signed row changed afterwards (another fingerprint swapped in): ignored.
        try await store.rawExecute("UPDATE plugin_approvals SET manifest_sha = 'sha-x' WHERE plugin_id = 'a'")
        #expect(try await !store.isPluginApproved(id: "a", fingerprint: "sha-x"))
        // A different key (another copy of the app's data): nothing counts.
        await store.setTrustKey(SymmetricKey(size: .bits256))
        #expect(try await !store.isPluginApproved(id: "old", fingerprint: "sha-old"))
        // Same plugin fingerprints, new trust key (for example a new Developer certificate on the same Mac).
        let key2 = SymmetricKey(size: .bits256)
        await store.setTrustKey(key2)
        #expect(try await store.resignAllApprovals() == 2)
        #expect(try await store.isPluginApproved(id: "old", fingerprint: "sha-old"))
        #expect(try await store.isPluginApproved(id: "a", fingerprint: "sha-x", permissionsHash: "sha-a"))
        // No key (Keychain unavailable): approvals as stored, as before.
        await store.setTrustKey(nil)
        #expect(try await store.isPluginApproved(id: "evil", fingerprint: "sha-e"))
        let logged = try await store.recentAudit(limit: 50).filter { $0.action == "trust.approval_not_signed" }.count
        #expect(logged >= 2)
    }

    @Test func approvalSurvivesFingerprintChangeWhenPermissionsUnchanged() async throws {
        let store = try Store(path: ":memory:")
        let key = SymmetricKey(size: .bits256)
        await store.setTrustKey(key)
        let perms = "perm-stable"
        try await store.approvePlugin(id: "feed", fingerprint: "fp-old", permissionsHash: perms, by: "you")
        #expect(try await store.isPluginApproved(id: "feed", fingerprint: "fp-new", permissionsHash: perms))
    }

    @Test func restoreCarriesSignatures() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hm-sig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let live = dir.appending(path: "hmunmawi.sqlite").path, copy = dir.appending(path: "copy.sqlite").path
        let key = SymmetricKey(size: .bits256)
        do {
            let s = try Store(path: live)
            await s.setTrustKey(key)
            try await s.backUp(to: copy)
            try await s.approvePlugin(id: "asc", fingerprint: "sha-new", by: "you")   // after the backup
        }
        try JSONSerialization.data(withJSONObject: ["path": copy, "kind": "full"]).write(to: Resilience.pendingRestoreFile(dir))
        #expect(Resilience.applyPendingRestore(support: dir) != nil)
        let back = try Store(path: live)
        await back.setTrustKey(key)
        #expect(try await back.isPluginApproved(id: "asc", fingerprint: "sha-new"))     // kept, still signed
    }
}

@Suite struct RestartPollingTests {
    @Test func aRestartDoesNotAskEveryServiceAgainAtOnce() async throws {
        // Checked 5 seconds before the restart (the test add-on checks every 60): not due again yet.
        let rig = try await Rig()
        let recent = PollStamps.memory(); recent.write(["test": Store.systemNow() - 5_000])
        let engine = Engine(store: rig.store, host: rig.host, rules: [], stamps: recent)
        await engine.pollDuePlugins()
        #expect(try await rig.store.events(since: 0).isEmpty)
        await rig.host.stopAll()
        // Never checked: due at once, and the time is saved for the next restart.
        let rig2 = try await Rig()
        let empty = PollStamps.memory()
        await Engine(store: rig2.store, host: rig2.host, rules: [], stamps: empty).pollDuePlugins()
        #expect(try await rig2.store.events(since: 0).count == 1)
        #expect(empty.read()["test"] != nil)
        await rig2.host.stopAll()
        // A stamp from the future (the clock was changed) never blocks checks.
        let rig3 = try await Rig()
        let future = PollStamps.memory(); future.write(["test": Store.systemNow() + 86_400_000])
        await Engine(store: rig3.store, host: rig3.host, rules: [], stamps: future).pollDuePlugins()
        #expect(try await rig3.store.events(since: 0).count == 1)
        await rig3.host.stopAll()
    }
}
