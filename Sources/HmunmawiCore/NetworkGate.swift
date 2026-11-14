import Foundation
import Security

public protocol SecretStore: Sendable {
    func secret(plugin: String, name: String) throws -> String?
}

public struct MemorySecretStore: SecretStore {
    /// Keys are `"<plugin>/<name>"`.
    public var values: [String: String]
    public init(_ values: [String: String] = [:]) { self.values = values }
    public func secret(plugin: String, name: String) throws -> String? { values["\(plugin)/\(name)"] }
}

/// A throwaway profile for testing first-run setup (launch with `HMUNMAWI_PROFILE=fresh`, plus `CFFIXED_USER_HOME`
/// pointing at an empty folder so settings and data live elsewhere). It gives every Keychain name a suffix, so a test
/// run can never read, overwrite or delete the real keys and trust flags. No profile means the normal app.
public enum TestProfile {
    public static let name: String? = {
        if let raw = ProcessInfo.processInfo.environment["HMUNMAWI_PROFILE"] {
            let clean = String(raw.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(20))
            if !clean.isEmpty { return clean }
        }
        // `swift test` (XCTest or Swift Testing) always runs as a test profile: unit tests can never read, write or
        // delete a real saved key, trust flag or data folder, even when one forgets to set HMUNMAWI_PROFILE.
        return runningUnitTests ? "unittest" : nil
    }()

    /// True inside a test runner (xctest / swiftpm-testing-helper, or any process with an .xctest bundle loaded).
    public static let runningUnitTests: Bool = {
        let p = ProcessInfo.processInfo
        if ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"].contains(where: { p.environment[$0] != nil }) { return true }
        let n = p.processName.lowercased()
        if n == "xctest" || n.contains("swiftpm-testing-helper") || n.hasSuffix("packagetests") { return true }
        return Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
    }()
    /// ".fresh" for a profile called "fresh", empty for the real app.
    public static var suffix: String { name.map { "." + $0 } ?? "" }
    /// The app's data folder name: "Hmunmawi" for the real app, "Hmunmawi-Test-<profile>" for a test profile, so a test run can
    /// never read or overwrite the real app's files.
    public static var supportFolderName: String { folderName(for: name) }
    /// "Hmunmawi" with no profile (the real app), "Hmunmawi-Test-<profile>" otherwise.
    public static func folderName(for profile: String?) -> String { "Hmunmawi" + (profile.map { "-Test-" + $0 } ?? "") }
}

/// Hmunmawi never shows macOS's "enter your login keychain password" box. When a saved item can't be read without it
/// (it was saved by a differently signed copy of the app), the read fails at once and the app says so in plain words,
/// instead of a password box that comes back even after "Always Allow". Process-wide, switched on once.
public enum Keychain {
    /// Switches the password box off (again). Not a run-once: code that briefly allows a box for something you chose
    /// (`replaceSecret`, picking an old key in Find my key) calls this afterwards to switch it back off.
    public static func neverPrompt() { _ = SecKeychainSetUserInteractionAllowed(false) }
    /// The two answers macOS gives when an item needs a prompt that is switched off.
    public static func needsPrompt(_ status: OSStatus) -> Bool { status == errSecAuthFailed || status == errSecInteractionNotAllowed }
    public static let cantReadText = "This saved key can't be read by this copy of Hmunmawi (it was saved by a differently signed copy). Remove it in Settings → Connections and enter it again."
}

public struct KeychainSecretStore: SecretStore {
    /// Bumped when file-based Keychain ACL from an old signing identity would block reads; items live under this service name only.
    public static var service: String { "io.github.priyevsingh.Hmunmawi.keys.v2" + TestProfile.suffix }
    /// When set, unreadable items re-import once from `secret-sources.json` and built-in hub paths.
    nonisolated(unsafe) public static var catalogURL: URL?
    private let serviceName: String
    public init(service: String? = nil) { serviceName = service ?? Self.service; Keychain.neverPrompt() }

    private var catalog: SecretSourceCatalog? {
        Self.catalogURL.map { SecretSourceCatalog(url: $0) }
    }


    /// A test profile never touches the Keychain at all (no prompts, nothing left behind): its secrets live in memory
    /// for the life of that run.
    private final class Memory: @unchecked Sendable {
        static let shared = Memory()
        private let lock = NSLock()
        private var values: [String: String] = [:]
        func get(_ k: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[k] }
        func set(_ v: String?, _ k: String) { lock.lock(); defer { lock.unlock() }; values[k] = v }
    }

