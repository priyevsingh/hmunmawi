import CryptoKit
import Foundation
import HmunmawiCore

/// Live purchases, the free way: a small worker in YOUR Cloudflare account (free plan) receives Apple's
/// App Store Server Notifications, keeps only Apple-signed ones for 7 days, and hands them to this Mac with a
/// private key. The app deploys it, shows the address to paste into App Store Connect, collects new
/// purchases every minute while it's open, and removes everything with one button.
/// Without it, sales still arrive the next morning from Apple's daily report.
@MainActor @Observable
final class LivePurchases {
    static let shared = LivePurchases()

    private let keychain = KeychainSecretStore()
    private let defaults = UserDefaults.standard
    private static let script = "hmunmawi-live"
    /// A second, webhook-only worker for people whose live sales already arrive through something else (for example a
    /// relay of their own). It never changes where purchases are read from.
    private static let hookScript = "hmunmawi-hooks"

    private(set) var url: String? { didSet { defaults.set(url, forKey: "HMLiveURL") } }
    private(set) var busy = false
    private(set) var status: String?
    private(set) var lastCheck: Date?
    private(set) var lastTestAt: Date?
    /// "com.example.app=My App" pairs, so purchases show your app names.
    var appNames: String { didSet { defaults.set(appNames, forKey: "HMLiveAppNames") } }
    var deployed: Bool { url != nil }
    /// True when this app made the worker (so it may delete it); false for an outbox you already run.
    var ownWorker: Bool { accountID != nil }
    /// Where App Store Connect sends notifications: the app's worker → <url>/apple; an existing outbox → its base.
    var appleAddress: String? {
        guard let url else { return nil }
        if ownWorker { return url + "/apple" }
        return url.hasSuffix("/outbox") ? String(url.dropLast(7)) : nil
    }

    private(set) var hookURL: String? { didSet { defaults.set(hookURL, forKey: "HMHookURL") } }
    private var hookAccount: String? { didSet { defaults.set(hookAccount, forKey: "HMHookAccount") } }
    private var hookKV: String? { didSet { defaults.set(hookKV, forKey: "HMHookKV") } }
    var hasHookWorker: Bool { hookURL != nil }
    private var accountID: String? { didSet { defaults.set(accountID, forKey: "HMLiveAccount") } }
    private var namespaceID: String? { didSet { defaults.set(namespaceID, forKey: "HMLiveKV") } }
    /// Newest purchase time already collected (ms).
    private var since: Double { get { defaults.double(forKey: "HMLiveSinceMs") } set { defaults.set(newValue, forKey: "HMLiveSinceMs") } }
    /// The full outbox address (the app's own worker: <url>/outbox; an existing outbox: its URL).
    private var outboxURL: String? { defaults.string(forKey: "HMLiveOutbox") ?? url.map { $0 + "/outbox" } }
    private var poller: Task<Void, Never>?
    private let ascStream = AscWebhookStream()
    /// Worker advertises v2 (DO queue); updated when capabilities are checked with a valid relay key.
    private(set) var ascWorkerUsesEventQueue = false
    /// `GET /asc/events` returned 200 with the saved hook relay key (queue read authorized).
    private(set) var ascRelayAuthorized = false
    /// True only after at least one webhook event was durably applied (seq advanced or non-empty ingest).
    private(set) var ascRelayDelivering = false
    private var ascRelayResyncAttempted = false
    /// Max KV `list` operations per app launch (`budget=1` each); worker import is idempotent by event id.
    private static let kvImportListOpsPerStartup = 5
    /// When true, next `deployHooks` upload includes the durable ASC relay (`ASC_QUEUE_V2`).
    var deployAscEventQueueV2 = false
    /// After user-approved activation, deploy hooks with DO relay and prefer the stream over KV webhook polling.
    var activateAscEventRelayOnDeploy = false
    /// Durably persist ASC webhook events before the worker ACK (hub `Store.ingest`).
    var applyAscEvents: (@MainActor ([Event]) async throws -> Void)?

    init() {
        url = defaults.string(forKey: "HMLiveURL")
        accountID = defaults.string(forKey: "HMLiveAccount")
        namespaceID = defaults.string(forKey: "HMLiveKV")
        hookURL = defaults.string(forKey: "HMHookURL")
        hookAccount = defaults.string(forKey: "HMHookAccount")
        hookKV = defaults.string(forKey: "HMHookKV")
        appNames = defaults.string(forKey: "HMLiveAppNames") ?? ""
        if let t = defaults.object(forKey: "HMLiveTest") as? Date { lastTestAt = t }
        // A token saved by a webhook setup that never finished is of no use to anyone: forget it.
        if hookURL == nil { for n in ["hookCloudflareToken", "hookRelayKey"] { keychain.deleteSecret(plugin: "live", name: n) } }
        AscStreamProtocol.seedStreamPreferenceIfNeeded(
            defaults: defaults, hookV2Live: defaults.bool(forKey: "HMHookV2Live"), hasHookWorker: hasHookWorker)
        if defaults.bool(forKey: "HMHookV2Live"), hasHookWorker {
            defaults.set(true, forKey: AscStreamProtocol.streamEnabledKey)
        }
        AscStreamProtocol.prepareProbeForLaunch(defaults: defaults, streamWanted: wantsAscEventStream())
        ascStream.onEvents = { [weak self] items, source in
            try await self?.persistAscWebhookItems(items)
            if !items.isEmpty {
                self?.ascRelayDelivering = true
                self?.ascRelayAuthorized = true
                UserDefaults.standard.set(source.rawValue, forKey: AscStreamProtocol.Telemetry.lastApplySourceKey)
            }
        }
        ascStream.onConnected = { [weak self] in
            self?.ascRelayAuthorized = true
            self?.status = nil
        }
        ascStream.onDisconnected = { [weak self] reason in
            guard let self, self.ascStream.enabled else { return }
            self.ascRelayDelivering = false
            self.status = "ASC webhook stream paused (\(reason)). Retrying with backoff; not using KV list."
        }
    }

    /// Builds upload metadata for hooks worker (unit-tested; mirrors `upload` when v2 is on).
    static func hooksWorkerUploadMetadata(kv: String, relayKey: String, ascSecret: String, bundleIDs: String, deployV2: Bool, includeMigrations: Bool = true) -> [String: Any] {
        var bindings: [[String: Any]] = [
            ["type": "kv_namespace", "name": "OUTBOX", "namespace_id": kv],
            ["type": "secret_text", "name": "RELAY_KEY", "text": relayKey],
            ["type": "secret_text", "name": "ASC_WEBHOOK_SECRET", "text": ascSecret],
        ]
        if !bundleIDs.isEmpty { bindings.append(["type": "plain_text", "name": "BUNDLE_IDS", "text": bundleIDs]) }
        if deployV2 {
            bindings.append(["type": "durable_object_namespace", "name": "ASC_RELAY", "class_name": "AscRelayDO"])
            bindings.append(["type": "plain_text", "name": "ASC_QUEUE_V2", "text": "1"])
            bindings.append(["type": "plain_text", "name": "ASC_KV_IMPORT", "text": "1"])
        }
        var metadata: [String: Any] = [
            "main_module": "worker.mjs",
            "compatibility_date": "2026-10-01",
            "bindings": bindings,
        ]
        if deployV2, includeMigrations {
            metadata["migration_tag"] = "v2-asc-relay-sqlite"
            metadata["migrations"] = [["tag": "v2-asc-relay-sqlite", "new_sqlite_classes": ["AscRelayDO"]]]
        }
        return metadata
    }

