import AppKit
import HmunmawiCore
import SwiftUI

/// Where the outreach reply watch gets its mail from. Off by default; a script feed that already supplies mail keeps
/// working beside this. Both sources are read-only and list-level: sender, subject, dates, message ids. Nothing is
/// sent, moved, flagged or deleted, and no message text is read.
enum MailSourceKind: String, CaseIterable, Identifiable {
    case off, appleMail, imap, zohoSafari
    var id: String { rawValue }
    var title: String { switch self { case .off: "Off"; case .appleMail: "Apple Mail"; case .imap: "Other mail (IMAP)"; case .zohoSafari: "Zoho Mail (your Safari login)" } }
    /// The choices offered: the Zoho Safari reader only when Your extras (or an owner settings file) switch it on, or
    /// when it is already picked.
    static func offered(current: MailSourceKind, owner: OwnerConfig = .current, extras: Bool? = nil) -> [MailSourceKind] {
        let zoho = extras ?? Extras.current.zohoMail.on
        return allCases.filter { $0 != .zohoSafari || owner.offersZoho || zoho || current == .zohoSafari }
    }
}

@MainActor
enum MailWatch {
    static let kindKey = "HMMailSource", hostKey = "HMMailHost", portKey = "HMMailPort", userKey = "HMMailUser"
    static let zohoHostKey = "HMMailZohoHost", lastKey = "HMMailLastRun", noteKey = "HMMailNote"
    private static let secrets = KeychainSecretStore()

    static var kind: MailSourceKind { MailSourceKind(rawValue: UserDefaults.standard.string(forKey: kindKey) ?? "") ?? .off }
    static var note: String { UserDefaults.standard.string(forKey: noteKey) ?? "" }

    static func password() -> String { ((try? secrets.secret(plugin: "mail", name: "imap-password")) ?? nil) ?? "" }
    static func setPassword(_ p: String) throws {
        if p.isEmpty { secrets.deleteSecret(plugin: "mail", name: "imap-password") } else { try secrets.setSecret(p, plugin: "mail", name: "imap-password") }
    }

    static var imapConfig: IMAPConfig {
        let d = UserDefaults.standard
        return IMAPConfig(host: d.string(forKey: hostKey) ?? "", port: (d.object(forKey: portKey) as? Int) ?? 993,
                          username: d.string(forKey: userKey) ?? "", password: password())
    }

    /// Reads the chosen source (at most every 10 minutes unless `force`) and hands new rows to the store. Returns a
    /// plain-words note for the log. Never throws: a failing mailbox must not stop the routine around it.
    static func refresh(model: AppModel, force: Bool = false) async -> String {
        let source = kind
        guard source != .off else { return "" }
        let last = UserDefaults.standard.double(forKey: lastKey)
        if !force, Date.now.timeIntervalSince1970 - last < 600 { return note }
        let result: Result<[MailRow], Error>
        switch source {
        case .appleMail:
            if let note = Permissions.shared.deferIfNeeded([.mail]) { return note }
        case .zohoSafari:
            if let note = Permissions.shared.deferIfNeeded([.safari]) { return note }
        default: break
        }
        switch source {
        case .imap:
            let config = imapConfig
            do { result = .success(try await IMAPMail.fetch(config, transport: IMAPTLSTransport(host: config.host.trimmingCharacters(in: .whitespaces), port: config.port))) }
            catch { result = .failure(error) }
        case .appleMail:
            result = await AppleMailReader.read()
        case .zohoSafari:
            result = await ZohoSafariReader.read(host: UserDefaults.standard.string(forKey: zohoHostKey) ?? "mail.zoho.com")
        case .off: return ""
        }
        UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: lastKey)
        var message: String
        switch result {
        case .success(let rows):
            let added = await model.ingestMail(rows)
            message = "Read \(rows.count) message\(rows.count == 1 ? "" : "s") from \(source.title) (\(added) new)."
        case .failure(let e):
            message = (e as? IMAPError)?.message ?? (e as? WireError)?.message ?? "Couldn't read the mail: \(e.localizedDescription)"
        }
        UserDefaults.standard.set(message, forKey: noteKey)
        return message
    }
}

