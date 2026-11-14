import Darwin
import Foundation

/// One running add-on: a child process speaking JSON lines over stdin/stdout.
public actor PluginProcess {
    public let manifest: PluginManifest
    let directory: URL
    let settings: JSONValue
    let logURL: URL?
    let requestHandler: @Sendable (WireMessage) async -> WireMessage

    private var process: Process?
    private var input: FileHandle?
    private var generation = 0
    private var counter = 0
    private var pending: [String: CheckedContinuation<JSONValue, any Error>] = [:]
    /// True while a request (e.g. a long poll) is in flight; the health check leaves a busy add-on alone
    /// unless that request has already outlived its timeout (a hung poll can still answer `ping`).
    public var isBusy: Bool { !pending.isEmpty }
    /// True when a request has been in flight longer than the time the app agreed to wait for it.
    public var hasCallPastDeadline: Bool {
        let now = ContinuousClock.now
        for (id, start) in pendingStarted {
            if let limit = pendingLimit[id], start.duration(to: now) > limit { return true }
        }
        return false
    }
    private var timeouts: [String: Task<Void, Never>] = [:]
    private var pendingStarted: [String: ContinuousClock.Instant] = [:]
    private var pendingLimit: [String: Duration] = [:]
    public private(set) var isRunning = false

    /// Run inside a macOS sandbox (see `sandboxProfile`).
    let sandboxed: Bool

    init(manifest: PluginManifest, directory: URL, settings: JSONValue, logURL: URL?, sandboxed: Bool = false,
         requestHandler: @escaping @Sendable (WireMessage) async -> WireMessage) {
        self.sandboxed = sandboxed
        self.manifest = manifest
        self.directory = directory
        self.settings = settings
        self.logURL = logURL
        self.requestHandler = requestHandler
    }

    static let sandboxExec = "/usr/bin/sandbox-exec"

    /// The sandbox an add-on runs in. Allowed by default (the Swift runtime needs many small system services), with
    /// everything that could reach your data or the outside world shut: no network of its own (web calls go through
    /// the app's gate), no starting programs, no reading anywhere in any home folder, other users or external disks
    /// except the add-on's own folder and state, no writing at all except its state folder (and /dev/null), and no side doors out: no Apple Events,
    /// no opening links or apps, no clipboard, no Keychain service (security audit, Nov 2026). Later rules win.
    static func sandboxProfile(executable: URL, directory: URL, id: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let state = "\(home)/Library/Application Support/Hmunmawi/AddOnState/\(id)"
        // The real path as the kernel sees it (/tmp and /var are links to /private/...; Foundation's
        // resolvingSymlinksInPath strips "/private", which the sandbox then doesn't match).
        func real(_ u: URL) -> String {
            guard let r = realpath(u.path, nil) else { return u.path }
            defer { free(r) }
            return String(cString: r)
        }
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        return """
        (version 1)
        (allow default)
        (deny network*)
        (deny process-fork)
        (deny process-exec (require-not (literal \(q(real(executable))))))
        (deny file-read* (subpath "/Users") (subpath "/Volumes") (subpath \(q(home))) (subpath "/private/tmp") (subpath "/private/var/folders"))
        (allow file-read* (subpath \(q(real(directory)))) (literal \(q(real(executable)))) (subpath \(q(state))))
        (deny file-read* (subpath "/System/Volumes/Data/Users") (subpath "/System/Volumes/Data/Volumes"))
        (deny file-write*)
        (allow file-write* (subpath \(q(state))) (literal "/dev/null"))
        (deny appleevent-send)
        (deny lsopen)
        (deny mach-lookup (global-name "com.apple.nsurlsessiond") (global-name "com.apple.nsurlsessiond.NSURLSessionProxyService")
                          (global-name "com.apple.pasteboard.1") (global-name "com.apple.SecurityServer")
                          (global-name "com.apple.securityd.xpc") (global-name "com.apple.coreservices.launchservicesd"))
        """
    }

    func start() async throws {
        guard !isRunning else { return }
        generation += 1
        let gen = generation

        let process = Process()
        let executable = directory.appending(path: manifest.executable)
        process.executableURL = executable
        // In the sandbox the add-on can't reach the network, start programs, or read your keys and files; it only
        // talks to the app over its pipes (web calls go through the app's gate, with its declared hosts and keys).
        if sandboxed {
            // No sandbox tool: refuse to start rather than run the add-on unconfined without anyone knowing.
            guard FileManager.default.isExecutableFile(atPath: Self.sandboxExec) else {
                throw WireError("no_sandbox", "\(manifest.name) wasn't started: this Mac can't apply its sandbox (\(Self.sandboxExec) is missing)")
            }
            process.executableURL = URL(fileURLWithPath: Self.sandboxExec)
            process.arguments = ["-p", Self.sandboxProfile(executable: executable, directory: directory, id: manifest.id), executable.path]
        }
        process.currentDirectoryURL = directory
        // A clean environment, so the user's own shell variables (which may hold keys) never reach add-ons.
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
                               "HMUNMAWI_PLUGIN_ID": manifest.id]
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = Self.logHandle(logURL) ?? FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            Task { await self?.didExit(generation: gen) }
        }
        try process.run()

        self.process = process
        input = stdinPipe.fileHandleForWriting
        if let fd = input?.fileDescriptor {
            let flags = fcntl(fd, F_GETFL)
            if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        }
        isRunning = true

        let lines = LineReader.lines(from: stdoutPipe.fileHandleForReading)
        Task { [weak self] in
            for await line in lines { await self?.receive(line) }
        }

        do {
            _ = try await call("initialize", params: .object(["protocol": .number(Double(hmunmawiProtocolVersion)),
                                                              "settings": settings]),
                               timeout: .seconds(15))
        } catch {
            stop()
            throw error
        }
    }

    public func call(_ method: String, params: JSONValue = .object([:]),
                     timeout: Duration = .seconds(60)) async throws -> JSONValue {
        guard isRunning, let input else { throw WireError("not_running", "\(manifest.name) is not running") }
        counter += 1
        let id = "c\(counter)"
        let data = try WireMessage(id: id, method: method, params: params).line()

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            pendingStarted[id] = .now
            pendingLimit[id] = timeout
            // Timeout starts before the write so a full stdin pipe cannot stall the actor forever.
            timeouts[id] = Task { [weak self, method] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                await self?.timedOut(id, method: method, timeout: timeout)
            }
            do {
                try input.write(contentsOf: data)
            } catch {
                resolve(id, .failure(WireError("crashed", "\(manifest.name) stopped unexpectedly")))
            }
        }
    }

    public func stop() {
        if let shutdown = try? WireMessage(method: "shutdown").line() {
            try? input?.write(contentsOf: shutdown)
        }
        process?.terminate()
        // An add-on that ignores the request is stopped for good after 3 seconds, so no old copy keeps running.
        if let p = process {
            let pid = p.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if p.isRunning { kill(pid, SIGKILL) } }
        }
        markStopped()
    }

    private func receive(_ line: String) {
        guard let message = try? WireMessage.decode(line) else { return }
        if message.isResponse, let id = message.id {
            if let error = message.error {
                resolve(id, .failure(error))
            } else {
                resolve(id, .success(message.result ?? .null))
            }
        } else if message.isRequest {
            // At most 8 requests in flight per add-on: a flood can't burn paid API quota or start many processes.
            guard inFlight < 8 else {
                if let id = message.id { send(WireMessage(id: id, error: WireError("busy", "Too many requests at once; try again"))) }
                return
            }
            inFlight += 1
            Task { [weak self, requestHandler] in
                let reply = await requestHandler(message)
                await self?.finished(reply)
            }
        }
    }

    private var inFlight = 0

    private func finished(_ reply: WireMessage) {
        inFlight -= 1
        send(reply)
    }

    private func send(_ message: WireMessage) {
        guard let data = try? message.line() else { return }
        try? input?.write(contentsOf: data)
    }

    /// The request ran out of time: fail it and stop the add-on so leftover work cannot block the next check
    /// (a hung poll still answers `ping`, so the health check would otherwise leave it running).
    private func timedOut(_ id: String, method: String, timeout: Duration) {
        resolve(id, .failure(WireError("timeout", "\(method) took longer than \(timeout)")))
        stop()
    }

    private func resolve(_ id: String, _ result: Result<JSONValue, any Error>) {
        timeouts.removeValue(forKey: id)?.cancel()
        pendingStarted.removeValue(forKey: id)
        pendingLimit.removeValue(forKey: id)
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    private func didExit(generation gen: Int) {
        guard gen == generation else { return }
        markStopped()
    }

    private func markStopped() {
        isRunning = false
        process = nil
        input = nil
        for id in Array(pending.keys) {
            resolve(id, .failure(WireError("crashed", "\(manifest.name) stopped unexpectedly")))
        }
    }

    private static func logHandle(_ url: URL?) -> FileHandle? {
        guard let url else { return nil }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Kept under 5 MB: a chatty or hostile add-on can't fill the disk (the old half is dropped at start).
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 5_000_000,
           let data = try? Data(contentsOf: url) {
            try? data.suffix(1_000_000).write(to: url, options: .atomic)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        return handle
    }
}
