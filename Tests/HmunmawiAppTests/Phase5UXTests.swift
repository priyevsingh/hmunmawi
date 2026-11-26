import Foundation
import HmunmawiProtocol
import Testing
@testable import HmunmawiApp
@testable import HmunmawiCore

@Suite struct Phase5UXTests {
    private func addOnRow(id: String, settingsJSON: String) throws -> AddOnRow {
        let json = """
        {
          "id": "\(id)",
          "name": "\(id.capitalized)",
          "version": "1.0.0",
          "protocol": 1,
          "executable": "\(id)-addon",
          "settings": \(settingsJSON)
        }
        """
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        let plugin = InstalledPlugin(manifest: manifest, directory: URL(filePath: "/tmp"), fingerprint: "fp")
        return AddOnRow(plugin: plugin, approved: true, savedSecrets: [], missing: [])
    }

    private func setKeyJob(id: Int64, connection: String, field: String, value: String?, pending: String? = nil) -> Job {
        let masked = pending != nil || value == nil ? "•••" : (value ?? "")
        var args: [String: JSONValue] = ["connection": .string(connection), "field": .string(field)]
        if let value, pending == nil { args["value"] = .string(value) }
        var obj: [String: JSONValue] = [
            "command": .string("set-key"),
            "agent": .string("Antigravity"),
            "reason": .string("Setup"),
            "summary": .string("Antigravity: set-key connection=\(connection) field=\(field) value=\(masked)"),
            "args": .object(args)
        ]
        if let pending { obj["pending"] = .string(pending) }
        return Job(id: id, kind: "agent.request", resource: "agent", priority: 3, state: .waitingApproval,
                   attempts: 0, maxAttempts: 1, runAfter: 0, owner: nil, ruleID: nil, eventID: nil,
                   payload: .object(obj), lastError: nil, updatedAt: 0)
    }

    @MainActor @Test func setKeyBatchPreviewRevealsPlainFieldsAndMasksSecrets() throws {
        let row = try addOnRow(id: "vercel", settingsJSON: """
        [
          {"key":"project","label":"Project","type":"text"},
          {"key":"apiToken","label":"Token","type":"secret"},
          {"key":"keyFile","label":"Key file","type":"secret-file"}
        ]
        """)

        // Plain field with summary fallback (as stored by parkAgentRequest) reveals value safely.
        let projJobWithPlainSummary = Job(
            id: 1, kind: "agent.request", resource: "agent", priority: 3, state: .waitingApproval,
            attempts: 0, maxAttempts: 1, runAfter: 0, owner: nil, ruleID: nil, eventID: nil,
            payload: .object([
                "command": .string("set-key"),
                "pending": .string("tok-1"),
                "summary": .string("Antigravity: set-key connection=vercel field=project value=escapethematrix.app"),
                "args": .object(["connection": .string("vercel"), "field": .string("project")])
            ]),
            lastError: nil, updatedAt: 0)
        #expect(SetKeyBatchPreview.displayLine(job: projJobWithPlainSummary, connection: "vercel", addOns: [row]) == "project = escapethematrix.app")

        // Secret and secret-file fields ALWAYS stay masked even if args.value or summary existed.
        let tok = setKeyJob(id: 2, connection: "vercel", field: "apiToken", value: "super-secret", pending: nil)
        #expect(SetKeyBatchPreview.displayLine(job: tok, connection: "vercel", addOns: [row]) == "apiToken = •••")
        let kf = setKeyJob(id: 3, connection: "vercel", field: "keyFile", value: "p8-data", pending: nil)
        #expect(SetKeyBatchPreview.displayLine(job: kf, connection: "vercel", addOns: [row]) == "keyFile = •••")

        // Unknown fields/connections fail closed to •••.
        let unk = setKeyJob(id: 4, connection: "vercel", field: "unknownKey", value: "leak", pending: nil)
        #expect(SetKeyBatchPreview.displayLine(job: unk, connection: "vercel", addOns: [row]) == "unknownKey = •••")
    }

