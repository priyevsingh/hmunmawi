import CryptoKit
import Foundation
import HmunmawiCore

/// Bring your own key: optional AI wording for suggestions, off until you switch it on.
///
/// What leaves the Mac: only the suggestion sentences and their numbers (never keys, purchase details,
/// customers or raw reports), straight to the provider you chose, over HTTPS (or to Ollama on this Mac).
/// The key stays in the Keychain (this Mac only, after unlock) and is only read to sign the request.
/// Results are cached by content, so the same suggestions are never sent twice.
enum AIProvider: String, CaseIterable, Identifiable, Codable {
    case claude, openai, gemini, openrouter, groq, mistral, ollama, custom
    var id: Self { self }

    var name: String {
        switch self {
        case .claude: "Claude (Anthropic)"
        case .openai: "OpenAI"
        case .gemini: "Google Gemini"
        case .openrouter: "OpenRouter"
        case .groq: "Groq"
        case .mistral: "Mistral"
        case .ollama: "Ollama (on this Mac)"
        case .custom: "Other (OpenAI-compatible)"
        }
    }

    /// The provider's own address for its OpenAI-style chat API (Claude uses its Messages API).
    var baseURL: String {
        switch self {
        case .claude: "https://api.anthropic.com/v1"
        case .openai: "https://api.openai.com/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta/openai"
        case .openrouter: "https://openrouter.ai/api/v1"
        case .groq: "https://api.groq.com/openai/v1"
        case .mistral: "https://api.mistral.ai/v1"
        case .ollama: "http://localhost:11434/v1"
        case .custom: ""
        }
    }

    var needsKey: Bool { self != .ollama }

    /// How to set aside credit just for Hmunmawi at the provider, so its spending is separate and capped there too.
    var dedicatedCreditHelp: String {
        switch self {
        case .claude: "In the Claude Console, create a workspace named Hmunmawi, give it a monthly spend limit, and create the key inside that workspace."
        case .openai: "In OpenAI, create a project named Hmunmawi with a monthly budget, and create the key inside that project."
        case .gemini: "Use a separate Google Cloud project for Hmunmawi's key and set a budget alert on it."
        case .openrouter: "In OpenRouter, create a key just for Hmunmawi and give it a credit limit."
        case .groq: "Create a key just for Hmunmawi and set spend limits in the Groq console."
        case .mistral: "Create a key just for Hmunmawi in its own workspace and set a usage limit in the Mistral console."
        case .ollama: "Runs on this Mac: nothing to pay."
        case .custom: "Create a key just for Hmunmawi and set a spending limit with your provider."
        }
    }

    var limitsURL: URL? {
        switch self {
        case .claude: URL(string: "https://platform.claude.com/settings/workspaces")
        case .openai: URL(string: "https://platform.openai.com/settings/organization/projects")
        case .gemini: URL(string: "https://console.cloud.google.com/billing/budgets")
        case .openrouter: URL(string: "https://openrouter.ai/settings/keys")
        case .groq: URL(string: "https://console.groq.com/settings/limits")
        case .mistral: URL(string: "https://console.mistral.ai/usage")
        case .ollama, .custom: nil
        }
    }
    /// A model we know is current; for the others the user types the model name from their provider.
    var suggestedModel: String { self == .claude ? "claude-opus-5-5" : "" }
    var whereToGetKey: String {
        switch self {
        case .claude: "console.anthropic.com → API keys"
        case .openai: "platform.openai.com → API keys"
        case .gemini: "aistudio.google.com → Get API key"
        case .openrouter: "openrouter.ai → Keys"
        case .groq: "console.groq.com → API keys"
        case .mistral: "console.mistral.ai → API keys"
        case .ollama: "No key: install Ollama and pull a model"
        case .custom: "Your provider's dashboard"
        }
    }
}

@MainActor @Observable
final class AISettings {
    static let shared = AISettings()
    private let defaults = UserDefaults.standard
    private let keychain = KeychainSecretStore()

