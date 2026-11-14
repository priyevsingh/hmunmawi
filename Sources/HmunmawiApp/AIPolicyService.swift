import Foundation
import HmunmawiCore

/// Writes AI pause policy only through the bundled or hub `ai_policy.py` (flock + atomic JSON). Never edits JSON directly.
@MainActor @Observable
final class AIPolicyService {
    static let shared = AIPolicyService()

    private(set) var statusJSON: [String: Any] = [:]
    private(set) var lastError: String?
    private(set) var busy = false

    var isPaused: Bool { statusJSON["blocked"] as? Bool == true }

    func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let (code, out) = await Self.run(["status"])
        guard code == 0, let data = out.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            lastError = out.isEmpty ? "Couldn't read AI pause policy." : String(out.prefix(200))
            return
        }
        statusJSON = obj
        lastError = nil
    }

    func setPause(until: Date, reason: String, account: String = "team") async -> Bool {
        let iso = ISO8601DateFormatter().string(from: until)
        let (code, out) = await Self.run(["set-pause", "--account", account, "--until", iso, "--reason", reason, "--source", "hmunmawi"])
        if code != 0 { lastError = out; return false }
        await refresh()
        return true
    }

    func setIndefinitePause(reason: String, account: String = "team") async -> Bool {
        let (code, out) = await Self.run(["set-pause", "--account", account, "--indefinite", "--reason", reason, "--source", "hmunmawi"])
        if code != 0 { lastError = out; return false }
        await refresh()
        return true
    }

    func clearManualPause(account: String = "team") async -> Bool {
        let (code, out) = await Self.run(["set-pause", "--account", account, "--clear"])
        if code != 0 { lastError = out; return false }
        await refresh()
        return true
    }

    /// Eligibility check: reads policy only (no Claude invocation).
    func checkAvailability(account: String = "team") async -> Bool {
        let (code, out) = await Self.run(["should-defer", "--account", account])
        guard code == 0, let data = out.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return obj["defer"] as? Bool != true
    }

    private static func scriptURL() -> URL? {
        if AIPolicyPaths.usesHubAdapter { return AIPolicyPaths.hubScript }
        return Bundle.main.url(forResource: "ai_policy", withExtension: "py")
    }

    nonisolated static func run(_ args: [String]) async -> (Int, String) {
        guard let script = await MainActor.run(body: { scriptURL() }) else {
            return (1, "AI policy tool not found on this Mac.")
        }
        return await Task.detached(priority: .utility) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            proc.arguments = [script.path] + args
            var env = ProcessInfo.processInfo.environment
            env["AI_POLICY_FILE"] = AIPolicyPaths.policyFile.path
            proc.environment = env
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            do {
                try proc.run()
                // Read first (a full pipe would block the script), and stop a stuck script after 30 s.
                let killer = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: killer)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                killer.cancel()
                let text = String(data: data, encoding: .utf8) ?? ""
                return (Int(proc.terminationStatus), text)
            } catch {
                return (1, error.localizedDescription)
            }
        }.value
    }
}
