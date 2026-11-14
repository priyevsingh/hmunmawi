import AppKit
import HmunmawiCore
import SwiftUI

/// Run now, Pause / Resume and Show log for one scheduled Mac job, from its row on "Your Mac's day".
/// Only for your own launchd agents (the script feed's AI routines are started by their scheduler, so they get
/// Show log only). Every action asks first and is written to the activity log.
enum JobControl {
    private static var domain: String { "gui/\(getuid())" }

    /// Starts the job now (if it's already running, nothing happens).
    static func runNow(_ label: String) -> String {
        launchctl(["kickstart", "\(domain)/\(label)"]) ? "Started. Its result shows here after the next check." : "macOS didn't start it."
    }

    /// Stops it from running on its schedule until you resume it (survives restarts).
    static func pause(_ label: String) -> String {
        _ = launchctl(["disable", "\(domain)/\(label)"])
        _ = launchctl(["bootout", "\(domain)/\(label)"])
        return "Paused. It won't run until you resume it."
    }

    static func resume(_ label: String, plist: String?) -> String {
        _ = launchctl(["enable", "\(domain)/\(label)"])
        if let plist { _ = launchctl(["bootstrap", domain, plist]) }
        return "Resumed. It runs again on its schedule."
    }

    /// Opens the job's log in Console.
    static func showLog(_ path: String) {
        NSWorkspace.shared.open([URL(fileURLWithPath: path)],
                                withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    @discardableResult
    private static func launchctl(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}

/// The "…" menu on a job row.
struct JobMenu: View {
    let run: AutomationDay.Run
    let model: AppModel
    @State private var confirm: Action?
    @State private var result: String?

    enum Action: Identifiable { case run, pause, resume; var id: Self { self } }

    var body: some View {
        if run.label != nil || run.log != nil {
            Menu {
                if run.label != nil {
                    Button("Run now", systemImage: "play.fill") { confirm = .run }
                    if run.paused {
                        Button("Resume", systemImage: "playpause.fill") { confirm = .resume }
                    } else {
                        Button("Pause", systemImage: "pause.fill") { confirm = .pause }
                    }
                }
                if let log = run.log {
                    Button("Show log", systemImage: "doc.text.magnifyingglass") { JobControl.showLog(log) }
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
            .menuStyle(.button).buttonStyle(.borderless).menuIndicator(.hidden).fixedSize()
            .help(result ?? "Run now, pause or see the log of \(run.title)")
            .accessibilityLabel("Actions for \(run.title)")
            .confirmationDialog(title, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                                titleVisibility: .visible) {
                Button(button) { perform() }
                Button("Cancel", role: .cancel) { confirm = nil }
            } message: {
                Text(message)
            }
        }
    }

    private var title: String {
        switch confirm {
        case .run: "Run \(run.title) now?"
        case .pause: "Pause \(run.title)?"
        case .resume: "Resume \(run.title)?"
        case nil: ""
        }
    }
    private var button: String { confirm == .run ? "Run now" : confirm == .pause ? "Pause" : "Resume" }
    private var message: String {
        switch confirm {
        case .run: "It runs once now, the same as at its scheduled time. Anything it sends (messages, posts, PRs) goes out as usual."
        case .pause: "It stops running on its schedule, also after a restart, until you resume it here."
        case .resume: "It runs on its schedule again."
        case nil: ""
        }
    }

    private func perform() {
        guard let label = run.label, let action = confirm else { return }
        let text = switch action {
        case .run: JobControl.runNow(label)
        case .pause: JobControl.pause(label)
        case .resume: JobControl.resume(label, plist: run.plist)
        }
        result = text
        confirm = nil
        Task { await model.recordJobAction("\(button.lowercased()): \(run.title)", label: label) }
    }
}