    @MainActor @Test func shieldPrepIncludesValidBuildNumberAndFallsBackWhenMissing() {
        let vid = "ver-123"
        let validEvent = StoredEvent(
            id: 1, source: "appstoreconnect", kind: "release.snapshot", app: "Dote",
            payload: .object(["version_id": .string(vid), "build": .string("66"), "build_processing": .string("VALID")]),
            occurredAt: 1_000)
        let invalidEvent = StoredEvent(
            id: 2, source: "appstoreconnect", kind: "release.snapshot", app: "Dote",
            payload: .object(["version_id": .string("ver-old"), "build": .string("65"), "build_processing": .string("INVALID")]),
            occurredAt: 1_000)

        let b1 = ShieldPrep.validBuild(in: [invalidEvent, validEvent], versionID: vid)
        #expect(b1 == "66")
        #expect(ShieldPrep.summary(app: "Dote", version: "1.0", item: "build", build: b1) == "Rejection Shield: attach build 66 to Dote 1.0")
        #expect(ShieldPrep.summary(app: "Dote", version: "1.0", item: "build", build: nil) == "Rejection Shield: prepare build for Dote 1.0")
        #expect(ShieldPrep.summary(app: "Dote", version: "1.0", item: "promo", build: "66") == "Rejection Shield: prepare promo for Dote 1.0")
    }

    @MainActor @Test func supersededSetKeyPruningTargetsOnlySavedNonEmptyFields() {
        let w1 = WaitingAction(job: setKeyJob(id: 101, connection: "vercel", field: "project", value: nil, pending: "p1"), title: "t", detail: "d")
        let w2 = WaitingAction(job: setKeyJob(id: 102, connection: "vercel", field: "apiToken", value: nil, pending: "p2"), title: "t", detail: "d")
        let w3 = WaitingAction(job: setKeyJob(id: 103, connection: "sentry", field: "project", value: nil, pending: "p3"), title: "t", detail: "d")
        let shield = WaitingAction(job: Job(
            id: 108, kind: "agent.request", resource: "agent", priority: 3, state: .waitingApproval,
            attempts: 0, maxAttempts: 1, runAfter: 0, owner: nil, ruleID: nil, eventID: nil,
            payload: .object(["command": .string("shield-fix"), "args": .object(["app": .string("Dote"), "item": .string("build")])]),
            lastError: nil, updatedAt: 0), title: "t", detail: "d")

        let pruned = AppModel.supersededSetKeyJobs(waiting: [w1, w2, w3, shield], connection: "vercel", savedFields: ["project"])
        #expect(pruned.map(\.id) == [101])
        #expect(AppModel.supersededSetKeyJobs(waiting: [w1, w2], connection: "vercel", savedFields: []).isEmpty)
    }

    @Test func vercelDetectorMergeKeepsMultiProjectIndicesAligned() {
        let d1 = VercelDetector.Detected(projectID: "prj_1", orgID: "team_abc123", projectName: "site-one", repo: "org/site-one", branch: "main")
        let d2 = VercelDetector.Detected(projectID: "prj_2", orgID: "team_abc123", projectName: "site-two", repo: "org/site-two", branch: "main")

        let merged = VercelDetector.merge(values: [:], detected: [d1, d2])
        #expect(merged["project"] == "prj_1, prj_2")
        #expect(merged["teamID"] == "team_abc123")
        #expect(merged["repo"] == "org/site-one, org/site-two")
        #expect(merged["siteName"] == "site-one, site-two")
        #expect(merged["branch"] == "main")

        // Re-detecting same project does not duplicate entries.
        let deduped = VercelDetector.merge(values: merged, detected: [d1])
        #expect(deduped["project"] == "prj_1, prj_2")
        #expect(deduped["repo"] == "org/site-one, org/site-two")
    }
}