    /// Whether an item exists (even when this copy of the app cannot read it without a Keychain prompt).
    public func secretItemExists(plugin: String, name: String) -> Bool {
        if TestProfile.name != nil { return Memory.shared.get("\(plugin)/\(name)") != nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: "\(plugin)/\(name)",
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    public func secret(plugin: String, name: String) throws -> String? {
        if TestProfile.name != nil { return Memory.shared.get("\(plugin)/\(name)") }
        switch try readKeychainItem(plugin: plugin, name: name) {
        case .missing: return nil
        case .value(let s): return s
        case .unreadable:
            if let catalog, SecretRebinder.rebind(store: self, catalog: catalog, plugin: plugin, name: name) {
                switch try readKeychainItem(plugin: plugin, name: name) {
                case .value(let s): return s
                case .missing, .unreadable: throw WireError("keychain", Keychain.cantReadText)
                case .failed(let status): throw WireError("keychain", "Keychain read failed (\(status))")
                }
            }
            throw WireError("keychain", Keychain.cantReadText)
        case .failed(let status):
            throw WireError("keychain", "Keychain read failed (\(status))")
        }
    }

    private enum KeychainRead {
        case missing, value(String), unreadable, failed(OSStatus)
    }

    /// Keychain read without auto-rebind (used by `SecretRebinder`).
    public func peekSecret(plugin: String, name: String) throws -> String? {
        if TestProfile.name != nil { return Memory.shared.get("\(plugin)/\(name)") }
        switch try readKeychainItem(plugin: plugin, name: name) {
        case .missing: return nil
        case .value(let s): return s
        case .unreadable: throw WireError("keychain", Keychain.cantReadText)
        case .failed(let status): throw WireError("keychain", "Keychain read failed (\(status))")
        }
    }

    private func readKeychainItem(plugin: String, name: String) throws -> KeychainRead {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: "\(plugin)/\(name)",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess, let data = item as? Data else {
            if Keychain.needsPrompt(status) { return .unreadable }
            return .failed(status)
        }
        return .value(String(decoding: data, as: UTF8.self))
    }

    /// Removes a saved key (Settings → Remove key). Missing is fine.
    public func deleteSecret(plugin: String, name: String) {
        if TestProfile.name != nil { Memory.shared.set(nil, "\(plugin)/\(name)"); return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: "\(plugin)/\(name)",
        ]
        SecItemDelete(query as CFDictionary)
    }

    public func setSecret(_ value: String, plugin: String, name: String) throws {
        if TestProfile.name != nil { Memory.shared.set(value, "\(plugin)/\(name)"); return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: "\(plugin)/\(name)",
        ]
        // Update in place first: delete-then-add lost the saved key whenever the add failed (locked, denied), and an
        // item made by a differently signed copy can't be deleted without a prompt anyway.
        let changes: [String: Any] = [kSecValueData as String: Data(value.utf8),
                                      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(base as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add.merge(changes) { $1 }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if Keychain.needsPrompt(status) { throw WireError("keychain", Keychain.cantReadText) }
        guard status == errSecSuccess else { throw WireError("keychain", "Keychain write failed (\(status))") }
    }

    /// Replaces a Keychain item that this app cannot update in place (different signing identity on the old item).
    public func replaceSecret(_ value: String, plugin: String, name: String) throws {
        if TestProfile.name != nil {
            try setSecret(value, plugin: plugin, name: name)
            return
        }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: "\(plugin)/\(name)",
        ]
        let changes: [String: Any] = [kSecValueData as String: Data(value.utf8),
                                      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(base as CFDictionary, changes as CFDictionary)
        if status == errSecSuccess { return }
        if status == errSecItemNotFound {
            try setSecret(value, plugin: plugin, name: name)
            return
        }
        if Keychain.needsPrompt(status) {
            SecKeychainSetUserInteractionAllowed(true)
            defer { Keychain.neverPrompt() }
            let del = SecItemDelete(base as CFDictionary)
            if del != errSecSuccess && del != errSecItemNotFound && Keychain.needsPrompt(del) {
                throw WireError("keychain", Keychain.cantReadText)
            }
            var add = base
            add.merge(changes) { $1 }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if Keychain.needsPrompt(status) { throw WireError("keychain", Keychain.cantReadText) }
        guard status == errSecSuccess else { throw WireError("keychain", "Keychain write failed (\(status))") }
    }

    /// Same as `secret(plugin:name:)` but uses an explicit catalog (for tests).
    public func secret(plugin: String, name: String, catalog: SecretSourceCatalog) throws -> String? {
        let prior = Self.catalogURL
        defer { Self.catalogURL = prior }
        Self.catalogURL = catalog.fileURL
        return try secret(plugin: plugin, name: name)
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}

    /// Read in chunks as they arrive and stopped at the limit (an answer of any size used to be fully loaded into
    /// memory first). Chunked, not byte by byte (a byte loop took 27 s for 5 MB), over one shared session so
    /// connections are reused. Redirects are refused.
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let task = Self.router.session.dataTask(with: request)
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<(Data, HTTPURLResponse), any Error>) in
                Self.router.track(task, limit: NetworkGate.maxResponseBytes, continuation: c)
            }
        } onCancel: { task.cancel() }
        // What the service says about its own request limit (shown in Usage, and available to agents).
        QuotaLedger.shared.note(host: request.url?.host(), status: result.1.statusCode, headers: result.1.allHeaderFields)
        return result
    }

    private static let router = Router()

    /// The shared session's delegate: one collector per request, answering each exactly once.
    private final class Router: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private struct Entry { var data = Data(); var response: HTTPURLResponse?; let limit: Int
                               let continuation: CheckedContinuation<(Data, HTTPURLResponse), any Error> }
        private let lock = NSLock()
        private var entries: [Int: Entry] = [:]
        private(set) lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)

