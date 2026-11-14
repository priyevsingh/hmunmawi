import Foundation
import Security
import Testing
@testable import HmunmawiCore

/// `swift test` must never see the real Keychain: every run is a test profile with in-memory keys, its own data
/// folder name and suffixed Keychain names, even when HMUNMAWI_PROFILE isn't set.
@Suite struct KeychainIsolationTests {
    @Test func testRunsAreAlwaysATestProfile() {
        #expect(TestProfile.runningUnitTests)
        #expect(TestProfile.name != nil)
        #expect(KeychainSecretStore.service != "io.github.priyevsingh.Hmunmawi.keys.v2")
        #expect(TestProfile.supportFolderName != "Hmunmawi")
        #expect(LegacySecretMigrator.legacyServices.allSatisfy { $0 != "io.github.priyevsingh.Hmunmawi" })
    }

    @Test func secretsLiveInMemoryOnly() throws {
        let store = KeychainSecretStore()
        let name = "iso-\(UUID().uuidString)"
        try store.setSecret("example-value-123", plugin: "conn", name: name)
        #expect(try store.secret(plugin: "conn", name: name) == "example-value-123")
        // The same name in the real Keychain service is untouched: a direct lookup there finds nothing.
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: "io.github.priyevsingh.Hmunmawi.keys.v2",
                                kSecAttrAccount as String: "conn/\(name)", kSecMatchLimit as String: kSecMatchLimitOne]
        #expect(SecItemCopyMatching(q as CFDictionary, nil) == errSecItemNotFound)
        store.deleteSecret(plugin: "conn", name: name)
        #expect(try store.secret(plugin: "conn", name: name) == nil)
        #expect(KeychainLegacySource(service: "io.github.priyevsingh.Hmunmawi").accounts().isEmpty)
    }
}
