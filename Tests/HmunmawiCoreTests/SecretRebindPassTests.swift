import Foundation
import Testing
@testable import HmunmawiCore

private func tempCatalog() -> SecretSourceCatalog {
    SecretSourceCatalog(url: FileManager.default.temporaryDirectory.appending(path: "rebind-\(UUID().uuidString).json"))
}

private final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var counts: [String: Int] = [:]
    func hit(_ p: String) { lock.lock(); counts[p, default: 0] += 1; lock.unlock() }
}

@Suite struct SecretRebindPassTests {
    @Test func importsKeysAndReadsEachFileOnce() {
        let id = "rb\(UUID().uuidString.prefix(6).lowercased())"
        let catalog = tempCatalog()
        let file = "/protected/asc-config.toml"
        catalog.record(plugin: id, name: "issuerID", ref: .init(path: file, kind: .tomlKey, field: "issuer_id"))
        catalog.record(plugin: id, name: "keyID", ref: .init(path: file, kind: .tomlKey, field: "key_id"))
        catalog.record(plugin: id, name: "other", ref: .init(path: file, kind: .tomlKey, field: "auth_token"))
        let counter = ReadCounter()
        let pass = SecretReadPass { p in
            counter.hit(p)
            return ("issuer_id = \"iss-123\"\nkey_id = \"key-456\"\nauth_token = \"tok-789\"\n", false)
        }
        let store = KeychainSecretStore()
        let report = SecretRebinder.rebindPass(store: store, catalog: catalog, pass: pass)
        #expect(report.rebound == 3)
        #expect(report.needsAttention.isEmpty)
        #expect(counter.counts[file] == 1)   // one read, so macOS can ask at most once
        #expect((try? store.peekSecret(plugin: id, name: "keyID")) == "key-456")
    }

    @Test func refusedFileIsReportedNotRetried() {
        let id = "rb\(UUID().uuidString.prefix(6).lowercased())"
        let catalog = tempCatalog()
        let file = "/Users/x/Documents/keys/sentry.env"
        catalog.record(plugin: id, name: "authToken", ref: .init(path: file, kind: .envLine, field: "SENTRY_AUTH_TOKEN"))
        catalog.record(plugin: id, name: "second", ref: .init(path: file, kind: .envLine, field: "OTHER"))
        let counter = ReadCounter()
        let pass = SecretReadPass { p in counter.hit(p); return (nil, true) }
        let report = SecretRebinder.rebindPass(store: KeychainSecretStore(), catalog: catalog, pass: pass)
        #expect(report.rebound == 0)
        #expect(Set(report.needsAttention) == ["\(id)/authToken", "\(id)/second"])
        #expect(report.addOnIDs == [id])
        #expect(report.refusedPaths == [file])
        #expect(counter.counts[file] == 1)
    }

    @Test func refusalIsDetectedFromRealFileErrors() {
        let missing = SecretReadPass.readFile("/nonexistent-\(UUID().uuidString)/x.env")
        #expect(missing.text == nil)
        #expect(missing.refused == false)
    }

    @Test func slowReadDelaysOnlyTheBackgroundPass() async {
        let id = "rb\(UUID().uuidString.prefix(6).lowercased())"
        let catalog = tempCatalog()
        catalog.record(plugin: id, name: "apiKey", ref: .init(path: "/slow/key.env", kind: .envLine, field: "K"))
        let gate = DispatchSemaphore(value: 0)
        let pass = SecretReadPass { _ in gate.wait(); return ("K=abc-123\n", false) }   // stands in for an open macOS prompt
        let store = KeychainSecretStore()
        let finished = Task.detached { SecretRebinder.rebindPass(store: store, catalog: catalog, pass: pass) }
        // The caller is free while the read waits.
        try? await Task.sleep(for: .milliseconds(150))
        #expect((try? store.peekSecret(plugin: id, name: "apiKey")) == nil)
        gate.signal()   // the owner answers the prompt
        let report = await finished.value
        #expect(report.rebound == 1)
        #expect((try? store.peekSecret(plugin: id, name: "apiKey")) == "abc-123")
    }

    @Test func readableSourceBehavesAsBefore() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "rbf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appending(path: "k.env")
        try "export MY_KEY='real-value-1'\n".write(to: f, atomically: true, encoding: .utf8)
        let id = "rb\(UUID().uuidString.prefix(6).lowercased())"
        let catalog = tempCatalog()
        catalog.record(plugin: id, name: "apiKey", ref: .init(path: f.path, kind: .envLine, field: "MY_KEY"))
        let store = KeychainSecretStore()
        #expect(SecretRebinder.rebindAll(store: store, catalog: catalog) == 1)
        #expect((try? store.peekSecret(plugin: id, name: "apiKey")) == "real-value-1")
    }
}
