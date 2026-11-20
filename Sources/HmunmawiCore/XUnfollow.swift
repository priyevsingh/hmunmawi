import Foundation

/// Automatic X unfollows (opt-in, off until you switch it on): the rules, the page checks and the daily pacing, pure
/// so they can be tested. The app opens one Safari tab per account through your own signed-in Safari, reads the page
/// with `probeJS`, decides with `classify`, clicks Following → Unfollow, checks the button now says Follow, and
/// closes the tab.
///
/// The list is a frozen snapshot made once (or when you press Rebuild list): accounts you follow later are never
/// added by themselves. Mutuals, your keeps, big accounts (`XSafariFinds.bigAccount`+ followers) and anyone whose
/// page shows "Follows you" are never unfollowed. Pace: at most `perDay` a day inside your window, at least 10
/// minutes apart, jittered and spread so the day's number fits the window. Any sign of trouble on X (login page,
/// challenge, rate limit, "Something went wrong", wrong account, lost tab, 3 accounts failing in a row) stops it
/// for the rest of the day with one message; the same hard stop two days running holds it until you press Resume.
public enum XUnfollow {
    public static let defaultPerDay = 25
    public static let maxPerDay = 40
    public static let minGap: TimeInterval = 600
    public static let defaultWindow = "10:00-20:00"
    /// One failed account is retried once (a later run), then skipped with its reason.
    public static let failsPerAccount = 2
    /// Different accounts failing in a row (same day) = something is wrong: stop for the day.
    public static let systemicFailures = 3
    /// Profiles opened per run (a skipped profile moves straight on to the next one).
    public static let opensPerRun = 4

    // MARK: Model

    public struct Account: Codable, Equatable, Sendable {
        public var handle: String
        /// X's user id when known (the Safari list and most bot files have it); checked against the page.
        public var id: String?
        public var followers: Int?
        public init(handle: String, id: String? = nil, followers: Int? = nil) { self.handle = handle; self.id = id; self.followers = followers }
        /// Done/skipped are kept by user id, or by handle when the list had no id.
        public var key: String { id.map { "id:\($0)" } ?? "@" + handle.lowercased() }
    }

    public struct Record: Codable, Equatable, Sendable {
        public var handle: String, key: String, at: Date, note: String
    }

    public struct Day: Codable, Equatable, Sendable {
        public var done = 0, skipped = 0, failed = 0, opened = 0
        public var stopped: String?
        public var nextDue: Date?
        public var summarySent = false
        public init() {}
    }

    public struct State: Codable, Equatable, Sendable {
        public var snapshot: [Account] = []
        public var snapshotAt: Date?
        public var snapshotSource: String?
        public var done: [Record] = []
        public var skipped: [Record] = []
        public var failures: [String: Int] = [:]
        public var failStreak: [String] = []
        public var streakDay: String?
        public var days: [String: Day] = [:]
        public var hold: String?
        public init() {}

        public var handled: Set<String> { Set(done.map(\.key)).union(skipped.map(\.key)) }
        public var lastDone: Date? { done.map(\.at).max() }
    }

    /// Accounts still to do, in list order: not done, not skipped, not in your keeps.
    public static func remaining(_ s: State, keep: Set<String>) -> [Account] {
        let seen = s.handled
        return s.snapshot.filter { !seen.contains($0.key) && !keep.contains($0.handle.lowercased()) }
    }

