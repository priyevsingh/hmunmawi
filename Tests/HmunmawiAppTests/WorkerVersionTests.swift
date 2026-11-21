import CryptoKit
import Foundation
import Testing
@testable import HmunmawiApp

/// The worker's code version must change whenever its files do, so installed apps know to update a deployed worker.
@Suite struct WorkerVersionTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func recordedVersionMatchesTheWorkerFiles() throws {
        let folder = Self.root.appending(path: "Resources/LiveWorker")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".mjs") }.sorted()
        var data = Data()
        for n in names {
            data.append(Data((n + "\n").utf8))
            data.append(try Data(contentsOf: folder.appending(path: n)))
            data.append(Data("\n".utf8))
        }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let recorded = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.root.appending(path: "Resources/LiveWorkerVersion.json"))) as? [String: Any]
        #expect(recorded?["sha256"] as? String == hash,
                "Worker files changed: bump WORKER_CODE_VERSION (workerCore.mjs), LivePurchases.workerCodeVersion and Resources/LiveWorkerVersion.json (new sha256 \(hash))")
        let version = recorded?["code_version"] as? Int
        #expect(version == LivePurchases.workerCodeVersion)
        let core = try String(contentsOf: folder.appending(path: "workerCore.mjs"), encoding: .utf8)
        #expect(core.contains("export const WORKER_CODE_VERSION = \(LivePurchases.workerCodeVersion);"))
    }

    @Test func olderOrUnversionedWorkersAreUpdatedOncePerVersion() throws {
        #expect(LivePurchases.workerNeedsUpdate(deployed: nil, current: 2))
        #expect(LivePurchases.workerNeedsUpdate(deployed: 1, current: 2))
        #expect(!LivePurchases.workerNeedsUpdate(deployed: 2, current: 2))
        #expect(!LivePurchases.workerNeedsUpdate(deployed: 3, current: 2))
        #expect(LivePurchases.mayAutoUpdate(triedVersion: 0, current: 2))
        #expect(!LivePurchases.mayAutoUpdate(triedVersion: 2, triedBuild: "153", current: 2, build: "153"))   // tried with this build: no loop
        #expect(LivePurchases.mayAutoUpdate(triedVersion: 2, triedBuild: "152", current: 2, build: "153"))    // a newer build gets one try
        #expect(!LivePurchases.mayAutoUpdate(triedVersion: 2, triedBuild: nil, current: 2, build: "153"))
        let caps = try JSONDecoder().decode(AscWebhookStream.Capabilities.self, from: Data(#"{"asc_queue_v2":true,"code_version":2,"protocol":2}"#.utf8))
        #expect(caps.code_version == 2)
        let old = try JSONDecoder().decode(AscWebhookStream.Capabilities.self, from: Data(#"{"asc_queue_v2":true}"#.utf8))
        #expect(old.code_version == nil)
    }

    /// A refused saved token makes Live sales ask for a new one (1.5.5).
    @Test func refusedTokenIsRecognised() {
        #expect(LivePurchases.tokenRefused(putOK: false, putHTTP: 403, error: nil))
        #expect(LivePurchases.tokenRefused(putOK: false, putHTTP: 401, error: nil))
        #expect(LivePurchases.tokenRefused(putOK: false, putHTTP: 0, error: "Cloudflare refused: No access to the specified resource.. Check the token's permissions."))
        #expect(LivePurchases.tokenRefused(putOK: false, putHTTP: 0, error: "That token can't see a Cloudflare account. Create it with …"))
        #expect(!LivePurchases.tokenRefused(putOK: true, putHTTP: 403, error: "old"))            // a later success clears it
        #expect(!LivePurchases.tokenRefused(putOK: false, putHTTP: 500, error: "Cloudflare is down"))  // not a token problem
    }
}