/// Apple Mail through its scripting interface: list level only (sender, subject, date sent, message id). Needs the
/// one "control Mail" permission, asked in Settings → Permissions (never in the middle of a run).
enum AppleMailReader {
    static func read(days: Int = 30, limit: Int = 300) async -> Result<[MailRow], Error> {
        await Task.detached(priority: .utility) { () -> Result<[MailRow], Error> in
            let script = """
            tell application "Mail"
                set cutoff to (current date) - (\(days) * days)
                set out to {}
                repeat with box in {inbox, sent mailbox}
                    set tag to "INBOX"
                    if box is sent mailbox then set tag to "SENT"
                    set found to (messages of box whose date received > cutoff)
                    set n to count of found
                    set startAt to 1
                    if n > \(limit) then set startAt to n - \(limit) + 1
                    repeat with i from startAt to n
                        set m to item i of found
                        set end of out to {tag, sender of m, subject of m, (date sent of m), message id of m}
                    end repeat
                end repeat
                return out
            end tell
            """
            var error: NSDictionary?
            guard let apple = NSAppleScript(source: script) else { return .failure(WireError("mail", "Couldn't prepare the Apple Mail read.")) }
            let d = apple.executeAndReturnError(&error)
            if let error {
                let code = error[NSAppleScript.errorNumber] as? Int ?? 0
                return .failure(WireError("mail", code == -1743
                    ? "Apple Mail isn't allowed yet: switch it on in Settings → Permissions."
                    : "Apple Mail couldn't be read (error \(code)). Is the Mail app set up with an account?"))
            }
            var rows: [MailRow] = []
            for i in 0..<max(0, d.numberOfItems) {
                guard let item = d.atIndex(i + 1), item.numberOfItems >= 5 else { continue }
                let tag = item.atIndex(1)?.stringValue ?? "INBOX", from = item.atIndex(2)?.stringValue ?? "", subject = item.atIndex(3)?.stringValue ?? ""
                let messageID = (item.atIndex(5)?.stringValue ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
                guard !messageID.isEmpty else { continue }
                let ms = item.atIndex(4)?.dateValue.map { Int64($0.timeIntervalSince1970 * 1000) }
                rows.append(MailRow(id: "applemail-\(messageID.prefix(120))-\(tag)", from: MailHeaders.decodeWords(from), subject: MailHeaders.decodeWords(subject),
                                    folder: tag, sentMs: ms, messageID: messageID, inReplyTo: nil))
            }
            return .success(rows)
        }.value
    }
}


/// Zoho Mail's free plan has no IMAP, so this reads the message LIST (sender, subject, folder) from Zoho's own web page
/// in a background Safari tab, using the Zoho login Safari already has. It never opens a message (Zoho would mark it
/// read), sends, moves or deletes anything, and never sees the password. Zoho publishes no page layout for this, so it
/// can stop working when Zoho redesigns the page: the note then says so. Needs Safari's Develop → "Allow JavaScript from
/// Apple Events" and the one Safari permission in Settings → Permissions.
enum ZohoSafariReader {
    static let hosts = ["mail.zoho.com", "mail.zoho.in", "mail.zoho.eu", "mail.zoho.com.au", "mail.zoho.jp"]

    static func read(host: String) async -> Result<[MailRow], Error> {
        guard hosts.contains(host) else { return .failure(WireError("mail", "Pick the Zoho address you sign in at.")) }
        return await Task.detached(priority: .utility) { () -> Result<[MailRow], Error> in
            let js = "(function(){var rows=document.querySelectorAll('.zmList');if(!rows.length)return '';return JSON.stringify(Array.prototype.slice.call(rows,0,60).map(function(r){function q(s){var e=r.querySelector(s);return e?((e.getAttribute('title')||e.innerText||'').trim()):'';}return {id:r.id,from:q('.zmLSenderName'),subject:q('.zmLSub'),folder:q('.zmLFolder')};}));})()"
            let script = """
            tell application "Safari"
                if (count of windows) is 0 then make new document
                set t to make new tab at end of tabs of window 1 with properties {URL:"https://\(host)/zm/#mail/views/all"}
                set res to ""
                repeat 20 times
                    delay 1.5
                    try
                        set res to do JavaScript "\(js.replacingOccurrences(of: "\"", with: "\\\""))" in t
                    end try
                    if res is not "" and res is not "[]" and res is not missing value then exit repeat
                end repeat
                close t
                return res
            end tell
            """
            var error: NSDictionary?
            guard let apple = NSAppleScript(source: script) else { return .failure(WireError("mail", "Couldn't prepare the Safari read.")) }
            let d = apple.executeAndReturnError(&error)
            if let error {
                let code = error[NSAppleScript.errorNumber] as? Int ?? 0
                return .failure(WireError("mail", code == -1743
                    ? "Safari isn't allowed yet: switch it on in Settings → Permissions."
                    : "Safari couldn't be read (error \(code)). In Safari, turn on Develop → Allow JavaScript from Apple Events."))
            }
            guard let text = d.stringValue, !text.isEmpty, let data = text.data(using: .utf8),
                  let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
                return .failure(WireError("mail", "Zoho's list didn't load. Are you signed in to \(host) in Safari? (If you are, Zoho may have changed its page.)"))
            }
            let rows: [MailRow] = list.compactMap { m in
                guard let id = m["id"] as? String, !id.isEmpty else { return nil }
                let folder = (m["folder"] as? String ?? "").lowercased().contains("sent") ? "SENT" : "INBOX"
                return MailRow(id: "zoho-\(id.prefix(80))", from: String((m["from"] as? String ?? "").prefix(200)),
                               subject: String((m["subject"] as? String ?? "").prefix(300)), folder: folder, sentMs: nil,
                               messageID: "zoho-\(id.prefix(80))", inReplyTo: nil)
            }
            return .success(rows)
        }.value
    }
}
