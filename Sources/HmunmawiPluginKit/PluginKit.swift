import Foundation
@_exported import HmunmawiProtocol

/// Implement this and call `PluginRuntime.run(MyPlugin())` from `main.swift`.
public protocol HmunmawiPlugin: Sendable {
    func initialize(settings: JSONValue, core: Core) async throws
    func poll(core: Core) async throws -> [PluginEvent]
    func act(action: String, params: JSONValue, core: Core) async throws -> JSONValue
}

extension HmunmawiPlugin {
    public func initialize(settings: JSONValue, core: Core) async throws {}
    public func poll(core: Core) async throws -> [PluginEvent] { [] }
    public func act(action: String, params: JSONValue, core: Core) async throws -> JSONValue {
        throw WireError("unknown_action", "This add-on has no action “\(action)”")
    }
}

/// The add-on's line back to the Hmunmawi app.
public actor Core {
    /// The add-on's plain settings from the app (never secrets).
    public private(set) var settings: JSONValue = .object([:])
    private var counter = 0
    private var pending: [String: CheckedContinuation<JSONValue, any Error>] = [:]

    /// Asks the app to make a web request. Use `{{secret:NAME}}` in headers or body for declared secrets.
    public func http(_ spec: HTTPRequestSpec) async throws -> HTTPResponseSpec {
        counter += 1
        let id = "p\(counter)"
        let message = WireMessage(id: id, method: "http", params: try JSONValue(encoding: spec))
        let result = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            send(message)
        }
        return try result.decode(HTTPResponseSpec.self)
    }

    /// Asks the app to do something only it may do on this Mac, such as `messages.send`. Must be declared in the manifest.
    public func mac(_ ability: String, params: JSONValue) async throws -> JSONValue {
        counter += 1
        let id = "p\(counter)"
        let message = WireMessage(id: id, method: "mac", params: .object(["ability": .string(ability), "params": params]))
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            send(message)
        }
    }

    /// Writes to the add-on's log file.
    public nonisolated func log(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    func setSettings(_ value: JSONValue) { settings = value }

    func send(_ message: WireMessage) {
        guard let data = try? message.line() else { return }
        try? FileHandle.standardOutput.write(contentsOf: data)
    }

    func resolve(_ message: WireMessage) {
        guard let id = message.id, let continuation = pending.removeValue(forKey: id) else { return }
        if let error = message.error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: message.result ?? .null)
        }
    }
}

public enum PluginRuntime {
    public static func run(_ plugin: some HmunmawiPlugin) async -> Never {
        signal(SIGPIPE, SIG_IGN)
        let core = Core()
        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                guard let message = try? WireMessage.decode(line) else { continue }
                if message.isResponse {
                    await core.resolve(message)
                    continue
                }
                if message.method == "shutdown" { break }
                guard let id = message.id, let method = message.method else { continue }
                let params = message.params ?? .object([:])
                Task {
                    let reply: WireMessage
                    do {
                        reply = WireMessage(id: id, result: try await handle(method, params, plugin, core))
                    } catch {
                        reply = WireMessage(id: id, error: error as? WireError ?? WireError("plugin_error", "\(error)"))
                    }
                    await core.send(reply)
                }
            }
        } catch {}
        exit(0)
    }

    private static func handle(_ method: String, _ params: JSONValue, _ plugin: some HmunmawiPlugin,
                               _ core: Core) async throws -> JSONValue {
        switch method {
        case "initialize":
            let settings = params[path: "settings"] ?? .object([:])
            await core.setSettings(settings)
            try await plugin.initialize(settings: settings, core: core)
            return .object(["protocol": .number(Double(hmunmawiProtocolVersion))])
        case "ping":
            return .string("pong")
        case "poll":
            return .object(["events": try JSONValue(encoding: try await plugin.poll(core: core))])
        case "act":
            guard let action = params[path: "action"]?.string else { throw WireError("bad_request", "act needs an action") }
            return try await plugin.act(action: action, params: params[path: "params"] ?? .object([:]), core: core)
        default:
            throw WireError("unknown_method", "Unknown method “\(method)”")
        }
    }
}

/// Saving a small state file from inside an add-on's sandbox. Foundation's `.atomic` writes go through a system
/// temporary folder the sandbox doesn't allow, so they always failed silently; this writes a temporary file next to
/// the target (inside the add-on's own folder) and renames it into place, which is just as safe.
public enum StateFile {
    @discardableResult
    public static func write(_ data: Data, to url: URL) -> Bool {
        let tmp = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).\(getpid()).tmp")
        do {
            try data.write(to: tmp)
            guard rename(tmp.path, url.path) == 0 else { try? FileManager.default.removeItem(at: tmp); return false }
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
    }
    @discardableResult
    public static func write(_ text: String, to url: URL) -> Bool { write(Data(text.utf8), to: url) }
}
