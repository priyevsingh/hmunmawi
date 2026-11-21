import Foundation

/// Event-driven ASC webhook delivery over a hibernating WebSocket (protocol v2).
/// Legacy `GET /asc/outbox` polling stays available until this stream is enabled and the worker has `ASC_QUEUE_V2`.
@MainActor
final class AscWebhookStream {
    struct Capabilities: Decodable {
        let asc_queue_v2: Bool
        let kv_import: Bool?
        let protocolVersion: Int?
        /// The deployed worker's code version (missing on workers older than 1.5.2: treated as 0).
        var code_version: Int? = nil

        enum CodingKeys: String, CodingKey {
            case asc_queue_v2
            case kv_import
            case code_version
            case protocolVersion = "protocol"
        }
    }

    /// Exponential backoff with full jitter, capped (seconds).
    nonisolated static func backoffDelay(attempt: Int, cap: TimeInterval = 120) -> TimeInterval {
        let base = min(cap, pow(2.0, Double(min(attempt, 10))) * 0.5)
        return Double.random(in: 0...base)
    }

    private let defaults: UserDefaults
    private var task: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var attempt = 0
    private let session: URLSession
    private(set) var lastApplySource: AscStreamProtocol.ApplySource = .websocket
    private var lastBaseURL: String?
    private var lastRelayKey: String?

    static let pingIntervalSec = AscStreamProtocol.pingIntervalSec

    init(defaults: UserDefaults = .standard, session: URLSession = URLSession(configuration: .ephemeral)) {
        self.defaults = defaults
        self.session = session
    }

    var enabled: Bool {
        get { defaults.bool(forKey: AscStreamProtocol.streamEnabledKey) }
        set { defaults.set(newValue, forKey: AscStreamProtocol.streamEnabledKey) }
    }

    /// Highest seq durably applied to the app (not merely received).
    var appliedSeq: Int64 {
        get { defaults.object(forKey: AscStreamProtocol.appliedSeqKey) as? Int64 ?? 0 }
        set { defaults.set(newValue, forKey: AscStreamProtocol.appliedSeqKey) }
    }

    /// When true, the minute poller should not call `GET /asc/events` (push path active).
    var prefersPushOverHttpPolling: Bool {
        guard enabled else { return false }
        let state = defaults.string(forKey: AscStreamProtocol.Telemetry.stateKey) ?? "closed"
        let lastFrame = defaults.double(forKey: AscStreamProtocol.Telemetry.lastFrameMsKey)
        let lastPong = defaults.double(forKey: AscStreamProtocol.Telemetry.lastPongMsKey)
        return AscStreamProtocol.streamHealthyForPolling(state: state, lastFrameMs: lastFrame, lastPongMs: lastPong)
    }

    /// Must complete only after events are durably ingested (hub SQLite); throws to withhold worker ACK.
    var onEvents: (@MainActor ([[String: Any]], AscStreamProtocol.ApplySource) async throws -> Void)?
    var onConnected: (() -> Void)?
    var onDisconnected: ((String) -> Void)?

