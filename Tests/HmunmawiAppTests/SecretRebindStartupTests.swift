import Foundation
import Testing
@testable import HmunmawiCore
@testable import HmunmawiApp

@MainActor
@Suite struct SecretRebindStartupTests {
    @Test func startReturnsAtOnceWhileAKeyFileReadIsStuck() async {
        let dir = FileManager.default.temporaryDirectory.appending(path: "rbs-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = "rb\(UUID().uuidString.prefix(6).lowercased())"
        SecretSourceCatalog(url: dir.appending(path: SecretSourceCatalog.fileName))
            .record(plugin: id, name: "apiKey", ref: .init(path: "/Users/x/Documents/k.env", kind: .envLine, field: "K"))
        let model = AppModel(supportDirectory: dir, runsEngine: false)
        let gate = DispatchSemaphore(value: 0)
        let started = Date()
        model.startSecretRebind(reader: SecretReadPass { _ in gate.wait(); return (nil, true) }, patience: .seconds(60))
        #expect(Date().timeIntervalSince(started) < 1)   // the main actor was never blocked
        gate.signal()
        for _ in 0..<50 where model.secretsNeedingAttention.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
        #expect(model.secretsNeedingAttention == [id])   // refused read: that connection needs attention
    }
}
