import Foundation
import HmunmawiCore
import SwiftUI

/// The Mac's own automations, read directly from launchd: every background job in ~/Library/LaunchAgents,
/// its schedule, whether it's running, how its last run ended and whether it's switched off. Works for any
/// user with no setup. Plain-English names and descriptions live in the app (`AutomationNotes`), editable.
@MainActor @Observable
final class MacAutomations {
    static let shared = MacAutomations()

    struct Job: Identifiable, Hashable {
        enum Kind: String { case daily, weekly, interval, always, login, watch, other }
        let label: String
        let kind: Kind
        let when: String          // "every 5 min", "Mon 06:30", "at login", "always"
        let days: [String]        // weekly jobs
        let state: String         // running, ok, failed, off
        let exitCode: Int?
        let program: String?
        var times: [String] = []        // "HH:MM" calendar times (daily/weekly)
        var plist: String? = nil
        var log: String? = nil          // the newest of its log files (evidence a run happened)
        var lastLog: Date? = nil        // when any of its logs last changed
        var runsSinceBoot: Int? = nil   // launchd's own run counter (resets at boot)
        var id: String { label }
    }

    private(set) var jobs: [Job] = []
    private(set) var lastRead: Date?
    /// When the Mac last started (launchd's run counters start from here).
    nonisolated static let bootTime: Date = {
        var tv = timeval(), size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0 else { return .distantPast }
        return Date(timeIntervalSince1970: Double(tv.tv_sec))
    }()

    /// Jobs from Apple and well-known vendors aren't the user's automations.
    nonisolated private static let ignored = ["com.apple.", "com.google.", "com.microsoft.", "com.adobe.", "us.zoom.", "com.dropbox.", "com.spotify.", "sh.brew."]

    @ObservationIgnored private var reading = false
    func refresh() async {
        guard !reading else { return }       // several callers at once share one read
        reading = true; defer { reading = false }
        let found = await Task.detached(priority: .utility) { Self.read() }.value
        jobs = found
        lastRead = .now
    }

    nonisolated private static func read() -> [Job] {
        let dir = URL.homeDirectory.appending(path: "Library/LaunchAgents")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let live = launchctlList(), disabled = disabledLabels()
        var out: [Job] = []
        for f in files where f.pathExtension == "plist" {
            guard let data = try? Data(contentsOf: f), data.count < 1_000_000,
                  let p = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let label = p["Label"] as? String, !ignored.contains(where: label.hasPrefix) else { continue }
            let (kind, when, days) = schedule(p)
            let status = live[label]
            let off = (p["Disabled"] as? Bool == true) || disabled.contains(label) || status == nil
            let state: String = off ? "off"
                : status?.pid != nil ? "running"
                : (status?.exit ?? 0) != 0 ? "failed" : "ok"
            let program = ((p["ProgramArguments"] as? [String])?.first { $0.hasSuffix(".py") || $0.hasSuffix(".sh") || $0.hasSuffix(".mjs") }
                           ?? (p["ProgramArguments"] as? [String])?.first ?? p["Program"] as? String)
            var job = Job(label: label, kind: kind, when: when, days: days, state: state, exitCode: status?.exit, program: program)
            job.times = calendarTimes(p)
            job.plist = f.path
            // Logs: stdout/stderr, plus logs next to its launch script (launch_x.sh -> launch_x.wrapper.log, launch_x.log).
            var logs = ["StandardOutPath", "StandardErrorPath"].compactMap { p[$0] as? String }.map { ($0 as NSString).expandingTildeInPath }
            for arg in (p["ProgramArguments"] as? [String]) ?? [] where arg.hasSuffix(".sh") || arg.hasSuffix(".py") {
                let base = ((arg as NSString).expandingTildeInPath as NSString).deletingPathExtension
                logs += [base + ".wrapper.log", base + ".log"]
            }
            let dated = logs.compactMap { l in fileModified(l).map { (l, $0) } }
            let newest = dated.max { $0.1 < $1.1 }
            job.log = newest?.0 ?? logs.first
            job.lastLog = newest?.1
            if !job.times.isEmpty, !off {
                let info = run(["print", "gui/\(getuid())/\(label)"])
                if let r = info.range(of: #"\n\s*runs = (\d+)"#, options: .regularExpression) {
                    job.runsSinceBoot = Int(info[r].split(separator: "=").last?.trimmingCharacters(in: .whitespaces) ?? "")
                }
            }
            out.append(job)
        }
        return out.sorted { $0.label < $1.label }
    }

    nonisolated private static func calendarTimes(_ p: [String: Any]) -> [String] {
        var cal: [[String: Any]] = []
        if let one = p["StartCalendarInterval"] as? [String: Any] { cal = [one] }
        if let many = p["StartCalendarInterval"] as? [[String: Any]] { cal = many }
        let withHour = cal.filter { $0["Hour"] != nil }
        return Array(Set(withHour.map { String(format: "%02d:%02d", ($0["Hour"] as? Int) ?? 0, ($0["Minute"] as? Int) ?? 0) })).sorted()
    }

