import Foundation
import Testing
@testable import HmunmawiCore

private struct FakeSource: LegacySecretSource {
    let name: String
    let items: [String: LegacyRead]
    func accounts() -> [String] { Array(items.keys) }
    func read(account: String) -> LegacyRead { items[account] ?? .missing }
}

private final class FakeTarget: SecretMigrationTarget {
    var values: [String: String]
    var unreadable: Set<String>
    var writes = 0
    init(_ values: [String: String] = [:], unreadable: Set<String> = []) { self.values = values; self.unreadable = unreadable }
    func hasItem(account: String) -> Bool { values[account] != nil || unreadable.contains(account) }
    func store(_ value: String, account: String) throws { writes += 1; values[account] = value }
}

@Suite struct LegacySecretMigratorTests {
    @Test func copiesMissingKeyFromOldService() {
        let old = FakeSource(name: "old.service", items: ["youtube/apiKey": .value("example-youtube-key-123")])
        let target = FakeTarget()
        let r = LegacySecretMigrator.migrate(sources: [old], into: target)
        #expect(r.copied == ["youtube/apiKey"])
        #expect(target.values["youtube/apiKey"] == "example-youtube-key-123")
    }

    @Test func neverOverwritesExistingOrUnreadableCurrentItem() {
        let old = FakeSource(name: "old", items: ["x/bearerToken": .value("old-value-123456"), "bing/apiKey": .value("old-bing-123456")])
        let target = FakeTarget(["x/bearerToken": "new-value-654321"], unreadable: ["bing/apiKey"])
        let r = LegacySecretMigrator.migrate(sources: [old], into: target)
        #expect(r.copied.isEmpty)
        #expect(Set(r.alreadyThere) == ["x/bearerToken", "bing/apiKey"])
        #expect(target.values["x/bearerToken"] == "new-value-654321")
        #expect(target.writes == 0)
    }

    @Test func idempotent() {
        let old = FakeSource(name: "old", items: ["posthog/apiKey": .value("phx_example_123456")])
        let target = FakeTarget()
        _ = LegacySecretMigrator.migrate(sources: [old], into: target)
        let second = LegacySecretMigrator.migrate(sources: [old], into: target)
        #expect(second.copied.isEmpty)
        #expect(second.alreadyThere == ["posthog/apiKey"])
        #expect(target.writes == 1)
    }

    @Test func unreadableIsReportedAndNextSourceIsTried() {
        let a = FakeSource(name: "first", items: ["youtube/apiKey": .unreadable, "sentry/authToken": .unreadable])
        let b = FakeSource(name: "second", items: ["youtube/apiKey": .value("example-key-abcdef")])
        let target = FakeTarget()
        let r = LegacySecretMigrator.migrate(sources: [a, b], into: target)
        #expect(r.copied == ["youtube/apiKey"])
        #expect(r.needsOK == ["sentry/authToken": "first"])
        #expect(target.values["sentry/authToken"] == nil)
    }

    @Test func appTrustStateAndBlankValuesAreNeverCopied() {
        let old = FakeSource(name: "old", items: ["hmunmawi/trust-key": .value("example-trust-key"), "bing/apiKey": .value("   "), "noslash": .value("example")])
        let target = FakeTarget()
        let r = LegacySecretMigrator.migrate(sources: [old], into: target)
        #expect(r.copied.isEmpty)
        #expect(target.writes == 0)
    }

    @Test func extraNamesWithoutAnySourceAreHarmless() {
        let target = FakeTarget()
        let r = LegacySecretMigrator.migrate(sources: [], into: target, also: ["youtube/apiKey"])
        #expect(r.copied.isEmpty && r.needsOK.isEmpty && target.writes == 0)
    }

    @Test func youtubeIsAConnectionSecret() {
        #expect(SecretRebinder.connectionSecretNames.contains("youtube/apiKey"))
        #expect(LegacySecretMigrator.legacyServices.allSatisfy { $0 != KeychainSecretStore.service })
    }
}