    var enabled: Bool { didSet { defaults.set(enabled, forKey: "HMAIEnabled") } }
    var provider: AIProvider { didSet { defaults.set(provider.rawValue, forKey: "HMAIProvider") } }
    var model: String { didSet { defaults.set(model, forKey: "HMAIModel.\(provider.rawValue)") } }
    var customURL: String { didSet { defaults.set(customURL, forKey: "HMAICustomURL") } }
    /// Most this app may spend on AI in a calendar month (USD), estimated from the tokens the provider reports.
    var monthlyBudget: Double { didSet { defaults.set(monthlyBudget, forKey: "HMAIBudget") } }
    /// Price per million tokens (in, out) for providers whose prices the app doesn't know. 0 = unknown.
    var priceIn: Double { didSet { defaults.set(priceIn, forKey: "HMAIPriceIn.\(provider.rawValue)") } }
    var priceOut: Double { didSet { defaults.set(priceOut, forKey: "HMAIPriceOut.\(provider.rawValue)") } }
    /// Explicit opt-in so non-Claude models without a built-in/custom price aren't blocked (USD spend stays uncounted).
    var allowUnpricedModels: Bool { didSet { defaults.set(allowUnpricedModels, forKey: "HMAIAllowUnpriced") } }
    /// Opt-in: polish Sunday's `story.weekly` digest with AI (linted against Words I never use).
    var polishWeeklyDigest: Bool { didSet { defaults.set(polishWeeklyDigest, forKey: "HMAIPolishWeeklyDigest") } }
    /// Models the provider lists for this key (filled right after the key is saved; also proves the key works).
    private(set) var models: [String] = []
    private(set) var checking = false
    private(set) var hasKey = false
    var lastError: String?

    struct Usage: Codable { var month = ""; var calls = 0; var input = 0; var output = 0; var usd = 0.0 }
    private(set) var usage = Usage()