    public static func keepSet(_ text: String?) -> Set<String> {
        Set((text ?? "").split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " @")).lowercased() }.filter { !$0.isEmpty })
    }

    public static func perDay(_ text: String?) -> Int { min(max(Int(text ?? "") ?? defaultPerDay, 1), maxPerDay) }

    // MARK: The frozen list

    /// From your Following page (`XSafariFinds.followingJS`): accounts that don't follow back, with their user id,
    /// minus big accounts. Nil when the page didn't answer with a list.
    public static func snapshot(fromFollowing json: String) -> [Account]? {
        guard let d = json.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let users = o["users"] as? [[String: Any]] else { return nil }
        var seen = Set<String>()
        return users.compactMap { u in
            guard (u["back"] as? Bool) != true, let h = (u["handle"] as? String).flatMap(XNative.validHandle),
                  let id = u["id"] as? String, !id.isEmpty, id.allSatisfy(\.isNumber), seen.insert(id).inserted else { return nil }
            let followers = (u["followers"] as? Int) ?? 0
            guard followers < XSafariFinds.bigAccount else { return nil }
            return Account(handle: h, id: id, followers: followers)
        }
    }

    /// From a bot's file (`{"non_followbacks": [{"handle", "id"?, "suggestion"?, "followers"?}], "mutuals"?: [...]}`
    /// or a plain list of handles): entries marked keep, mutuals and big accounts are left out.
    public static func snapshot(fromFile any: Any) -> [Account] {
        let doc = any as? [String: Any]
        let list: [Any] = (any as? [Any]) ?? (doc?["non_followbacks"] as? [Any]) ?? []
        let mutuals = Set(((doc?["mutuals"] as? [Any]) ?? []).compactMap { ($0 as? String)?.lowercased() })
        var seen = Set<String>()
        return list.compactMap { e -> Account? in
            var a: Account
            if let h = (e as? String).flatMap(XNative.validHandle) { a = Account(handle: h) }
            else if let o = e as? [String: Any], let h = (o["handle"] as? String).flatMap(XNative.validHandle) {
                if (o["suggestion"] as? String ?? "unfollow").lowercased().contains("keep") { return nil }
                let id = (o["id"] as? String) ?? (o["id"] as? Int).map(String.init)
                a = Account(handle: h, id: id.flatMap { $0.allSatisfy(\.isNumber) && !$0.isEmpty ? $0 : nil },
                            followers: o["followers"] as? Int)
            } else { return nil }
            if mutuals.contains(a.handle.lowercased()) || (a.followers ?? 0) >= XSafariFinds.bigAccount { return nil }
            return seen.insert(a.key).inserted ? a : nil
        }
    }

    /// Scrolls your Following page a step and reports every account X's page has loaded so far (the list grows as
    /// it scrolls; X keeps every loaded account in its store).
    public static func followingScrollJS(handle: String) -> String {
        """
        (function(){
          \(XSafariFinds.storeFinder)
          var me='\(handle.lowercased())';
          window.scrollBy(0, Math.max(window.innerHeight*2, 1600));
          var out=Object.keys(users).map(function(k){var u=users[k]; return u;})
            .filter(function(u){return u.following===true && (u.screen_name||'').toLowerCase()!==me})
            .map(function(u){return {handle:u.screen_name, id:u.id_str||'', back:u.followed_by===true, followers:u.followers_count||0}});
          return JSON.stringify({users:out});
        })()
        """
    }

    // MARK: Reading one profile

    /// What the page shows, read without clicking anything.
    public static func probeJS(_ a: Account) -> String {
        let id = jsString(a.id ?? ""), h = jsString(a.handle.lowercased())
        return """
        (function(){
        var ID=\(id), H=\(h);
        var r={url:location.href, ready:document.readyState};
        var body=document.body?document.body.innerText:'';
        var pc=document.querySelector('[data-testid="primaryColumn"]'); var pct=pc?pc.innerText:'';
        var p=location.pathname.toLowerCase();
        r.login=p.indexOf('/login')==0||p.indexOf('/i/flow')==0||!!document.querySelector('[data-testid="loginButton"]');
        r.challenge=p.indexOf('/account/access')==0||!!document.querySelector('iframe[src*="arkoselabs"],iframe[src*="captcha"]')||/unusual activity|verify (that )?you.re (a )?human|are you a robot|help us keep x secure/i.test(body);
        r.ratelimit=/rate limit|too many requests|over the daily limit|unfollowing too many|following too many/i.test(body);
        r.wrong=/something went wrong/i.test(pct);
        r.suspended=/account suspended/i.test(pct);
        r.notfound=/this account doesn.t exist/i.test(pct);
        r.blocked=/you.re blocked|blocked you/i.test(pct);
        r.withheld=/account withheld|has been withheld in/i.test(pct);
        var me=document.querySelector('[data-testid="SideNav_AccountSwitcher_Button"]'); r.me=me?me.innerText:'';
        var un=document.querySelector('[data-testid="UserName"]'); r.username=un?un.innerText:'';
        r.follows_you=!!document.querySelector('[data-testid="userFollowIndicator"]');
        var first=pc?pc.querySelector('[data-testid$="-unfollow"],[data-testid$="-follow"]'):null;
        var m=first?(first.getAttribute('data-testid')||'').match(/^([0-9]+)-(un)?follow$/):null; r.page_id=m?m[1]:'';
        if(!ID) ID=r.page_id;
        var uf=ID?document.querySelector('[data-testid="'+ID+'-unfollow"]'):null, f=ID?document.querySelector('[data-testid="'+ID+'-follow"]'):null;
        var ufTxt=uf?(uf.innerText||''):'';
        function vis(el){return (el&&(el.innerText||'')).trim();}
        var followingBtn=(uf&&vis(uf)==='Following')?uf:null;
        var ariaUf=null;
        document.querySelectorAll('button[aria-label]').forEach(function(b){ if(/^Unfollow @/i.test(b.getAttribute('aria-label')||'')) ariaUf=b; });
        r.aria_unfollow=ariaUf?(ariaUf.getAttribute('aria-label')||''):'';
        if(followingBtn){r.btn='following';r.btn_text='Following';}
        else if(ariaUf){r.btn='following';r.btn_text=vis(ariaUf)||vis(uf)||'';}
        else if(f){r.btn='follow';r.btn_text=f.innerText;}
        else if(uf&&/subscribe/i.test(ufTxt)){r.btn='subscribe';r.btn_text=ufTxt;}
        else{r.btn='';r.btn_text=ufTxt||(f?f.innerText:'');}
        r.confirm=!!document.querySelector('[data-testid="confirmationSheetConfirm"]');
        var toast=document.querySelector('[data-testid="toast"]'); r.toast=toast?toast.innerText:'';
        if(/rate limit|too many|limit/i.test(r.toast)) r.ratelimit=true;
        if(/something went wrong/i.test(r.toast)) r.wrong=true;
        return JSON.stringify(r);})()
        """
    }

    public struct Page: Equatable, Sendable {
        public var ready = false, login = false, challenge = false, rateLimit = false, wrong = false
        public var suspended = false, notFound = false, blocked = false, withheld = false
        public var me = "", username = "", pageID = "", button = "", buttonText = "", ariaUnfollow = "", toast = ""
        public var followsYou = false, confirm = false
        public init() {}

        public init?(json: String) {
            guard let d = json.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  o["error"] == nil else { return nil }
            func b(_ k: String) -> Bool { (o[k] as? Bool) ?? false }
            func s(_ k: String) -> String { (o[k] as? String) ?? "" }
            ready = s("ready") == "complete"; login = b("login"); challenge = b("challenge"); rateLimit = b("ratelimit")
            wrong = b("wrong"); suspended = b("suspended"); notFound = b("notfound"); blocked = b("blocked"); withheld = b("withheld")
            me = s("me"); username = s("username"); pageID = s("page_id"); button = s("btn"); buttonText = s("btn_text")
            ariaUnfollow = s("aria_unfollow"); toast = s("toast"); followsYou = b("follows_you"); confirm = b("confirm")
        }

        /// The page has loaded enough to decide.
        public var settled: Bool {
            login || challenge || rateLimit || wrong || suspended || notFound || blocked || withheld
                || (!username.isEmpty && (!button.isEmpty || followsYou || !ariaUnfollow.isEmpty))
        }
        public var trouble: Bool { login || challenge || rateLimit || wrong }
    }

    public enum ClickPath: String, Sendable { case following, aria }

    public enum Verdict: Equatable, Sendable {
        /// Stop for the day (and tell you once).
        case safety(String)
        /// Leave this account (with the reason) and move on.
        case skip(String)
        /// Couldn't tell; tried again once in a later run, then skipped.
        case fail(String)
        /// You follow them and it's safe to click.
        case following(ClickPath)
    }

    /// The decision for one profile, in the job's order: trouble on X first, then the account itself.
    public static func classify(_ p: Page, account a: Account, me: String) -> Verdict {
        let h = a.handle.lowercased()
        if p.login { return .safety("X showed its login page") }
        if p.challenge { return .safety("X showed a challenge or unusual-activity page") }
        if p.rateLimit { return .safety("X rate limit") }
        if p.wrong { return .safety("X said \"Something went wrong\"") }
        if !p.me.isEmpty, !hasHandle(p.me, me) { return .safety("Safari is signed in to X as someone else") }
        if p.suspended { return .skip("account suspended") }
        if p.notFound { return .skip("account not found") }
        if p.blocked { return .skip("blocked") }
        if p.withheld { return .skip("account withheld in your country") }
        if p.followsYou { return .skip("now follows you (mutual), kept") }
        guard !p.username.isEmpty, !p.button.isEmpty else { return .fail("profile did not load") }
        if !hasHandle(p.username, h) { return .skip("page is a different user (handle changed?)") }
        if let id = a.id, !p.pageID.isEmpty, p.pageID != id { return .skip("page is a different user (id changed)") }
        if p.me.isEmpty { return .fail("could not confirm the signed-in account") }
        if p.button == "follow" { return .skip("already not following") }
        if p.button == "following", p.buttonText.trimmingCharacters(in: .whitespaces) == "Following" { return .following(.following) }
        if ["following", "subscribe"].contains(p.button),
           p.ariaUnfollow.trimmingCharacters(in: .whitespaces).lowercased() == "unfollow @" + h { return .following(.aria) }
        if ["following", "subscribe"].contains(p.button) { return .skip("already not following (button says \(p.buttonText.isEmpty ? "Subscribe" : p.buttonText))") }
        return .fail("profile did not load")
    }

    /// The text shows exactly this @handle as a word ("@quiet2" is not "@quiet").
    public static func hasHandle(_ text: String, _ handle: String) -> Bool {
        // X writes the name and handle together ("Josh 🍕@joshdholtz"), so only what follows the handle is checked.
        let t = text.lowercased(), want = "@" + handle.lowercased()
        var from = t.startIndex
        while let r = t.range(of: want, range: from..<t.endIndex) {
            guard let next = t[r.upperBound...].first, next.isASCII, next.isLetter || next.isNumber || next == "_" else { return true }
            from = r.upperBound
        }
        return false
    }

    /// After the click: the button now says Follow (or no Following control is left).
    public static func unfollowed(_ p: Page) -> Bool {
        guard p.ariaUnfollow.isEmpty else { return false }
        return p.button == "follow" || p.button == "subscribe" || (p.button.isEmpty && !p.username.isEmpty)
    }

    /// Clicks the profile's own "Following" button (never anything else).
    public static func clickFollowingJS(_ a: Account, pageID: String) -> String {
        let id = jsString(a.id ?? pageID)
        return """
        (function(){
        var id=\(id);
        function vis(el){return (el&&(el.innerText||'')).trim();}
        var uf=id?document.querySelector('[data-testid="'+id+'-unfollow"]'):null;
        if(uf&&vis(uf)==='Following'){uf.click();return 'clicked';}
        return 'nobtn';})()
        """
    }

    /// Confirms X's "Unfollow @handle?" sheet (only when its button says Unfollow).
    public static let confirmJS = """
    (function(){var c=document.querySelector('[data-testid="confirmationSheetConfirm"]');
    if(!c)return '';var t=c.innerText;if(!/unfollow/i.test(t))return 'odd';c.click();return 'ok';})()
    """

    /// Subscription-style profiles: click the "Unfollow @handle" icon (its menu is drawn after this call returns).
    public static func ariaClickJS(_ a: Account) -> String {
        let want = jsString("unfollow @" + a.handle.lowercased())
        return """
        (function(){var want=\(want);
        var b=[].slice.call(document.querySelectorAll('button[aria-label]')).find(function(x){
          return (x.getAttribute('aria-label')||'').trim().toLowerCase()===want;});
        if(!b) return 'nobtn'; b.click(); return 'clicked';})()
        """
    }

    /// Then, in a second call: the confirmation sheet, or the menu item whose text is exactly "Unfollow @handle".
    public static func ariaMenuJS(_ a: Account) -> String {
        let want = jsString("unfollow @" + a.handle.lowercased())
        return """
        (function(){
        if(document.querySelector('[data-testid="confirmationSheetConfirm"]')) return 'sheet';
        var want=\(want);
        var items=[].slice.call(document.querySelectorAll('#layers [role="menuitem"], [role="menu"] [role="menuitem"]'));
        var item=items.find(function(m){return (m.innerText||'').trim().toLowerCase()===want;});
        if(item){item.click();return 'menu';}
        return '';})()
        """
    }

    /// A string as a JavaScript literal (JSON-escaped, so a handle or id can't break out of it).
    public static func jsString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    // MARK: The day

    /// "10:00-20:00" → minutes after midnight (start, end); nil when it isn't a valid window of at least an hour.
    public static func window(_ text: String?) -> (start: Int, end: Int)? {
        let parts = (text?.isEmpty == false ? text! : defaultWindow).split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return nil }
        func mins(_ s: String) -> Int? {
            let hm = s.split(separator: ":").compactMap { Int($0) }
            guard hm.count == 2, (0...23).contains(hm[0]) || (hm[0] == 24 && hm[1] == 0), (0...59).contains(hm[1]) else { return nil }
            return hm[0] * 60 + hm[1]
        }
        guard let a = mins(parts[0]), let b = mins(parts[1]), b - a >= 60 else { return nil }
        return (a, b)
    }

    /// Seconds to the next unfollow: the rest of the window shared by what's left of today's number, jittered,
    /// never under 10 minutes.
    public static func nextGap(secondsLeftInWindow: TimeInterval, doneToday: Int, perDay: Int, using rng: inout some RandomNumberGenerator) -> TimeInterval {
        let left = Double(max(perDay - doneToday, 1))
        let base = max(secondsLeftInWindow / left, minGap)
        return max(base * Double.random(in: 0.6...1.3, using: &rng), minGap + Double.random(in: 0...240, using: &rng))
    }

    public enum Result: Equatable, Sendable { case unfollowed, checked, skip, fail, safety }

    /// Keeps the result. One failure is retried once (in a later run); a second one skips the account with its reason.
    public static func record(_ s: inout State, day: String, account a: Account, result: Result, note: String, at: Date) {
        var d = s.days[day] ?? Day()
        if s.streakDay != day { s.streakDay = day; s.failStreak = [] }
        let rec = Record(handle: a.handle, key: a.key, at: at, note: note)
        switch result {
        case .unfollowed, .skip:
            if result == .unfollowed { s.done.append(rec); d.done += 1 } else { s.skipped.append(rec); d.skipped += 1 }
            s.failStreak = []
            s.failures[a.key] = nil
        case .fail:
            d.failed += 1
            if !s.failStreak.contains(a.key) { s.failStreak.append(a.key) }
            let n = (s.failures[a.key] ?? 0) + 1
            if n >= failsPerAccount {
                s.skipped.append(Record(handle: a.handle, key: a.key, at: at, note: "failed \(n) times, skipped: \(note)"))
                d.skipped += 1
                s.failures[a.key] = nil
            } else { s.failures[a.key] = n }
        case .checked, .safety: break
        }
        s.days[day] = d
    }

    /// Stops for the rest of the day. A login, challenge or rate-limit stop on two days running holds the job until
    /// you press Resume. Returns the one message to send.
    public static func stop(_ s: inout State, day: String, previousDay: String, reason: String, left: Int) -> String {
        var d = s.days[day] ?? Day()
        d.stopped = reason
        s.days[day] = d
        func hard(_ r: String?) -> Bool { guard let r = r?.lowercased() else { return false }; return ["login", "challenge", "rate limit"].contains { r.contains($0) } }
        if hard(reason), hard(s.days[previousDay]?.stopped) { s.hold = "\(day): \(reason), two days running" }
        let tail = s.hold != nil ? "Held until you press Resume (Automations → X unfollows)." : "It starts again tomorrow."
        return "X unfollows stopped for today: \(reason) (\(d.done) done today, \(left) left). \(tail)"
    }

    /// The day's one summary line.
    public static func summary(_ d: Day, left: Int) -> String {
        "X unfollows today: \(d.done) done, \(d.skipped) skipped, \(left) left" + (left == 0 ? ". The list is finished; the job has nothing more to do until you rebuild it." : ".")
    }
}