        func track(_ task: URLSessionDataTask, limit: Int, continuation: CheckedContinuation<(Data, HTTPURLResponse), any Error>) {
            lock.withLock { entries[task.taskIdentifier] = Entry(limit: limit, continuation: continuation) }
            task.resume()
        }
        private func finish(_ task: URLSessionTask, _ result: Result<(Data, HTTPURLResponse), any Error>) {
            guard let e = lock.withLock({ entries.removeValue(forKey: task.taskIdentifier) }) else { return }
            if case .failure = result { task.cancel() }
            e.continuation.resume(with: result)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            guard let http = response as? HTTPURLResponse else {
                completionHandler(.cancel); finish(dataTask, .failure(WireError("http_failed", "Not an HTTP response"))); return
            }
            let tooBig: Bool = lock.withLock {
                let id = dataTask.taskIdentifier
                guard let limit = entries[id]?.limit else { return false }
                if http.expectedContentLength > Int64(limit) { return true }
                entries[id]!.response = http
                if http.expectedContentLength > 0 { entries[id]!.data.reserveCapacity(Int(min(http.expectedContentLength, Int64(limit)))) }
                return false
            }
            if tooBig { completionHandler(.cancel); finish(dataTask, .failure(WireError("too_large", "Response is over 20 MB"))); return }
            completionHandler(.allow)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
            // Appended in place (copying the entry out and back would copy the whole download on every chunk).
            let over: Bool = lock.withLock {
                guard entries[dataTask.taskIdentifier] != nil else { return false }
                entries[dataTask.taskIdentifier]!.data.append(chunk)
                return entries[dataTask.taskIdentifier]!.data.count > entries[dataTask.taskIdentifier]!.limit
            }
            if over { finish(dataTask, .failure(WireError("too_large", "Response is over 20 MB"))) }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            if let error { finish(task, .failure(error)); return }
            let got: (Data, HTTPURLResponse?)? = lock.withLock { entries[task.taskIdentifier].map { ($0.data, $0.response) } }
            guard let got, let r = got.1 else { finish(task, .failure(WireError("http_failed", "No response"))); return }
            finish(task, .success((got.0, r)))
        }
    }
}

/// Every web call an add-on makes goes through here: https only, declared hosts only, no redirects,
/// and secrets filled in by the app so the add-on never holds them.
public struct NetworkGate: Sendable {
    static let maxResponseBytes = 20 * 1024 * 1024
    static let allowedMethods: Set<String> = ["GET", "POST", "PUT", "PATCH", "DELETE"]