    /// Built-in Claude prices (USD per million tokens, in / out).
    static let claudePrices: [String: (Double, Double)] = [
        "claude-opus-5-5": (4, 20), "claude-sonnet-5-5": (2, 10), "claude-haiku-5-5": (0.10, 0.50),
        "claude-fable-5-1": (10, 50), "claude-opus-5": (5, 25), "claude-sonnet-5": (2, 10),
    ]
    /// Built-in prices for common OpenAI, Gemini and Groq models (USD per million tokens, in / out).
    static let builtInPrices: [AIProvider: [String: (Double, Double)]] = [
        .openai: [
            "gpt-5": (1.25, 10.0), "gpt-5-mini": (0.25, 2.0), "gpt-5-nano": (0.05, 0.40),
            "gpt-4.1": (2.0, 8.0), "gpt-4.1-mini": (0.40, 1.60), "gpt-4.1-nano": (0.10, 0.40),
            "gpt-4o": (2.50, 10.0), "gpt-4o-mini": (0.15, 0.60),
            "o3": (2.0, 8.0), "o4-mini": (1.10, 4.40),
        ],
        .gemini: [
            "gemini-2.5-pro": (1.25, 10.0), "gemini-2.5-flash": (0.30, 2.50),
            "gemini-2.5-flash-lite": (0.10, 0.40), "gemini-2.0-flash": (0.10, 0.40),
        ],
        .groq: [
            "llama-3.3-70b-versatile": (0.59, 0.79), "llama-3.1-8b-instant": (0.05, 0.08),
            "openai/gpt-oss-120b": (0.15, 0.60), "openai/gpt-oss-20b": (0.075, 0.30),
            "qwen/qwen3-32b": (0.29, 0.59),
        ],
    ]
    static func matchPrice(_ table: [String: (Double, Double)], model: String) -> (Double, Double)? {
        table[model] ?? table.filter { model.hasPrefix($0.key) }.max { $0.key.count < $1.key.count }?.value
    }
    var prices: (Double, Double)? {
        // A dated or new Claude model id matches its family; an unknown one is counted at the highest known
        // price, so the monthly budget always stops it (never counted as free).
        if provider == .claude {
            return Self.matchPrice(Self.claudePrices, model: model)
                ?? Self.claudePrices.values.max { $0.1 < $1.1 }
        }
        if provider == .ollama { return (0, 0) }   // runs on this Mac
        if priceIn > 0 || priceOut > 0 { return (priceIn, priceOut) }
        if let table = Self.builtInPrices[provider] {
            return Self.matchPrice(table, model: model)
        }
        return nil
    }
    static func monthKey() -> String { Date.now.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month()) }
    /// This month's AI spend: the stored tally belongs to an earlier month until the next AI call resets it.
    var usdThisMonth: Double { usage.month == Self.monthKey() ? usage.usd : 0 }
    var budgetLeft: Bool { usage.month != Self.monthKey() || usage.usd < monthlyBudget }

    func record(input: Int, output: Int) {
        if usage.month != Self.monthKey() { usage = Usage(month: Self.monthKey()) }
        usage.calls += 1; usage.input += input; usage.output += output
        if let (i, o) = prices { usage.usd += Double(input) / 1e6 * i + Double(output) / 1e6 * o }
        if let data = try? JSONEncoder().encode(usage) { defaults.set(data, forKey: "HMAIUsage") }
    }

    /// Checks the key by asking the provider which models it offers; picks a sensible one if none is chosen.
    func checkKey() async {
        guard hasKey || !provider.needsKey else { models = []; return }
        checking = true
        defer { checking = false }
        do {
            models = try await AIWriter.listModels()
            lastError = nil
            if model.isEmpty || !models.contains(model) {
                model = models.first { $0 == provider.suggestedModel } ?? models.first ?? model
            }
        } catch {
            models = []
            lastError = (error as? WireError)?.message ?? "Couldn't reach \(provider.name)."
        }
    }

    init() {
        enabled = defaults.bool(forKey: "HMAIEnabled")
        let p = AIProvider(rawValue: defaults.string(forKey: "HMAIProvider") ?? "") ?? .claude
        provider = p
        model = defaults.string(forKey: "HMAIModel.\(p.rawValue)") ?? p.suggestedModel
        customURL = defaults.string(forKey: "HMAICustomURL") ?? ""
        monthlyBudget = defaults.object(forKey: "HMAIBudget") as? Double ?? 1.0
        priceIn = defaults.double(forKey: "HMAIPriceIn.\(p.rawValue)")
        priceOut = defaults.double(forKey: "HMAIPriceOut.\(p.rawValue)")
        allowUnpricedModels = defaults.bool(forKey: "HMAIAllowUnpriced")
        polishWeeklyDigest = defaults.bool(forKey: "HMAIPolishWeeklyDigest")
        if let data = defaults.data(forKey: "HMAIUsage"), let u = try? JSONDecoder().decode(Usage.self, from: data) { usage = u }
        refreshKeyState()
    }

    func switchProvider(_ p: AIProvider) {
        provider = p
        model = defaults.string(forKey: "HMAIModel.\(p.rawValue)") ?? p.suggestedModel
        priceIn = defaults.double(forKey: "HMAIPriceIn.\(p.rawValue)")
        priceOut = defaults.double(forKey: "HMAIPriceOut.\(p.rawValue)")
        models = []
        refreshKeyState()
        Task { await checkKey() }
    }

    func refreshKeyState() {
        if !provider.needsKey { hasKey = true; return }
        let name = provider.rawValue
        let account = "ai/\(name)"
        do {
            if let v = try keychain.peekSecret(plugin: "ai", name: name), !v.isEmpty {
                hasKey = true; lastError = nil; return
            }
            // Key not yet in v2 Keychain: if legacy Keychain had an unreadable item or a file source exists, surface/recover.
            let catalog = SecretSourceCatalog(url: URL.hmSupport.appending(path: SecretSourceCatalog.fileName))
            if SecretRebinder.rebind(store: keychain, catalog: catalog, plugin: "ai", name: name) {
                hasKey = true; lastError = nil
            } else if LegacySecretMigrator.lastReport.needsOK[account] != nil {
                hasKey = false
                lastError = "Your AI key is in an older Keychain item from a differently signed copy. Use Find my key or re-enter it here."
            } else {
                hasKey = false
            }
        } catch {
            let catalog = SecretSourceCatalog(url: URL.hmSupport.appending(path: SecretSourceCatalog.fileName))
            if SecretRebinder.rebind(store: keychain, catalog: catalog, plugin: "ai", name: name) {
                hasKey = true; lastError = nil
            } else {
                hasKey = false
                lastError = "Your AI key is in the Keychain but was saved by a differently signed copy. Use Find my key or re-enter it here."
            }
        }
    }

    func saveKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do { try keychain.setSecret(trimmed, plugin: "ai", name: provider.rawValue); lastError = nil }
        catch { lastError = "Couldn't save the key in the Keychain." }
        SecretSourceDefaults.mirrorTypedKey(trimmed, plugin: "ai", name: provider.rawValue)
        refreshKeyState()
        Task { await checkKey() }
    }

    func removeKey() {
        keychain.deleteSecret(plugin: "ai", name: provider.rawValue)
        models = []
        refreshKeyState()
    }

    fileprivate func key() -> String? { (try? keychain.secret(plugin: "ai", name: provider.rawValue)) ?? nil }

    /// The address to call: https only, except Ollama on this Mac.
    var endpoint: URL? {
        let base = (provider == .custom ? customURL : provider.baseURL).trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: base), let host = url.host() else { return nil }
        let local = host == "localhost" || host == "127.0.0.1"
        guard url.scheme == "https" || (url.scheme == "http" && local) else { return nil }
        return url
    }

    var ready: Bool { enabled && hasKey && !model.isEmpty && endpoint != nil && budgetLeft }
}