    private func persistAscWebhookItems(_ items: [[String: Any]]) async throws {
        var events: [Event] = []
        for i in items {
            if let e = Self.webhookEvent(i, versionName: versionName) { events.append(e) }
        }
        guard !events.isEmpty else { return }
        if let applyAscEvents {
            try await applyAscEvents(events)
            return
        }
        if let onEvents {
            await onEvents(events)
            return
        }
        throw AscWebhookStream.StreamError.applyFailed
    }

    /// "com.example.app=Name, com.example.two=Two" -> "com.example.app,com.example.two"; nil when none is given.
    nonisolated static func bundleIDs(_ names: String) -> String? {
        let ids = names.split(separator: ",").compactMap { pair -> String? in
            let id = pair.split(separator: "=").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            return id.isEmpty ? nil : id
        }
        return ids.isEmpty ? nil : ids.joined(separator: ",")
    }

    // MARK: Set up and remove

    /// Deploys (or updates) the worker with a Cloudflare API token that can edit Workers and Workers KV.
    func deploy(token: String) async {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        // The worker only takes your own apps' sales, so it needs their bundle ids first.
        guard Self.bundleIDs(appNames) != nil else {
            status = "Add your app names first (bundle.id=Name, comma separated), so the worker only takes your apps' sales."
            return
        }
        busy = true
        defer { busy = false }
        do {
            try keychain.setSecret(token, plugin: "live", name: "cloudflareToken")
            let accounts = try await cf("GET", "/accounts", token: token)
            guard let account = (accounts["result"] as? [[String: Any]])?.first?["id"] as? String else {
                throw WireError("cf", "That token can't see a Cloudflare account. Create it with Account → Workers Scripts: Edit and Workers KV Storage: Edit.")
            }
            accountID = account
            // The 7-day store.
            let list = try await cf("GET", "/accounts/\(account)/storage/kv/namespaces?per_page=100", token: token)
            if let existing = (list["result"] as? [[String: Any]])?.first(where: { $0["title"] as? String == Self.script })?["id"] as? String {
                namespaceID = existing
            } else {
                let made = try await cf("POST", "/accounts/\(account)/storage/kv/namespaces", token: token, json: ["title": Self.script])
                namespaceID = (made["result"] as? [String: Any])?["id"] as? String
            }
            guard let kv = namespaceID else { throw WireError("cf", "Cloudflare didn't create the store.") }
            // A fresh private key for this Mac on every deploy.
            let relay = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
            try keychain.setSecret(relay, plugin: "live", name: "relayKey")
            try await upload(account: account, kv: kv, relayKey: relay, token: token)
            _ = try await cf("POST", "/accounts/\(account)/workers/scripts/\(Self.script)/subdomain", token: token,
                             json: ["enabled": true, "previews_enabled": false])
            let sub = try await cf("GET", "/accounts/\(account)/workers/subdomain", token: token)
            guard let name = (sub["result"] as? [String: Any])?["subdomain"] as? String, !name.isEmpty else {
                throw WireError("cf", "Open Workers & Pages in Cloudflare once to choose your free workers.dev name, then try again.")
            }
            url = "https://\(Self.script).\(name).workers.dev"
            status = "Ready. Paste the address below into App Store Connect."
            start()
        } catch {
            status = (error as? WireError)?.message ?? "Couldn't set it up: \(error.localizedDescription)"
        }
    }

    /// Deploys the webhook-only worker (separate name and store) and leaves the purchase source exactly as it is.
    func deployHooks(token: String) async {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        if activateAscEventRelayOnDeploy || defaults.bool(forKey: "HMActivateAscEventRelay") {
            deployAscEventQueueV2 = true
        }
        let priorHookURL = hookURL
        busy = true
        defer { busy = false }
        do {
            try keychain.setSecret(token, plugin: "live", name: "hookCloudflareToken")
            let accounts = try await cf("GET", "/accounts", token: token)
            let account = try WorkerDeployMetadata.pickHookDeployAccount(
                list: accounts["result"] as? [[String: Any]] ?? [],
                pinned: hookAccount ?? defaults.string(forKey: "HMHookAccount"))
            defaults.set(account, forKey: "HMAscProbeDeployAccountUsed")
            var kv = hookKV ?? defaults.string(forKey: "HMHookKV")
            if kv == nil {
                let list = try await cf("GET", "/accounts/\(account)/storage/kv/namespaces?per_page=100", token: token)
                kv = (list["result"] as? [[String: Any]])?.first(where: { $0["title"] as? String == Self.hookScript })?["id"] as? String
                if kv == nil {
                    let made = try await cf("POST", "/accounts/\(account)/storage/kv/namespaces", token: token, json: ["title": Self.hookScript])
                    kv = (made["result"] as? [String: Any])?["id"] as? String
                }
            } else {
                defaults.set("pinned", forKey: "HMAscProbeDeployKvSource")
            }
            guard let kv else { throw WireError("cf", "Cloudflare didn't create the store.") }
            // Keep the Mac's relay key when updating bindings (v2 upgrade or resync). Rotating here breaks stream/auth until Settings is used again.
            let relay: String
            if let saved = try keychain.secret(plugin: "live", name: "hookRelayKey")?.trimmingCharacters(in: .whitespacesAndNewlines), !saved.isEmpty {
                relay = saved
            } else {
                relay = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
                try keychain.setSecret(relay, plugin: "live", name: "hookRelayKey")
            }
            var includeMigrations = deployAscEventQueueV2
            if let probeBase = priorHookURL ?? hookURL, let probeKey = liveSecret("hookRelayKey"),
               let caps = await AscWebhookStream.fetchCapabilities(baseURL: probeBase, relayKey: probeKey),
               caps.asc_queue_v2 {
                includeMigrations = false
                defaults.set(false, forKey: "HMAscProbeDeployIncludeMigrations")
            } else {
                defaults.set(includeMigrations, forKey: "HMAscProbeDeployIncludeMigrations")
            }
            try await upload(account: account, kv: kv, relayKey: relay, token: token, script: Self.hookScript, includeMigrations: includeMigrations)
            try await syncHookWorkerSecret(account: account, script: Self.hookScript, token: token, name: "RELAY_KEY", text: relay, defaultsKey: "HMAscProbeRelaySecretPutHTTP")
            try await syncHookWorkerSecret(account: account, script: Self.hookScript, token: token, name: "ASC_WEBHOOK_SECRET", text: ascWebhookSecret(), defaultsKey: "HMAscProbeAscWebhookSecretPutHTTP")
            defaults.removeObject(forKey: "HMAscProbeDeployCfError")
            defaults.removeObject(forKey: "HMAscProbeDeployCfErrorCode")
            hookAccount = account; hookKV = kv
            if let priorHookURL, hasHookWorker {
                hookURL = priorHookURL
                defaults.set("kept", forKey: "HMAscProbeDeployHookURL")
            } else {
                _ = try await cf("POST", "/accounts/\(account)/workers/scripts/\(Self.hookScript)/subdomain", token: token,
                                 json: ["enabled": true, "previews_enabled": false])
                let sub = try await cf("GET", "/accounts/\(account)/workers/subdomain", token: token)
                guard let name = (sub["result"] as? [String: Any])?["subdomain"] as? String, !name.isEmpty else {
                    throw WireError("cf", "Open Workers & Pages in Cloudflare once to choose your free workers.dev name, then try again.")
                }
                hookURL = "https://\(Self.hookScript).\(name).workers.dev"
            }
            defaults.set(true, forKey: "HMAscProbeDeployPutOK")
            if let base = hookURL, let key = liveSecret("hookRelayKey") {
                let verify = await AscWebhookStream.relayAuthHTTPStatus(baseURL: base, relayKey: key)
                defaults.set(verify ?? -1, forKey: "HMAscProbeEventsHTTPAfterDeploy")
            }
            status = "Webhook worker ready. Create the webhook in App Store Connect with the address below."
            if deployAscEventQueueV2, let hookURL, let key = secret("hookRelayKey"),
               let caps = await AscWebhookStream.fetchCapabilities(baseURL: hookURL, relayKey: key),
               caps.asc_queue_v2 {
                ascStream.enabled = true
            }
            start()
        } catch {
            defaults.set(false, forKey: "HMAscProbeDeployPutOK")
            if let err = error as? WireError {
                defaults.set(err.message, forKey: "HMAscProbeDeployCfError")
                defaults.set(err.code, forKey: "HMAscProbeDeployCfErrorCode")
            }
            if hookURL == nil { for n in ["hookCloudflareToken", "hookRelayKey"] { keychain.deleteSecret(plugin: "live", name: n) } }
            status = (error as? WireError)?.message ?? "Couldn't set it up: \(error.localizedDescription)"
        }
    }