    nonisolated private static func schedule(_ p: [String: Any]) -> (Job.Kind, String, [String]) {
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        var cal: [[String: Any]] = []
        if let one = p["StartCalendarInterval"] as? [String: Any] { cal = [one] }
        if let many = p["StartCalendarInterval"] as? [[String: Any]] { cal = many }
        if !cal.isEmpty {
            func hm(_ d: [String: Any]) -> String {
                String(format: "%02d:%02d", (d["Hour"] as? Int) ?? 0, (d["Minute"] as? Int) ?? 0)
            }
            let weekdays = cal.compactMap { $0["Weekday"] as? Int }.map { names[min(max($0, 0), 7)] }
            let times = Array(Set(cal.map(hm))).sorted()
            if !weekdays.isEmpty && weekdays.count == cal.count {
                let days = Array(NSOrderedSet(array: weekdays)) as? [String] ?? weekdays
                return (.weekly, "\(days.joined(separator: ", ")) \(times.joined(separator: " · "))", days)
            }
            if cal.allSatisfy({ $0["Hour"] == nil }) { return (.interval, "hourly at :\(String(format: "%02d", (cal[0]["Minute"] as? Int) ?? 0))", []) }
            return (.daily, times.joined(separator: " · "), [])
        }
        if let s = p["StartInterval"] as? Int {
            let when = s < 60 ? "every \(s) s" : s < 3600 ? "every \(s / 60) min" : s % 3600 == 0 ? "every \(s / 3600) h" : "every \(s / 60) min"
            return (.interval, when, [])
        }
        if p["KeepAlive"] != nil && (p["KeepAlive"] as? Bool) != false { return (.always, "always", []) }
        if p["WatchPaths"] != nil || p["QueueDirectories"] != nil { return (.watch, "when files change", []) }
        if p["RunAtLoad"] as? Bool == true { return (.login, "at login", []) }
        return (.other, "on demand", [])
    }

    nonisolated private static func run(_ args: [String]) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated private static func launchctlList() -> [String: (pid: Int?, exit: Int?)] {
        var out: [String: (pid: Int?, exit: Int?)] = [:]
        for line in run(["list"]).split(separator: "\n").dropFirst() {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            out[String(parts[2])] = (Int(parts[0]), Int(parts[1]))
        }
        return out
    }

    nonisolated private static func disabledLabels() -> Set<String> {
        let text = run(["print-disabled", "gui/\(getuid())"])
        var out = Set<String>()
        for line in text.split(separator: "\n") where line.contains("=> disabled") || line.contains("=> true") {
            if let a = line.firstIndex(of: "\""), let b = line[line.index(after: a)...].firstIndex(of: "\"") {
                out.insert(String(line[line.index(after: a)..<b]))
            }
        }
        return out
    }
}

/// Names, descriptions and "if it fails" notes for automations, owned by the app (JSON next to its data,
/// readable and editable by agents). Labels without a note get a name made from the label.
@MainActor @Observable
final class AutomationNotes {
    static let shared = AutomationNotes()

    struct Note: Codable, Hashable {
        var title: String
        var detail: String = ""
        var safetyNet: Bool = false
        var hidden: Bool = false
        /// For notes that aren't a Mac job ("note:<name>"): how often or since when, in your words.
        var when: String?
        /// Optional live check for a note that isn't a Mac job:
        /// "app:<path>" (green when the app is there) or "file:<path>|<hours>" (green when updated within <hours>).
        var check: String?
    }

    /// Runs a note's live check: "ok", "failed" or "unknown" (no check / bad format). Paths may start with ~.
    nonisolated static func run(check: String?) -> String {
        guard let check, let colon = check.firstIndex(of: ":") else { return "unknown" }
        let kind = check[..<colon], rest = String(check[check.index(after: colon)...])
        let parts = rest.split(separator: "|", maxSplits: 1).map(String.init)
        guard let raw = parts.first, raw.count < 1024 else { return "unknown" }
        let path = (raw as NSString).expandingTildeInPath
        switch kind {
        case "app":
            return FileManager.default.fileExists(atPath: path) ? "ok" : "failed"
        case "file":
            guard let date = fileModified(path) else { return "failed" }
            let hours = parts.count > 1 ? Double(parts[1]) ?? 48 : 48
            return Date.now.timeIntervalSince(date) < min(max(hours, 1), 24 * 90) * 3600 ? "ok" : "failed"
        default:
            return "unknown"
        }
    }
    struct Failure: Codable, Hashable, Identifiable {
        var failure: String
        var happens: String
        var result: String
        var id: String { failure }
    }
    struct File: Codable { var notes: [String: Note] = [:]; var failures: [Failure] = [] }

    private(set) var file = File()
    private let url = URL.hmSupport.appending(path: "automations.json")

    init() {
        if let d = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(File.self, from: d) { file = f }
    }

    func note(_ label: String) -> Note {
        file.notes[label] ?? Note(title: Self.title(from: label))
    }

    func set(_ label: String, _ note: Note) { file.notes[label] = note; save() }

