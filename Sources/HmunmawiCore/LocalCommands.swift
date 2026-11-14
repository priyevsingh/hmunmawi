import Foundation

/// Mac abilities the core can offer without special app permissions: reading launchd job status and
/// running a feed script the user picked.
enum LocalCommands {
    static let maxOutputBytes = 5 * 1024 * 1024

    struct Output: Sendable {
        var status: Int32
        var stdout: String
    }

    static func run(_ executable: String, _ arguments: [String] = [], timeout: Duration = .seconds(120)) async throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: executable).deletingLastPathComponent()
        process.environment = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "LANG": "en_US.UTF-8",
        ]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let collector = OutputCollector(cap: maxOutputBytes)
        let reader = out.fileHandleForReading
        // Read as it comes, never more than the cap (a script printing forever used to fill memory first).
        reader.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; collector.finish(); return }
            if collector.append(chunk), process.isRunning { killTree(process.processIdentifier) }
        }
        // Exit is reported by callback (waitUntilExit could miss the exit of a force-stopped script and wait forever).
        let exited = OutputCollector(cap: 0)
        process.terminationHandler = { _ in exited.finish() }
        try process.run()

        // At the time limit: ask it to stop, then force it 3 s later, and stop waiting for output either way (a
        // child process that keeps the pipe open used to block a thread forever).
        let killer = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            collector.timedOut()
            if process.isRunning { process.terminate() }
            try? await Task.sleep(for: .seconds(3))
            if process.isRunning { killTree(process.processIdentifier) }   // never a reaped (reusable) pid
            collector.finish()
            try? await Task.sleep(for: .seconds(2))
            exited.finish()                                                 // last resort: stop waiting
        }
        await collector.wait()
        reader.readabilityHandler = nil
        await exited.wait()
        killer.cancel()
        try? reader.close()
        if collector.overCap { throw WireError("too_large", "Output is over 5 MB") }
        // Reading the exit status of a process that is somehow still running would crash: treat it as a timeout.
        if process.isRunning || collector.didTimeOut || process.terminationReason == .uncaughtSignal {
            throw WireError("timeout", "\(URL(fileURLWithPath: executable).lastPathComponent) took longer than \(timeout)")
        }
        return Output(status: process.terminationStatus, stdout: String(decoding: collector.data, as: UTF8.self))
    }

    /// Force-stops a command and everything it started (children first found, then killed, deepest last), so
    /// nothing it left behind keeps running or keeps a pipe open.
    static func killTree(_ pid: pid_t) {
        guard pid > 0 else { return }
        var all: [pid_t] = [pid], i = 0
        while i < all.count, all.count < 512 {
            var kids = [pid_t](repeating: 0, count: 256)
            let n = proc_listchildpids(all[i], &kids, Int32(kids.count * MemoryLayout<pid_t>.size))
            if n > 0 { all += kids.prefix(Int(n)).filter { $0 > 0 } }
            i += 1
        }
        for p in all { kill(p, SIGKILL) }
    }

    /// Collects a command's output from the pipe's handler thread, up to a cap, and wakes the waiter once.
    final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private var done = false, over = false, timed = false
        private var waiter: CheckedContinuation<Void, Never>?
        let cap: Int
        init(cap: Int) { self.cap = cap }

        /// Returns true once the output passed the cap (the rest is dropped).
        func append(_ chunk: Data) -> Bool {
            lock.withLock {
                if !over { buffer.append(chunk); if buffer.count > cap { over = true; buffer = Data() } }
                return over
            }
        }
        func timedOut() { lock.withLock { timed = true } }
        func finish() {
            let w: CheckedContinuation<Void, Never>? = lock.withLock {
                guard !done else { return nil }
                done = true; defer { waiter = nil }; return waiter
            }
            w?.resume()
        }
        func wait() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let now: Bool = lock.withLock { if done { return true }; waiter = c; return false }
                if now { c.resume() }
            }
        }
        var data: Data { lock.withLock { buffer } }
        var overCap: Bool { lock.withLock { over } }
        var didTimeOut: Bool { lock.withLock { timed } }
    }

    /// `launchctl list` rows whose label starts with one of `prefixes`.
    static func launchdJobs(prefixes: [String], withRuns: Bool = false, watch: Set<String> = []) async throws -> JSONValue {
        let output = try await run("/bin/launchctl", ["list"], timeout: .seconds(20))
        var rows: [JSONValue] = [], lookups = 0, watchLookups = 0
        for line in output.stdout.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cols.count == 3, prefixes.contains(where: { cols[2].hasPrefix($0) }) else { continue }
            var row: [String: JSONValue] = ["label": .string(cols[2]), "running": .bool(cols[0] != "-"),
                                            "status": .number(Double(cols[1]) ?? 0)]
            // For a failed job, launchd's run counter (since boot), so one failure is one alert: "list" keeps
            // showing the last exit code until the job runs again, which can be days for a weekly job.
            // Only when asked (the Mac jobs add-on), and at most 10 quick lookups per check: a broad prefix can
            // match hundreds of system jobs.
            // Jobs you asked to hear about when they finish: their counter too (at most 10 more lookups).
            let watched = withRuns && cols[0] == "-" && watch.contains(where: { cols[2] == $0 || cols[2].hasSuffix("." + $0) || cols[2].hasSuffix("-" + $0) }) && watchLookups < 10
            if watched { watchLookups += 1 }
            if withRuns, watched || (cols[1] != "0" && cols[0] == "-" && lookups < 10 && { lookups += 1; return true }()),
               let detail = try? await run("/bin/launchctl", ["print", "gui/\(getuid())/\(cols[2])"], timeout: .seconds(3)),
               let m = detail.stdout.firstMatch(of: /\n\s*runs = (\d+)/), let runs = Double(m.1) {
                row["runs"] = .number(runs)
            }
            rows.append(.object(row))
        }
        // The real boot time (fixed until restart). "now - uptime" moved on every sleep, because uptime doesn't count
        // sleep, so a failed job's alert key changed and it alerted again after each wake.
        var tv = timeval(), size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        let bootSeconds = sysctl(&mib, 2, &tv, &size, nil, 0) == 0 && tv.tv_sec > 0 ? Double(tv.tv_sec)
            : Date.now.timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
        let boot = Int(bootSeconds / 60)   // minutes, stable per boot
        return .object(["jobs": .array(rows), "boot": .number(Double(boot))])
    }

    /// Runs the feed script only if it's exactly the path saved in this add-on's settings.
    static func runFeedScript(params: JSONValue, settings: JSONValue) async throws -> JSONValue {
        let path = params[path: "path"]?.string ?? ""
        guard !path.isEmpty, path == settings[path: "script"]?.string else {
            throw WireError("blocked_script", "Only the script chosen in this add-on's settings may run")
        }
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw WireError("not_executable", "\(path) is missing or not executable")
        }
        let output = try await run(path)
        guard output.status == 0 else { throw WireError("script_failed", "The feed script exited with \(output.status)") }
        return .object(["stdout": .string(output.stdout)])
    }

    /// Your X numbers from the X file set for the X connection (or Settings → General → X), with the morning
    /// digest beside it as a fallback. Free: no network, no key.
    static func readXFile(settings: JSONValue, defaults: UserDefaults = .standard, now: Date = .now) -> JSONValue {
        let set = (settings[path: "file"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let file = set.isEmpty ? (defaults.string(forKey: "HMXFile") ?? "") : (set as NSString).expandingTildeInPath
        let glance = (defaults.string(forKey: "HMXGlanceFile") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return XFileNumbers.load(file: file, digest: XFileNumbers.digestPath(nextTo: file),
                                 glanceFile: glance.isEmpty ? nil : (glance as NSString).expandingTildeInPath,
                                 glanceFiles: [defaults.string(forKey: "HMXSafariFile")].compactMap { $0 }, now: now)
    }
}