    let secrets: any SecretStore
    let transport: any HTTPTransport

    public init(secrets: any SecretStore, transport: any HTTPTransport = URLSessionTransport()) {
        self.secrets = secrets
        self.transport = transport
    }

    public func perform(_ spec: HTTPRequestSpec, for manifest: PluginManifest) async throws -> HTTPResponseSpec {
        let request = try buildRequest(try await withGoogleTokens(spec, for: manifest), for: manifest)
        let (data, response) = try await transport.send(request)
        guard data.count <= Self.maxResponseBytes else { throw WireError("too_large", "Response is over 20 MB") }
        // A service that echoes the request back (an error page quoting the header) must not hand the add-on the
        // key it never held: every filled value is blanked out of what the add-on gets.
        let filled = Self.filledValues(request, spec: spec)
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            headers[String(describing: key)] = Self.scrub(String(describing: value), filled)
        }
        if let text = String(data: data, encoding: .utf8) {
            return HTTPResponseSpec(status: response.statusCode, headers: headers, body: Self.scrub(text, filled))
        }
        return HTTPResponseSpec(status: response.statusCode, headers: headers, bodyBase64: Self.scrub(data, filled).base64EncodedString())
    }

    /// The pieces of the request the app filled in (header values and URL parts that differ from what the add-on
    /// wrote), split so a "Bearer <key>" also catches the bare key. Only values of 8+ characters.
    static func filledValues(_ request: URLRequest, spec: HTTPRequestSpec) -> [String] {
        var out: [String] = []
        for (name, written) in spec.headers where written.contains("{{") {
            guard let sent = request.value(forHTTPHeaderField: name), sent != written else { continue }
            out.append(sent)
            out += sent.split(separator: " ").map(String.init)
        }
        if spec.url.contains("{{secret:"), let sent = request.url?.absoluteString {
            for part in sent.split(whereSeparator: { "?&=/".contains($0) }).map(String.init) where !spec.url.contains(part) {
                out.append(part)
                if let plain = part.removingPercentEncoding { out.append(plain) }
            }
        }
        return Array(Set(out.filter { $0.count >= 8 })).sorted { $0.count > $1.count }
    }

    static func scrub(_ text: String, _ values: [String]) -> String {
        variants(values).reduce(text) { $0.replacingOccurrences(of: $1, with: "[key hidden]") }
    }

    /// The same blanking on bytes that aren't text (an echo with a non-UTF-8 byte must not carry the key back).
    static func scrub(_ data: Data, _ values: [String]) -> Data {
        var out = data
        let mask = Data("[key hidden]".utf8)
        for v in variants(values) {
            let needle = Data(v.utf8)
            guard !needle.isEmpty else { continue }
            var from = out.startIndex
            while let r = out.range(of: needle, in: from..<out.endIndex) {
                out.replaceSubrange(r, with: mask)
                from = r.lowerBound + mask.count
            }
        }
        return out
    }

    /// Each value plus its JSON-escaped form ("/" written as "\/"), longest first.
    static func variants(_ values: [String]) -> [String] {
        Array(Set(values + values.map { $0.replacingOccurrences(of: "/", with: "\\/") })).sorted { $0.count > $1.count }
    }

    func buildRequest(_ spec: HTTPRequestSpec, for manifest: PluginManifest) throws -> URLRequest {
        // Some APIs (Bing Webmaster) take the key in the address; it is filled here, after the add-on built the URL.
        let address = spec.url.contains("{{secret:") ? try fillSecrets(spec.url, for: manifest, encodeForURL: true) : spec.url
        guard let url = URL(string: address), url.scheme == "https", let host = url.host()?.lowercased(),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443
        else { throw WireError("blocked_url", "Only plain https addresses are allowed") }
        guard manifest.permissions.hosts.contains(host) else {
            throw WireError("blocked_host", "\(host) is not one of this add-on's approved sites")
        }
        // A key tied to certain hosts never goes anywhere else, even another host the add-on declared.
        let written = ([spec.url] + Array(spec.headers.values)).joined(separator: " ")
        for (name, allowed) in manifest.permissions.secretHosts where !allowed.contains(host) {
            let usesJWT = written.contains("{{asc-jwt}}") && AppStoreConnectToken.requiredSecrets.contains(name)
            if written.contains("{{secret:\(name)}}") || usesJWT {
                throw WireError("blocked_secret_host", "The key “\(name)” may only be sent to \(allowed.joined(separator: ", "))")
            }
        }
        let method = spec.method.uppercased()
        guard Self.allowedMethods.contains(method) else { throw WireError("blocked_method", "\(method) is not allowed") }

        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        for (name, value) in spec.headers {
            request.setValue(try fillSecrets(value, for: manifest), forHTTPHeaderField: name)
        }
        if let base64 = spec.bodyBase64 {
            guard let data = Data(base64Encoded: base64) else { throw WireError("bad_body", "bodyBase64 is not valid") }
            request.httpBody = data
        } else if let body = spec.body {
            // Bodies are sent exactly as written: no secret filling. A body can carry user or AI text (a public
            // review reply, What's New), and a "{{asc-jwt}}" typed there must never turn into a live token.
            // Secrets belong in headers (and Bing's URL), which is where every add-on puts them.
            request.httpBody = Data(body.utf8)
        }
        return request
    }

    func fillSecrets(_ text: String, for manifest: PluginManifest, encodeForURL: Bool = false) throws -> String {
        var result = text
        if result.contains("{{asc-jwt}}") {
            var values: [String] = []
            for name in AppStoreConnectToken.requiredSecrets {
                guard manifest.permissions.secrets.contains(name) else {
                    throw WireError("blocked_secret", "App Store Connect tokens need the secret “\(name)” declared")
                }
                guard let value = try secrets.secret(plugin: manifest.id, name: name), !value.isEmpty else {
                    throw WireError("missing_secret", "Secret “\(name)” has not been set yet")
                }
                values.append(value)
            }
            let token = try AppStoreConnectToken.make(keyID: values[0], issuerID: values[1], privateKeyPEM: values[2])
            result = result.replacingOccurrences(of: "{{asc-jwt}}", with: token)
        }
        for match in text.matches(of: /\{\{secret:([A-Za-z0-9._-]+)\}\}/) {
            let name = String(match.1)
            guard manifest.permissions.secrets.contains(name) else {
                throw WireError("blocked_secret", "Secret “\(name)” was not declared by this add-on")
            }
            guard let value = try secrets.secret(plugin: manifest.id, name: name) else {
                throw WireError("missing_secret", "Secret “\(name)” has not been set yet")
            }
            let filled = encodeForURL ? (value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?#"))) ?? value) : value
            result = result.replacingOccurrences(of: String(match.0), with: filled)
        }
        return result
    }
}


