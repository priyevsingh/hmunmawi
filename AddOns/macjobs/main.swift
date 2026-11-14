import Foundation
import HmunmawiPluginKit

struct MacJobs: HmunmawiPlugin {
    func poll(core: Core) async throws -> [PluginEvent] {
        let prefixes = (await core.settings[path: "prefixes"]?.string ?? "")
            .split(separator: ",").map { $0.replacingOccurrences(of: " ", with: "") }.filter { !$0.isEmpty }   // job labels never contain spaces
        guard !prefixes.isEmpty else { throw WireError("not_set_up", "Add at least one job name prefix") }

        // Jobs to hear about when they finish (names as shown, or full labels); empty = none.
        let finished = (await core.settings[path: "finished"]?.string ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.contains(" ") }.prefix(10)
        let result = try await core.mac("launchd.list", params: .object(["prefixes": .array(prefixes.map(JSONValue.string)), "runs": .bool(true),
                                                                         "watch": .array(finished.map(JSONValue.string))]))
        let now = Date.now
        let day = now.formatted(.iso8601.year().month().day())
        let boot = result[path: "boot"]?.number.map { String(Int($0)) } ?? "?"
        // One alert per failure: the first time a job is seen failing (with this exit status, since this boot) is
        // remembered, and that moment is the alert's key. It stays the same on every check, whether or not launchd's
        // run counter could be read, so a weekly job that failed once alerts once, not every day or twice. When the
        // job runs cleanly again (or is running), the memory clears and its next failure alerts afresh.
        var seen = FailureMemory.load()
        var failingNow: Set<String> = []
        let events: [PluginEvent] = (result[path: "jobs"]?.array ?? []).compactMap { job in
            guard let label = job[path: "label"]?.string, let status = job[path: "status"]?.number,
                  status != 0, job[path: "running"] != .bool(true) else { return nil }
            let name = prefixes.reduce(label) { name, prefix in
                name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: ".-")) : name
            }
            let id = "\(label)|\(Int(status))|boot\(boot)"
            failingNow.insert(id)
            let first = seen[id] ?? Int(now.timeIntervalSince1970)
            seen[id] = first
            return PluginEvent(kind: "job.failed", app: name,
                               payload: .object(["label": .string(label), "status": .number(status)]),
                               occurredAt: Int64(now.timeIntervalSince1970 * 1000),
                               dedupeKey: "\(label)-\(Int(status))-boot\(boot)-since\(first)")
        }
        // Finished jobs you asked about: launchd's run counter went up and it ended cleanly. The first sighting only
        // remembers the counter (no message for a run that happened before you asked).
        var counters = RunMemory.load(), finishedEvents: [PluginEvent] = []
        for job in result[path: "jobs"]?.array ?? [] {
            guard let label = job[path: "label"]?.string, let runs = job[path: "runs"]?.number,
                  finished.contains(where: { label == $0 || label.hasSuffix("." + $0) || label.hasSuffix("-" + $0) }) else { continue }
            let key = "\(label)|boot\(boot)"
            defer { counters[key] = Int(runs) }
            guard let before = counters[key], Int(runs) > before, job[path: "status"]?.number == 0, job[path: "running"] != .bool(true) else { continue }
            let name = prefixes.reduce(label) { name, prefix in
                name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: ".-")) : name
            }
            finishedEvents.append(PluginEvent(kind: "job.finished", app: name, payload: .object(["label": .string(label), "runs": .number(runs)]),
                                              occurredAt: Int64(now.timeIntervalSince1970 * 1000), dedupeKey: "\(label)-finished-\(Int(runs))-boot\(boot)"))
        }
        RunMemory.save(counters.filter { $0.key.hasSuffix("|boot\(boot)") })
        // Jobs no longer failing are forgotten (their next failure is a new one).
        seen = seen.filter { failingNow.contains($0.key) }
        FailureMemory.save(seen)
        _ = day
        return events + finishedEvents
    }
}

/// Each watched job's run counter at the last check (only finished-job messages use it).
enum RunMemory {
    static var file: URL { FailureMemory.file.deletingLastPathComponent().appending(path: "runs.json") }
    static func load() -> [String: Int] { (try? JSONDecoder().decode([String: Int].self, from: Data(contentsOf: file))) ?? [:] }
    static func save(_ m: [String: Int]) { (try? JSONEncoder().encode(m)).map { StateFile.write($0, to: file) } }
}

/// When each failing job was first seen failing, kept in the add-on's own folder (survives restarts).
enum FailureMemory {
    static var file: URL {
        let d = URL.applicationSupportDirectory.appending(path: "Hmunmawi/AddOnState/macjobs", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return d.appending(path: "failing.json")
    }
    static func load() -> [String: Int] {
        (try? JSONDecoder().decode([String: Int].self, from: Data(contentsOf: file))) ?? [:]
    }
    static func save(_ m: [String: Int]) { (try? JSONEncoder().encode(m)).map { StateFile.write($0, to: file) } }
}

await PluginRuntime.run(MacJobs())