    func start(baseURL: String, relayKey: String, consumer: String = "mac-default") {
        guard enabled else { return }
        lastBaseURL = baseURL
        lastRelayKey = relayKey
        task?.cancel()
        task = Task { @MainActor [weak self] in
            await self?.run(baseURL: baseURL, relayKey: relayKey, consumer: consumer)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        setProbeState("closed")
    }

    /// Bounded HTTP recovery when the WebSocket path is down (startup gate or periodic fallback).
    func boundedHttpCatchUp(baseURL: String, relayKey: String, source: AscStreamProtocol.ApplySource) async -> Bool {
        let n = defaults.integer(forKey: AscStreamProtocol.Telemetry.httpCatchupCountKey) + 1
        defaults.set(n, forKey: AscStreamProtocol.Telemetry.httpCatchupCountKey)
        defaults.set(Date.now.timeIntervalSince1970 * 1000, forKey: AscStreamProtocol.Telemetry.lastHttpCatchupMsKey)
        lastApplySource = source
        return await catchUpHTTP(baseURL: baseURL, relayKey: relayKey, source: source)
    }

    private func run(baseURL: String, relayKey: String, consumer: String) async {
        while !Task.isCancelled {
            do {
                try await connect(baseURL: baseURL, relayKey: relayKey, consumer: consumer)
                attempt = 0
                defaults.set(0, forKey: AscStreamProtocol.Telemetry.reconnectAttemptKey)
            } catch {
                attempt += 1
                defaults.set(attempt, forKey: AscStreamProtocol.Telemetry.reconnectAttemptKey)
                recordError(error)
                onDisconnected?(shortError(error))
                setProbeState("stale")
                _ = await boundedHttpCatchUp(baseURL: baseURL, relayKey: relayKey, source: .httpCatchup)
                setProbeState("closed")
            }
            let delay = Self.backoffDelay(attempt: attempt)
            defaults.set(delay, forKey: AscStreamProtocol.Telemetry.backoffSecKey)
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private func connect(baseURL: String, relayKey: String, consumer: String) async throws {
        setProbeState("connecting")
        let resume = AscStreamProtocol.resumeAfterSeq(appliedSeq: appliedSeq, storedAckSeq: appliedSeq)
        guard var comps = URLComponents(string: baseURL + "/asc/stream") else { throw StreamError.badURL }
        comps.queryItems = [
            URLQueryItem(name: "consumer", value: consumer),
            URLQueryItem(name: "after_seq", value: String(resume)),
        ]
        guard let url = comps.url else { throw StreamError.badURL }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(relayKey)", forHTTPHeaderField: "Authorization")
        let ws = session.webSocketTask(with: request)
        socket = ws
        ws.resume()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            final class Once: @unchecked Sendable {
                private let lock = NSLock()
                private var fired = false
                func resume(_ cont: CheckedContinuation<Void, Error>, _ result: Result<Void, Error>) {
                    lock.lock(); defer { lock.unlock() }
                    guard !fired else { return }
                    fired = true
                    switch result {
                    case .success: cont.resume()
                    case .failure(let error): cont.resume(throwing: error)
                    }
                }
            }
            let once = Once()
            Task { @MainActor in
                do { try await self.pingLoop(ws) } catch {
                    ws.cancel(with: .goingAway, reason: nil)
                    once.resume(cont, .failure(error))
                }
            }
            Task { @MainActor in
                do { try await self.readLoop(ws); once.resume(cont, .success(())) } catch {
                    ws.cancel(with: .goingAway, reason: nil)
                    once.resume(cont, .failure(error))
                }
            }
        }
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func pingLoop(_ ws: URLSessionWebSocketTask) async throws {
        while !Task.isCancelled {
            try await Task.sleep(for: .seconds(Self.pingIntervalSec))
            let state = defaults.string(forKey: AscStreamProtocol.Telemetry.stateKey) ?? "closed"
            let lastFrame = defaults.double(forKey: AscStreamProtocol.Telemetry.lastFrameMsKey)
            let lastPong = defaults.double(forKey: AscStreamProtocol.Telemetry.lastPongMsKey)
            let now = Date.now.timeIntervalSince1970 * 1000
            if state == "open", !AscStreamProtocol.streamTransportAlive(state: state, lastFrameMs: lastFrame, lastPongMs: lastPong, nowMs: now) {
                setProbeState("stale")
                throw StreamError.transportStale
            }
            try await sendTransportPing(ws)
        }
    }

    private func sendTransportPing(_ ws: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            ws.sendPing { error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume() }
            }
        }
        let now = Date.now.timeIntervalSince1970 * 1000
        defaults.set(now, forKey: AscStreamProtocol.Telemetry.lastPongMsKey)
        if defaults.double(forKey: AscStreamProtocol.Telemetry.openMsKey) == 0 {
            defaults.set(now, forKey: AscStreamProtocol.Telemetry.openMsKey)
            setProbeState("open")
            onConnected?()
        }
    }

    private func readLoop(_ ws: URLSessionWebSocketTask) async throws {
        while !Task.isCancelled {
            let message = try await ws.receive()
            switch message {
            case .string(let text):
                try await handleMessage(text)
            case .data(let data):
                if let text = String(data: data, encoding: .utf8) { try await handleMessage(text) }
            @unknown default:
                break
            }
        }
    }

    private func handleMessage(_ text: String) async throws {
        let now = Date.now.timeIntervalSince1970 * 1000
        defaults.set(now, forKey: AscStreamProtocol.Telemetry.lastFrameMsKey)
        if defaults.double(forKey: AscStreamProtocol.Telemetry.handshakeMsKey) == 0 {
            defaults.set(now, forKey: AscStreamProtocol.Telemetry.handshakeMsKey)
        }
        if defaults.string(forKey: AscStreamProtocol.Telemetry.stateKey) != "open" {
            defaults.set(now, forKey: AscStreamProtocol.Telemetry.openMsKey)
            setProbeState("open")
            onConnected?()
        }
        if let frame = AscStreamProtocol.parseStreamFrame(text) {
            defaults.set(frame.type, forKey: AscStreamProtocol.Telemetry.lastFrameTypeKey)
            switch frame.type {
            case "event":
                if let decoded = AscStreamProtocol.decodeEventFrame(text), decoded.seq > appliedSeq {
                    try await deliverAndAck([decoded.item.merging(["seq": decoded.seq]) { _, n in n }], source: .websocket)
                }
            case "caught_up":
                break
            case "ack_ok":
                break
            case "error":
                let err = (frame.body["error"] as? String) ?? "stream_error"
                defaults.set("worker:\(err)", forKey: AscStreamProtocol.Telemetry.lastErrorKey)
            default:
                break
            }
            return
        }
        if let decoded = AscStreamProtocol.decodeEventFrame(text), decoded.seq > appliedSeq {
            try await deliverAndAck([decoded.item.merging(["seq": decoded.seq]) { _, n in n }], source: .websocket)
        }
    }

    private func deliverAndAck(_ items: [[String: Any]], source: AscStreamProtocol.ApplySource) async throws {
        let fresh = AscStreamProtocol.filterNewItems(items, appliedSeq: appliedSeq)
        guard !fresh.isEmpty else { return }
        lastApplySource = source
        defaults.set(source.rawValue, forKey: AscStreamProtocol.Telemetry.lastApplySourceKey)
        try await onEvents?(fresh, source)
        let maxSeq = fresh.compactMap { $0["seq"] as? Int64 ?? ($0["seq"] as? Int).map(Int64.init) }.max() ?? 0
        appliedSeq = max(appliedSeq, maxSeq)
        if let ack = AscStreamProtocol.ackSeqAfterApply(appliedSeq: appliedSeq, candidate: maxSeq) {
            try await sendAck(ack)
        }
    }

    private func sendAck(_ seq: Int64) async throws {
        guard let ws = socket else { return }
        let payload = try JSONSerialization.data(withJSONObject: ["type": "ack", "seq": seq])
        try await ws.send(.string(String(decoding: payload, as: UTF8.self)))
    }

    private func catchUpHTTP(baseURL: String, relayKey: String, source: AscStreamProtocol.ApplySource) async -> Bool {
        var after = appliedSeq
        var appliedAny = false
        while !Task.isCancelled {
            guard var comps = URLComponents(string: baseURL + "/asc/events") else { break }
            comps.queryItems = [
                URLQueryItem(name: "after_seq", value: String(after)),
                URLQueryItem(name: "limit", value: "200"),
            ]
            var request = URLRequest(url: comps.url!)
            request.setValue("Bearer \(relayKey)", forHTTPHeaderField: "Authorization")
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = body["items"] as? [[String: Any]] else { return appliedAny }
            let fresh = AscStreamProtocol.filterNewItems(items, appliedSeq: appliedSeq)
            if !fresh.isEmpty {
                try? await deliverAndAck(fresh, source: source)
                appliedAny = true
            }
            after = items.compactMap { $0["seq"] as? Int64 }.max() ?? after
            let more = body["has_more"] as? Bool ?? false
            if !more || items.isEmpty { break }
        }
        return appliedAny
    }

    private func setProbeState(_ state: String) {
        defaults.set(state, forKey: AscStreamProtocol.Telemetry.stateKey)
    }

    private func recordError(_ error: Error) {
        let ns = error as NSError
        defaults.set("\(ns.domain)#\(ns.code)", forKey: AscStreamProtocol.Telemetry.lastErrorKey)
    }

    private func shortError(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) \(ns.code)"
    }

