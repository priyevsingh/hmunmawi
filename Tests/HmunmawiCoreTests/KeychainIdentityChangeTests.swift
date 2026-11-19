import Foundation
import Security
import Testing
@testable import HmunmawiCore

/// A Keychain where some items were made by "another signature": reads and changes of them are refused, as macOS does
/// for a release build meeting a development build's items.
private final class FakeKeychain: KeychainBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    private var foreign = Set<String>()
    var updateSucceedsOnForeign = false
    func addForeign(_ account: String, _ value: String) { lock.lock(); items[account] = value; foreign.insert(account); lock.unlock() }
    func read(service: String, account: String) -> (status: OSStatus, value: String?) {
        lock.lock(); defer { lock.unlock() }
        guard let v = items[account] else { return (errSecItemNotFound, nil) }
        return foreign.contains(account) ? (errSecAuthFailed, nil) : (errSecSuccess, v)
    }
    func exists(service: String, account: String) -> Bool { lock.lock(); defer { lock.unlock() }; return items[account] != nil }
    func update(service: String, account: String, value: String) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        guard items[account] != nil else { return errSecItemNotFound }
        if foreign.contains(account) { return updateSucceedsOnForeign ? errSecSuccess : errSecInteractionNotAllowed }
        items[account] = value; return errSecSuccess
    }
    func add(service: String, account: String, value: String) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        guard items[account] == nil else { return errSecDuplicateItem }
        items[account] = value; return errSecSuccess
    }
    func delete(service: String, account: String) {
        lock.lock(); defer { lock.unlock() }
        if !foreign.contains(account) { items[account] = nil }
    }
    func accounts() -> [String] { lock.lock(); defer { lock.unlock() }; return items.keys.sorted() }
}

@Suite struct KeychainIdentityChangeTests {
    private func store(_ k: FakeKeychain) -> KeychainSecretStore { KeychainSecretStore(service: "t", backend: k) }

    @Test func itemFromAnotherSignatureIsUnreadableButExists() throws {
        let k = FakeKeychain(); k.addForeign("sentry/authToken", "old")
        let s = store(k)
        #expect(s.secretItemExists(plugin: "sentry", name: "authToken"))
        #expect(throws: (any Error).self) { try s.peekSecret(plugin: "sentry", name: "authToken") }
    }

    @Test func savingNextToAnotherSignaturesItemWorksWithoutAPrompt() throws {
        let k = FakeKeychain(); k.addForeign("sentry/authToken", "old")
        let s = store(k)
        try s.replaceSecret("new", plugin: "sentry", name: "authToken")
        #expect(try s.peekSecret(plugin: "sentry", name: "authToken") == "new")
        #expect(k.accounts() == ["sentry/authToken", "sentry/authToken#1"])
        // Changing it again updates the item this copy made.
        try s.setSecret("newer", plugin: "sentry", name: "authToken")
        #expect(try s.peekSecret(plugin: "sentry", name: "authToken") == "newer")
        #expect(k.accounts() == ["sentry/authToken", "sentry/authToken#1"])
    }

    @Test func updateThatReportsSuccessOnAForeignItemStillMovesOn() throws {
        let k = FakeKeychain(); k.updateSucceedsOnForeign = true; k.addForeign("sentry/authToken", "old")
        let s = store(k)
        try s.replaceSecret("new", plugin: "sentry", name: "authToken")
        #expect(try s.peekSecret(plugin: "sentry", name: "authToken") == "new")
    }

    @Test func aSecondIdentityChangeMovesOnAgain() throws {
        let k = FakeKeychain(); k.addForeign("a/b", "1"); k.addForeign("a/b#1", "2")
        let s = store(k)
        try s.setSecret("3", plugin: "a", name: "b")
        #expect(try s.peekSecret(plugin: "a", name: "b") == "3")
        #expect(k.accounts().contains("a/b#2"))
    }

    @Test func plainSaveReadDeleteStillWork() throws {
        let k = FakeKeychain(); let s = store(k)
        #expect(try s.peekSecret(plugin: "x", name: "y") == nil)
        try s.setSecret("v", plugin: "x", name: "y")
        #expect(try s.peekSecret(plugin: "x", name: "y") == "v")
        s.deleteSecret(plugin: "x", name: "y")
        #expect(!s.secretItemExists(plugin: "x", name: "y"))
    }

    @Test func rebindImportsFromTheSavedFileOverAnotherSignaturesItem() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "kic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let env = dir.appending(path: "s.env")
        try "SENTRY_AUTH_TOKEN=fromfile\n".write(to: env, atomically: true, encoding: .utf8)
        let catalog = SecretSourceCatalog(url: dir.appending(path: "sources.json"))
        catalog.record(plugin: "sentry", name: "authToken", ref: SecretSourceRef(path: env.path, kind: .envLine, field: "SENTRY_AUTH_TOKEN"))
        let k = FakeKeychain(); k.addForeign("sentry/authToken", "old")
        let s = store(k)
        #expect(SecretRebinder.rebind(store: s, catalog: catalog, plugin: "sentry", name: "authToken"))
        #expect(try s.peekSecret(plugin: "sentry", name: "authToken") == "fromfile")
    }

    @Test func signingChangeNoteNamesThePermissions() {
        #expect(SigningIdentity.changeNote(previous: nil, current: "Developer ID (X)") == nil)
        #expect(SigningIdentity.changeNote(previous: "A (X)", current: "A (X)") == nil)
        let note = SigningIdentity.changeNote(previous: "Apple Development (X)", current: "Developer ID (X)")
        #expect(note?.contains("Full Disk Access") == true)
        #expect(note?.contains("Calendars") == true)
        #expect(note?.contains("Accessibility") == true)
    }
}
