import Foundation
import Testing
@testable import HmunmawiCore

private struct YTFakeTransport: HTTPTransport {
    let status: Int
    let body: String
    let seen: @Sendable (URLRequest) -> Void
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        seen(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private final class Box: @unchecked Sendable { var request: URLRequest? }

@Suite struct YouTubeSignInTests {
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "yt-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func signInFileInTheKeyFolderIsFoundByDefault() throws {
        let keys = try tempDir(); defer { try? FileManager.default.removeItem(at: keys) }
        #expect(SecretSourceDefaults.ref(plugin: "youtube", name: "signIn", keyFolder: keys, typedFolder: nil) == nil)
        let file = keys.appending(path: "youtube_token.json")
        try "{}".write(to: file, atomically: true, encoding: .utf8)
        let ref = SecretSourceDefaults.ref(plugin: "youtube", name: "signIn", keyFolder: keys, typedFolder: nil)
        #expect(ref == SecretSourceRef(path: file.path, kind: .wholeFile, field: ""))
    }

    @Test func typedKeyIsMirroredPrivatelyAndFoundAgain() throws {
        let folder = try tempDir().appending(path: "keys"); defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        #expect(SecretSourceDefaults.mirrorTypedKey("typed-value-123", plugin: "youtube", name: "apiKey", in: folder))
        let file = folder.appending(path: "youtube.apiKey")
        let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        let dirPerms = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
        #expect(dirPerms == 0o700)
        let ref = try #require(SecretSourceDefaults.ref(plugin: "youtube", name: "apiKey", keyFolder: nil, typedFolder: folder))
        #expect(SecretFileReader.value(ref: ref) == "typed-value-123")
        // Replacing keeps the permissions.
        #expect(SecretSourceDefaults.mirrorTypedKey("newer", plugin: "youtube", name: "apiKey", in: folder))
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) == 0o600)
        #expect(SecretFileReader.value(ref: ref) == "newer")
    }

    @Test func noFolderMeansNothingIsWritten() {
        #expect(SecretSourceDefaults.mirrorTypedKey("v", plugin: "youtube", name: "apiKey", in: nil) == false)
        #expect(SecretSourceDefaults.mirrorTypedKey("v", plugin: "../evil", name: "apiKey", in: FileManager.default.temporaryDirectory) == false)
    }

    @Test func signInRebindsIntoTheKeychainFromItsFile() throws {
        let keys = try tempDir(); defer { try? FileManager.default.removeItem(at: keys) }
        let file = keys.appending(path: "youtube_token.json")
        try #"{"client_id":"id","client_secret":"sec","refresh_token":"rt"}"#.write(to: file, atomically: true, encoding: .utf8)
        let id = "yt\(UUID().uuidString.prefix(6).lowercased())"
        let catalog = SecretSourceCatalog(url: FileManager.default.temporaryDirectory.appending(path: "yt-cat-\(UUID().uuidString).json"))
        catalog.record(plugin: id, name: "signIn", ref: try #require(SecretSourceDefaults.ref(plugin: "youtube", name: "signIn", keyFolder: keys, typedFolder: nil)))
        let store = KeychainSecretStore()
        defer { store.deleteSecret(plugin: id, name: "signIn") }
        #expect(SecretRebinder.rebind(store: store, catalog: catalog, plugin: id, name: "signIn"))
        #expect((try store.peekSecret(plugin: id, name: "signIn"))?.contains("refresh_token") == true)
    }

    @Test func refreshTokenBecomesAnAccessToken() async throws {
        let box = Box()
        let t = YTFakeTransport(status: 200, body: #"{"access_token":"at-1","expires_in":3599}"#) { box.request = $0 }
        let token = try await GoogleUserToken.fetch(signInJSON: #"{"client_id":"a b","client_secret":"s","refresh_token":"r"}"#, transport: t)
        #expect(token == "at-1")
        let req = try #require(box.request)
        #expect(req.url?.host == "oauth2.googleapis.com")
        let body = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("grant_type=refresh_token") && body.contains("client_id=a%20b"))
    }

    @Test func badOrRefusedSignInIsAPlainError() async {
        let ok = YTFakeTransport(status: 400, body: #"{"error_description":"Token has been revoked"}"#) { _ in }
        await #expect(throws: WireError.self) { try await GoogleUserToken.fetch(signInJSON: #"{"client_id":"a","client_secret":"s","refresh_token":"r"}"#, transport: ok) }
        await #expect(throws: WireError.self) { try await GoogleUserToken.fetch(signInJSON: "not json", transport: ok) }
        // A token address that isn't Google's never receives the sign-in.
        await #expect(throws: WireError.self) {
            try await GoogleUserToken.fetch(signInJSON: #"{"client_id":"a","client_secret":"s","refresh_token":"r","token_uri":"https://evil.example/token"}"#, transport: ok)
        }
    }
}
