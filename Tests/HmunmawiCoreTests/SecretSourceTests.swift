import Foundation
import Testing
@testable import HmunmawiCore

@Suite struct SecretSourceFileReaderTests {
    @Test func envLineReader() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hm-secret-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appending(path: "k.env").path
        try "FOO=abc12345\n# BAR=baz\n".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(SecretFileReader.envValue(path: path, key: "FOO") == "abc12345")
        #expect(SecretFileReader.envValue(path: path, key: "BAR") == nil)
    }

    @Test func tomlKeyReader() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hm-toml-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appending(path: "config.toml").path
        try "issuer_id = \"issuer-uuid-1234\"\nkey_id = \"AB12\"\n".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(SecretFileReader.tomlValue(path: path, key: "issuer_id") == "issuer-uuid-1234")
        #expect(SecretFileReader.tomlValue(path: path, key: "key_id") == "AB12")
    }

    @Test func catalogRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "hm-catalog-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let catalog = SecretSourceCatalog(url: url)
        let ref = SecretSourceRef(path: "/tmp/x.env", kind: .envLine, field: "FOO")
        catalog.record(plugin: "posthog", name: "apiKey", ref: ref)
        #expect(catalog.ref(plugin: "posthog", name: "apiKey") == ref)
    }
}

@Suite struct SecretRebindTests {
    @Test func replaceSecretRoundTrips() throws {
        let store = KeychainSecretStore()
        let plugin = "conn", name = "tok-\(UUID().uuidString)"
        defer { store.deleteSecret(plugin: plugin, name: name) }
        try store.replaceSecret("first-value-12345", plugin: plugin, name: name)
        #expect(try store.secret(plugin: plugin, name: name) == "first-value-12345")
        try store.replaceSecret("second-value-67890", plugin: plugin, name: name)
        #expect(try store.secret(plugin: plugin, name: name) == "second-value-67890")
    }

    @Test func rebindReadsCatalogValue() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hm-rebind-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appending(path: "s.env").path
        try "TOK=from-file-value-99\n".write(toFile: path, atomically: true, encoding: .utf8)
        let ref = SecretSourceRef(path: path, kind: .envLine, field: "TOK")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(SecretFileReader.value(ref: ref) == "from-file-value-99")
    }
}
