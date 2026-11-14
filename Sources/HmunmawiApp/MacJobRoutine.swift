import Foundation
import HmunmawiCore

/// "Run one of my Mac jobs": a routine that starts one of your own LaunchAgents (~/Library/LaunchAgents) on the
/// routine's schedule. macOS still runs the job exactly as its file says (command, environment, logs, check-ins);
/// only the start comes from Hmunmawi. With "Take over its own timer", Hmunmawi removes the job's own schedule keys
/// (after a backup in Hmunmawi's folder) so it doesn't run twice; switching that off puts the original back.
enum MacJobRoutine {
    static let backups = URL.hmSupport.appending(path: "launchagents-backup")
    static let scheduleKeys = ["StartInterval", "StartCalendarInterval", "RunAtLoad", "WatchPaths", "QueueDirectories", "StartOnMount"]

    /// A label is only accepted when its file is in your LaunchAgents folder (letters, digits, dots, dashes).
    static func plist(_ label: String) -> URL? {
        guard label.wholeMatch(of: /[A-Za-z0-9._-]{3,200}/) != nil else { return nil }
        let u = URL.homeDirectory.appending(path: "Library/LaunchAgents/\(label).plist")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// "com.example.mail-watch" -> "mail-watch": the part a person recognises.
    static func shortName(_ label: String) -> String {
        let parts = label.split(separator: ".")
        return parts.count >= 3 ? parts.dropFirst(2).joined(separator: ".") : label
    }
    static func uid() -> String { String(getuid()) }

    /// Starts the job now (nothing happens if it's already running). Returns (ok, note).
    static func start(_ label: String) async -> (ok: Bool, note: String) {
        guard plist(label) != nil else { return (false, "No Mac job named \(label) in your LaunchAgents folder.") }
        let r = await launchctl(["kickstart", "gui/\(uid())/\(label)"])
        return r.code == 0 ? (true, "started \(label)") : (false, "macOS couldn't start \(label): \(r.out.prefix(160))")
    }

    /// Whether the job's own file still has a schedule of its own.
    static func hasOwnTimer(_ label: String) -> Bool {
        guard let u = plist(label), let d = try? Data(contentsOf: u),
              let p = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] else { return false }
        return scheduleKeys.contains { p[$0] != nil && !($0 == "RunAtLoad" && p[$0] as? Bool == false) }
    }

    /// Removes the job's own schedule (backup first) and reloads it, so only Hmunmawi starts it.
    static func takeOver(_ label: String) async -> String? {
        guard let u = plist(label) else { return "No Mac job named \(label)." }
        guard let d = try? Data(contentsOf: u),
              var p = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] else { return "Couldn't read \(label)'s file." }
        try? FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let backup = backups.appending(path: "\(label).plist")
        if !FileManager.default.fileExists(atPath: backup.path) { try? d.write(to: backup) }   // keep the first original
        for k in scheduleKeys { p.removeValue(forKey: k) }
        guard let out = try? PropertyListSerialization.data(fromPropertyList: p, format: .xml, options: 0) else { return "Couldn't write \(label)'s file." }
        do { try out.write(to: u, options: .atomic) } catch { return "Couldn't write \(label)'s file." }
        return await reload(label, u)
    }

    /// Puts the original file back (from the backup) and reloads it: the job runs on its own timer again.
    static func handBack(_ label: String) async -> String? {
        guard let u = plist(label) else { return "No Mac job named \(label)." }
        let backup = backups.appending(path: "\(label).plist")
        guard let d = try? Data(contentsOf: backup) else { return "No backup of \(label) to put back." }
        do { try d.write(to: u, options: .atomic) } catch { return "Couldn't write \(label)'s file." }
        try? FileManager.default.removeItem(at: backup)
        return await reload(label, u)
    }

    private static func reload(_ label: String, _ u: URL) async -> String? {
        _ = await launchctl(["bootout", "gui/\(uid())/\(label)"])
        let r = await launchctl(["bootstrap", "gui/\(uid())", u.path])
        return r.code == 0 || r.out.contains("already") ? nil : "macOS couldn't reload \(label): \(r.out.prefix(160))"
    }

    static func launchctl(_ args: [String]) async -> (code: Int32, out: String) {
        await Task.detached {
            let p = Process(), pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = args
            p.standardOutput = pipe; p.standardError = pipe
            guard (try? p.run()) != nil else { return (-1, "couldn't run launchctl") }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }.value
    }

    /// Keeps the Mac jobs' own timers in line with the routines, each minute: a routine that's on with "Take over
    /// its own timer" owns the schedule; when it's switched off, deleted or the switch is off, the original returns.
    @MainActor static func reconcile(_ routines: [MyRoutine], state: (MyRoutine) -> Routines.State) async {
        var owned = Set<String>()
        for r in routines where r.does == RoutineKind.macJob.rawValue && r.params?["takeover"] == "1" && state(r) == .on {
            guard let label = r.params?["label"], plist(label) != nil else { continue }
            owned.insert(label)
            if hasOwnTimer(label), let err = await takeOver(label) { Routines.shared.note(r, err) }
        }
        await retryFailed(owned)
        let backed = ((try? FileManager.default.contentsOfDirectory(atPath: backups.path)) ?? [])
            .filter { $0.hasSuffix(".plist") }.map { String($0.dropLast(6)) }
        for label in backed where !owned.contains(label) { _ = await handBack(label) }
    }

    /// Self-healing: a job this app starts that ended with an error is started once more, a few minutes later
    /// (most failures are a busy Mac, a sleeping network or a browser tab in the way). One retry per failure; the
    /// next retry only after the job has worked again, so a broken job is never hammered.
    @MainActor private static var retried: [String: Date] = [:]
    @MainActor static func retryFailed(_ labels: Set<String>) async {
        for label in labels {
            let (code, out) = await launchctl(["print", "gui/\(uid())/\(label)"])
            guard code == 0, let exit = lastExit(out) else { continue }
            if exit == 0 { retried[label] = nil; continue }
            guard !out.contains("state = running"), retried[label] == nil else { continue }
            retried[label] = .now
            try? await Task.sleep(for: .seconds(1))
            let r = await start(label)
            try? await Routines.shared.model?.liveStore?.appendAudit(actor: "app", action: "job.retry", subject: shortName(label),
                detail: .object(["exit": .string(String(exit)), "restarted": .string(r.ok ? "yes" : "no")]))
        }
    }

    /// "last exit code = 1" from launchctl print; nil when the job never ran.
    nonisolated static func lastExit(_ printed: String) -> Int? {
        for line in printed.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("last exit code = ") { return Int(t.dropFirst("last exit code = ".count).prefix { $0.isNumber || $0 == "-" }) }
        }
        return nil
    }
}