@MainActor
enum AIWriter {
    private static let cacheKey = "HMAIWordingCache"

    /// Short, plain rewording of each suggestion (id → sentence). Empty when AI is off or anything fails;
    /// the app then shows its own wording.
    static func reword(_ suggestions: [Suggestion]) async -> [String: String] {
        let settings = AISettings.shared
        if settings.enabled && !settings.budgetLeft {
            settings.lastError = "This month's AI budget is used up; using the app's own wording until next month."
        }
        guard settings.ready, !suggestions.isEmpty else { return [:] }
        // Numbered items (not the app's long ids, which a model may rewrite), mapped back below.
        let input = suggestions.enumerated().map { "\($0.offset + 1)\t\($0.element.title). \($0.element.why) \($0.element.action)" }
            .joined(separator: "\n")
        let hash = SHA256.hash(data: Data((settings.provider.rawValue + settings.model + input).utf8))
            .map { String(format: "%02x", $0) }.joined()
        var cache = (UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: [String: String]]) ?? [:]
        if let hit = cache[hash] { return hit }

        let prompt = """
        You help an indie app developer decide what to do today. Rewrite each item below as one short, plain \
        sentence (under 25 words) that says what to do and why. Keep every number and name exactly. No jargon.
        Reply with JSON only, no code fence: an object mapping each item's number (the text before the tab, as a string) to its sentence.

        \(input)
        """
        do {
            let text = try await send(prompt, settings: settings)
            // The JSON object, even if the model wrapped it in a code fence or added a line around it.
            let json: String = {
                guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close else { return text }
                return String(text[open...close])
            }()
            guard let data = json.data(using: .utf8),
                  let map = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                settings.lastError = "The AI's reply wasn't in the expected form; using the app's own wording."
                return [:]
            }
            var valid: [String: String] = [:]
            for (number, sentence) in map {
                guard let i = Int(number), i >= 1, i <= suggestions.count, let text = sentence as? String, !text.isEmpty else { continue }
                valid[suggestions[i - 1].id] = text
            }
            cache = [hash: valid]                      // only the latest set is kept
            UserDefaults.standard.set(cache, forKey: cacheKey)
            settings.lastError = nil
            return valid
        } catch {
            settings.lastError = (error as? WireError)?.message ?? "Couldn't reach \(settings.provider.name)."
            return [:]
        }
    }

    /// Free-form drafting (Rejection Shield: What's New, reviewer notes). Needs a key and budget, not the
    /// "Word Next steps" switch. Throws a plain message when it can't run.
    static func draft(_ prompt: String) async throws -> String {
        let settings = AISettings.shared
        guard settings.hasKey, !settings.model.isEmpty else { throw WireError("ai_key", "Add an AI key in Settings → General first.") }
        guard settings.budgetLeft else { throw WireError("ai_budget", "This month's AI budget is used up.") }
        // Without a price the budget can't be tracked, unless the user explicitly opted into unpriced models.
        guard settings.prices != nil || settings.allowUnpricedModels else {
            throw WireError("ai_no_price", "Enter this model's prices in Settings → General first (or allow unpriced models), so the monthly budget can stop it.")
        }
        return try await send(prompt, settings: settings)
    }

    /// One test call from Settings, so a wrong key or model shows at once.
    static func test() async -> String {
        let settings = AISettings.shared
        guard settings.hasKey, !settings.model.isEmpty, settings.endpoint != nil else { return "Add a key, a model and a valid https address first." }
        do {
            let reply = try await send("Reply with the single word OK.", settings: settings)
            return reply.localizedCaseInsensitiveContains("ok") ? "Works: \(settings.provider.name) answered." : "Answered, but unexpectedly: \(reply.prefix(60))"
        } catch {
            return (error as? WireError)?.message ?? "Couldn't reach \(settings.provider.name)."
        }
    }

    private static func send(_ prompt: String, settings: AISettings) async throws -> String {
        guard let base = settings.endpoint else { throw WireError("ai_url", "The provider address must start with https://") }
        let key = settings.provider.needsKey ? settings.key() : nil
        if settings.provider.needsKey, key?.isEmpty != false { throw WireError("ai_key", "Add your \(settings.provider.name) key first.") }
        var request: URLRequest
        if settings.provider == .claude {
            // Claude Messages API (raw HTTPS; there is no official Swift SDK).
            request = URLRequest(url: base.appending(path: "messages"), timeoutInterval: 60)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": settings.model, "max_tokens": 4000,
                "output_config": ["effort": "low"],
                "messages": [["role": "user", "content": prompt]],
            ])
        } else {
            // The OpenAI-style chat API that OpenAI, Gemini, OpenRouter, Groq, Mistral and Ollama all offer.
            request = URLRequest(url: base.appending(path: "chat/completions"), timeoutInterval: 60)
            if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            var payload: [String: Any] = ["model": settings.model, "messages": [["role": "user", "content": prompt]]]
            // Ask the provider to keep as little as it can: OpenAI not to store the exchange; OpenRouter to route
            // only to providers that don't collect prompts.
            if settings.provider == .openai { payload["store"] = false }
            if settings.provider == .openrouter { payload["provider"] = ["data_collection": "deny"] }
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request, delegate: NoRedirects())
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200 else {
            let detail = ((body["error"] as? [String: Any])?["message"] as? String) ?? "status \(status)"
            throw WireError("ai_failed", "\(settings.provider.name): \(detail)")
        }
        let usage = body["usage"] as? [String: Any] ?? [:]
        settings.record(input: (usage["input_tokens"] ?? usage["prompt_tokens"]) as? Int ?? 0,
                        output: (usage["output_tokens"] ?? usage["completion_tokens"]) as? Int ?? 0)
        if settings.provider == .claude {
            // Text blocks only (thinking blocks, if any, are skipped).
            return ((body["content"] as? [[String: Any]]) ?? []).filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }.joined()
        }
        let choice = (body["choices"] as? [[String: Any]])?.first
        return ((choice?["message"] as? [String: Any])?["content"] as? String) ?? ""
    }

    /// The models this key can use (Claude: GET /v1/models; the others: GET /models on the OpenAI-style API).
    static func listModels() async throws -> [String] {
        let settings = AISettings.shared
        guard let base = settings.endpoint else { throw WireError("ai_url", "The provider address must start with https://") }
        var request = URLRequest(url: base.appending(path: "models"), timeoutInterval: 30)
        let key = settings.key()
        if settings.provider == .claude {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        } else if let key {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request, delegate: NoRedirects())
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200 else {
            let detail = ((body["error"] as? [String: Any])?["message"] as? String) ?? (status == 401 ? "the key was refused" : "status \(status)")
            throw WireError("ai_failed", "\(settings.provider.name): \(detail)")
        }
        let ids = ((body["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
            .map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 }   // Gemini lists "models/…"
        return ids.sorted()
    }

    /// No cookies, no on-disk cache, no redirects: the request goes to the provider you chose and nowhere else.
    private static let session = URLSession(configuration: .ephemeral)
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }
}
