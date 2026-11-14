import Foundation
import Testing
@testable import HmunmawiCore

@Suite struct ConnectionAuditTests {
    @Test func newerHttpSupersedesPollFailed() {
        let fail = AuditEntry(id: 2, at: 2000, actor: "posthog", action: "plugin.poll_failed",
                              subject: nil, detail: .object(["error": .string("keychain: unreadable")]))
        let ok = AuditEntry(id: 1, at: 3000, actor: "posthog", action: "plugin.http", subject: "us.posthog.com", detail: .null)
        let d = ConnectionAudit.display(audit: [ok, fail], actor: "posthog", approved: true, missing: false)
        #expect(d.tone == .good)
        #expect(d.label == "Connected")
    }

    @Test func staleFailureStillShowsWhenNewest() {
        let fail = AuditEntry(id: 2, at: 3000, actor: "posthog", action: "plugin.poll_failed",
                              subject: nil, detail: .object(["error": .string("posthog_failed: timeout")]))
        let ok = AuditEntry(id: 1, at: 2000, actor: "posthog", action: "plugin.http", subject: "x", detail: .null)
        let d = ConnectionAudit.display(audit: [fail, ok], actor: "posthog", approved: true, missing: false)
        #expect(d.tone == .bad)
    }

    @Test func xFileFreshIsGreenAndSupersedesOld402() {
        let old = AuditEntry(id: 1, at: 100, actor: "x", action: "plugin.poll_failed",
                             subject: nil, detail: .object(["error": .string("x_failed: Your X API credits are used up. Add credits at console.x.com")]))
        let ok = AuditEntry(id: 2, at: 200, actor: "x", action: "plugin.mac", subject: "xfile.read",
                            detail: .object(["status": .string("fresh")]))
        let d = ConnectionAudit.display(audit: [ok, old], actor: "x", approved: true, missing: false)
        #expect(d.tone == .good)
        #expect(d.label == "Connected")
    }

    @Test func xFileStaleIsAmberWithReason() {
        let ok = AuditEntry(id: 2, at: 200, actor: "x", action: "plugin.mac", subject: "xfile.read",
                            detail: .object(["status": .string("stale"), "reason": .string("Your Mac's X file was last updated 14 h ago")]))
        let d = ConnectionAudit.display(audit: [ok], actor: "x", approved: true, missing: false)
        #expect(d.tone == .caution)
        #expect(d.detail == "Your Mac's X file was last updated 14 h ago")
    }

    @Test func xFileMissingIsRed() {
        let fail = AuditEntry(id: 3, at: 300, actor: "x", action: "plugin.poll_failed", subject: nil,
                              detail: .object(["error": .string("x_file_missing: Your Mac's X file isn't there")]))
        let ok = AuditEntry(id: 2, at: 200, actor: "x", action: "plugin.mac", subject: "xfile.read", detail: .object(["status": .string("fresh")]))
        let d = ConnectionAudit.display(audit: [fail, ok], actor: "x", approved: true, missing: false)
        #expect(d.tone == .bad)
        #expect(d.label == "X file missing")
    }

    @Test func ntfyDeliveryFailureIsRedUntilNextSuccess() {
        let fail = AuditEntry(id: 2, at: 200, actor: "ntfy", action: "plugin.delivery_failed", subject: "ntfy.sh",
                              detail: .object(["error": .string("ntfy answered 429")]))
        let ok = AuditEntry(id: 3, at: 300, actor: "ntfy", action: "plugin.delivered", subject: "ntfy.sh", detail: .null)
        #expect(ConnectionAudit.display(audit: [fail], actor: "ntfy", approved: true, missing: false).tone == .bad)
        #expect(ConnectionAudit.display(audit: [ok, fail], actor: "ntfy", approved: true, missing: false).tone == .good)
    }

    @Test func pollRetryShowsCheckingAgainUntilItSucceeds() {
        let ok = AuditEntry(id: 1, at: 1000, actor: "appstoreconnect", action: "plugin.http",
                            subject: "api.appstoreconnect.apple.com", detail: .null)
        let retry = AuditEntry(id: 2, at: 2000, actor: "appstoreconnect", action: "plugin.poll_retry",
                               subject: nil, detail: .object(["error": .string(Engine.pollTimeoutText),
                                                              "attempt": .number(1), "max": .number(3)]))
        let d = ConnectionAudit.display(audit: [retry, ok], actor: "appstoreconnect", approved: true, missing: false)
        #expect(d.label == "Checking again")
        #expect(d.tone == .caution)
        #expect(d.detail == Engine.pollTimeoutText)
        let done = AuditEntry(id: 3, at: 3000, actor: "appstoreconnect", action: "plugin.http",
                              subject: "api.appstoreconnect.apple.com", detail: .null)
        let recovered = ConnectionAudit.display(audit: [done, retry, ok], actor: "appstoreconnect", approved: true, missing: false)
        #expect(recovered.label == "Connected")
        #expect(recovered.tone == .good)
    }
}
