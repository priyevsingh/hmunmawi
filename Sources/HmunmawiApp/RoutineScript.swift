import AppKit
import Darwin
import Foundation
import HmunmawiCore

/// Runs your own script for a routine ("Run my script"): one at a time per routine, with a time limit, its
/// output kept in routine-logs/<id>.log. In Try out it runs with the script's own dry-run argument and only
/// records what it would have done; nothing is sent. Only you can add or change a script routine (in the app):
/// agents may run or pause one, never point it at a different command.
enum ScriptRunner {
    static let logs = URL.hmSupport.appending(path: "routine-logs")

    struct Result { let exit: Int32; let output: String; let timedOut: Bool }

    /// An absolute path to a file this Mac can run, or nil.
    static func executable(_ raw: String) -> URL? {
        let p = (InputRule.path.clean(raw.trimmingCharacters(in: .whitespacesAndNewlines)) as NSString).expandingTildeInPath
        guard p.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: p) else { return nil }
        return URL(filePath: p)
    }

    static func split(_ line: String) -> [String] { ArgLine.split(line) }

    /// Runs the script and waits for it. It never hangs the caller: at the time limit the script and everything it
    /// started get SIGTERM, then SIGKILL 5 s later; once it exits, output is read for at most 2 s more (a background
    /// process it left behind may keep the pipe open forever).
    static func run(_ exe: URL, args: [String], folder: String?, routine: String, timeout: TimeInterval = 600,
                    envFile: String? = nil) async -> Result {
        await Task.detached(priority: .utility) {
            runBlocking(exe, args: args, folder: folder, routine: routine, timeout: timeout, envFile: envFile)
        }.value
    }

    /// The blocking part, on a background thread (never on the main actor).
    /// KEY=VALUE lines of a settings file (`export ` prefix, quotes and # comments allowed); values never logged.
    nonisolated static func envFile(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }), !(key.first?.isNumber ?? true) else { continue }
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let f = value.first, f == "\"" || f == "'", value.last == f { value = String(value.dropFirst().dropLast()) }
            out[key] = value
        }
        return out
    }

    private static func runBlocking(_ exe: URL, args: [String], folder: String?, routine: String, timeout: TimeInterval,
                                    envFile file: String?) -> Result {
        do {
            let p = Process()
            p.executableURL = exe
            p.arguments = args
            if let folder, !folder.isEmpty {
                let f = (folder as NSString).expandingTildeInPath
                var dir: ObjCBool = false
                if FileManager.default.fileExists(atPath: f, isDirectory: &dir), dir.boolValue { p.currentDirectoryURL = URL(filePath: f) }
            }
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" + (env["PATH"].map { ":" + $0 } ?? "")
            // The routine's own settings file (optional), e.g. keys a script needs; PATH and the routine id stay ours.
            if let file, !file.isEmpty, let text = try? String(contentsOfFile: (file as NSString).expandingTildeInPath, encoding: .utf8) {
                for (k, v) in envFile(text) where k != "PATH" { env[k] = v }
            }
            env["HMUNMAWI_ROUTINE"] = routine
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe; p.standardError = pipe; p.standardInput = FileHandle.nullDevice
            let output = OutputBuffer()
            pipe.fileHandleForReading.readabilityHandler = { h in
                let chunk = h.availableData
                if chunk.isEmpty { h.readabilityHandler = nil; output.end() } else { output.append(chunk) }
            }
            let exited = DispatchSemaphore(value: 0)
            p.terminationHandler = { _ in exited.signal() }
            do { try p.run() } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                return Result(exit: -1, output: "Couldn't start: \(error.localizedDescription)", timedOut: false)
            }
            let pid = p.processIdentifier
            var timedOut = false
            if exited.wait(timeout: .now() + timeout) == .timedOut {
                timedOut = true
                let victims = tree(pid)   // listed once: after the script ends its children move to launchd
                for v in victims.reversed() { kill(v, SIGTERM) }
                if exited.wait(timeout: .now() + 5) == .timedOut {
                    for v in victims.reversed() { kill(v, SIGKILL) }
                    _ = exited.wait(timeout: .now() + 5)
                }
            }
            // Let the last output arrive, but don't wait on a pipe a left-behind process still holds.
            output.waitForEnd(seconds: 2)
            pipe.fileHandleForReading.readabilityHandler = nil
            try? pipe.fileHandleForReading.close()
            let code: Int32 = p.isRunning ? -9 : p.terminationStatus
            return Result(exit: code, output: output.text, timedOut: timedOut)
        }
    }

    /// The process and all its descendants, parents before children (at most 256).
    static func tree(_ root: pid_t) -> [pid_t] {
        var out: [pid_t] = [root], i = 0
        while i < out.count, out.count < 256 {
            var buf = [pid_t](repeating: 0, count: 128)
            let n = Int(proc_listchildpids(out[i], &buf, Int32(MemoryLayout<pid_t>.size * buf.count)))
            if n > 0 { out += buf.prefix(min(n, buf.count)).filter { $0 > 0 && !out.contains($0) } }
            i += 1
        }
        return out
    }

    /// Appends one run to the routine's log (kept under 1 MB, newest last).
    static func log(_ id: String, header: String, output: String) {
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let url = logs.appending(path: InputRule.identifier.clean(id) + ".log")
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        text += "=== \(header)\n\(output.suffix(20_000))\(output.hasSuffix("\n") ? "" : "\n")"
        if text.utf8.count > 1_000_000 { text = String(text.suffix(500_000)) }
        try? text.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func logURL(_ id: String) -> URL { logs.appending(path: InputRule.identifier.clean(id) + ".log") }
}

/// A script's output as it arrives (from the pipe's reader thread), keeping at most the last 200 KB.
final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var ended = false
    private let done = DispatchSemaphore(value: 0)

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !ended else { return }
        data.append(chunk)
        if data.count > 400_000 { data = data.suffix(200_000) }
    }

    /// Called with an empty chunk at end of file.
    func end() { lock.lock(); let first = !ended; ended = true; lock.unlock(); if first { done.signal() } }

    func waitForEnd(seconds: Double) { _ = done.wait(timeout: .now() + seconds) }

    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data.suffix(200_000), as: UTF8.self) }
}

/// A flag set from another thread (the time limit) and read after the process ends.
final class ManagedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    func set() { lock.lock(); on = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return on }
}
