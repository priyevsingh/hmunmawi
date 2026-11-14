import Foundation

/// Pure protocol helpers for ASC stream v2 (testable without network).
enum AscStreamProtocol {
    static let appliedSeqKey = "HMWebhookAppliedSeq"
    static let streamEnabledKey = "HMUseAscEventStream"

    /// Non-secret stream diagnostics (presence enums / counts / ms timestamps only).
    enum Telemetry {
        static let stateKey = "HMAscStreamProbeState"
        static let openMsKey = "HMAscStreamProbeOpenMs"
        static let handshakeMsKey = "HMAscStreamProbeHandshakeMs"
        static let lastFrameMsKey = "HMAscStreamProbeLastFrameMs"
        static let lastFrameTypeKey = "HMAscStreamProbeLastFrameType"
        static let lastPongMsKey = "HMAscStreamProbeLastPongMs"
        static let lastErrorKey = "HMAscStreamProbeLastError"
        static let reconnectAttemptKey = "HMAscStreamProbeReconnectAttempt"
        static let backoffSecKey = "HMAscStreamProbeBackoffSec"
        static let lastApplySourceKey = "HMAscProbeLastApplySource"
        static let httpCatchupCountKey = "HMAscStreamProbeHttpCatchupCount"
        static let lastHttpCatchupMsKey = "HMAscStreamProbeLastHttpCatchupMs"
    }

    enum ApplySource: String {
        case websocket, httpCatchup, httpStartup
    }

    /// Client WebSocket transport ping interval (must match `AscWebhookStream.pingIntervalSec`).
    static let pingIntervalSec: TimeInterval = 45

    /// After this long without a successful transport ping or frame, the socket is treated as stale.
    static var transportStaleSec: TimeInterval { pingIntervalSec * 2 }

    /// Idle HTTP catch-up is skipped when the WebSocket transport is alive (not merely "open" in prefs).
    static let streamHealthyGraceSec: TimeInterval = 150

    /// ACK to the worker is only valid after local apply caught up to this seq.
    static func ackSeqAfterApply(appliedSeq: Int64, candidate: Int64) -> Int64? {
        guard candidate > 0, candidate <= appliedSeq else { return nil }
        return candidate
    }

    /// Resume catchup after a crash between apply and ack: never skip below applied.
    static func resumeAfterSeq(appliedSeq: Int64, storedAckSeq: Int64) -> Int64 {
        max(appliedSeq, storedAckSeq)
    }

    /// Dedupe on replay: ignore events already applied locally.
    static func filterNewItems(_ items: [[String: Any]], appliedSeq: Int64) -> [[String: Any]] {
        items.filter { item in
            guard let seq = item["seq"] as? Int64 ?? (item["seq"] as? Int).map(Int64.init) else { return true }
            return seq > appliedSeq
        }
    }

    static func parseStreamFrame(_ text: String) -> (type: String, body: [String: Any])? {
        guard let data = text.data(using: .utf8),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = body["type"] as? String else { return nil }
        return (type, body)
    }

    /// True when the WebSocket still answers transport pings or delivers frames (two ping intervals).
    static func streamTransportAlive(state: String, lastFrameMs: Double, lastPongMs: Double,
                                     nowMs: Double = Date.now.timeIntervalSince1970 * 1000) -> Bool {
        guard state == "open" else { return false }
        let grace = transportStaleSec * 1000
        let last = max(lastFrameMs, lastPongMs, 0)
        return last > 0 && (nowMs - last) < grace
    }

    /// Human label for the live sales stream row in the status popover.
    static func streamHealthLabel(state: String, lastFrameMs: Double, lastPongMs: Double,
                                  nowMs: Double = Date.now.timeIntervalSince1970 * 1000) -> (text: String, healthy: Bool) {
        switch state {
        case "open":
            if streamTransportAlive(state: state, lastFrameMs: lastFrameMs, lastPongMs: lastPongMs, nowMs: nowMs) {
                return ("Open", true)
            }
            return ("Stale — reconnecting", false)
        case "connecting": return ("Connecting…", false)
        case "stale": return ("Stale — catching up", false)
        default: return ("Closed", false)
        }
    }

    /// True when recent stream activity means periodic HTTP `/asc/events` polling is unnecessary.
    static func streamHealthyForPolling(state: String, lastFrameMs: Double, lastPongMs: Double,
                                        nowMs: Double = Date.now.timeIntervalSince1970 * 1000) -> Bool {
        streamTransportAlive(state: state, lastFrameMs: lastFrameMs, lastPongMs: lastPongMs, nowMs: nowMs)
    }

    /// Saved-user default: v2 hook relay with a key keeps the event stream on across relaunch and re-sign.
    static func seedStreamPreferenceIfNeeded(defaults: UserDefaults, hookV2Live: Bool, hasHookWorker: Bool) {
        guard defaults.object(forKey: streamEnabledKey) == nil else { return }
        if hookV2Live, hasHookWorker {
            defaults.set(true, forKey: streamEnabledKey)
        }
    }

    /// Whether the Mac should run the WebSocket path (not only the one-shot activation flag).
    static func wantsEventStream(defaults: UserDefaults, activateAscEventRelay: Bool, hookV2Live: Bool,
                                 hasHookWorker: Bool) -> Bool {
        if activateAscEventRelay { return true }
        if hookV2Live, hasHookWorker { return true }
        if defaults.bool(forKey: streamEnabledKey) { return true }
        return false
    }

    /// Drop stale probe values from a previous process so Health does not show "open" while the stream is off.
    static func prepareProbeForLaunch(defaults: UserDefaults, streamWanted: Bool) {
        if !streamWanted {
            resetProbeTelemetry(defaults)
            return
        }
        defaults.set("closed", forKey: Telemetry.stateKey)
        defaults.set(0, forKey: Telemetry.lastPongMsKey)
        defaults.removeObject(forKey: Telemetry.lastErrorKey)
    }

    static func resetProbeTelemetry(_ defaults: UserDefaults) {
        defaults.set("closed", forKey: Telemetry.stateKey)
        defaults.set(0, forKey: Telemetry.openMsKey)
        defaults.set(0, forKey: Telemetry.handshakeMsKey)
        defaults.set(0, forKey: Telemetry.lastFrameMsKey)
        defaults.removeObject(forKey: Telemetry.lastFrameTypeKey)
        defaults.set(0, forKey: Telemetry.lastPongMsKey)
        defaults.removeObject(forKey: Telemetry.lastErrorKey)
    }

    /// Decode one stream frame; returns nil for non-event frames.
    static func decodeEventFrame(_ text: String) -> (seq: Int64, item: [String: Any])? {
        guard let data = text.data(using: .utf8),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              body["type"] as? String == "event",
              let item = body["item"] as? [String: Any] else { return nil }
        let seq = (body["seq"] as? Int64) ?? (body["seq"] as? Int).map(Int64.init) ?? 0
        return (seq, item)
    }
}