    static func fetchCapabilities(baseURL: String, relayKey: String, session: URLSession = URLSession(configuration: .ephemeral)) async -> Capabilities? {
        guard let url = URL(string: baseURL + "/asc/capabilities") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(relayKey)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let raw = try? JSONDecoder().decode(Capabilities.self, from: data) else { return nil }
        return raw
    }

    /// HTTP status for authenticated queue read (`GET /asc/events`), or nil when the request did not complete.
    static func relayAuthHTTPStatus(baseURL: String, relayKey: String, session: URLSession = URLSession(configuration: .ephemeral)) async -> Int? {
        guard var comps = URLComponents(string: baseURL + "/asc/events") else { return nil }
        comps.queryItems = [URLQueryItem(name: "after_seq", value: "0"), URLQueryItem(name: "limit", value: "1")]
        guard let url = comps.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(relayKey)", forHTTPHeaderField: "Authorization")
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return http.statusCode
    }

    /// True only when `relayAuthHTTPStatus` is 200.
    static func relayAuthorized(baseURL: String, relayKey: String, session: URLSession = URLSession(configuration: .ephemeral)) async -> Bool {
        await relayAuthHTTPStatus(baseURL: baseURL, relayKey: relayKey, session: session) == 200
    }

    enum StreamError: Error {
        case badURL, http, notReady, applyFailed, transportStale
    }
}