// MARK: Google service accounts

extension NetworkGate {
    /// Fills `{{google-token:<scope>}}` with a short-lived Google access token made from the add-on's
    /// `serviceAccount` secret (the service account's JSON key). The app signs and exchanges it; the add-on
    /// only ever sees the hour-long access token in its own request, never the key.
    func withGoogleTokens(_ spec: HTTPRequestSpec, for manifest: PluginManifest) async throws -> HTTPRequestSpec {
        // Headers only: a body can hold text written by you or an AI, which must never carry a live token out.
        let texts = Array(spec.headers.values)
        let scopes = Set(texts.flatMap { $0.matches(of: /\{\{google-token:([^}]+)\}\}/).map { String($0.1) } })
        guard !scopes.isEmpty else { return spec }
        guard manifest.permissions.secrets.contains("serviceAccount") else {
            throw WireError("blocked_secret", "Google tokens need the secret “serviceAccount” declared")
        }
        guard let json = try secrets.secret(plugin: manifest.id, name: "serviceAccount"), !json.isEmpty else {
            throw WireError("missing_secret", "Add the Google service account key (JSON) first")
        }
        var out = spec
        for scope in scopes {
            let token = try await GoogleTokenCache.shared.token(plugin: manifest.id, scope: scope) {
                try await GoogleServiceToken.fetch(serviceAccountJSON: json, scope: scope, transport: transport)
            }
            let tag = "{{google-token:\(scope)}}"
            out.headers = out.headers.mapValues { $0.replacingOccurrences(of: tag, with: token) }
        }
        return out
    }
}