    /// Deletes only the webhook worker and its store; purchases are untouched.
    func removeHooks() async {
        busy = true
        defer { busy = false }
        if let token = secret("hookCloudflareToken"), let account = hookAccount {
            _ = try? await cf("DELETE", "/accounts/\(account)/workers/scripts/\(Self.hookScript)?force=true", token: token)
            if let kv = hookKV { _ = try? await cf("DELETE", "/accounts/\(account)/storage/kv/namespaces/\(kv)", token: token) }
        }
        for n in ["hookCloudflareToken", "hookRelayKey"] { keychain.deleteSecret(plugin: "live", name: n) }
        hookURL = nil; hookAccount = nil; hookKV = nil; webhookSince = 0
        ascStream.stop()
        defaults.set(false, forKey: AscStreamProtocol.streamEnabledKey)
        AscStreamProtocol.resetProbeTelemetry(defaults)
        status = "Webhook worker removed from your Cloudflare account."
    }

    /// Deletes the worker and its store from your Cloudflare account and forgets the keys.
    func remove() async {
        busy = true
        defer { busy = false }
        poller?.cancel()
        let had = ownWorker
        if let token = secret("cloudflareToken"), let account = accountID {
            _ = try? await cf("DELETE", "/accounts/\(account)/workers/scripts/\(Self.script)?force=true", token: token)
            if let kv = namespaceID { _ = try? await cf("DELETE", "/accounts/\(account)/storage/kv/namespaces/\(kv)", token: token) }
        }
        for n in ["cloudflareToken", "relayKey"] { keychain.deleteSecret(plugin: "live", name: n) }
        url = nil; accountID = nil; namespaceID = nil; since = 0
        defaults.removeObject(forKey: "HMLiveOutbox")
        status = had ? "Removed from your Cloudflare account." : "Disconnected. Nothing was deleted."
    }

