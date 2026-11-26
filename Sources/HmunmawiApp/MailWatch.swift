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

    /// Auto-fills `HMOwnEmail` from the configured mail username if empty so users don't enter it twice.
    static func syncOwnEmailIfEmpty() {
        let d = UserDefaults.standard
        let own = (d.string(forKey: Outreach.ownKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard own.isEmpty else { return }
        let user = (d.string(forKey: userKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if SMTPConfig.isSingleEmail(user) {
            d.set(user, forKey: Outreach.ownKey)
        }
    }

    /// Reads the chosen source (at most every 10 minutes unless `force`) and hands new rows to the store. Returns a
    /// plain-words note for the log. Never throws: a failing mailbox must not stop the routine around it.
    static func refresh(model: AppModel, force: Bool = false) async -> String {
        syncOwnEmailIfEmpty()
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
        let matchers = outreachMatchers()
        switch source {
        case .imap:
            let config = imapConfig
            do {
                result = .success(try await IMAPMail.fetch(config, transport: IMAPTLSTransport(host: config.host.trimmingCharacters(in: .whitespaces), port: config.port),
                                                           matchOutreach: { Self.matchesOutreach(from: $0.from, subject: $0.subject, matchers: matchers) }))
            }
            catch { result = .failure(error) }
        case .appleMail:
            result = await AppleMailReader.read()
        case .zohoSafari:
            result = await ZohoSafariReader.read(host: UserDefaults.standard.string(forKey: zohoHostKey) ?? "mail.zoho.com",
                                                 matching: { Self.matchesOutreach(from: $0.from, subject: $0.subject, matchers: matchers) })
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

    struct OutreachMatchers: Sendable {
        let emails: Set<String>
        let domains: Set<String>
        let subjects: Set<String>
    }

    static func outreachMatchers() -> OutreachMatchers {
        var emails = Set<String>()
        var domains = Set<String>()
        var subjects = Set<String>()
        for item in Outreach.items() {
            if let c = item.contact?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty {
                if c.contains("@") { emails.insert(c) }
                if let d = ReplyMatch.domain(c), !ReplyMatch.sharedDomains.contains(d) { domains.insert(d) }
            }
            if let s = item.subject, !s.isEmpty {
                let t = ReplyMatch.thread(s)
                if t.count >= 4 { subjects.insert(t) }
            }
        }
        return OutreachMatchers(emails: emails, domains: domains, subjects: subjects)
    }

    nonisolated static func matchesOutreach(from: String, subject: String, matchers: OutreachMatchers) -> Bool {
        let addr = ReplyMatch.address(from)
        if !addr.isEmpty, matchers.emails.contains(addr) { return true }
        if let d = ReplyMatch.domain(from), !ReplyMatch.sharedDomains.contains(d), matchers.domains.contains(d) { return true }
        let t = ReplyMatch.thread(subject)
        if !t.isEmpty, matchers.subjects.contains(t) { return true }
        return false
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

    /// Validates Zoho message/thread IDs (`/^t?\d{6,25}$/`) before passing them to `md.do`.
    nonisolated static func isValidMessageID(_ raw: String) -> Bool {
        raw.wholeMatch(of: /^t?\d{6,25}$/) != nil
    }

    static func read(host: String, matching: @escaping @Sendable (MailRow) -> Bool = { _ in false }) async -> Result<[MailRow], Error> {
        guard hosts.contains(host) else { return .failure(WireError("mail", "Pick the Zoho address you sign in at.")) }
        return await Task.detached(priority: .utility) { () -> Result<[MailRow], Error> in
            let js = "(function(){var rows=document.querySelectorAll('.zmList');if(!rows.length)return '';return JSON.stringify(Array.prototype.slice.call(rows,0,60).map(function(r){function q(s){var e=r.querySelector(s);return e?((e.getAttribute('title')||e.innerText||'').trim()):'';}return {id:r.id,msgid:(r.getAttribute('data-msgid')||r.id||''),from:q('.zmLSenderName'),subject:q('.zmLSub'),folder:q('.zmLFolder')};}));})()"
            // Its own tagged tab through SafariAuto: the shared Safari lock, found by tag, closed on every path.
            let session = SafariAuto.Session(job: "zoho_mail")
            func fail(_ e: Error) -> Result<[MailRow], Error> {
                if case SafariAuto.Failure.busy = e {
                    return .failure(WireError("mail", "Safari is busy with another Hmunmawi job; the mail read is tried again at the next check."))
                }
                let msg = (e as? SafariAuto.Failure).flatMap { if case .script(let m) = $0 { return m } else { return nil } } ?? ""
                return .failure(WireError("mail", msg.contains("-1743")
                    ? "Safari isn't allowed yet: switch it on in Settings → Permissions."
                    : "Safari couldn't be read (\(msg.isEmpty ? "unknown error" : String(msg.prefix(80)))). In Safari, turn on Develop → Allow JavaScript from Apple Events."))
            }
            do { try await session.enter(timeout: 240) } catch { return fail(error) }
            var found = ""
            var rawList: [[String: Any]] = []
            var bodiesByID: [String: String] = [:]
            do {
                let tab = try await session.open(url: "https://\(host)/zm/#mail/views/all", needle: "mail.zoho", seconds: 30)
                for _ in 0..<20 {
                    try? await Task.sleep(for: .seconds(1.5))
                    if let r = try? await tab.js(js), !r.isEmpty, r != "[]", r != "missing value" { found = r; break }
                }
                if !found.isEmpty, let data = found.data(using: .utf8),
                   let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
                    rawList = list
                    // Read-only md.do body fetch ONLY for INBOX rows matching outreach contacts/domains/threads,
                    // keeping unread status untouched and validating message ids strictly.
                    var fetched = 0
                    for m in list where fetched < 15 {
                        guard let rawID = m["id"] as? String, !rawID.isEmpty else { continue }
                        let folder = (m["folder"] as? String ?? "").lowercased().contains("sent") ? "SENT" : "INBOX"
                        guard folder == "INBOX" else { continue }
                        let row = MailRow(id: "zoho-\(rawID.prefix(80))",
                                          from: String((m["from"] as? String ?? "").prefix(200)),
                                          subject: String((m["subject"] as? String ?? "").prefix(300)),
                                          folder: folder, sentMs: nil,
                                          messageID: "zoho-\(rawID.prefix(80))", inReplyTo: nil)
                        guard matching(row) else { continue }
                        let msgID = ((m["msgid"] as? String) ?? rawID).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard Self.isValidMessageID(msgID) else { continue }
                        fetched += 1
                        let readJS = """
                        (function(){var x=new XMLHttpRequest();x.open('GET','/zm/md.do?msgId=\(msgID)&isMsgRead=false&mode=view',false);x.send(null);if(x.status!==200)return '';return (x.responseText||'').slice(0,32768);})()
                        """
                        if let rawBody = try? await tab.js(readJS), !rawBody.isEmpty, rawBody != "missing value" {
                            let extracted = Self.extractZohoBody(rawBody)
                            let clean = MailBodyText.clean(extracted)
                            if !clean.isEmpty { bodiesByID[rawID] = clean }
                        }
                    }
                }
            } catch {
                await session.exit()
                return fail(error)
            }
            await session.exit()
            guard !found.isEmpty, !rawList.isEmpty else {
                return .failure(WireError("mail", "Zoho's list didn't load. Are you signed in to \(host) in Safari? (If you are, Zoho may have changed its page.)"))
            }
            let rows: [MailRow] = rawList.compactMap { m in
                guard let id = m["id"] as? String, !id.isEmpty else { return nil }
                let folder = (m["folder"] as? String ?? "").lowercased().contains("sent") ? "SENT" : "INBOX"
                return MailRow(id: "zoho-\(id.prefix(80))", from: String((m["from"] as? String ?? "").prefix(200)),
                               subject: String((m["subject"] as? String ?? "").prefix(300)), folder: folder, sentMs: nil,
                               messageID: "zoho-\(id.prefix(80))", inReplyTo: nil, text: bodiesByID[id])
            }
            return .success(rows)
        }.value
    }

    /// Extracts message text from Zoho `md.do` JSON or HTML responses.
    nonisolated static func extractZohoBody(_ raw: String) -> String {
        if let d = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            if let c = obj["CONTENT"] as? String { return c }
            if let body = (obj["DATA"] as? [String: Any])?["CONTENT"] as? String { return body }
        }
        return raw
    }
}
