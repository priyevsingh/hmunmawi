import CryptoKit
import Foundation
import Testing
@testable import HmunmawiCore

private func decodeBase64URL(_ text: String) -> Data? {
    var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while s.count % 4 != 0 { s += "=" }
    return Data(base64Encoded: s)
}

private func manifest(_ json: String) throws -> PluginManifest {
    try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
}

struct FakeMac: MacAbilities {
    func perform(_ ability: String, params: JSONValue) async throws -> JSONValue { .object(["did": .string(ability)]) }
}

@Suite struct KeychainSecretPresenceTests {
    @Test func requiredSecretCountsAsPresentWhenItemExistsButUnreadable() {
        let store = KeychainSecretStore()
        let plugin = "conn", name = "token-\(UUID().uuidString)"
        defer { store.deleteSecret(plugin: plugin, name: name) }
        #expect(store.secretItemExists(plugin: plugin, name: name) == false)
        try? store.setSecret("s3cret", plugin: plugin, name: name)
        #expect(store.secretItemExists(plugin: plugin, name: name) == true)
    }
}

@Suite struct AppStoreConnectTokenTests {
    @Test(arguments: [false, true])
    func tokenIsSignedES256(pastedOnOneLine: Bool) throws {
        let key = P256.Signing.PrivateKey()
        let pem = pastedOnOneLine ? key.pemRepresentation.replacingOccurrences(of: "\n", with: " ") : key.pemRepresentation
        let token = try AppStoreConnectToken.make(keyID: "KEY123", issuerID: "issuer-1", privateKeyPEM: pem)
        let parts = token.split(separator: ".").map(String.init)
        #expect(parts.count == 3)

        let header = try JSONValue.parse(String(decoding: try #require(decodeBase64URL(parts[0])), as: UTF8.self))
        #expect(header[path: "alg"] == .string("ES256"))
        #expect(header[path: "kid"] == .string("KEY123"))
        let payload = try JSONValue.parse(String(decoding: try #require(decodeBase64URL(parts[1])), as: UTF8.self))
        #expect(payload[path: "aud"] == .string("appstoreconnect-v1"))

        let signature = try P256.Signing.ECDSASignature(rawRepresentation: try #require(decodeBase64URL(parts[2])))
        #expect(key.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
    }

    @Test func gateFillsTokenOnlyWhenKeysAreDeclared() throws {
        let pem = P256.Signing.PrivateKey().pemRepresentation
        let gate = NetworkGate(secrets: MemorySecretStore(["asc/keyID": "K", "asc/issuerID": "I", "asc/privateKey": pem]),
                               transport: FakeTransport())
        let spec = HTTPRequestSpec(url: "https://api.appstoreconnect.apple.com/v1/apps",
                                   headers: ["Authorization": "Bearer {{asc-jwt}}"])
        let declared = try manifest(#"{"id":"asc","name":"ASC","version":"1","protocol":1,"executable":"x","permissions":{"hosts":["api.appstoreconnect.apple.com"],"secrets":["keyID","issuerID","privateKey"]}}"#)
        let header = try gate.buildRequest(spec, for: declared).value(forHTTPHeaderField: "Authorization")
        #expect(header?.hasPrefix("Bearer ey") == true)

        let undeclared = try manifest(#"{"id":"asc","name":"ASC","version":"1","protocol":1,"executable":"x","permissions":{"hosts":["api.appstoreconnect.apple.com"]}}"#)
        #expect(throws: WireError.self) { try gate.buildRequest(spec, for: undeclared) }
    }
}

@Suite struct MacAbilityTests {
    private func ask(_ manifestJSON: String, to: String = "+15550100", settingTo: String = "+15550100") async throws -> WireMessage {
        let store = try Store(path: ":memory:")
        let request = WireMessage(id: "1", method: "mac", params: .object(["ability": .string("messages.send"),
                                                                           "params": .object(["to": .string(to)])]))
        return await PluginHost.answer(request, manifest: try manifest(manifestJSON),
                                       gate: NetworkGate(secrets: MemorySecretStore()), mac: FakeMac(), store: store,
                                       settings: .object(["to": .string(settingTo)]))
    }

    @Test func undeclaredAbilityIsBlocked() async throws {
        let reply = try await ask(#"{"id":"x","name":"X","version":"1","protocol":1,"executable":"x"}"#)
        #expect(reply.error?.code == "blocked_ability")
    }

    @Test func declaredAbilityRuns() async throws {
        let reply = try await ask(#"{"id":"x","name":"X","version":"1","protocol":1,"executable":"x","permissions":{"mac":["messages.send"]}}"#)
        #expect(reply.result?[path: "did"] == .string("messages.send"))
    }

    /// An add-on can message only the recipient set in its own settings, never one it picks.
    @Test func otherRecipientIsRefused() async throws {
        let reply = try await ask(#"{"id":"x","name":"X","version":"1","protocol":1,"executable":"x","permissions":{"mac":["messages.send"]}}"#,
                                  to: "+15550199")
        #expect(reply.error?.code == "not_allowed")
    }
}

@Suite struct ConnectionDataTests {
    @Test func reviewAlertText() {
        let event = StoredEvent(id: 1, source: "asc", kind: "review.new", app: "Pocket Garden",
                                payload: .object(["rating": .number(1), "title": .string("Crashes")]), occurredAt: 0)
        #expect(EventText.describe(event) == "1★ review for Pocket Garden: “Crashes”")
    }

    @Test func waitingJobSaysWhatAndWhy() async throws {
        let store = try Store(path: ":memory:")
        let event = Event(source: "demo", kind: "revenue.refund", app: "Night Owl Timer", occurredAt: Store.systemNow(), dedupeKey: "r1")
        let rule = Rule(id: "refunds", name: "Tell me about refunds", when: "revenue.refund",
                        actions: [RuleAction(action: "notify", resource: "imessage")], approval: .ask, dryRun: false)
        let id = try #require(try await store.ingest(event, rules: [rule]).jobIDs.first)
        let job = try #require(try await store.job(id))
        let stored = try await store.event(try #require(job.eventID))
        #expect(JobText.title(job) == "Send an alert by iMessage")
        #expect(JobText.detail(job, event: stored, ruleName: rule.name) == "Refund for Night Owl Timer · rule: Tell me about refunds")
    }

    @Test func hubSignalsLandInTheRightSlots() {
        let now: Millis = 100 * TodayBuilder.day
        var events: [StoredEvent] = (0..<8).map { i in
            StoredEvent(id: Int64(i), source: "scriptfeed", kind: "revenue.daily", app: "My App",
                        payload: .object(["units": .number(i == 7 ? 20 : 10), "day": .string("2026-10-2\(i)")]),
                        occurredAt: now - Millis(8 - i) * TodayBuilder.day + 1000)
        }
        events.append(StoredEvent(id: 20, source: "scriptfeed", kind: "crash.daily", app: "Other App",
                                  payload: .object(["crashed": .number(3), "crash_free_rate": .number(0.987)]),
                                  occurredAt: now - 3_600_000))
        events.append(StoredEvent(id: 21, source: "scriptfeed", kind: "mail.reply", app: "My App",
                                  payload: .object(["subject": .string("Re: review request"), "unread": .bool(true)]),
                                  occurredAt: now - 60_000))
        let card = TodayBuilder.build(events: events, waitingApprovals: 0, failedJobs: 0, now: now)
        #expect(card.win.title == "My App downloads up 100%")
        #expect(card.worry.title == "Other App: 3 crashes in 24 hours")
        #expect(card.worry.evidence == "Sentry · 98.7% crash-free")
        #expect(card.next.title == "Answer 1 email")

        let summary = SummaryBuilder.apps(events: events, now: now).first { $0.name == "My App" }
        #expect(summary?.latest == 20)
        #expect(summary?.caption.hasPrefix("downloads on") == true)
    }

    @Test func twoSendersForOneDayCountOnceInItsOwnSlot() {
        // 3 Nov 20:00 UTC. The script feed stamps 1 Nov at 18:29:59 UTC (end of the day in India), App Store Connect at
        // 23:59:59 UTC; 2 Nov comes from the script feed only. Each day must count once, in its own slot.
        let now = Millis(ISO8601DateFormatter().date(from: "2026-11-03T20:00:00Z")!.timeIntervalSince1970 * 1000)
        func at(_ s: String) -> Millis { Millis(ISO8601DateFormatter().date(from: s)!.timeIntervalSince1970 * 1000) }
        let events = [
            StoredEvent(id: 1, source: "scriptfeed", kind: "revenue.daily", app: "A", payload: .object(["units": .number(5), "day": .string("2026-11-01")]), occurredAt: at("2026-11-01T18:29:59Z")),
            StoredEvent(id: 2, source: "appstoreconnect", kind: "revenue.daily", app: "A", payload: .object(["units": .number(5), "day": .string("2026-11-01")]), occurredAt: at("2026-11-01T23:59:59Z")),
            StoredEvent(id: 3, source: "scriptfeed", kind: "revenue.daily", app: "A", payload: .object(["units": .number(7), "day": .string("2026-11-02")]), occurredAt: at("2026-11-02T18:29:59Z")),
        ]
        let s = SummaryBuilder.apps(events: events, now: now).first!
        #expect(s.daily == [0, 0, 0, 0, 5, 7, 0])
        #expect(s.latest == 7)
    }

    @Test func failedJobSaysWhichAndWhy() async throws {
        let store = try Store(path: ":memory:")
        let id = try await store.enqueue(kind: "notify", resource: "imessage", maxAttempts: 1)
        _ = try await store.claimNext(owner: "engine")
        try await store.fail(id, error: "timeout: act took longer than 60.0 seconds")
        let card = try await store.today()
        #expect(card.worry.title == "1 job failed")
        #expect(card.worry.evidence == "Send an alert by iMessage · timed out")
    }

    @Test func failedMacJobIsAWorry() {
        let event = StoredEvent(id: 1, source: "macjobs", kind: "job.failed", app: "poll-sales",
                                payload: .object(["status": .number(1)]), occurredAt: 999_000_000)
        let card = TodayBuilder.build(events: [event], waitingApprovals: 0, failedJobs: 0, now: 1_000_000_000)
        #expect(card.worry.title == "Mac job “poll-sales” failed")
    }

    @Test func feedScriptMustMatchSavedPath() async throws {
        let script = FileManager.default.temporaryDirectory.appending(path: "hm-feed-\(UUID().uuidString).sh")
        try "#!/bin/sh\necho '{\"events\":[]}'\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let settings: JSONValue = .object(["script": .string(script.path)])

        let ok = try await LocalCommands.runFeedScript(params: .object(["path": .string(script.path)]), settings: settings)
        #expect(ok[path: "stdout"]?.string?.contains("events") == true)
        await #expect(throws: WireError.self) {
            _ = try await LocalCommands.runFeedScript(params: .object(["path": .string("/bin/ls")]), settings: settings)
        }
    }

    @Test func launchdListingWorks() async throws {
        let result = try await LocalCommands.launchdJobs(prefixes: ["com.apple."])
        #expect((result[path: "jobs"]?.array?.count ?? 0) > 0)
    }

    @Test func dailyUsersDropIsAWorry() {
        let now: Millis = 100 * TodayBuilder.day
        let counts: [Double] = [200, 210, 190, 205, 195, 200, 100]
        let events = counts.enumerated().map { i, users in
            StoredEvent(id: Int64(i), source: "posthog", kind: "analytics.daily_users", app: "Pocket Garden",
                        payload: .object(["users": .number(users)]),
                        occurredAt: now - Millis(counts.count - i) * TodayBuilder.day + 1000)
        }
        let card = TodayBuilder.build(events: events, waitingApprovals: 0, failedJobs: 0, now: now)
        #expect(card.worry.title == "Pocket Garden daily users down 50%")
    }

    @Test func configKeepsDefaultsAndRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "hm-config-\(UUID().uuidString).json")
        var config = try AppConfig.load(from: url)
        #expect(config.rules == AppConfig.defaultRules)
        config.plugins["ntfy"] = ["topic": "abc"]
        try config.save(to: url)
        #expect(try AppConfig.load(from: url) == config)
    }
}

@Suite struct SecretScrubTests {
    /// An API that quotes the Authorization header back can't hand the add-on the key.
    @Test func echoedKeyIsHidden() throws {
        var req = URLRequest(url: URL(string: "https://api.example.com/x")!)
        req.setValue("Bearer sk-live-1234567890abcdef", forHTTPHeaderField: "Authorization")
        let spec = HTTPRequestSpec(url: "https://api.example.com/x", headers: ["Authorization": "Bearer {{secret:key}}"])
        let filled = NetworkGate.filledValues(req, spec: spec)
        let out = NetworkGate.scrub(#"{"error":"bad header Bearer sk-live-1234567890abcdef","key":"sk-live-1234567890abcdef"}"#, filled)
        #expect(!out.contains("sk-live-1234567890abcdef"))
        #expect(out.contains("[key hidden]"))
    }
}

@Suite struct SecretHostTests {
    @Test func boundKeyGoesOnlyToItsHost() throws {
        let m = try manifest(#"{"id":"x","name":"X","version":"1","protocol":1,"executable":"x","permissions":{"hosts":["api.good.example","fx.example"],"secrets":["key"],"secretHosts":{"key":["api.good.example"]}}}"#)
        let gate = NetworkGate(secrets: MemorySecretStore(["x/key": "abcdefgh12345678"]))
        #expect(throws: Never.self) { try gate.buildRequest(HTTPRequestSpec(url: "https://api.good.example/v1", headers: ["Authorization": "Bearer {{secret:key}}"]), for: m) }
        #expect(throws: WireError.self) { try gate.buildRequest(HTTPRequestSpec(url: "https://fx.example/v1", headers: ["Authorization": "Bearer {{secret:key}}"]), for: m) }
        #expect(throws: Never.self) { try gate.buildRequest(HTTPRequestSpec(url: "https://fx.example/latest"), for: m) }   // no key: fine
    }
}
