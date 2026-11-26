import AppKit
import Foundation
import HmunmawiCore

/// Outbound mail sender for owner-approved outreach emails:
///   1. SMTP (SMTPS port 465 / STARTTLS port 587, credentials in the app-owned `"mail"` Keychain area)
///   2. Zoho Mail via Safari (`SafariAuto.Session` on `mail.zoho.*`, for Zoho free plans without SMTP)
///   3. `mailto:` fallback when neither is configured (opens the draft in the user's mail app)
enum MailSendTransport: String, CaseIterable, Identifiable {
    case auto, smtp, zohoSafari, mailto
    var id: Self { self }
    var title: String {
        switch self {
        case .auto: "Automatic (SMTP, else Zoho Safari)"
        case .smtp: "SMTP (465 / 587)"
        case .zohoSafari: "Zoho Mail (your Safari login)"
        case .mailto: "Open in Mail app (mailto:)"
        }
    }
}

@MainActor
enum MailSender {
    static let transportKey = "HMMailSendTransport"
    static let smtpHostKey = "HMSMTPHost"
    static let smtpPortKey = "HMSMTPPort"
    static let smtpUserKey = "HMSMTPUser"
    static let smtpFromKey = "HMSMTPFrom"
    private static let secrets = KeychainSecretStore()

    static var transport: MailSendTransport {
        MailSendTransport(rawValue: UserDefaults.standard.string(forKey: transportKey) ?? "") ?? .auto
    }

    static func smtpPassword() -> String {
        ((try? secrets.secret(plugin: "mail", name: "smtp-password")) ?? nil) ?? ""
    }

    static func setSMTPPassword(_ p: String) throws {
        if p.isEmpty { secrets.deleteSecret(plugin: "mail", name: "smtp-password") }
        else { try secrets.setSecret(p, plugin: "mail", name: "smtp-password") }
    }

    static var smtpConfig: SMTPConfig {
        let d = UserDefaults.standard
        let user = d.string(forKey: smtpUserKey) ?? ""
        let from = d.string(forKey: smtpFromKey).flatMap { $0.isEmpty ? nil : $0 }
            ?? d.string(forKey: Outreach.ownKey).flatMap { $0.isEmpty ? nil : $0 }
            ?? user
        let port = (d.object(forKey: smtpPortKey) as? Int) ?? 465
        return SMTPConfig(host: d.string(forKey: smtpHostKey) ?? "", port: port, username: user, password: smtpPassword(), from: from)
    }

    static var isConfigured: Bool {
        smtpConfig.problem == nil || MailWatch.kind == .zohoSafari || transport == .zohoSafari
    }

    static var modeDescription: String {
        let t = transport
        if (t == .auto || t == .smtp), smtpConfig.problem == nil {
            return "SMTP (\(smtpConfig.host):\(smtpConfig.port))"
        }
        if t == .zohoSafari || (t == .auto && MailWatch.kind == .zohoSafari) {
            return "Zoho Mail (Safari)"
        }
        return "Mail app (mailto:)"
    }

    /// Sends one owner-approved outreach email. Never sends without a valid recipient pinned from the outreach list.
    static func send(to: String, subject: String, body: String, inReplyTo: String? = nil) async -> (ok: Bool, via: String, note: String) {
        let cleanTo = to.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SMTPConfig.isSingleEmail(cleanTo) else {
            return (false, "none", "Recipient address is missing or invalid; nothing was sent.")
        }
        let msg = SMTPMessage(to: cleanTo, subject: subject, body: body, inReplyTo: inReplyTo)
        if let problem = msg.problem {
            return (false, "none", problem)
        }

        let chosen = transport
        let cfg = smtpConfig
        if chosen == .smtp || (chosen == .auto && cfg.problem == nil) {
            if let problem = cfg.problem { return (false, "smtp", problem) }
            do {
                let net = SMTPStreamTransport(host: cfg.host.trimmingCharacters(in: .whitespaces), port: cfg.port)
                try await SMTPClient.send(msg, config: cfg, transport: net)
                return (true, "smtp", "Sent via SMTP (\(cfg.host)).")
            } catch let e as SMTPError {
                return (false, "smtp", e.message)
            } catch {
                return (false, "smtp", error.localizedDescription)
            }
        }

        if chosen == .zohoSafari || (chosen == .auto && MailWatch.kind == .zohoSafari) {
            if let deferNote = Permissions.shared.deferIfNeeded([.safari]) {
                return (false, "zoho", deferNote)
            }
            let zohoHost = UserDefaults.standard.string(forKey: MailWatch.zohoHostKey) ?? "mail.zoho.com"
            do {
                try await ZohoSafariSender.send(host: zohoHost, to: cleanTo, subject: subject, body: body)
                return (true, "zoho", "Sent via Zoho Mail (Safari).")
            } catch {
                return (false, "zoho", (error as? WireError)?.message ?? error.localizedDescription)
            }
        }

        // mailto: fallback (opens in the user's mail app rather than sending automatically)
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = cleanTo
        c.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
        if let u = c.url, NSWorkspace.shared.open(u) {
            return (false, "mailto", "Opened the draft in your Mail app (no SMTP or Zoho Safari sender configured). Send it there, then mark it done.")
        }
        return (false, "none", "No outbound mail sender is configured (Settings → Connections → Outbound mail).")
    }
}

