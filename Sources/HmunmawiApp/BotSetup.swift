import AppKit
import CryptoKit
import SwiftUI
import Foundation
import HmunmawiCore

/// Working with a bot that has no shell (Grok Bot and the like): Hmunmawi writes what the bot should do into a
/// shared folder and gives you one message to paste into the bot. The bot hands its results back as files, which
/// Hmunmawi checks arrived on time. Bots with a shell (Claude Code, Cursor, cloud agents) use `hm` instead.
enum BotSetup {
    static let folderKey = "HMBotFolder"
    static let copiedKey = "HMBotInstructionsCopied"   // hash of the message you last copied
    static let lateOptions = [30, 60, 120, 240]        // minutes after its time before a missing file counts as late

    /// The shared folder: a place both the bot and you can see (Documents, not Library, which a sandboxed bot
    /// app may not reach). Set with `hm set key=bot.folder`.
    static var folder: String {
        let f = UserDefaults.standard.string(forKey: folderKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return f.isEmpty ? "~/Documents/Hmunmawi Bot" : f
    }
    static var folderURL: URL { URL(filePath: (folder as NSString).expandingTildeInPath) }

    /// The routines your bot runs (listed with "Runs on: bot" and switched on).
    static func botRoutines(_ list: [MyRoutine] = MyRoutines.read()) -> [MyRoutine] {
        let key = AppModel.trustKey(KeychainSecretStore())
        return list.filter { $0.who == "bot" && $0.does == nil && $0.off != true && ($0.elsewhere ?? "").isEmpty && Routines.isTrusted($0, key: key) }
    }

    /// The file a routine's run leaves behind, with {date} explained.
    static func fileLine(_ r: MyRoutine) -> String? {
        guard let p = r.proof, !p.isEmpty else { return nil }
        return p.contains("{date}") ? "\(p) ({date} = that day's date, YYYY-MM-DD)" : "\(p) (update it each run)"
    }

    /// The message to paste into your bot. Plain text, so it works in any chat box.
    static func instructions(_ list: [MyRoutine] = MyRoutines.read()) -> String {
        let jobs = botRoutines(list)
        let name = BotName.current == "Your bot" ? "my bot" : BotName.current
        var out = """
        Hi \(name). I use Hmunmawi, a Mac app that runs my app business's routine jobs. These are the jobs I'd like you \
        to do for me. Please save them as your scheduled routines and follow them exactly.

        Shared folder (you and Hmunmawi both use it): \(folder)
        Write your results as files. Hmunmawi only reads them, it never runs anything you write. Write each file \
        completely (a temporary name, then rename it), never put passwords or keys in them, and use plain JSON or text.

        """
        if jobs.isEmpty {
            out += "\nThere are no jobs for you yet. I'll send you an updated message when there are.\n"
        } else {
            out += "\nJobs (times are my Mac's local time):\n"
            for (i, r) in jobs.enumerated() {
                out += "\n\(i + 1). \(r.title): \(MyRoutines.when(r))\n"
                if !r.detail.isEmpty { out += "   What to do: \(r.detail)\n" }
                if let f = fileLine(r) { out += "   When done, write: \(f)\n" }
                if let late = r.params?["late"].flatMap(Int.init), r.proof != nil {
                    out += "   Hmunmawi tells me if that file isn't there \(lateText(late)) after the time above.\n"
                }
            }
        }
        out += """

        If a job can't be done (a login expired, a site is down), write a file named "problem-<job>-<date>.txt" in the \
        shared folder saying what went wrong in a line or two, instead of guessing; Hmunmawi passes it on to me.
        When I change these jobs, I'll paste an updated version of this message: replace your routines with it.
        """
        return out
    }

    static func lateText(_ minutes: Int) -> String {
        minutes % 60 == 0 ? (minutes == 60 ? "1 hour" : "\(minutes / 60) hours") : "\(minutes) minutes"
    }

    static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// True when the jobs changed since you last copied the message (nothing copied yet = nothing to warn about).
    static var needsUpdate: Bool {
        guard let copied = UserDefaults.standard.string(forKey: copiedKey) else { return false }
        return copied != hash(instructions())
    }

    /// Called when you copy the message: remembers it, and creates the shared folder with routines.md.
    static func markCopied() {
        UserDefaults.standard.set(hash(instructions()), forKey: copiedKey)
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        syncFile()
    }

    /// Keeps routines.md in the shared folder current. Only once the folder exists (you set up the bot), so
    /// nothing appears in Documents on its own.
    static func syncFile(_ list: [MyRoutine] = MyRoutines.read()) {
        var dir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &dir), dir.boolValue else { return }
        let url = folderURL.appending(path: "routines.md")
        let text = "# Routines for \(BotName.current)\n\nWritten by Hmunmawi; changes here are overwritten. Change routines in Hmunmawi (Automations → Your routines).\n\n```\n\(instructions(list))\n```\n"
        let existing = try? String(contentsOf: url, encoding: .utf8)
        if existing == text { return }
        // Only a file Hmunmawi wrote (or none): never someone else's routines.md in a folder pointed here.
        if let existing, !existing.hasPrefix("# Jobs for "), !existing.hasPrefix("# Routines for ") { return }   // only a file Hmunmawi wrote
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// New "problem-….txt" files your bot left in the shared folder (written in the last 2 days, not told yet),
    /// as (file name, its first lines). Marks them as told.
    struct Problem { let id: String; let name: String; let text: String }

    /// Problem files not told yet (written in the last 2 days), oldest name first. Marked seen only once told.
    static func newProblems(now: Date = .now) -> [Problem] {
        let seen = Set(UserDefaults.standard.stringArray(forKey: "HMBotProblemsSeen") ?? [])
        let files = (try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
        var out: [Problem] = []
        for f in files where f.lastPathComponent.hasPrefix("problem-") && f.pathExtension == "txt" {
            let v = try? f.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard let m = v?.contentModificationDate, now.timeIntervalSince(m) < 2 * 86_400, (v?.fileSize ?? 0) < 64_000 else { continue }
            let id = "\(f.lastPathComponent)@\(Int(m.timeIntervalSince1970))"
            guard !seen.contains(id) else { continue }
            let text = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
            out.append(Problem(id: id, name: f.lastPathComponent, text: InputRule.text(400).clean(text.trimmingCharacters(in: .whitespacesAndNewlines))))
        }
        return out.sorted { $0.name < $1.name }
    }

    static func markSeen(_ ids: [String]) {
        let d = UserDefaults.standard
        let seen = (d.stringArray(forKey: "HMBotProblemsSeen") ?? []) + ids
        d.set(Array(seen.suffix(300)), forKey: "HMBotProblemsSeen")
        let today = Date.now.localDay
        let count = d.string(forKey: "HMBotProblemsDay") == today ? d.integer(forKey: "HMBotProblemsCount") : 0
        d.set(today, forKey: "HMBotProblemsDay"); d.set(count + 1, forKey: "HMBotProblemsCount")
    }

    /// Problem messages sent today (at most 10 a day, so a bot stuck in a loop can't flood you).
    static func problemsToldToday() -> Int {
        let d = UserDefaults.standard
        return d.string(forKey: "HMBotProblemsDay") == Date.now.localDay ? d.integer(forKey: "HMBotProblemsCount") : 0
    }

    /// The bot routine's file is late today: its time + grace has passed, it ran on no earlier day's file,
    /// and today is one of its days. nil = not late (or not watched).
    static func lateSince(_ r: MyRoutine, now: Date = .now, calendar: Calendar = .current) -> Date? {
        guard r.does == nil, r.off != true, let proof = r.proof, !proof.isEmpty,
              let late = r.params?["late"].flatMap(Int.init),
              let due = RoutineSchedule.overdue(at: r.at, days: r.days, lateMinutes: late, now: now, calendar: calendar) else { return nil }
        return JobLists.proofRan(InputRule.path.clean(proof), today: now.localDay) ? nil : due
    }
}

/// "Set up your bot": the bot's name, the shared folder and the message to paste into the bot.
struct BotSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = UserDefaults.standard.string(forKey: "HMBotName") ?? ""
    @State private var folder = UserDefaults.standard.string(forKey: BotSetup.folderKey) ?? ""
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set up your bot").font(.title2.bold())
            Text("For a bot you chat with (like Grok Bot): copy this message and paste it into the bot once. It saves the jobs as its own routines and leaves its results as files in the shared folder; Hmunmawi checks they arrive.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Bot's name").gridColumnAlignment(.trailing)
                    TextField("Bot's name", text: $name, prompt: Text("Your bot")).labelsHidden().input(.name, $name)
                        .onChange(of: name) { UserDefaults.standard.set(name.trimmingCharacters(in: .whitespaces), forKey: "HMBotName"); copied = false }
                }
                GridRow {
                    Text("Shared folder")
                    HStack(alignment: .firstTextBaseline) {
                        // Wraps instead of cutting a long path off.
                        TextField("Shared folder", text: $folder, prompt: Text("~/Documents/Hmunmawi Bot"), axis: .vertical)
                            .lineLimit(1...3).labelsHidden().input(.path, $folder)
                            .onChange(of: folder) { UserDefaults.standard.set(folder.trimmingCharacters(in: .whitespaces), forKey: BotSetup.folderKey); copied = false }
                        Button("Show") {
                            try? FileManager.default.createDirectory(at: BotSetup.folderURL, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(BotSetup.folderURL)
                        }
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
            ScrollView {
                Text(BotSetup.instructions()).font(.callout.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            .frame(height: 340)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            Text("Claude Code, Cursor and other agents that can run commands need nothing pasted: they read and change the same list with `hm routine-list` (see `hm help`).")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if copied {
                    Label("Copied. Paste it into \(BotName.inSentence).", systemImage: "checkmark.circle.fill").foregroundStyle(Brand.good)
                }
                Spacer()
                Button("Copy message") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(BotSetup.instructions(), forType: .string)
                    BotSetup.markCopied()
                    copied = true
                }
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.pillProminent)
            }
        }
        .padding(22)
        .frame(width: 620)
    }
}
