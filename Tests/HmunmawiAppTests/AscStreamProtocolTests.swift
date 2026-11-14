import Foundation
import Testing
@testable import HmunmawiApp

@Test func ackOnlyAfterApply() {
    #expect(AscStreamProtocol.ackSeqAfterApply(appliedSeq: 5, candidate: 5) == 5)
    #expect(AscStreamProtocol.ackSeqAfterApply(appliedSeq: 5, candidate: 6) == nil)
    #expect(AscStreamProtocol.ackSeqAfterApply(appliedSeq: 0, candidate: 1) == nil)
}

@Test func resumeUsesAppliedCursor() {
    #expect(AscStreamProtocol.resumeAfterSeq(appliedSeq: 10, storedAckSeq: 3) == 10)
    #expect(AscStreamProtocol.resumeAfterSeq(appliedSeq: 2, storedAckSeq: 7) == 7)
}

@Test func dedupeOnReplay() {
    let items: [[String: Any]] = [["seq": Int64(1)], ["seq": Int64(2)], ["seq": Int64(3)]]
    let kept = AscStreamProtocol.filterNewItems(items, appliedSeq: 2)
    #expect(kept.count == 1)
    #expect(kept.first?["seq"] as? Int64 == 3)
}

@Test func decodeEventFrame() throws {
    let json = #"{"type":"event","seq":4,"item":{"id":"x","type":"t"}}"#
    let parsed = try #require(AscStreamProtocol.decodeEventFrame(json))
    #expect(parsed.seq == 4)
    #expect(parsed.item["id"] as? String == "x")
}

@Test func decodeIgnoresNonEvent() {
    #expect(AscStreamProtocol.decodeEventFrame(#"{"type":"caught_up"}"#) == nil)
}

@Test func parseStreamCaughtUp() {
    let frame = AscStreamProtocol.parseStreamFrame(#"{"type":"caught_up","next_seq":3}"#)
    #expect(frame?.type == "caught_up")
    #expect(frame?.body["next_seq"] as? Int == 3)
}

@Test func streamHealthyUsesFrameOrPong() {
    let now = 1_000_000.0
    let ping = AscStreamProtocol.transportStaleSec * 1000
    #expect(AscStreamProtocol.streamHealthyForPolling(state: "open", lastFrameMs: now - 10_000, lastPongMs: 0, nowMs: now))
    #expect(AscStreamProtocol.streamHealthyForPolling(state: "open", lastFrameMs: 0, lastPongMs: now - 10_000, nowMs: now))
    #expect(!AscStreamProtocol.streamHealthyForPolling(state: "open", lastFrameMs: now - ping * 1.5, lastPongMs: 0, nowMs: now))
    #expect(!AscStreamProtocol.streamHealthyForPolling(state: "closed", lastFrameMs: now - 1_000, lastPongMs: now - 1_000, nowMs: now))
}

@Test func streamHealthLabelMarksStaleOpenSocket() {
    let now = 1_000_000.0
    let staleMs = AscStreamProtocol.transportStaleSec * 1000 * 1.5
    let label = AscStreamProtocol.streamHealthLabel(state: "open", lastFrameMs: now - staleMs, lastPongMs: 0, nowMs: now)
    #expect(label.healthy == false)
    #expect(label.text.contains("Stale"))
}

@Test func wantsEventStreamForSavedHookV2User() {
    let d = UserDefaults(suiteName: "AscStreamProtocolTests")!
    d.removePersistentDomain(forName: "AscStreamProtocolTests")
    d.set(false, forKey: AscStreamProtocol.streamEnabledKey)
    #expect(AscStreamProtocol.wantsEventStream(
        defaults: d, activateAscEventRelay: false, hookV2Live: true, hasHookWorker: true))
    #expect(!AscStreamProtocol.wantsEventStream(
        defaults: d, activateAscEventRelay: false, hookV2Live: false, hasHookWorker: true))
}

@Test func prepareProbeClearsStaleOpenAtLaunch() {
    let d = UserDefaults(suiteName: "AscStreamProbeReset")!
    d.removePersistentDomain(forName: "AscStreamProbeReset")
    d.set("open", forKey: AscStreamProtocol.Telemetry.stateKey)
    d.set(1, forKey: AscStreamProtocol.Telemetry.lastPongMsKey)
    d.set("NSPOSIXErrorDomain#57", forKey: AscStreamProtocol.Telemetry.lastErrorKey)
    AscStreamProtocol.prepareProbeForLaunch(defaults: d, streamWanted: true)
    #expect(d.string(forKey: AscStreamProtocol.Telemetry.stateKey) == "closed")
    #expect(d.string(forKey: AscStreamProtocol.Telemetry.lastErrorKey) == nil)
    #expect(d.double(forKey: AscStreamProtocol.Telemetry.lastPongMsKey) == 0)
}

@Test func seedStreamPreferenceDefaultsOnForV2() {
    let d = UserDefaults(suiteName: "AscStreamSeed")!
    d.removePersistentDomain(forName: "AscStreamSeed")
    AscStreamProtocol.seedStreamPreferenceIfNeeded(defaults: d, hookV2Live: true, hasHookWorker: true)
    #expect(d.bool(forKey: AscStreamProtocol.streamEnabledKey))
}

@Test func hookDeployAccountPrefersPinnedWhenTokenListsMany() throws {
    let pinned = "0123456789abcdef0123456789abcdef"
    let list: [[String: Any]] = [["id": "other-account"], ["id": pinned]]
    let picked = try WorkerDeployMetadata.pickHookDeployAccount(list: list, pinned: pinned)
    #expect(picked == pinned)
}

@Test @MainActor func deployMetadataValidationAcceptsHooksV2Shape() {
    let metadata = LivePurchases.hooksWorkerUploadMetadata(
        kv: "kv-id", relayKey: "rk", ascSecret: "sec", bundleIDs: "com.example.app", deployV2: true)
    let bindings = metadata["bindings"] as? [[String: Any]] ?? []
    let modules = ["worker.mjs", "workerCore.mjs", "ascRelayDO.mjs", "ascKvImport.mjs", "verify.mjs", "x509.mjs", "root.mjs"]
    #expect(WorkerDeployMetadata.validateHooksV2(bindings: bindings, metadata: metadata, moduleNames: modules).isEmpty)
}

@Test func deployMetadataValidationCatchesMissingBindings() {
    let issues = WorkerDeployMetadata.validateHooksV2(
        bindings: [["name": "OUTBOX"]],
        metadata: ["main_module": "worker.mjs", "migrations": []],
        moduleNames: ["worker.mjs"]
    )
    #expect(issues.contains { $0.contains("ASC_RELAY") })
}