    private func upload(account: String, kv: String, relayKey: String, token: String, script: String = LivePurchases.script, includeMigrations: Bool = true) async throws {
        guard let folder = Bundle.main.resourceURL?.appending(path: "LiveWorker"),
              FileManager.default.fileExists(atPath: folder.appending(path: "worker.mjs").path)
        else { throw WireError("cf", "The worker files are missing from the app.") }
        let modules = ["worker.mjs", "workerCore.mjs", "ascKvImport.mjs", "verify.mjs", "x509.mjs", "root.mjs", "ascRelayDO.mjs"]
        // Your apps' bundle ids (from "App names" above), so the worker refuses notifications for anyone else's app.
        let bundleIDs = Self.bundleIDs(appNames) ?? ""
        var bindings: [[String: Any]] = [
                ["type": "kv_namespace", "name": "OUTBOX", "namespace_id": kv],
                ["type": "secret_text", "name": "RELAY_KEY", "text": relayKey],
                // The secret you give App Store Connect when you create a webhook (see ascWebhookSecret).
                ["type": "secret_text", "name": "ASC_WEBHOOK_SECRET", "text": ascWebhookSecret()],
        ]
        if !bundleIDs.isEmpty { bindings.append(["type": "plain_text", "name": "BUNDLE_IDS", "text": bundleIDs]) }
        let deployV2 = script == Self.hookScript && deployAscEventQueueV2
        var metadata = Self.hooksWorkerUploadMetadata(
            kv: kv, relayKey: relayKey, ascSecret: ascWebhookSecret(), bundleIDs: bundleIDs, deployV2: deployV2,
            includeMigrations: deployV2 && includeMigrations)
        if script != Self.hookScript {
            metadata = [
                "main_module": "worker.mjs",
                "compatibility_date": "2026-10-01",
                "bindings": bindings,
            ]
        }
        let boundary = "hm-\(UUID().uuidString)"
        var body = Data()
        func part(_ name: String, _ filename: String?, _ type: String, _ data: Data) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"".utf8))
            if let filename { body.append(Data("; filename=\"\(filename)\"".utf8)) }
            body.append(Data("\r\nContent-Type: \(type)\r\n\r\n".utf8))
            body.append(data)
            body.append(Data("\r\n".utf8))
        }
        part("metadata", nil, "application/json", try JSONSerialization.data(withJSONObject: metadata))
        for m in modules {
            part(m, m, "application/javascript+module", try Data(contentsOf: folder.appending(path: m)))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        guard let url = URL(string: "https://api.cloudflare.com/client/v4/accounts/\(account.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")/workers/scripts/\(script)") else { throw WireError("cloudflare_account", "Cloudflare returned an account id Hmunmawi can't use.") }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await Self.session.data(for: request)
        let putHTTP = (response as? HTTPURLResponse)?.statusCode ?? -1
        defaults.set(putHTTP, forKey: "HMAscProbeDeployPutHTTP")
        try Self.check(data, response)
    }

    /// Uses an outbox you already run (for example your own server's /api/asn/outbox) with its relay key.
    func connect(outbox: String, key: String) async {
        let outbox = outbox.trimmingCharacters(in: .whitespaces), key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard outbox.hasPrefix("https://"), !key.isEmpty else { status = "Use the outbox's https address and its key."; return }
        try? keychain.setSecret(key, plugin: "live", name: "relayKey")
        defaults.set(outbox, forKey: "HMLiveOutbox")
        url = outbox
        since = Date.now.timeIntervalSince1970 * 1000 - 3 * 86_400_000   // pick up the last 3 days once
        status = nil
        await collect()
        if status == nil { status = "Connected. Purchases arrive as Apple reports them." }
        start()
    }

    // MARK: Keeping the worker up to date

    /// The worker code this app carries (WORKER_CODE_VERSION in Resources/LiveWorker/workerCore.mjs; a test keeps them equal).
    nonisolated static let workerCodeVersion = 2
    /// A deployed worker is older when it reports a lower code version, or none (workers before 1.5.2).
    nonisolated static func workerNeedsUpdate(deployed: Int?, current: Int = workerCodeVersion) -> Bool { (deployed ?? 0) < current }
    /// One automatic try per code version: a failed update is never retried in a loop; Update worker in Settings tries again.
    nonisolated static func mayAutoUpdate(triedVersion: Int, current: Int = workerCodeVersion) -> Bool { triedVersion < current }
    static let workerUpdateTriedKey = "HMHookWorkerUpdateTried"

    /// Updates the webhook worker to this app's worker code when the deployed one is older, with the saved Cloudflare
    /// token, keeping its address, store and relay key (deployHooks does that). At most once per code version.
    func updateHooksWorkerIfOutdated(caps: AscWebhookStream.Capabilities?) async {
        guard let caps, caps.asc_queue_v2, Self.workerNeedsUpdate(deployed: caps.code_version),
              Self.mayAutoUpdate(triedVersion: defaults.integer(forKey: Self.workerUpdateTriedKey)) else { return }
        defaults.set(Self.workerCodeVersion, forKey: Self.workerUpdateTriedKey)
        guard let token = liveSecret("hookCloudflareToken") else {
            status = "Your webhook worker is an older version. Paste a Cloudflare token and press Update worker (Settings → Connections → Live sales)."
            return
        }
        _ = await updateHooksWorker(token: token)
    }

    /// Redeploys the webhook worker with this app's code and checks that it now reports the current code version.
    @discardableResult
    func updateHooksWorker(token: String) async -> Bool {
        guard hasHookWorker else { status = "No webhook worker to update."; return false }
        deployAscEventQueueV2 = true   // keep the event queue the running worker already has
        await deployHooks(token: token)
        guard defaults.bool(forKey: "HMAscProbeDeployPutOK") else {
            status = "Couldn't update the webhook worker: \(status ?? "Cloudflare refused it"). It keeps running as before."
            return false
        }
        if let base = hookURL, let key = liveSecret("hookRelayKey") {
            for _ in 0..<5 {   // Cloudflare can serve the old code for a few seconds after an upload
                if let c = await AscWebhookStream.fetchCapabilities(baseURL: base, relayKey: key), !Self.workerNeedsUpdate(deployed: c.code_version) {
                    defaults.set(Self.workerCodeVersion, forKey: "HMHookWorkerCodeVersion")
                    status = "Webhook worker updated (version \(Self.workerCodeVersion))."
                    return true
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        status = "Webhook worker uploaded; it will report the new version shortly."
        return true
    }

    /// Updates the purchase worker you deployed here with this app's code (same token; a fresh relay key, as on setup).
    func updatePurchaseWorker() async {
        guard ownWorker, let token = liveSecret("cloudflareToken") else {
            status = "Paste a Cloudflare token to update the worker."
            return
        }
        await deploy(token: token)
    }

    func updateHooksWorkerWithSavedToken() async {
        guard let token = liveSecret("hookCloudflareToken") else { status = "Paste a Cloudflare token to update the worker."; return }
        await updateHooksWorker(token: token)
    }

    /// Whether a saved Cloudflare token can update a worker without typing one (read from the Keychain by
    /// `refreshSavedTokens`, never while a view draws).
    private(set) var hasSavedHookToken = false
    private(set) var hasSavedPurchaseToken = false
    var canUpdateHooksWorker: Bool { hasHookWorker && hasSavedHookToken }
    var canUpdatePurchaseWorker: Bool { ownWorker && hasSavedPurchaseToken }
    func refreshSavedTokens() {
        hasSavedHookToken = keychainPresence("hookCloudflareToken") == .present
        hasSavedPurchaseToken = keychainPresence("cloudflareToken") == .present
    }

    // MARK: Collecting

    /// Collects new purchases every minute while the app runs.
    /// One-shot hooks worker upgrade when `HMActivateAscEventRelay` is set (uses Keychain token; no purchase path changes).
    func upgradeHooksToEventRelayIfNeeded() async {
        await recordStartupRelayProbe()
        if wantsAscEventStream() {
            defaults.set(true, forKey: AscStreamProtocol.streamEnabledKey)
        }
        let hookRelayPresence = keychainPresence("hookRelayKey")
        guard wantsAscEventStream() else {
            recordRelaySuppressReason("asc_event_stream_off")
            AscStreamProtocol.resetProbeTelemetry(defaults)
            return
        }
        guard hasHookWorker else {
            recordRelaySuppressReason("no_hook_worker_url")
            return
        }
        guard let base = hookURL else {
            recordRelaySuppressReason("hook_url_missing")
            return
        }
        let cfTokenPresence = keychainPresence("hookCloudflareToken")
        defaults.set(hookRelayPresence.rawValue, forKey: "HMAscProbeHookRelayKey")
        defaults.set(cfTokenPresence.rawValue, forKey: "HMAscProbeHookCfToken")
        guard let key = liveSecret("hookRelayKey") else {
            ascRelayAuthorized = false
            if hookRelayPresence == .unreadable {
                recordRelaySuppressReason("hook_relay_key_unreadable")
                return
            }
            defaults.set(false, forKey: AscStreamProtocol.streamEnabledKey)
            ascStream.enabled = false
            recordRelaySuppressReason("hook_relay_key_absent")
            return
        }
        let caps = await AscWebhookStream.fetchCapabilities(baseURL: base, relayKey: key)
        ascWorkerUsesEventQueue = caps?.asc_queue_v2 == true
        let eventsHTTP = await AscWebhookStream.relayAuthHTTPStatus(baseURL: base, relayKey: key)
        defaults.set(eventsHTTP ?? -1, forKey: "HMAscProbeEventsHTTP")
        ascRelayAuthorized = eventsHTTP == 200
        if eventsHTTP == 200 {
            defaults.set(true, forKey: "HMHookV2Live")
            defaults.set(true, forKey: AscStreamProtocol.streamEnabledKey)
            ascStream.enabled = true
            startAscStreamIfNeeded()
            if await waitForStreamHandshake(maxWaitSec: 20) == false {
                _ = await ascStream.boundedHttpCatchUp(baseURL: base, relayKey: key, source: .httpStartup)
            }
            await importKvBacklogIfNeeded(base: base, key: key, kvImportEnabled: caps?.kv_import == true)
            recordRelaySuppressReason("none")
            await updateHooksWorkerIfOutdated(caps: caps)
            return
        }
        guard caps?.asc_queue_v2 == true else {
            recordRelaySuppressReason("worker_not_v2")
            guard cfTokenPresence == .present, let token = liveSecret("hookCloudflareToken") else {
                recordRelaySuppressReason(cfTokenPresence == .unreadable ? "hook_cf_token_unreadable" : "hook_cf_token_absent")
                return
            }
            if defaults.bool(forKey: "HMHookV2DeployFailed") {
                recordRelaySuppressReason("HMHookV2DeployFailed")
                return
            }
            deployAscEventQueueV2 = true
            await deployHooks(token: token)
            if status?.hasPrefix("Couldn't") == true || status?.contains("refused") == true {
                defaults.set(true, forKey: "HMHookV2DeployFailed")
            }
            return
        }
        ascStream.stop()
        ascWorkerUsesEventQueue = true
        if eventsHTTP == 401, cfTokenPresence == .present, let token = liveSecret("hookCloudflareToken"), !ascRelayResyncAttempted {
            ascRelayResyncAttempted = true
            defaults.set(true, forKey: "HMAscProbeCfResyncAttempted")
            deployAscEventQueueV2 = true
            await deployHooks(token: token)
            let retryHTTP = await AscWebhookStream.relayAuthHTTPStatus(baseURL: base, relayKey: key)
            defaults.set(retryHTTP ?? -1, forKey: "HMAscProbeEventsHTTPAfterResync")
            ascRelayAuthorized = retryHTTP == 200
            if retryHTTP == 200 {
                defaults.set(true, forKey: "HMHookV2Live")
                ascStream.enabled = true
                startAscStreamIfNeeded()
                if await waitForStreamHandshake(maxWaitSec: 20) == false {
                    _ = await ascStream.boundedHttpCatchUp(baseURL: base, relayKey: key, source: .httpStartup)
                }
                await importKvBacklogIfNeeded(base: base, key: key, kvImportEnabled: caps?.kv_import == true)
                recordRelaySuppressReason("none")
            } else {
                recordRelaySuppressReason("events_http_\(retryHTTP ?? -1)_after_resync")
            }
            return
        }
        recordRelaySuppressReason(eventsHTTP.map { "events_http_\($0)" } ?? "events_http_unreachable")
        if cfTokenPresence != .present {
            recordRelaySuppressReason(cfTokenPresence == .unreadable ? "hook_cf_token_unreadable" : "hook_cf_token_absent")
        }
    }

    func start() {
        guard deployed || hasHookWorker, poller == nil || poller?.isCancelled == true else { return }
        startAscStreamIfNeeded()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.collect()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func startAscStreamIfNeeded() {
        let base: String?, key: String?
        if let h = hookURL { base = h; key = liveSecret("hookRelayKey") }
        else if ownWorker, let u = url { base = u; key = liveSecret("relayKey") }
        else { return }
        guard let base, let key, ascStream.enabled, ascRelayAuthorized else { return }
        Task { @MainActor in
            guard let caps = await AscWebhookStream.fetchCapabilities(baseURL: base, relayKey: key), caps.asc_queue_v2 else {
                ascStream.stop()
                return
            }
            ascStream.start(baseURL: base, relayKey: key)
        }
    }

    func collect() async {
        // The Pages outbox key is live/relayKey; older setups only stored it as hookRelayKey (same RELAY_KEY file).
        guard let outbox = outboxURL, let key = secret("relayKey") ?? secret("hookRelayKey"),
              var comps = URLComponents(string: outbox) else { await collectWebhooks(); return }
        comps.queryItems = [URLQueryItem(name: "since", value: String(Int64(since)))]
        var request = URLRequest(url: comps.url!, timeoutInterval: 30)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await Self.session.data(for: request)
            try Self.check(data, response)
            let items = ((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["items"] as? [[String: Any]]) ?? []
            lastCheck = .now
            var events: [Event] = []
            for item in items {
                let t = (item["at"] as? Double) ?? Double(String((item["key"] as? String ?? "").dropFirst(3).prefix(13))) ?? 0
                if t > since { since = t }
                if item["type"] as? String == "TEST" { lastTestAt = .now; defaults.set(lastTestAt, forKey: "HMLiveTest"); continue }
                if let e = event(item) { events.append(e) }
            }
            if !events.isEmpty { await onEvents?(events) }
            await collectWebhooks()
            if status?.hasPrefix("Couldn't reach") == true { status = nil }
        } catch {
            status = "Couldn't reach your worker: \((error as? WireError)?.message ?? error.localizedDescription)"
        }
    }

    /// App Store Connect webhook notifications (state changes), from the worker's /asc/outbox. A failure here never
    /// affects purchases: it is only noted, and the next minute tries again.
    private var webhookSince: Double { get { defaults.double(forKey: "HMLiveWebhookSinceMs") } set { defaults.set(newValue, forKey: "HMLiveWebhookSinceMs") } }
    /// Set by the app model: names an App Store version id ("Pulse Diary 4.1.7"), when the app knows it.
    var versionName: ((String) -> String?)?

    private func collectWebhooks() async {
        let base: String?, key: String?
        if let h = hookURL { base = h; key = liveSecret("hookRelayKey") } else { base = ownWorker ? url : nil; key = liveSecret("relayKey") }
        guard let base, let key else { return }
        if ascStream.enabled {
            if ascStream.prefersPushOverHttpPolling { return }
            _ = await ascStream.boundedHttpCatchUp(baseURL: base, relayKey: key, source: .httpCatchup)
            return
        }
        if ascWorkerUsesEventQueue {
            _ = await collectWebhooksFromSeq(base: base, key: key, source: .httpCatchup)
            return
        }
        guard var comps = URLComponents(string: base + "/asc/outbox") else { return }
        comps.queryItems = [URLQueryItem(name: "since", value: String(Int64(webhookSince)))]
        var request = URLRequest(url: comps.url!, timeoutInterval: 30)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await Self.session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let items = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["items"] as? [[String: Any]] else { return }
        await ingestWebhookItems(items)
    }

    /// DO seq catch-up over HTTP (no KV `list`); used when v2 is live but WebSocket is not delivering yet.
    private func waitForStreamHandshake(maxWaitSec: Int) async -> Bool {
        let deadline = Date.now.addingTimeInterval(TimeInterval(maxWaitSec))
        while Date.now < deadline {
            if defaults.string(forKey: AscStreamProtocol.Telemetry.stateKey) == "open",
               defaults.double(forKey: AscStreamProtocol.Telemetry.handshakeMsKey) > 0 {
                return true
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return ascStream.prefersPushOverHttpPolling
    }

    @discardableResult
    private func collectWebhooksFromSeq(base: String, key: String, source: AscStreamProtocol.ApplySource) async -> Bool {
        let after = ascStream.appliedSeq
        guard var comps = URLComponents(string: base + "/asc/events") else { return false }
        comps.queryItems = [
            URLQueryItem(name: "after_seq", value: String(after)),
            URLQueryItem(name: "limit", value: "200"),
        ]
        var request = URLRequest(url: comps.url!, timeoutInterval: 30)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await Self.session.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        if http.statusCode == 401 {
            ascRelayAuthorized = false
            ascRelayDelivering = false
            defaults.set(401, forKey: "HMAscProbeEventsHTTP")
            return false
        }
        guard http.statusCode == 200 else { return false }
        ascRelayAuthorized = true
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = body["items"] as? [[String: Any]] else { return false }
        let mapped = items.map { item -> [String: Any] in
            var row = item
            if row["id"] == nil, let eid = row["event_id"] as? String { row["id"] = eid }
            return row
        }
        guard !mapped.isEmpty else { return false }
        let seqBefore = ascStream.appliedSeq
        do {
            try await persistAscWebhookItems(mapped)
            if let maxSeq = items.compactMap({ $0["seq"] as? Int64 }).max() {
                ascStream.appliedSeq = max(ascStream.appliedSeq, maxSeq)
            }
            if ascStream.appliedSeq > seqBefore {
                ascRelayDelivering = true
                defaults.set(source.rawValue, forKey: AscStreamProtocol.Telemetry.lastApplySourceKey)
            }
            return ascStream.appliedSeq > seqBefore
        } catch {
            status = "ASC webhook events could not be saved locally. Worker still has them; fix disk access and retry."
            return false
        }
    }

    /// Bounded KV pages per startup (`budget=1` list op each); checkpoint on worker; idempotent by event id.
    private func importKvBacklogIfNeeded(base: String, key: String, kvImportEnabled: Bool) async {
        guard kvImportEnabled, ascRelayAuthorized else { return }
        let nowMs = Date.now.timeIntervalSince1970 * 1000
        if let until = defaults.object(forKey: "HMKvImportQuotaUntilMs") as? Double, until > nowMs {
            defaults.set(Int(until), forKey: "HMAscProbeKvImportPausedUntilMs")
            return
        }
        var complete = false
        for op in 0..<Self.kvImportListOpsPerStartup where !complete {
            guard let url = URL(string: base + "/asc/import/kv?budget=1&kv_cursor=resume") else { return }
            var request = URLRequest(url: url, timeoutInterval: 60)
            request.httpMethod = "POST"
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            guard let (data, response) = try? await Self.session.data(for: request),
                  let http = response as? HTTPURLResponse else { return }
            let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            defaults.set(http.statusCode, forKey: "HMAscProbeKvImportLastHTTP")
            if http.statusCode == 401 { return }
            let errBlob = String(describing: body).lowercased()
            if http.statusCode == 429 || errBlob.contains("quota") || errBlob.contains("limit exceeded") || errBlob.contains("too many") {
                defaults.set(Self.nextUtcMidnightMs(), forKey: "HMKvImportQuotaUntilMs")
                defaults.set(true, forKey: "HMAscProbeKvImportQuotaHit")
                return
            }
            guard (200..<300).contains(http.statusCode) else { return }
            complete = body["list_complete"] as? Bool == true
            if (body["imported"] as? Int ?? 0) > 0, !ascStream.prefersPushOverHttpPolling {
                _ = await collectWebhooksFromSeq(base: base, key: key, source: .httpCatchup)
            }
        }
        defaults.set(complete, forKey: "HMAscProbeKvImportComplete")
    }

    private enum KeychainPresence: String {
        case absent, present, unreadable
    }

    private func keychainPresence(_ name: String) -> KeychainPresence {
        do {
            guard let v = try keychain.secret(plugin: "live", name: name) else { return .absent }
            return v.isEmpty ? .absent : .present
        } catch is WireError {
            return .unreadable
        } catch {
            return .unreadable
        }
    }

    private func recordRelaySuppressReason(_ reason: String) {
        defaults.set(reason, forKey: "HMAscRelaySuppressReason")
        defaults.set(Date.now.timeIntervalSince1970 * 1000, forKey: "HMAscProbeAtMs")
    }

    private func wantsAscEventStream() -> Bool {
        AscStreamProtocol.wantsEventStream(
            defaults: defaults, activateAscEventRelay: defaults.bool(forKey: "HMActivateAscEventRelay"),
            hookV2Live: defaults.bool(forKey: "HMHookV2Live"), hasHookWorker: hasHookWorker)
    }

    private func recordStartupRelayProbe() async {
        defaults.set(Date.now.timeIntervalSince1970 * 1000, forKey: "HMAscProbeAtMs")
        if let outbox = outboxURL, let key = keychainPresence("relayKey") == .present ? liveSecret("relayKey") : nil,
           var comps = URLComponents(string: outbox) {
            comps.queryItems = [URLQueryItem(name: "since", value: "0")]
            var request = URLRequest(url: comps.url!, timeoutInterval: 20)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            if let (_, response) = try? await Self.session.data(for: request), let http = response as? HTTPURLResponse {
                defaults.set(http.statusCode, forKey: "HMAscProbePurchaseOutboxHTTP")
            } else {
                defaults.set(-1, forKey: "HMAscProbePurchaseOutboxHTTP")
            }
        } else {
            defaults.set(keychainPresence("relayKey").rawValue, forKey: "HMAscProbePurchaseRelayKey")
        }
        if let base = hookURL, defaults.string(forKey: "HMAscProbeHookRelayKey") == nil {
            defaults.set(keychainPresence("hookRelayKey").rawValue, forKey: "HMAscProbeHookRelayKey")
        }
    }

    private static func nextUtcMidnightMs() -> Double {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let start = cal.startOfDay(for: .now)
        guard let next = cal.date(byAdding: .day, value: 1, to: start) else {
            return Date.now.timeIntervalSince1970 * 1000 + 24 * 3_600_000
        }
        return next.timeIntervalSince1970 * 1000
    }

    private static func utcDayString() -> String {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: .now)
    }

    private static func shortIST(_ ms: Double) -> String {
        let d = Date(timeIntervalSince1970: ms / 1000)
        let f = DateFormatter()
        f.timeZone = Extras.current.zone   // the Mac's own time zone (or a fixed one from Your extras)
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: d)
    }

    private func ingestWebhookItems(_ items: [[String: Any]]) async {
        var events: [Event] = []
        for i in items {
            let at = (i["at"] as? Double) ?? 0
            if at > webhookSince { webhookSince = at }
            if let e = Self.webhookEvent(i, versionName: versionName) { events.append(e) }
        }
        if !events.isEmpty { await onEvents?(events) }
    }

    /// One webhook item → an `asc.webhook` event with a plain-words title. States are shown as Apple names them, only
    /// made readable ("WAITING_FOR_REVIEW" → "Waiting for review").
    static func webhookEvent(_ i: [String: Any], versionName: ((String) -> String?)? = nil) -> Event? {
        guard let type = i["type"] as? String, let id = (i["id"] as? String) ?? (i["key"] as? String) else { return nil }
        func pretty(_ s: String?) -> String? {
            guard let s, !s.isEmpty else { return nil }
            let t = s.replacingOccurrences(of: "_", with: " ").lowercased()
            return t.prefix(1).uppercased() + t.dropFirst()
        }
        let from = pretty(i["from"] as? String), to = pretty(i["to"] as? String)
        let what = (i["instanceId"] as? String).flatMap { versionName?($0) }
        let generic: String = switch type {
        case "appStoreVersionAppVersionStateUpdated": "An App Store version"
        case "buildBetaDetailExternalBuildStateUpdated": "A TestFlight build"
        case "betaFeedbackScreenshotSubmissionCreated": "TestFlight feedback with a screenshot"
        case "betaFeedbackCrashSubmissionCreated": "A TestFlight crash report"
        case "webhookPingCreated": "Apple's test ping"
        default: "An App Store Connect update"
        }
        let subject = what ?? generic
        let change = to.map { "\(from.map { $0 + " → " } ?? "")\($0)" }
        let at = Int64(safe: (i["at"] as? Double) ?? Date.now.timeIntervalSince1970 * 1000)
        let bad = (i["to"] as? String)?.contains("REJECTED") == true
        return Event(source: "appstoreconnect-webhook", kind: "asc.webhook", app: nil,
                     payload: .object(["title": .string(change.map { "\(subject): \($0)" } ?? (type == "webhookPingCreated" ? "Apple's test ping arrived: live updates work" : "\(subject) arrived")), "type": .string(type), "from": .string(from ?? ""), "to": .string(to ?? ""),
                                       "rejected": .bool(bad), "instance": .string((i["instanceId"] as? String) ?? "")]),
                     occurredAt: at, dedupeKey: "ascwh:\(id)")
    }

    /// Set by the app model: stores new events like any other source.
    var onEvents: (([Event]) async -> Void)?

    /// Apple's notification → the same event the rest of the app shows (ticker, sale moment, Money).
    func event(_ i: [String: Any]) -> Event? {
        if i["title"] != nil, let uuid = i["uuid"] as? String { return hubEvent(i, uuid: uuid) }
        guard i["environment"] as? String != "Sandbox" else { return nil }   // test purchases aren't sales
        let type = i["type"] as? String ?? "", sub = i["subtype"] as? String
        let kind: String? = switch type {
        case "SUBSCRIBED", "ONE_TIME_CHARGE": "revenue.purchase"
        case "DID_RENEW": "revenue.renewal"
        case "DID_CHANGE_RENEWAL_STATUS" where sub == "AUTO_RENEW_DISABLED": "revenue.cancelled"
        case "EXPIRED": "revenue.expired"
        case "REFUND": "revenue.refund"
        default: nil
        }
        guard let kind else { return nil }
        let bundle = i["bundleId"] as? String ?? ""
        let product = i["product"] as? String ?? ""
        var facts: [String: JSONValue] = ["product": .string(product)]
        var detail = Self.plan(product)
        if let price = i["price"] as? Double, let currency = i["currency"] as? String {
            facts["price"] = .number(price)
            facts["currency"] = .string(currency)
            detail += " · " + price.formatted(.currency(code: currency))
        }
        if let s = i["storefront"] as? String { facts["storefront"] = .string(s) }
        if i["inFamily"] as? Bool == true { facts["family"] = .bool(true) }
        let given = i["at"] as? Double
        let at = Int64(safe: given ?? Date.now.timeIntervalSince1970 * 1000)
        // Fallback key from the item itself, never from the time we read it (that made each re-read a new alert).
        let tx = (i["transactionId"] as? String) ?? (i["originalTransactionId"] as? String) ?? given.map { String(Int64(safe: $0)) } ?? ""

        return Event(source: "live", kind: kind, app: name(for: bundle),
                     payload: .object(["detail": .string(detail), "facts": .object(facts)]),
                     occurredAt: at, dedupeKey: "live:\(i["key"] as? String ?? "\(type)|\(bundle)|\(product)|\(tx)")")   // no key: one built from the item itself, so a resend is a duplicate, not a second alert
    }

    /// An item from an external outbox your own scripts fill ("My App New sale", body line, facts). Same key as the
    /// script feed uses, so a purchase that also arrives through the feed is stored once.
    private func hubEvent(_ i: [String: Any], uuid: String) -> Event? {
        let title = i["title"] as? String ?? "", tags = i["tags"] as? String ?? ""
        guard tags != "test_tube" else { return nil }
        let known = appNames.split(separator: ",").compactMap { $0.split(separator: "=").last.map { $0.trimmingCharacters(in: .whitespaces) } }
            + APPName.known
        let app = known.first { title.hasPrefix($0 + " ") } ?? String(title.split(separator: " ").first ?? "")
        let label = title.hasPrefix(app) ? String(title.dropFirst(app.count)).trimmingCharacters(in: .whitespaces) : title
        let l = label.lowercased()
        let kind: String? = tags == "gift" ? "revenue.free"
            : l.contains("renew") ? "revenue.renewal" : l.contains("refund") ? "revenue.refund"
            : l.contains("cancel") ? "revenue.cancelled" : l.contains("expire") ? "revenue.expired"
            : (l.contains("sale") || l.contains("purchase") || l.contains("subscri")) ? "revenue.purchase" : nil
        guard let kind else { return nil }
        var p: [String: JSONValue] = ["label": .string(label), "detail": .string(i["body"] as? String ?? ""), "uuid": .string(uuid)]
        if let f = i["flag"] as? String { p["flag"] = .string(f) }
        if let s = i["storefront"] as? String { p["storefront"] = .string(s) }
        if let facts = i["facts"], let data = try? JSONSerialization.data(withJSONObject: facts), let v = try? JSONValue.parse(String(decoding: data, as: UTF8.self)) { p["facts"] = v }
        let given = i["at"] as? Double
        let at = Int64(safe: given ?? Date.now.timeIntervalSince1970 * 1000)
        // Fallback key from the item itself, never from the time we read it (that made each re-read a new alert).
        let tx = (i["transactionId"] as? String) ?? (i["originalTransactionId"] as? String) ?? given.map { String(Int64(safe: $0)) } ?? ""

        return Event(source: "live", kind: kind, app: app, payload: .object(p), occurredAt: at, dedupeKey: "scriptfeed:asn-\(uuid)")
    }

    /// "com.x.weekly" → "Weekly"; the plan name people know.
    static func plan(_ product: String) -> String {
        let last = product.split(separator: ".").last.map(String.init) ?? product
        for p in ["weekly", "monthly", "yearly", "annual", "lifetime"] where last.lowercased().contains(p) { return p == "annual" ? "Yearly" : p.capitalized }
        return last
    }

    private func name(for bundle: String) -> String {
        for pair in appNames.split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2, kv[0] == bundle { return kv[1] }
        }
        return bundle.split(separator: ".").last.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? bundle
    }

    // MARK: Cloudflare API

    /// The shared secret for App Store Connect webhooks (made once, kept in the Keychain). It goes to your worker when
    /// you deploy it, and you paste the same text into the webhook you create in App Store Connect.
    func ascWebhookSecret() -> String {
        if let s = secret("ascWebhookSecret"), !s.isEmpty { return s }
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let made = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        try? keychain.setSecret(made, plugin: "live", name: "ascWebhookSecret")
        return made
    }

    /// Where App Store Connect should send webhooks (only for a worker this app made).
    var ascWebhookAddress: String? { hookURL.map { $0 + "/asc" } ?? (ownWorker ? url.map { $0 + "/asc" } : nil) }

    /// The request body for creating a webhook in App Store Connect (Apple's POST /v1/webhooks), to copy. Hmunmawi never
    /// sends it: creating a webhook is a change in your App Store Connect, so you do it.
    func ascWebhookRequestBody(appID: String) -> String? {
        guard let address = ascWebhookAddress else { return nil }
        let body: [String: Any] = ["data": ["type": "webhooks", "attributes": [
            "enabled": true, "name": "Hmunmawi", "secret": ascWebhookSecret(), "url": address,
            "eventTypes": ["APP_STORE_VERSION_APP_VERSION_STATE_UPDATED"]],
            "relationships": ["app": ["data": ["type": "apps", "id": appID]]]]]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys])).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func secret(_ name: String) -> String? { liveSecret(name) }

    /// Surfaces Keychain signing mismatches instead of treating them as a missing key (the old `try?` swallow hid the real fix).
    @discardableResult
    private func liveSecret(_ name: String) -> String? {
        let catalog = SecretSourceCatalog(url: AppModel.defaultSupportDirectory().appending(path: SecretSourceCatalog.fileName))
        do {
            guard let raw = try keychain.secret(plugin: "live", name: name, catalog: catalog) else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch let err as WireError where err.code == "keychain" {
            status = err.message
            return nil
        } catch {
            status = "Couldn't read the relay key: \(plainError(error))"
            return nil
        }
    }

    private static let session = URLSession(configuration: .ephemeral)

    private static func digestPrefix(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// CLI helper: fingerprint relay key vs `asn_relay.env`, probe `GET /asc/events`, sync worker on 401 (never prints secrets).
    func probeHookRelay(log: (String) -> Void) async -> Int32 {
        KeychainSecretStore.catalogURL = AppModel.defaultSupportDirectory().appending(path: SecretSourceCatalog.fileName)
        Keychain.neverPrompt()
        var relay = (try? keychain.peekSecret(plugin: "live", name: "hookRelayKey")) ?? ""
        let canonPath = SecretSourceDefaults.keyFolder()?.appending(path: "asn_relay.env").path
        let canon = canonPath.flatMap { SecretFileReader.envValue(path: $0, key: "RELAY_KEY") } ?? ""
        log("keychain \(Self.digestPrefix(relay))")
        log("asn_relay.env \(Self.digestPrefix(canon))")
        log("local_match \(relay == canon && !canon.isEmpty)")
        if !canon.isEmpty, relay != canon {
            try? keychain.setSecret(canon, plugin: "live", name: "hookRelayKey")
            relay = canon
            log("rebound_hook_relay_from_canon")
        }
        guard !relay.isEmpty, let base = hookURL else {
            log("hook_url missing")
            return 1
        }
        var http = await AscWebhookStream.relayAuthHTTPStatus(baseURL: base, relayKey: relay)
        log("events_http \(http ?? -1)")
        if http == 401, let token = try? keychain.peekSecret(plugin: "live", name: "hookCloudflareToken"),
           let account = hookAccount ?? defaults.string(forKey: "HMAscProbeDeployAccountUsed") {
            do {
                try await syncHookWorkerSecret(account: account, script: Self.hookScript, token: token,
                                             name: "RELAY_KEY", text: relay, defaultsKey: "HMAscProbeRelaySecretPutHTTP")
                log("worker_relay_secret_put ok")
            } catch {
                log("worker_relay_secret_put fail")
                return 1
            }
            http = await AscWebhookStream.relayAuthHTTPStatus(baseURL: base, relayKey: relay)
            log("events_http_after_sync \(http ?? -1)")
        }
        return http == 200 ? 0 : 1
    }

    /// PUT one worker secret (creates a new script version); required when multipart upload does not refresh secret bindings.
    private func syncHookWorkerSecret(account: String, script: String, token: String, name: String, text: String, defaultsKey: String) async throws {
        let path = "/accounts/\(account)/workers/scripts/\(script)/secrets"
        let payload: [String: Any] = ["name": name, "text": text, "type": "secret_text"]
        let (data, response) = try await cfRaw("PUT", path, token: token, json: payload)
        defaults.set((response as? HTTPURLResponse)?.statusCode ?? -1, forKey: defaultsKey)
        try Self.check(data, response)
    }

    private func cf(_ method: String, _ path: String, token: String, json: [String: Any]? = nil) async throws -> [String: Any] {
        let (data, response) = try await cfRaw(method, path, token: token, json: json)
        try Self.check(data, response)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func cfRaw(_ method: String, _ path: String, token: String, json: [String: Any]? = nil) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: URL(string: "https://api.cloudflare.com/client/v4" + path)!, timeoutInterval: 60)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return try await Self.session.data(for: request)
    }

    private static func check(_ data: Data, _ response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            let message = ((body["errors"] as? [[String: Any]])?.first?["message"] as? String) ?? (body["error"] as? String) ?? "status \(status)"
            throw WireError("cf", status == 403 || status == 401 ? "Cloudflare refused: \(message). Check the token's permissions." : message)
        }
    }
}
