import Foundation
import Testing
@testable import HmunmawiApp
@testable import HmunmawiCore

@Test func certificateExpiryUsesNewestValidPerType() throws {
    let now = try #require(try? Date("2026-11-10T12:00:00Z", strategy: .iso8601))
    let items: [JSONValue] = [
        .object(["kind": .string("Certificate"), "type": .string("DEVELOPMENT"),
                 "name": .string("Old"), "expires": .string("2026-12-10T15:44:49.000+0000")]),
        .object(["kind": .string("Certificate"), "type": .string("DEVELOPMENT"),
                 "name": .string("New"), "expires": .string("2027-03-19T18:06:45.000+0000")]),
    ]
    let account = JSONValue.object([
        "next_certificate_expiry": .string("2026-12-10"),
        "certificates": .array([
            .object(["type": .string("Development"), "expires": .string("2026-12-10")]),
            .object(["type": .string("Development"), "expires": .string("2027-03-19")]),
        ]),
    ])
    let value = HealthCheck.certificateExpiry(expiryItems: items, account: account, now: now)
    #expect(value?.string == "2027-03-19")
}

@Test func certificateExpiryIgnoresExpiredWithinType() throws {
    let now = try #require(try? Date("2026-11-10T12:00:00Z", strategy: .iso8601))
    let items: [JSONValue] = [
        .object(["kind": .string("Certificate"), "type": .string("DEVELOPMENT"),
                 "name": .string("Old"), "expires": .string("2026-09-01T00:00:00.000+0000")]),
        .object(["kind": .string("Certificate"), "type": .string("DEVELOPMENT"),
                 "name": .string("New"), "expires": .string("2027-03-19T18:06:45.000+0000")]),
    ]
    let value = HealthCheck.certificateExpiry(expiryItems: items, account: nil, now: now)
    #expect(value?.string == "2027-03-19")
}

@Test func certificateExpirySoonestAcrossTypes() throws {
    let now = try #require(try? Date("2026-11-10T12:00:00Z", strategy: .iso8601))
    let items: [JSONValue] = [
        .object(["kind": .string("Certificate"), "type": .string("DEVELOPMENT"),
                 "expires": .string("2027-03-19T18:06:45.000+0000")]),
        .object(["kind": .string("Certificate"), "type": .string("DISTRIBUTION"),
                 "expires": .string("2026-12-20T00:00:00.000+0000")]),
    ]
    let value = HealthCheck.certificateExpiry(expiryItems: items, account: nil, now: now)
    #expect(value?.string == "2026-12-20")
}


@Test func missingMacPermissionsAreAmberHealth() {
    let missing = MacPermissionCatalog.snapshot(from: MacPermissionFacts())
    let check = HealthCheck.permissionsCheck(missing)
    #expect(check?.level == .caution)
    #expect(check?.title == "Mac permissions")
    #expect(check?.value.contains("Files in Documents") == true)

    let ok = MacPermissionCatalog.snapshot(from: MacPermissionFacts(filesAndFolders: true, keychain: .granted))
    if HealthCheck.permissionsCheck(ok) != nil {
        Issue.record("Health should be clear when required permissions are granted")
    }
}