actor GoogleTokenCache {
    static let shared = GoogleTokenCache()
    private var tokens: [String: (String, Date)] = [:]

    func token(plugin: String, scope: String, make: () async throws -> String) async throws -> String {
        let key = plugin + "|" + scope
        if let (t, until) = tokens[key], until > .now { return t }
        let t = try await make()
        tokens[key] = (t, Date.now.addingTimeInterval(50 * 60))
        return t
    }
}

enum GoogleServiceToken {
    static func fetch(serviceAccountJSON: String, scope: String, transport: any HTTPTransport, now: Date = .now) async throws -> String {
        guard let info = try? JSONSerialization.jsonObject(with: Data(serviceAccountJSON.utf8)) as? [String: Any],
              let email = info["client_email"] as? String, let pem = info["private_key"] as? String
        else { throw WireError("bad_key", "That isn't a Google service account key; download the JSON key file again") }
        let tokenURI = (info["token_uri"] as? String) ?? "https://oauth2.googleapis.com/token"
        let assertion = try jwt(email: email, pem: pem, scope: scope, audience: tokenURI, now: now)
        // The signed key goes only to Google's own token endpoint, whatever the key file says.
        guard let url = URL(string: tokenURI), url.scheme == "https", let host = url.host, host == "googleapis.com" || host.hasSuffix(".googleapis.com")
        else { throw WireError("bad_key", "Bad token address in the key") }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=\(assertion)".utf8)
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = body["access_token"] as? String
        else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error_description"] as? String
            throw WireError("google_auth", "Google refused the service account: \(detail ?? "status \(response.statusCode)")")
        }
        return token
    }

    static func jwt(email: String, pem: String, scope: String, audience: String, now: Date) throws -> String {
        let iat = Int(now.timeIntervalSince1970)
        let header = try JSONSerialization.data(withJSONObject: ["alg": "RS256", "typ": "JWT"], options: [.sortedKeys])
        let claims = try JSONSerialization.data(withJSONObject: ["iss": email, "scope": scope, "aud": audience,
                                                                 "iat": iat, "exp": iat + 3600], options: [.sortedKeys])
        let input = AppStoreConnectToken.base64URL(header) + "." + AppStoreConnectToken.base64URL(claims)
        let key = try rsaKey(pem)
        var error: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(input.utf8) as CFData, &error) as Data? else {
            throw WireError("bad_key", "Could not sign with the service account key")
        }
        return input + "." + AppStoreConnectToken.base64URL(sig)
    }

    /// A PKCS#8 "BEGIN PRIVATE KEY" RSA key as a Security key (Security wants the inner PKCS#1 bytes).
    static func rsaKey(_ pem: String) throws -> SecKey {
        let b64 = pem.components(separatedBy: "\n").filter { !$0.hasPrefix("-----") }.joined()
            .replacingOccurrences(of: "\\n", with: "").filter { !$0.isWhitespace }
        guard let der = Data(base64Encoded: b64), let pkcs1 = pkcs1(fromPKCS8: [UInt8](der)) else {
            throw WireError("bad_key", "The service account's private key could not be read")
        }
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPrivate]
        guard let key = SecKeyCreateWithData(Data(pkcs1) as CFData, attrs as CFDictionary, nil) else {
            throw WireError("bad_key", "The service account's private key could not be read")
        }
        return key
    }

    /// PKCS#8: SEQUENCE { INTEGER 0, SEQUENCE { OID, NULL }, OCTET STRING { PKCS#1 } } → the OCTET STRING's bytes.
    static func pkcs1(fromPKCS8 b: [UInt8]) -> [UInt8]? {
        var i = 0
        func length() -> Int? {
            guard i < b.count else { return nil }
            let first = Int(b[i]); i += 1
            if first < 0x80 { return first }
            let n = first & 0x7f
            guard n <= 4, i + n <= b.count else { return nil }
            var v = 0
            for _ in 0..<n { v = v << 8 | Int(b[i]); i += 1 }
            return v
        }
        func skip(_ tag: UInt8) -> Int? { guard i < b.count, b[i] == tag else { return nil }; i += 1; return length() }
        guard skip(0x30) != nil else { return nil }             // outer SEQUENCE: step inside
        guard let intLen = skip(0x02) else { return nil }; i += intLen   // version
        guard let algLen = skip(0x30) else { return nil }; i += algLen   // algorithm
        guard let octLen = skip(0x04), i + octLen <= b.count else { return nil }
        return Array(b[i..<(i + octLen)])
    }
}
