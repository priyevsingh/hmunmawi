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

    @Test func vercelAndGitHubHintsDoNotCross() {
        let vercelAPI = KeyFinder.hints(addOn: "vercel", field: "apiToken")
        #expect(vercelAPI.contains("VERCEL"))
        let gh = KeyFinder.hints(addOn: "vercel", field: "githubToken")
        #expect(gh.contains("GITHUB") && gh.contains("GH_TOKEN"))
        #expect(!gh.contains("VERCEL"))
    }

    @Test func decodesGoKeyringBase64KeychainPayload() {
        let raw = "example-gh-token-abc"
        let encoded = "go-keyring-base64:" + Data(raw.utf8).base64EncodedString()
        #expect(KeyFinder.decodeKeychainData(Data(encoded.utf8)) == raw)
        #expect(KeyFinder.decodeKeychainData(Data("plain-token\n".utf8)) == "plain-token")
    }

    @Test func vercelRepoDetectorParsesProjectAndGitRemote() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hm-vdet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appending(path: ".vercel"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appending(path: ".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try #"{"projectId":"prj_12345","orgId":"team_67890","projectName":"example.com"}"#
            .write(to: dir.appending(path: ".vercel/project.json"), atomically: true, encoding: .utf8)
        try "[remote \"origin\"]\n\turl = git@github.com:example-org/example-site.git\n"
            .write(to: dir.appending(path: ".git/config"), atomically: true, encoding: .utf8)
        try "ref: refs/heads/main\n"
            .write(to: dir.appending(path: ".git/HEAD"), atomically: true, encoding: .utf8)

        let d = VercelDetector.detect(in: dir)
        #expect(d.projectID == "prj_12345")
        #expect(d.orgID == "team_67890")
        #expect(d.projectName == "example.com")
        #expect(d.repo == "example-org/example-site")
        #expect(d.branch == "main")
        #expect(VercelDetector.extractGitHubSlug("https://github.com/octocat/hello-world.git") == "octocat/hello-world")
    }
}
