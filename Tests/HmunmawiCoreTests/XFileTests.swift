import Foundation
import Testing
@testable import HmunmawiCore

@Suite struct XFileNumbersTests {
    private func write(_ json: String, _ name: String = "native.json") throws -> (dir: URL, file: String) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "xfile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appending(path: "x"), withIntermediateDirectories: true)
        let file = dir.appending(path: "x/\(name)")
        try Data(json.utf8).write(to: file)
        return (dir, file.path)
    }

    private let native = #"""
    {"generated":"2026-11-10T04:20:12Z","account":{"username":"example_dev","followers":129},"followers_delta_1d":0,
     "posts":[{"url":"https://x.com/a/status/1","created_at":"2026-11-10T02:27:26.000Z","text":"hi","type":"reply","impressions":2,"likes":1,"replies":0,"reposts":0,"quotes":0,"bookmarks":0},
              {"url":"https://x.com/a/status/2","created_at":"2026-11-01T02:27:26.000Z","text":"old","type":"post","impressions":50,"likes":3}],
     "totals_7d":{"posts":36,"impressions":2899,"likes":10,"replies":8,"reposts":1}}
    """#
    private let at = ISO8601DateFormatter().date(from: "2026-11-10T06:00:00Z")!

    @Test func freshFileGivesRealNumbers() throws {
        let (_, file) = try write(native)
        let r = XFileNumbers.load(file: file, digest: XFileNumbers.digestPath(nextTo: file), now: at)
        #expect(r[path: "status"] == .string("fresh"))
        #expect(r[path: "source"] == .string("x_file"))
        #expect(r[path: "followers"] == .number(129))
        #expect(r[path: "posts_24h"] == .number(1))
        #expect(r[path: "impressions_24h"] == .number(2))
        #expect(r[path: "engagements_24h"] == .number(1))
        #expect(r[path: "impressions_7d"] == .number(2899))
        #expect(r[path: "as_of"] == .string("2026-11-10T04:20:12Z"))
    }

    @Test func oldFileIsStaleWithReason() throws {
        let (_, file) = try write(native)
        let r = XFileNumbers.load(file: file, digest: nil, now: at.addingTimeInterval(12 * 3600))
        #expect(r[path: "status"] == .string("stale"))
        #expect(r[path: "reason"]?.string?.contains("last updated") == true)
        #expect(r[path: "followers"] == .number(129))   // still the file's numbers, marked old
    }

    @Test func missingFieldsAreNullNotZero() throws {
        let (_, file) = try write(#"{"generated":"2026-11-10T04:20:12Z","account":{}}"#)
        let r = XFileNumbers.load(file: file, digest: nil, now: at)
        #expect(r[path: "followers"] == .null)
        #expect(r[path: "followers_reason"]?.string != nil)
        #expect(r[path: "posts_24h"] == .null)
        #expect(r[path: "impressions_7d"] == .null)
    }

    @Test func missingFileFallsBackToDigest() throws {
        let (dir, file) = try write(native, "other.json")
        let missing = dir.appending(path: "x/native.json").path
        _ = file
        try FileManager.default.createDirectory(at: dir.appending(path: "out/digest"), withIntermediateDirectories: true)
        try Data(#"{"generated":"2026-11-10T08:30:02+05:30","sources":{"native_x_as_of":"2026-11-09T22:20:10Z"},"x":{"followers":129,"posts_7d":36,"impr_7d":2947}}"#.utf8)
            .write(to: dir.appending(path: "out/digest/morning_digest.json"))
        let r = XFileNumbers.load(file: missing, digest: XFileNumbers.digestPath(nextTo: missing), now: at)
        #expect(r[path: "source"] == .string("digest"))
        #expect(r[path: "status"] == .string("fresh"))
        #expect(r[path: "followers"] == .number(129))
        #expect(r[path: "impressions_24h"] == .null)
        #expect(r[path: "reason"]?.string?.contains("morning digest") == true)
    }

    @Test func nothingThereIsMissing() {
        let r = XFileNumbers.load(file: "/nonexistent/x/native.json", digest: "/nonexistent/out/digest/morning_digest.json", now: at)
        #expect(r[path: "status"] == .string("missing"))
        #expect(r[path: "followers"] == nil)
    }

    @Test func abilityReadsOnlyTheConfiguredFileAndAuditsFreshness() async throws {
        let (_, file) = try write(native)
        let store = try Store(path: ":memory:")
        let m = try JSONDecoder().decode(PluginManifest.self, from: Data(#"{"id":"x","name":"X","version":"1","protocol":1,"executable":"x","permissions":{"mac":["xfile.read"]}}"#.utf8))
        let request = WireMessage(id: "1", method: "mac", params: .object(["ability": .string("xfile.read"),
                                                                           "params": .object(["path": .string("/etc/passwd")])]))
        let reply = await PluginHost.answer(request, manifest: m, gate: NetworkGate(secrets: MemorySecretStore()), mac: nil,
                                            store: store, settings: .object(["file": .string(file)]))
        #expect(reply.result?[path: "path"] == .string(file))   // the add-on's own path is ignored
        #expect(reply.result?[path: "followers"] == .number(129))
        let audit = try await store.recentAudit(limit: 5)
        #expect(audit.first?.subject == "xfile.read")
        #expect(audit.first?.detail[path: "status"] != nil)
    }

    @Test func xManifestHasNoNetworkOrKey() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "AddOns/x/manifest.json")
        let m = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: url))
        #expect(m.permissions.hosts.isEmpty)
        #expect(m.permissions.secrets.isEmpty)
        #expect(m.permissions.mac == ["xfile.read"])
        let code = try String(contentsOf: url.deletingLastPathComponent().appending(path: "main.swift"), encoding: .utf8)
        #expect(!code.contains("api.x.com"))
        #expect(!code.contains("core.http"))
    }
}

@Suite struct NtfyRelayTests {
    @Test func newestSuccessAndFailure() {
        let state = Data(#"{"delivered":{"a":{"ntfy":"cloudflare","seen":1794000000000},"b":{"ntfy":1794230967250,"seen":1794230967000},"c":{"imessage":1,"seen":1794300000000}}}"#.utf8)
        let log = "2026-11-03 19:48:33+0530 ntfy sent from Mac ob:1\n2026-11-04 01:04:18+0530 ntfy FAILED ob:2 (retry next run)\n"
        let r = NtfyRelay.latest(state: state, log: log)
        #expect(r.successCount == 2)
        #expect(r.success == Date(timeIntervalSince1970: 1794230967.25))
        #expect(r.successVia == "this Mac")
        #expect(r.failure != nil)
    }

    @Test func nothingRecorded() {
        let r = NtfyRelay.latest(state: nil, log: nil)
        #expect(r.success == nil && r.failure == nil)
    }
}
