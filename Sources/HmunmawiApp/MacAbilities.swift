import Foundation
import HmunmawiCore

/// Runs inside the signed app, which holds the Automation permission for Messages.
struct AppMacAbilities: MacAbilities {
    /// Recipient and text arrive as arguments, never spliced into the script text.
    static let sendScript = """
        on run argv
            tell application "Messages"
                set targetService to 1st account whose service type = iMessage
                send (item 2 of argv) to participant (item 1 of argv) of targetService
            end tell
        end run
        """

    func perform(_ ability: String, params: JSONValue) async throws -> JSONValue {
        switch ability {
        case "messages.send":
            guard let to = params[path: "to"]?.string,
                  to.wholeMatch(of: /\+?[0-9 ()-]{5,20}|[^\s"\\@]+@[^\s"\\@]+\.[^\s"\\@]+/) != nil
            else { throw WireError("bad_recipient", "Use a phone number or an email address") }
            let text = String((params[path: "text"]?.string ?? "").prefix(1000))
            if let note = await MainActor.run(body: { Permissions.shared.deferIfNeeded([.messages]) }) {
                throw WireError("needs_permission", note)
            }
            try await Self.osascript(Self.sendScript, arguments: [to, text])
            return .object(["sent": .bool(true)])
        default:
            throw WireError("unknown_ability", "This app can't do “\(ability)”")
        }
    }

    /// A separate process, so a slow Messages app never blocks Hmunmawi. The child inherits this signed app as the
    /// responsible process for Automation, so the grant stays on Hmunmawi's bundle id rather than on a versioned binary.
    /// Permission must already be granted (pre-flight above); this must not be the place a system box first appears.
    static func osascript(_ script: String, arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-"] + arguments
        let input = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data(script.utf8))
        try input.fileHandleForWriting.close()
        // Never left hanging (e.g. a Messages permission prompt nobody answers): stopped after 45 seconds,
        // well inside the app's own wait, so a late send can't overlap a second one.
        let watchdog = Task.detached {
            try? await Task.sleep(for: .seconds(45))
            if !Task.isCancelled, process.isRunning { process.terminate() }
        }
        defer { watchdog.cancel() }
        let message = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let data = errors.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
        guard process.terminationStatus == 0 else {
            throw WireError("messages_failed", String(message.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)))
        }
    }
}