    func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? enc.encode(file).write(to: url, options: .atomic)
    }

    var isEmpty: Bool { file.notes.isEmpty && file.failures.isEmpty }

    /// "com.example.tools.disk-guard" -> "Disk guard"
    static func title(from label: String) -> String {
        let last = label.split(separator: ".").last.map(String.init) ?? label
        let words = last.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// One-time import of words you already wrote (e.g. your portal's automation page), so nothing is lost.
    /// Only fills labels that have no note yet; after this the app owns the words.
    func importOnce(notes: [String: Note], failures: [Failure]) {
        for (k, v) in notes where file.notes[k] == nil { file.notes[k] = v }
        if file.failures.isEmpty { file.failures = failures }
        save()
    }
}


/// Job lists: any script, bot or cloud service can describe its own scheduled jobs in a small JSON file in
/// ~/Library/Application Support/Hmunmawi/joblists/ (format in AGENTS.md). The app shows them beside the
/// Mac's launchd jobs, so schedulers it can't see (a script's own routines, GitHub, a cloud bot) still appear.
///   {"source": "...", "who": "mac|bot|cloud", "off": false,
///    "jobs": [{"id", "title", "detail", "at": "HH:MM", "every": "5 min", "days": ["Mon"], "off": false,
///              "last": {"date": "YYYY-MM-DD", "status": "ran|failed|missed"},
///              "proof": "~/path/{date}.json"}]}
/// "proof" (optional): a file the job writes when it runs; {date} becomes today's YYYY-MM-DD. If it exists
/// (or, without {date}, changed today), today's run counts as done. Lets bots and cloud jobs show real status.
enum JobLists {
    static let folder = URL.hmSupport.appending(path: "joblists")

    struct Entry: Identifiable, Hashable {
        let id: String
        let source: String
        let who: String
        let title: String
        let detail: String
        let at: String?
        let every: String?
        let days: [String]
        let off: Bool
        let lastStatus: String?
    }

    static func read() -> [Entry] {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var out: [Entry] = []
        for f in files where f.pathExtension == "json" {
            guard ((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) < 512_000,
                  let d = try? Data(contentsOf: f), let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            let source = InputRule.name.clean(root["source"] as? String ?? f.deletingPathExtension().lastPathComponent)
            let who = InputRule.identifier.clean(root["who"] as? String ?? "mac")
            let allOff = root["off"] as? Bool == true
            let today = Date.now.localDay
            for (i, j) in ((root["jobs"] as? [[String: Any]]) ?? []).prefix(200).enumerated() {
                // A routine another scheduler runs is shown once, by that scheduler's own entry.
                if let e = j["elsewhere"] as? String, !e.isEmpty { continue }
                var j = j
                // Built-in routines show their real timing and whether they went out today.
                switch j["does"] as? String {
                case "morning-story":
                    j["at"] = "08:00"; j["days"] = [String]()
                    if UserDefaults.standard.string(forKey: "HMMorningStorySent") == today { j["last"] = ["date": today, "status": "ran"] }
                case "weekly-digest":
                    let wd = (UserDefaults.standard.object(forKey: "HMDigestWeekday") as? Int) ?? 2
                    let hr = (UserDefaults.standard.object(forKey: "HMDigestHour") as? Int) ?? 9
                    j["at"] = String(format: "%02d:00", hr); j["days"] = [RoutineSchedule.weekdays[max(0, min(6, wd - 1))]]
                    if UserDefaults.standard.string(forKey: "HMWeeklyDigestSent") == today { j["last"] = ["date": today, "status": "ran"] }
                default: break
                }
                let last = j["last"] as? [String: Any]
                var status = (last?["date"] as? String) == today ? (last?["status"] as? String) : nil
                if status == nil, let proof = (j["proof"] as? String).map({ InputRule.path.clean($0) }), !proof.isEmpty {
                    status = proofRan(proof, today: today) ? "ran" : nil
                }
                out.append(Entry(id: "\(source)#\(j["id"] as? String ?? String(i))", source: source,
                                 who: (j["who"] as? String).map { InputRule.identifier.clean($0) } ?? who,
                                 title: InputRule.name.clean(j["title"] as? String ?? "Job"),
                                 detail: InputRule.text(600).clean(j["detail"] as? String ?? ""),
                                 at: (j["at"] as? String).map { InputRule.short.clean($0) },
                                 every: (j["every"] as? String).map { InputRule.short.clean($0) },
                                 days: ((j["days"] as? [String]) ?? []).map { String($0.prefix(3)) },
                                 off: allOff || j["off"] as? Bool == true,
                                 lastStatus: status.map { InputRule.identifier.clean($0) }))
            }
        }
        return out
    }

    /// True when a job's proof file shows it ran today.
    static func proofRan(_ pattern: String, today: String) -> Bool {
        let path = (pattern.replacingOccurrences(of: "{date}", with: today) as NSString).expandingTildeInPath
        guard let date = fileModified(path) else { return false }
        return pattern.contains("{date}") || Calendar.current.isDateInToday(date)
    }
}
