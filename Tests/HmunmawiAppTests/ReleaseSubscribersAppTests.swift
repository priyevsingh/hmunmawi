import CryptoKit
import Foundation
import Testing
@testable import HmunmawiApp
@testable import HmunmawiCore

@MainActor
@Suite(.serialized) struct ReleaseSubscribersAppTests {
    private func makeContext() async throws -> (dir: URL, subscribers: ReleaseSubscribers, store: Store, model: AppModel) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hm-rel-sub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let subURL = dir.appending(path: ReleaseSubscribersStore.fileName)
        let subscribers = ReleaseSubscribers(url: subURL)
        let store = try Store(path: ":memory:")
        let model = AppModel(supportDirectory: dir, runsEngine: false)
        await model.attachTestStore(store)
        return (dir, subscribers, store, model)
    }

    private func ingestRelease(
        store: Store,
        app: String,
        version: String,
        whatsNew: String = "Performance improvements and bug fixes.",
        occurredAt: Millis,
        tag: String
    ) async throws {
        _ = try await store.ingest(
            Event(
                source: "appstoreconnect",
                kind: "app.snapshot",
                app: app,
                payload: .object(["version": .string(version)]),
                occurredAt: occurredAt,
                dedupeKey: "app-\(app)-\(version)-\(tag)"
            ),
            rules: []
        )
        _ = try await store.ingest(
            Event(
                source: "appstoreconnect",
                kind: "release.snapshot",
                app: app,
                payload: .object([
                    "live": .bool(true),
                    "live_version": .string(version),
                    "whats_new": .string(whatsNew),
                ]),
                occurredAt: occurredAt,
                dedupeKey: "rel-\(app)-\(version)-\(tag)"
            ),
            rules: []
        )
    }

    @Test func releaseDetectionPatchGateAutoDraftDedupeAndAgentApprovalRefusal() async throws {
        let prevProject = ProjectStore.shared.selectedID
        let prevAllowed = UserDefaults.standard.stringArray(forKey: "HMAgentPolicy")
        let prevSmart = UserDefaults.standard.bool(forKey: "HMAgentSmartAutopilot")
        let prevTrustUntil = UserDefaults.standard.object(forKey: "HMAgentFullTrustUntil")
        let prevPerAgent = UserDefaults.standard.data(forKey: "HMAgentPolicyPerAgent")
        let prevSig = UserDefaults.standard.string(forKey: "HMAgentPolicySig")
        defer {
            ProjectStore.shared.selectedID = prevProject
            if let prevAllowed { UserDefaults.standard.set(prevAllowed, forKey: "HMAgentPolicy") } else { UserDefaults.standard.removeObject(forKey: "HMAgentPolicy") }
            UserDefaults.standard.set(prevSmart, forKey: "HMAgentSmartAutopilot")
            if let prevTrustUntil { UserDefaults.standard.set(prevTrustUntil, forKey: "HMAgentFullTrustUntil") } else { UserDefaults.standard.removeObject(forKey: "HMAgentFullTrustUntil") }
            if let prevPerAgent { UserDefaults.standard.set(prevPerAgent, forKey: "HMAgentPolicyPerAgent") } else { UserDefaults.standard.removeObject(forKey: "HMAgentPolicyPerAgent") }
            if let prevSig { UserDefaults.standard.set(prevSig, forKey: "HMAgentPolicySig") } else { UserDefaults.standard.removeObject(forKey: "HMAgentPolicySig") }
            AgentPolicy.shared.set(.decisions, false)
            AgentPolicy.shared.setFullTrust(for: 0)
        }
        ProjectStore.shared.selectedID = nil

        let ctx = try await makeContext()
        defer { try? FileManager.default.removeItem(at: ctx.dir) }

        ctx.subscribers.importCSV("Alex <alex@example.com>", defaultApps: ["Pulse Diary"])
        let t0 = Millis(Date.now.timeIntervalSince1970 * 1000) - 60_000

        // 1. First run baselines existing version with 0 drafts queued.
        try await ingestRelease(store: ctx.store, app: "Pulse Diary", version: "4.1.9", occurredAt: t0, tag: "t0")
        await ctx.model.refresh()

        let baseline = await ctx.subscribers.checkNewReleases(model: ctx.model)
        #expect(baseline.isEmpty)
        #expect(ctx.subscribers.book.notifiedVersions["Pulse Diary"] == "4.1.9")
        #expect(ctx.model.waiting.isEmpty)

        // 2. Patch transition 4.1.9 -> 4.1.10 does NOT draft when allowPatchUpdates == false.
        try await ingestRelease(store: ctx.store, app: "Pulse Diary", version: "4.1.10", occurredAt: t0 + 10_000, tag: "t1")
        await ctx.model.refresh()

        let patchBlocked = await ctx.subscribers.checkNewReleases(model: ctx.model)
        #expect(patchBlocked.isEmpty)
        #expect(ctx.subscribers.book.notifiedVersions["Pulse Diary"] == "4.1.10")
        #expect(ctx.model.waiting.isEmpty)

        // 3. Minor transition 4.1.10 -> 4.2.0 auto-drafts ONE release.notify waiting job, no duplicates on repeat.
        try await ingestRelease(store: ctx.store, app: "Pulse Diary", version: "4.2.0", occurredAt: t0 + 20_000, tag: "t2")
        await ctx.model.refresh()

        let minorDrafts = await ctx.subscribers.checkNewReleases(model: ctx.model)
        #expect(minorDrafts.count == 1)
        #expect(minorDrafts[0].app == "Pulse Diary")
        #expect(minorDrafts[0].version == "4.2.0")
        #expect(minorDrafts[0].recipients == 1)

        #expect(ctx.model.waiting.count == 1)
        let waiting = try #require(ctx.model.waiting.first)
        #expect(waiting.job.id == minorDrafts[0].jobID)
        #expect(waiting.job.kind == "release.notify")
        #expect(waiting.job.state == .waitingApproval)
        #expect(waiting.job.payload[path: "app"]?.string == "Pulse Diary")
        #expect(waiting.job.payload[path: "version"]?.string == "4.2.0")

        let repeatCheck = await ctx.subscribers.checkNewReleases(model: ctx.model)
        #expect(repeatCheck.isEmpty)
        let repeatDraft = await ctx.subscribers.draftNotification(app: "Pulse Diary", version: "4.2.0", model: ctx.model)
        #expect(!repeatDraft.ok)
        #expect(repeatDraft.jobID == waiting.job.id)
        #expect(ctx.model.waiting.count == 1)

        // 4. AgentBridge.shared.handle("approve", ...) refuses release.notify even with .decisions + Full Autopilot.
        AgentBridge.shared.start(model: ctx.model)
        let key = SymmetricKey(size: .bits256)
        AgentPolicy.shared.signCurrent(key)
        AgentPolicy.shared.set(.decisions, true)
        AgentPolicy.shared.setFullTrust(for: 3600)

        let approveReply = await AgentBridge.shared.handle(
            "approve",
            ["id": "\(waiting.job.id)"],
            agent: "Test Bot",
            reason: "Auto-approve release notify"
        )
        #expect(approveReply["ok"] as? Bool == false)
        #expect((approveReply["error"] as? String)?.contains("Only the owner can approve") == true)
        #expect(ctx.model.waiting.count == 1)
    }

    @Test func patchTransitionDraftsWhenAllowPatchUpdatesIsEnabled() async throws {
        let prevProject = ProjectStore.shared.selectedID
        defer { ProjectStore.shared.selectedID = prevProject }
        ProjectStore.shared.selectedID = nil

        let ctx = try await makeContext()
        defer { try? FileManager.default.removeItem(at: ctx.dir) }

        ctx.subscribers.importCSV("Alex <alex@example.com>", defaultApps: ["Pulse Diary"])
        ctx.subscribers.setConfig(ReleaseNotifyAppConfig(allowPatchUpdates: true, autoDraftOnRelease: true), forApp: "Pulse Diary")

        let t0 = Millis(Date.now.timeIntervalSince1970 * 1000) - 60_000
        try await ingestRelease(store: ctx.store, app: "Pulse Diary", version: "4.1.9", occurredAt: t0, tag: "p0")
        await ctx.model.refresh()

        let baseline = await ctx.subscribers.checkNewReleases(model: ctx.model)
        #expect(baseline.isEmpty)

        try await ingestRelease(store: ctx.store, app: "Pulse Diary", version: "4.1.10", occurredAt: t0 + 10_000, tag: "p1")
        await ctx.model.refresh()

        let patchDrafts = await ctx.subscribers.checkNewReleases(model: ctx.model)
        #expect(patchDrafts.count == 1)
        #expect(patchDrafts[0].app == "Pulse Diary")
        #expect(patchDrafts[0].version == "4.1.10")
        #expect(ctx.model.waiting.count == 1)
        #expect(ctx.model.waiting.first?.job.kind == "release.notify")
        #expect(ctx.model.waiting.first?.job.state == .waitingApproval)
    }

    @Test func processMailEventsAndUndoMailAction() async throws {
        let ctx = try await makeContext()
        defer { try? FileManager.default.removeItem(at: ctx.dir) }

        ctx.subscribers.importCSV("Reader <reader@example.com>", defaultApps: ["Pulse Diary"])
        #expect(ctx.subscribers.activeCount(forApp: "Pulse Diary") == 1)

        let nowMs = Millis(Date.now.timeIntervalSince1970 * 1000)
        _ = try await ctx.store.ingest(
            Event(
                source: "mail",
                kind: "mail.seen",
                app: nil,
                payload: .object([
                    "id": .string("mail-unsub-100"),
                    "from": .string("Reader <reader@example.com>"),
                    "subject": .string("Re: Pulse Diary 4.2.0 is now available"),
                    "folder": .string("INBOX"),
                    "text": .string("Please unsubscribe me from future emails."),
                ]),
                occurredAt: nowMs,
                dedupeKey: "mail-unsub-100"
            ),
            rules: []
        )

        let applied = await ctx.subscribers.processMailEvents(model: ctx.model)
        #expect(applied.count == 1)
        let record = try #require(applied.first)
        #expect(record.kind == .unsubscribe)
        #expect(record.email == "reader@example.com")
        #expect(ctx.subscribers.activeCount(forApp: "Pulse Diary") == 0)

        // Repeat processing is a no-op.
        let secondPass = await ctx.subscribers.processMailEvents(model: ctx.model)
        #expect(secondPass.isEmpty)

        // Owner can undo cleanly.
        #expect(ctx.subscribers.undoMailAction(record))
        #expect(ctx.subscribers.activeCount(forApp: "Pulse Diary") == 1)
        #expect(ctx.subscribers.book.mailActions?.first?.undone == true)
        #expect(!ctx.subscribers.undoMailAction(record))
    }
}
