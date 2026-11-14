import Foundation
import Testing
@testable import HmunmawiApp
@testable import HmunmawiCore

@Suite struct KeyFinderSmokeTests {
    @Test(arguments: [
        ("appstoreconnect", "issuerID", false),
        ("appstoreconnect", "keyID", false),
        ("appstoreconnect", "privateKey", true),
        ("posthog", "apiKey", false),
        ("sentry", "authToken", false),
        ("bing", "apiKey", false),
        ("cloudflare", "apiToken", false),
        ("searchconsole", "serviceAccount", true),
    ])
    func canonicalFindReturnsAtLeastOne(addOn: String, field: String, wantsFile: Bool) async {
        guard let a = SecretSourceDefaults.ascConfig(), FileManager.default.fileExists(atPath: a.path)
            || SecretSourceDefaults.keyFolder().map({ FileManager.default.fileExists(atPath: $0.path) }) == true else { return }
        let matches = await KeyFinder.find(addOn: addOn, field: field, wantsFile: wantsFile)
        #expect(!matches.isEmpty, "Find my key for \(addOn)/\(field)")
        let hub = matches.first { $0.rank == 0 && $0.source != "Keychain" }
        #expect(hub != nil, "expected a hub/config match for \(addOn)/\(field)")
    }
}

private struct OldStore: LegacySecretSource {
    let name = "io.example.OldApp"
    func accounts() -> [String] { ["youtube/apiKey"] }
    func read(account: String) -> LegacyRead { account == "youtube/apiKey" ? .value("example-key-000111") : .missing }
}

@Suite struct KeyFinderLegacyTests {
    @Test func legacyKeychainMatchIsLabelledByServiceAndHidesValue() {
        let m = KeyFinder.legacyKeychain(addOn: "youtube", field: "apiKey", sources: [OldStore()])
        #expect(m.count == 1)
        #expect(m.first?.label == "Keychain · io.example.OldApp")
        #expect(m.first?.source == "Keychain")
        #expect(m.first?.label.contains("example-key") == false)
        #expect(m.first?.fetch() == "example-key-000111")
        #expect(KeyFinder.legacyKeychain(addOn: "x", field: "bearerToken", sources: [OldStore()]).isEmpty)
    }
}
