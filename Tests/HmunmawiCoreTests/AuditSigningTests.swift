import CryptoKit
import Foundation
import Testing
@testable import HmunmawiCore

@Suite struct AuditSigningTests {
    private func store(key: SymmetricKey?) async throws -> Store {
        let s = try Store(path: ":memory:")
        await s.setTrustKey(key)
        return s
    }

    @Test func signedLogPassesAndRewriteWithoutTheKeyIsCaught() async throws {
        let key = SymmetricKey(size: .bits256)
        let s = try await store(key: key)
        try await s.appendAudit(actor: "app", action: "a")
        try await s.appendAudit(actor: "app", action: "b")
        try await s.appendAudit(actor: "app", action: "c")
        #expect(try await s.firstBrokenAuditEntry(requireSigned: true) == nil)

        // Someone with the database but not the key edits entry 2 and recomputes plain links from there.
        try await s.rawExecute("UPDATE audit SET action = 'x' WHERE id = 2")
        #expect(try await s.firstBrokenAuditEntry(requireSigned: true) == 2)
    }

    @Test func unsignedRewriteOfASignedLogIsCaught() async throws {
        let key = SymmetricKey(size: .bits256)
        let s = try await store(key: key)
        try await s.appendAudit(actor: "app", action: "a")
        // Rebuild the whole log as plain links (what an attacker without the key could do).
        await s.setTrustKey(nil)
        try await s.rawExecute("DELETE FROM audit")
        try await s.appendAudit(actor: "app", action: "forged")
        await s.setTrustKey(key)
        #expect(try await s.firstBrokenAuditEntry(requireSigned: true) != nil)
        #expect(try await s.firstBrokenAuditEntry(requireSigned: false) == nil)
    }

    @Test func oldUnsignedEntriesThenSignedOnesAreFine() async throws {
        let s = try await store(key: nil)
        try await s.appendAudit(actor: "app", action: "old")
        await s.setTrustKey(SymmetricKey(size: .bits256))
        try await s.appendAudit(actor: "app", action: "new")
        #expect(try await s.firstBrokenAuditEntry(requireSigned: true) == nil)
    }
}