/// Sends an owner-approved email through Zoho Webmail inside a dedicated SafariAuto tab.
/// Fails loudly if Zoho's compose DOM changed rather than claiming sent.
enum ZohoSafariSender {
    /// Encodes a Swift string as a safe JSON/JS string literal (never raw interpolation).
    nonisolated static func jsLiteral(_ value: String) -> String? {
        guard let d = try? JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes]),
              let arr = String(data: d, encoding: .utf8),
              arr.count >= 2 else { return nil }
        return String(arr.dropFirst().dropLast())
    }

    static func send(host: String, to: String, subject: String, body: String) async throws {
        guard ZohoSafariReader.hosts.contains(host) else {
            throw WireError("mail_send", "Pick a supported Zoho host in Settings → Connections.")
        }
        guard let toJS = jsLiteral(to), let subjJS = jsLiteral(subject), let bodyJS = jsLiteral(body) else {
            throw WireError("mail_send", "Couldn't encode message fields safely.")
        }
        try await Task.detached(priority: .utility) {
            let session = SafariAuto.Session(job: "zoho_send")
            do { try await session.enter(timeout: 240) } catch {
                if case SafariAuto.Failure.busy = error {
                    throw WireError("mail_send", "Safari is busy with another Hmunmawi job; try approving again in a moment.")
                }
                throw WireError("mail_send", "Safari isn't available for Zoho Mail send.")
            }
            defer { Task { await session.exit() } }

            let tab = try await session.open(url: "https://\(host)/zm/#mail/views/all", needle: "mail.zoho", seconds: 30)
            // 1. Open compose if not already open.
            let openJS = """
            (function(){
              var btn=document.querySelector('[data-testid*="compose"],.zmComposeBtn,button[title*="Compose"],a[href*="compose"]');
              if(btn){btn.click();return 'clicked';}
              return document.querySelector('input[placeholder*="Subject"],input[name="subject"],[data-testid="subject"]')?'already':'missing';
            })()
            """
            var opened = false
            for _ in 0..<12 {
                try? await Task.sleep(for: .seconds(1))
                let r = (try? await tab.js(openJS)) ?? ""
                if r == "clicked" || r == "already" { opened = true; break }
            }
            guard opened else {
                throw WireError("mail_send", "Zoho Mail's Compose button wasn't found (are you signed in, or did Zoho change its page?).")
            }

            // 2. Fill To, Subject, Body using JSON-encoded string literals and verify fields exist.
            let fillJS = """
            (function(){
              var toVal=\(toJS), subjVal=\(subjJS), bodyVal=\(bodyJS);
              var toEl=document.querySelector('input[data-testid*="to"],input[name="to"],.zmCmpTo input,input[aria-label="To"]');
              var subjEl=document.querySelector('input[placeholder*="Subject"],input[name="subject"],[data-testid="subject"]');
              var bodyEl=document.querySelector('.zmCmpBody [contenteditable="true"],iframe.ze_area,textarea[name="content"],[data-testid="compose-body"] [contenteditable="true"]');
              if(!toEl||!subjEl||!bodyEl) return 'missing_fields';
              function setInput(el,val){
                el.focus();
                var proto=Object.getPrototypeOf(el);
                var setter=Object.getOwnPropertyDescriptor(proto,'value');
                if(setter&&setter.set){setter.set.call(el,val);}else{el.value=val;}
                el.dispatchEvent(new Event('input',{bubbles:true}));
                el.dispatchEvent(new Event('change',{bubbles:true}));
                el.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',keyCode:13,bubbles:true}));
              }
              setInput(toEl,toVal);
              setInput(subjEl,subjVal);
              if(bodyEl.tagName==='IFRAME'){
                var doc=bodyEl.contentDocument;
                if(!doc||!doc.body) return 'missing_body_doc';
                doc.body.innerText=bodyVal;
              }else if(bodyEl.isContentEditable){
                bodyEl.focus();
                bodyEl.innerText=bodyVal;
                bodyEl.dispatchEvent(new Event('input',{bubbles:true}));
              }else{
                setInput(bodyEl,bodyVal);
              }
              var sendBtn=document.querySelector('[data-testid*="send"],button.zmSendBtn,button[title*="Send"]');
              if(!sendBtn) return 'missing_send';
              if((subjEl.value||'').indexOf(subjVal)===-1) return 'verify_failed';
              sendBtn.click();
              return 'sent';
            })()
            """
            var outcome = ""
            for _ in 0..<8 {
                try? await Task.sleep(for: .seconds(1))
                let r = (try? await tab.js(fillJS)) ?? ""
                if !r.isEmpty && r != "missing value" {
                    outcome = r
                    if r == "sent" || r == "verify_failed" || r == "missing_send" { break }
                }
            }
            guard outcome == "sent" else {
                throw WireError("mail_send", "Zoho Mail send didn't complete (\(outcome.isEmpty ? "compose didn't load" : outcome)); nothing was marked sent.")
            }
            // Brief settle for XHR dispatch before closing the tab.
            try? await Task.sleep(for: .seconds(2))
        }.value
    }
}
