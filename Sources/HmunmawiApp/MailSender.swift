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

/// Inspects Zoho Mail Safari login state and brings Safari forward on the Zoho sign-in page if sign-in is required.
enum ZohoSafariAuth {
    struct PageState: Equatable, Sendable {
        var url: String
        var hasCompose: Bool
        var hasRows: Bool
        var loginForm: Bool
        var composeOpen: Bool

        var isMailReady: Bool { hasCompose || hasRows || composeOpen }
        var needsSignIn: Bool { loginForm || isLoginURL(url) }
    }

    nonisolated static func isLoginURL(_ raw: String) -> Bool {
        let u = raw.lowercased()
        return u.contains("accounts.zoho.") || u.contains("/signin") || u.contains("/login") || u.contains("://iam.")
    }

    nonisolated static func parsePageState(_ raw: String) -> PageState? {
        guard !raw.isEmpty, raw != "missing value",
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return PageState(
            url: (obj["url"] as? String) ?? "",
            hasCompose: (obj["hasCompose"] as? Bool) ?? false,
            hasRows: (obj["hasRows"] as? Bool) ?? false,
            loginForm: (obj["loginForm"] as? Bool) ?? false,
            composeOpen: (obj["composeOpen"] as? Bool) ?? false
        )
    }

    nonisolated static let pageStateJS = #"""
    (function(){
      var composeSel='[data-testid="new-btn-opt"],[data-testid*="compose"],.zmComposeBtn,button[title*="Compose"],button[title*="New Mail"],a[href*="compose"]';
      var hasComp=!!document.querySelector(composeSel)||Array.from(document.querySelectorAll('button')).some(function(b){var t=(b.innerText||'').trim();return t==='New Mail'||t==='Compose';});
      var compOpen=!!document.querySelector('[data-testid="com_To_field"],[data-testid="com_send"]');
      var loginEl=!!document.querySelector('#login_id,input[name="LOGIN_ID"],[data-testid="signin"],.signin_box');
      var hasRows=document.querySelectorAll('.zmList').length>0;
      return JSON.stringify({url:location.href,hasCompose:hasComp,hasRows:hasRows,loginForm:loginEl,composeOpen:compOpen});
    })()
    """#

    @MainActor
    static func openInSafari(host: String) {
        let cleanHost = ZohoSafariReader.hosts.contains(host) ? host : "mail.zoho.com"
        if let u = URL(string: "https://\(cleanHost)/zm/#mail/views/all") {
            NSWorkspace.shared.open(u)
        }
    }

    /// Opens Zoho Mail in a `SafariAuto` tab, waiting cleanly whether already signed in or redirected to Zoho login.
    nonisolated static func ensureReady(
        session: SafariAuto.Session,
        host: String,
        allowInteractiveLogin: Bool,
        loginWaitSeconds: Int = 90
    ) async throws -> SafariAuto.Tab {
        let tab = try await session.open(url: "https://\(host)/zm/#mail/views/all", needle: "zoho.", seconds: 30)
        // 1. Give the SPA / SSO redirect up to ~10 seconds to settle into inbox automatically.
        var lastState: PageState?
        for _ in 0..<12 {
            if let raw = try? await tab.js(pageStateJS), let st = parsePageState(raw) {
                lastState = st
                if st.isMailReady && !st.needsSignIn { return tab }
                if st.needsSignIn { break }
            }
            try? await Task.sleep(for: .seconds(0.8))
        }

        // Already redirected into Zoho Login / accounts.zoho.*.
        if let st = lastState, st.needsSignIn || !st.isMailReady {
            guard allowInteractiveLogin else {
                throw WireError("mail", "Zoho Mail isn't signed in on \(host) in Safari yet. Open \(host) in Safari (or click Send once to sign in).")
            }
            // Bring the sign-in tab forward in Safari so the user sees it immediately and can sign in.
            await tab.revealInSafari()
            let polls = max(1, Int(Double(loginWaitSeconds) / 1.5))
            var missCount = 0
            for _ in 0..<polls {
                try? await Task.sleep(for: .seconds(1.5))
                do {
                    let raw = try await tab.js(pageStateJS)
                    missCount = 0
                    if let cur = parsePageState(raw), cur.isMailReady && !cur.needsSignIn {
                        return tab
                    }
                } catch SafariAuto.Failure.noTab {
                    missCount += 1
                    if missCount >= 4 {
                        throw WireError("mail_send", "Zoho Mail tab was closed before sign-in finished.")
                    }
                } catch {
                    // Brief error while cross-origin OAuth page reloads.
                }
            }
            // Leave Safari open on Zoho login for the user rather than closing it under them.
            await session.handOffToUser(tab)
            throw WireError("mail_send", "Opened Zoho Mail in Safari for sign-in — finish signing in there, then click Send again.")
        }
        return tab
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

            let tab = try await ZohoSafariAuth.ensureReady(session: session, host: host, allowInteractiveLogin: true)

            // 1. Open compose if not already open.
            let openJS = """
            (function(){
              if(document.querySelector('[data-testid="com_To_field"],[data-testid="com_send"]')) return 'already';
              var btn=document.querySelector('[data-testid="new-btn-opt"],[data-testid*="compose"],.zmComposeBtn,button[title*="Compose"],button[title*="New Mail"],a[href*="compose"]');
              if(!btn){
                btn=Array.from(document.querySelectorAll('button')).find(function(b){
                  var t=(b.innerText||'').trim();
                  return (t==='New Mail'||t==='Compose')&&b.getBoundingClientRect().width>0;
                });
              }
              if(btn){btn.click();return 'clicked';}
              return document.querySelector('input[placeholder*="Subject"],input[name="subject"],[data-testid="subject"]')?'already':'missing';
            })()
            """
            var opened = false
            for _ in 0..<12 {
                let r = (try? await tab.js(openJS)) ?? ""
                if r == "clicked" || r == "already" { opened = true; break }
                try? await Task.sleep(for: .seconds(1))
            }
            guard opened else {
                throw WireError("mail_send", "Zoho Mail's Compose button wasn't found (are you signed in on \(host), or did Zoho change its page?).")
            }

            // 2. Fill To, Subject, and the visible Body editor using JSON-encoded string literals.
            let fillJS = """
            (function(){
              var toVal=\(toJS), subjVal=\(subjJS), bodyVal=\(bodyJS);
              var toEl=document.querySelector('[data-testid="com_To_field"],input[aria-label="To Recipients"],input[data-testid*="to"],input[name="to"],.zmCmpTo input,input[aria-label="To"]');
              var subjEl=document.querySelector('input[placeholder="Subject"],input[placeholder*="Subject"],input[name="subject"],[data-testid="subject"]');
              var bodyEl=Array.from(document.querySelectorAll('iframe.ze_area,iframe[title="Text editor area"]')).find(function(f){
                var rc=f.getBoundingClientRect();
                return rc.width>0&&rc.height>0;
              })||document.querySelector('.zmCmpBody [contenteditable="true"],textarea[name="content"],[data-testid="compose-body"] [contenteditable="true"]');
              if(!toEl||!subjEl||!bodyEl) return 'missing_fields';
              function setInput(el,val){
                el.focus();
                var proto=Object.getPrototypeOf(el);
                var setter=Object.getOwnPropertyDescriptor(proto,'value');
                if(setter&&setter.set){setter.set.call(el,val);}else{el.value=val;}
                el.dispatchEvent(new Event('input',{bubbles:true}));
                el.dispatchEvent(new Event('change',{bubbles:true}));
              }
              function esc(s){return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');}
              function toHtml(s){
                return s.split('\\n').map(function(line){
                  return line===''?'<div><br></div>':'<div>'+esc(line)+'</div>';
                }).join('');
              }
              setInput(toEl,toVal);
              toEl.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true}));
              toEl.dispatchEvent(new KeyboardEvent('keyup',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true}));
              setInput(subjEl,subjVal);
              if(bodyEl.tagName==='IFRAME'){
                var doc=bodyEl.contentDocument;
                if(!doc||!doc.body) return 'missing_body_doc';
                doc.body.focus();
                doc.body.innerHTML=toHtml(bodyVal);
                doc.body.dispatchEvent(new Event('input',{bubbles:true}));
              }else if(bodyEl.isContentEditable){
                bodyEl.focus();
                bodyEl.innerHTML=toHtml(bodyVal);
                bodyEl.dispatchEvent(new Event('input',{bubbles:true}));
              }else{
                setInput(bodyEl,bodyVal);
              }
              return 'filled';
            })()
            """
            var filled = ""
            for _ in 0..<10 {
                try? await Task.sleep(for: .seconds(0.8))
                let r = (try? await tab.js(fillJS)) ?? ""
                if !r.isEmpty && r != "missing value" {
                    filled = r
                    if r == "filled" || r == "missing_body_doc" {
                        if r == "filled" { break }
                    }
                }
            }
            guard filled == "filled" else {
                throw WireError("mail_send", "Zoho Mail compose fields didn't load (\(filled.isEmpty ? "timeout" : filled)); nothing was sent.")
            }

            // 3. Give Zoho's recipient pill a moment to commit, verify Subject, and click Send (`com_send`, not `com_send_later`).
            try? await Task.sleep(for: .seconds(0.7))
            let sendJS = """
            (function(){
              var subjVal=\(subjJS);
              var subjEl=document.querySelector('input[placeholder="Subject"],input[placeholder*="Subject"],input[name="subject"],[data-testid="subject"]');
              if(!subjEl||(subjEl.value||'').indexOf(subjVal)===-1) return 'verify_failed';
              var sendBtn=document.querySelector('button[data-testid="com_send"],button[aria-label="Send"],button.zmSendBtn,button[title="Send"],button[title*="Send Mail"]');
              if(!sendBtn) return 'missing_send';
              sendBtn.click();
              return 'sent';
            })()
            """
            let sendResult = (try? await tab.js(sendJS)) ?? ""
            guard sendResult == "sent" else {
                throw WireError("mail_send", "Zoho Mail send didn't complete (\(sendResult.isEmpty ? "no response" : sendResult)); nothing was marked sent.")
            }
            // Wait until the compose Send button closes (or settle 5s) before closing the tab.
            for _ in 0..<8 {
                try? await Task.sleep(for: .seconds(0.7))
                let stillOpen = (try? await tab.js("!!document.querySelector('button[data-testid=\"com_send\"]')")) ?? ""
                if stillOpen == "false" { break }
            }
        }.value
    }
}
