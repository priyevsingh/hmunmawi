import Foundation
import Testing
@testable import HmunmawiCore

/// An agent's request you approve is run by the app itself; afterwards it must leave "waiting", whether it worked or not.
@Suite struct ApprovalTests {
    @Test func approvedRequestLeavesWaitingWhenItWorks() async throws {
        let store = try Store(path: ":memory:")
        let id = try await store.enqueue(kind: "agent.request", resource: "agent", payload: .object([:]), needsApproval: true)
        try await store.resolveApproved(id, ok: true, by: "you", detail: .object([:]))
        #expect(try await store.job(id)?.state == .done)
    }

    @Test func approvedRequestLeavesWaitingWhenItFails() async throws {
        let store = try Store(path: ":memory:")
        let id = try await store.enqueue(kind: "agent.request", resource: "agent", payload: .object([:]), needsApproval: true)
        try await store.resolveApproved(id, ok: false, by: "you", detail: .object(["result": .string("No build")]))
        #expect(try await store.job(id)?.state == .failed)
    }

    @Test func cannotResolveSomethingNotWaiting() async throws {
        let store = try Store(path: ":memory:")
        let id = try await store.enqueue(kind: "notify", resource: "ntfy", payload: .object([:]))
        await #expect(throws: (any Error).self) { try await store.resolveApproved(id, ok: true, by: "you", detail: .object([:])) }
    }
}
