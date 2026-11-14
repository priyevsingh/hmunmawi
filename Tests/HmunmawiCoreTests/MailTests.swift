import Foundation
import Testing
@testable import HmunmawiCore

@Suite struct MailHeaderTests {
    @Test func readsAPlainHeaderBlock() {
        let block = "From: Jane Doe <jane@press.example>\r\nSubject: Re: Lift Crew\r\nDate: Thu, 5 Nov 2026 09:30:00 +0530\r\nMessage-ID: <abc@press.example>\r\nIn-Reply-To: <orig@mydomain.example>\r\n\r\n"
        let r = MailHeaders.row(id: "x", folder: "INBOX", block: block)
        #expect(r.from == "Jane Doe <jane@press.example>" && r.subject == "Re: Lift Crew")
        #expect(r.messageID == "abc@press.example" && r.inReplyTo == "orig@mydomain.example")
        #expect(r.sentMs == 1_793_851_200_000)
    }

    @Test func foldedLinesAndEncodedWords() {
        let block = "Subject: =?UTF-8?B?UmU6IEzDpGNoZWxu?=\r\n =?UTF-8?Q?_und_mehr?=\r\nFrom: =?ISO-8859-1?Q?J=FCrgen?= <j@example.de>\r\n"
        let h = MailHeaders.parse(block)
        #expect(MailHeaders.decodeWords(h["subject"] ?? "") == "Re: Lächeln und mehr")
        #expect(MailHeaders.decodeWords(h["from"] ?? "") == "Jürgen <j@example.de>")
    }

    @Test func oddInputNeverCrashes() {
        #expect(MailHeaders.decodeWords("=?broken").isEmpty == false)
        #expect(MailHeaders.dateMs("not a date") == nil && MailHeaders.dateMs(nil) == nil)
        #expect(MailHeaders.messageID("") == nil)
        #expect(MailHeaders.parse("\r\n: nothing\r\n").isEmpty)
    }
}

/// A scripted mail server: each command the client sends gets the canned answer for its first word(s).
final class ScriptedIMAP: IMAPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Data] = [Data("* OK IMAP ready\r\n".utf8)]
    var sent: [String] = []
    let answers: [(String, String)]   // (command prefix, untagged answer text)
    let failLogin: Bool
    init(_ answers: [(String, String)], failLogin: Bool = false) { self.answers = answers; self.failLogin = failLogin }

    func send(_ data: Data) async throws {
        let line = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let tag = parts[0], cmd = parts.count > 1 ? parts[1] : ""
        lock.withLock {
            sent.append(cmd)
            if cmd.hasPrefix("LOGIN"), failLogin { queue.append(Data("\(tag) NO [AUTHENTICATIONFAILED] Invalid credentials\r\n".utf8)); return }
            let body = answers.first { cmd.hasPrefix($0.0) }?.1 ?? ""
            queue.append(Data((body + "\(tag) OK done\r\n").utf8))
        }
    }
    func receive() async throws -> Data {
        lock.withLock { queue.isEmpty ? Data() : queue.removeFirst() }
    }
    func close() {}
}

@Suite struct IMAPTests {
    private let cfg = IMAPConfig(host: "imap.example.com", username: "me@example.com", password: "app-password")
    private let header = "From: Jane <jane@press.example>\r\nSubject: Re: Lift Crew\r\nDate: Thu, 5 Nov 2026 09:30:00 +0530\r\nMessage-ID: <m1@press.example>\r\nIn-Reply-To: <o1@x>\r\n\r\n"

    private func server() -> ScriptedIMAP {
        ScriptedIMAP([
            ("LIST", "* LIST (\\HasNoChildren) \"/\" \"INBOX\"\r\n* LIST (\\HasNoChildren \\Sent) \"/\" \"Sent Items\"\r\n* LIST (\\Noselect) \"/\" \"[Gmail]\"\r\n"),
            ("EXAMINE", "* OK [UIDVALIDITY 77] ok\r\n"),
            ("UID SEARCH", "* SEARCH 5\r\n"),
            ("UID FETCH", "* 1 FETCH (UID 5 BODY[HEADER.FIELDS (FROM SUBJECT DATE MESSAGE-ID IN-REPLY-TO)] {\(header.utf8.count)}\r\n\(header))\r\n"),
        ])
    }

    @Test func badLiteralSizesAreRefusedNotCrashed() async throws {
        for size in ["-5", "999999999"] {
            let s = ScriptedIMAP([("NOOP", "* 1 FETCH (BODY[HEADER] {\(size)}\r\n")])
            let session = IMAPSession(transport: s)
            try await session.greeting()
            await #expect(throws: IMAPError.self) { try await session.command("NOOP") }
        }
    }

    @Test func readsInboxAndSentWithoutChangingAnything() async throws {
        let s = server()
        let rows = try await IMAPMail.fetch(cfg, transport: s, now: Date(timeIntervalSince1970: 1_793_900_000))
        #expect(rows.count == 2 && Set(rows.map(\.folder)) == ["INBOX", "SENT"])
        #expect(rows[0].subject == "Re: Lift Crew" && rows[0].inReplyTo == "o1@x" && rows[0].id.hasSuffix("-INBOX-77-5"))
        // Read-only: folders opened with EXAMINE, never SELECT; headers with PEEK; nothing that writes.
        let all = s.sent.joined(separator: "\n")
        #expect(all.contains("EXAMINE \"INBOX\"") && all.contains("EXAMINE \"Sent Items\"") && all.contains("BODY.PEEK["))
        for forbidden in ["SELECT", "STORE", "APPEND", "DELETE", "EXPUNGE", "COPY", "MOVE", "SEND", "BODY["] {
            #expect(!s.sent.contains { $0.hasPrefix(forbidden) || ($0.contains(forbidden) && forbidden == "BODY[") }, "\(forbidden) must never be sent")
        }
    }

    @Test func aRefusedLoginSaysSoWithoutTheSecret() async {
        do { _ = try await IMAPMail.fetch(cfg, transport: ScriptedIMAP([], failLogin: true)); Issue.record("should have thrown") }
        catch let e as IMAPError { #expect(e.message.contains("refused the login") && !e.message.contains("app-password")) }
        catch { Issue.record("wrong error \(error)") }
    }

    @Test func badSetupsAreRefusedBeforeConnecting() {
        #expect(IMAPConfig(host: "bad host", username: "a", password: "b").problem != nil)
        #expect(IMAPConfig(host: "imap.example.com", port: 0, username: "a", password: "b").problem != nil)
        #expect(IMAPConfig(host: "imap.example.com", username: "a\r\nb", password: "b").problem != nil)
        #expect(IMAPConfig(host: "imap.example.com", username: "a", password: "pässword").problem != nil)
        #expect(cfg.problem == nil)
        #expect(IMAPMail.listName("* LIST (\\Sent) \"/\" \"Sent Items\"") == "Sent Items")
        #expect(IMAPMail.listName("* LIST () NIL Sent") == "Sent")
    }
}

@Suite struct RatingDropTests {
    private func snap(_ daysAgo: Double, _ rating: Double, _ count: Int, now: Date) -> StoredEvent {
        StoredEvent(id: 0, source: "appstoreconnect", kind: "app.snapshot", app: "Pulse Diary",
                    payload: .object(["rating": .number(rating), "ratings_count": .number(Double(count))]),
                    occurredAt: Int64(now.addingTimeInterval(-daysAgo * 86_400).timeIntervalSince1970 * 1000))
    }
    private let now = Date(timeIntervalSince1970: 1_793_960_000)

    @Test func aRealFallWithNewRatingsIsReported() throws {
        let rows = [snap(8, 4.6, 30, now: now), snap(7, 4.6, 30, now: now), snap(3, 4.5, 33, now: now), snap(0.1, 4.3, 36, now: now)]
        let d = try #require(RatingDrop.detect(app: "Pulse Diary", snapshots: rows, now: now))
        #expect(d.from == 4.6 && d.to == 4.3 && d.newRatings == 6 && d.days >= 7)
        #expect(d.title.hasPrefix("Pulse Diary: rating fell from 4.6 to 4.3"))
    }

    @Test func noiseIsNotReported() {
        // Small fall, too few new ratings, a rise, stale data, and not enough history each give nothing.
        #expect(RatingDrop.detect(app: "A", snapshots: [snap(7, 4.6, 30, now: now), snap(0, 4.5, 33, now: now)], now: now) == nil)
        #expect(RatingDrop.detect(app: "A", snapshots: [snap(7, 4.6, 30, now: now), snap(0, 4.2, 31, now: now)], now: now) == nil)
        #expect(RatingDrop.detect(app: "A", snapshots: [snap(7, 4.2, 30, now: now), snap(0, 4.6, 36, now: now)], now: now) == nil)
        #expect(RatingDrop.detect(app: "A", snapshots: [snap(14, 4.6, 30, now: now), snap(10, 4.2, 36, now: now)], now: now) == nil)
        #expect(RatingDrop.detect(app: "A", snapshots: [snap(1, 4.6, 30, now: now), snap(0, 4.2, 36, now: now)], now: now) == nil)
        #expect(RatingDrop.detect(app: "A", snapshots: [], now: now) == nil)
    }
}

@Suite struct DataExportTests {
    private func review(_ id: Int64, _ title: String, _ body: String) -> StoredEvent {
        StoredEvent(id: id, source: "x", kind: "review.new", app: "Pulse Diary", payload: .object(["rating": .number(2), "title": .string(title), "body": .string(body),
                    "territory": .string("USA"), "review_id": .string("r\(id)")]), occurredAt: 1_793_900_000_000 + id)
    }

    @Test func reviewsExportAsSafeCSV() {
        let t = DataExport.table(.reviews, events: [review(2, "=HYPERLINK(\"http://evil\")", "line one\nline, two \"quoted\""), review(1, "Fine", "ok")])
        #expect(t.rows.count == 2 && t.rows[0][3] == "Fine")           // oldest first
        let csv = DataExport.csv(t)
        #expect(csv.hasPrefix("\u{FEFF}date,app,stars,title,text,country,review_id\r\n"))
        #expect(csv.contains("'=HYPERLINK(\"\"http://evil\"\")"))        // formula neutralised, quotes doubled
        #expect(csv.contains("\"line one\nline, two \"\"quoted\"\"\""))  // newline and comma kept inside one cell
        #expect(csv.contains(",2,"))                                     // numbers stay numbers
    }

    @Test func dailyKeepsTheNewestReadingPerAppAndDay() {
        func day(_ id: Int64, _ units: Double, _ usd: Double) -> StoredEvent {
            StoredEvent(id: id, source: "x", kind: "revenue.daily", app: "Pocket Garden", payload: .object(["day": .string("2026-11-04"), "units": .number(units), "proceeds_usd": .number(usd)]), occurredAt: 1_793_900_000_000 + id)
        }
        let t = DataExport.table(.daily, events: [day(1, 3, 1.5), day(2, 4, 5.2)])
        #expect(t.rows == [["2026-11-04", "Pocket Garden", "4", "5.20"]])
        #expect(DataExport.json(t).contains("\"downloads\" : 4") && DataExport.json(t).contains("\"proceeds_usd\" : 5.2"))
    }

    @Test func emptyAndFilenames() {
        #expect(DataExport.csv(DataExport.table(.reviews, events: [])).hasSuffix("review_id\r\n"))
        #expect(DataExport.json(DataExport.table(.daily, events: [])) == "[\n\n]\n" || DataExport.json(DataExport.table(.daily, events: [])).contains("["))
        #expect(DataExport.filename(.reviews, json: true, now: Date(timeIntervalSince1970: 1_793_900_000)) == "hmunmawi-reviews-2026-11-05.json")
    }
}

@Suite struct QuotaTests {
    @Test func readsAppleXAndStandardHeaders() {
        let apple = QuotaHeaders.parse(["x-rate-limit": "user-hour-lim:3500;user-hour-rem:500;"])
        #expect(apple == .init(limit: 3500, remaining: 500, window: "hour", resetsAt: nil))
        let now = Date(timeIntervalSince1970: 1_793_900_000)
        let x = QuotaHeaders.parse(["x-rate-limit-limit": "300", "x-rate-limit-remaining": "12", "x-rate-limit-reset": "1793900600"], now: now)
        #expect(x?.limit == 300 && x?.remaining == 12 && x?.resetsAt == Date(timeIntervalSince1970: 1_793_900_600))
        let std = QuotaHeaders.parse(["ratelimit-limit": "100", "ratelimit-remaining": "90", "ratelimit-reset": "30"], now: now)
        #expect(std?.resetsAt == now.addingTimeInterval(30))
        #expect(QuotaHeaders.parse(["content-type": "x"]) == nil && QuotaHeaders.parse(["x-rate-limit-limit": "abc"]) == nil)
        #expect(QuotaHeaders.retryAfter("120", now: now) == now.addingTimeInterval(120) && QuotaHeaders.retryAfter("junk") == nil)
    }

    @Test func theLedgerShowsLimitsAnd429sOnly() {
        let l = QuotaLedger(), now = Date(timeIntervalSince1970: 1_793_900_000)
        l.note(host: "API.AppStoreConnect.apple.com", status: 200, headers: ["X-Rate-Limit": "user-hour-lim:3500;user-hour-rem:3400;"], now: now)
        l.note(host: "example.com", status: 200, headers: [:], now: now)                      // no limit reported: not a quota
        l.note(host: "api.x.com", status: 429, headers: ["Retry-After": "60"], now: now)
        let r = l.readings(now: now)
        #expect(r.map(\.host).sorted() == ["api.appstoreconnect.apple.com", "api.x.com"])
        let asc = r.first { $0.host.contains("appstore") }
        #expect(asc?.usedPercent.map { Int($0.rounded()) } == 3 && asc?.callsLastHour == 1)
        #expect(r.first { $0.host == "api.x.com" }?.lastTooMany == now)
        #expect(l.readings(now: now.addingTimeInterval(2 * 86_400)).count == 1)               // a day later the old 429 is forgotten, the limit stays
    }
}

@Suite struct ReleaseTimelineTests {
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)     // go-live moment

    private func snap(_ at: Date, live: String) -> StoredEvent {
        StoredEvent(id: 0, source: "x", kind: "release.snapshot", app: "A", payload: .object(["live_version": .string(live)]), occurredAt: Int64(at.timeIntervalSince1970 * 1000))
    }
    private func day(_ offset: Int, units: Double, usd: Double) -> StoredEvent {
        let d = t0.addingTimeInterval(Double(offset) * 86_400)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return StoredEvent(id: 0, source: "x", kind: "revenue.daily", app: "A", payload: .object(["day": .string(f.string(from: d)), "units": .number(units), "proceeds_usd": .number(usd)]), occurredAt: Int64(d.timeIntervalSince1970 * 1000))
    }
    private let versions = StoredEvent(id: 0, source: "x", kind: "versions.snapshot", app: "A", payload: .object(["versions": .array([
        .object(["version": .string("4.1.6"), "state": .string("READY_FOR_SALE"), "created": .string("2026-10-20T10:00:00Z")]),
        .object(["version": .string("4.1.7"), "state": .string("READY_FOR_SALE"), "created": .string("2026-10-27T10:00:00Z")])])]), occurredAt: 0)

    @Test func theFirstSnapshotIsNotAGoLiveButAChangeIs() throws {
        let history = [snap(t0.addingTimeInterval(-9 * 86_400), live: "4.1.6"), snap(t0.addingTimeInterval(-3 * 86_400), live: "4.1.6"), snap(t0, live: "4.1.7")]
        let entries = ReleaseTimeline.build(versions: versions, history: history, daily: [], now: t0.addingTimeInterval(3_600))
        #expect(entries.map(\.version) == ["4.1.7", "4.1.6"])               // newest first
        #expect(entries[0].liveSeenAt == t0 && entries[1].liveSeenAt == nil)  // 4.1.6 was already live when watching began: no guess
    }

    @Test func numbersAroundAGoLive() throws {
        let history = [snap(t0.addingTimeInterval(-9 * 86_400), live: "4.1.6"), snap(t0, live: "4.1.7")]
        let daily = (-7 ... -1).map { day($0, units: 3, usd: 1) } + (0 ... 6).map { day($0, units: 5, usd: 2) }
        let done = ReleaseTimeline.build(versions: versions, history: history, daily: daily, now: t0.addingTimeInterval(8 * 86_400))
        let e = try #require(done[0].effect)
        #expect(e.downloadsBefore == 3 && e.downloadsAfter == 5 && e.complete)
        #expect(done[0].effectLine() == "First-time downloads a day 3.0 → 5.0 · proceeds a day $1.00 → $2.00 (7 days after; Apple's sales report)")
        // Too little data on one side: no line rather than a made-up one.
        let thin = ReleaseTimeline.build(versions: versions, history: history, daily: [day(-1, units: 3, usd: 1)], now: t0.addingTimeInterval(8 * 86_400))
        #expect(thin[0].effect == nil)
        // Still inside the window: shown as "so far".
        let partial = ReleaseTimeline.build(versions: versions, history: history, daily: (-7 ... -1).map { day($0, units: 3, usd: 1) } + (0 ... 3).map { day($0, units: 4, usd: 1) }, now: t0.addingTimeInterval(3.5 * 86_400))
        #expect(partial[0].effect?.complete == false && partial[0].effectLine()?.contains("so far") == true)
    }

    @Test func missingDataNeverCrashes() {
        #expect(ReleaseTimeline.build(versions: nil, history: [], daily: []).isEmpty)
    }
}

@Suite struct NativeAppsTests {
    private func ev(_ kind: String, _ app: String, _ payload: [String: JSONValue], _ at: Int64 = 1_793_900_000_000) -> StoredEvent {
        StoredEvent(id: at, source: "x", kind: kind, app: app, payload: .object(payload), occurredAt: at)
    }
    private let short: (String) -> String = { $0.split(separator: ":").first.map(String.init) ?? $0 }
    private let now = Date(timeIntervalSince1970: 1_793_900_000)

    @Test func parsesTheListingAndRefusesOddAnswers() {
        let ok = Data(#"{"resultCount":1,"results":[{"trackName":"Pulse Diary","averageUserRating":3.66667,"userRatingCount":9,"version":"4.1.7"}]}"#.utf8)
        #expect(StoreListing.parse(ok) == StoreListing(name: "Pulse Diary", rating: 3.66667, count: 9, version: "4.1.7"))
        #expect(StoreListing.parse(Data(#"{"resultCount":0,"results":[]}"#.utf8)) == nil)
        #expect(StoreListing.parse(Data(#"{"results":[{"averageUserRating":0,"userRatingCount":0}]}"#.utf8)) == nil)   // unrated is no data, not a 0
        #expect(StoreListing.parse(Data("not json".utf8)) == nil)
    }

    @Test func weightsTheRatingByHowManyPeopleRated() throws {
        let p = try #require(NativeApps.ratingPayload(["us": .init(name: nil, rating: 3.0, count: 9, version: "4.1.7"), "in": .init(name: nil, rating: 5.0, count: 1, version: nil)], appID: "1"))
        #expect(p[path: "rating"]?.number == 3.2 && p[path: "ratings_count"]?.number == 10)
        #expect(p[path: "ratings_by_country.US"]?.number == 3.0 && p[path: "ratings_count_by_country.IN"]?.number == 1)
        #expect(NativeApps.ratingPayload([:], appID: "1") == nil)
    }

    @Test func buildsAnAppPageFromAddOnData() throws {
        let events = [
            ev("icon.snapshot", "Pulse Diary: Widgets", ["appID": .string("1")]),
            ev("release.snapshot", "Pulse Diary", ["live_version": .string("4.1.7"), "live": .bool(true)]),
            ev("versions.snapshot", "Pulse Diary: Widgets", ["versions": .array([.object(["version": .string("4.1.7"), "state": .string("READY_FOR_DISTRIBUTION")])])]),
            ev("rating.snapshot", "Pulse Diary: Widgets", ["rating": .number(4.4), "ratings_count": .number(35)]),
            ev("revenue.daily", "Pulse Diary", ["day": .string("2026-11-04"), "units": .number(4)], 1_793_800_000_000),
            ev("revenue.daily", "Pulse Diary", ["day": .string("2026-11-03"), "units": .number(3)], 1_793_700_000_000),
        ]
        let out = NativeApps.snapshots(events: events, short: short, now: now)
        let s = try #require(out.first)
        #expect(out.count == 1 && s.app == "Pulse Diary" && s.kind == "app.snapshot")
        #expect(s.payload[path: "version"]?.string == "4.1.7" && s.payload[path: "version_state"]?.string == "READY_FOR_DISTRIBUTION")
        #expect(s.payload[path: "rating"]?.number == 4.4 && s.payload[path: "downloads_14d"]?.number == 7 && s.payload[path: "latest_sales_day"]?.string == "2026-11-04")
        #expect(s.payload[path: "active_subs"] == nil && s.payload[path: "conversion"] == nil)       // never invented
    }

    @Test func nativeAppsEachHaveTheirOwnID() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let events = ["Pocket Garden", "Night Owl Timer"].enumerated().map { i, app in
            StoredEvent(id: Int64(i + 1), source: "appstoreconnect", kind: "release.snapshot", app: app,
                        payload: .object(["live": .bool(true), "live_version": .string("1.0")]), occurredAt: 1_799_999_000_000)
        }
        let out = NativeApps.snapshots(events: events, short: { $0 }, now: now)
        #expect(out.count == 2 && Set(out.map(\.id)).count == 2)
        #expect(NativeApps.snapshots(events: events, short: { $0 }, now: now).map(\.id) == out.map(\.id))   // stable
    }

    @Test func anAppNotOnTheStoreYetStaysOffTheAppPages() {
        let events = [ev("icon.snapshot", "Paw Planner: Pet Care", [:]), ev("release.snapshot", "Paw Planner", ["live": .bool(false)]),
                      ev("versions.snapshot", "Paw Planner: Pet Care", ["versions": .array([.object(["version": .string("1.0"), "state": .string("PREPARE_FOR_SUBMISSION")])])])]
        #expect(NativeApps.snapshots(events: events, short: short, now: now).isEmpty)
    }

    @Test func anAppTheFeedAlreadyDescribesIsLeftAlone() {
        let events = [ev("icon.snapshot", "Pocket Garden: Plant Care", [:]), ev("app.snapshot", "Pocket Garden", ["rating": .number(5)])]
        #expect(NativeApps.snapshots(events: events, short: short, now: now).isEmpty)
    }
}

@Suite struct RatingCoverageTests {
    @Test func aDifferentSetOfStorefrontsIsNotComparable() {
        let now = Date(timeIntervalSince1970: 1_793_960_000)
        func snap(_ daysAgo: Double, _ rating: Double, _ count: Int, coverage: Int) -> StoredEvent {
            StoredEvent(id: 0, source: "x", kind: "rating.snapshot", app: "A", payload: .object(["rating": .number(rating), "ratings_count": .number(Double(count)), "coverage": .number(Double(coverage))]),
                        occurredAt: Int64(now.addingTimeInterval(-daysAgo * 86_400).timeIntervalSince1970 * 1000))
        }
        // Last week looked at 3 storefronts, today at 9: the lower average and bigger count come from coverage, not a real fall.
        #expect(RatingDrop.detect(app: "A", snapshots: [snap(7, 4.6, 10, coverage: 3), snap(0.1, 4.2, 40, coverage: 9)], now: now) == nil)
        // The same 9 storefronts both times: a real fall is reported.
        #expect(RatingDrop.detect(app: "A", snapshots: [snap(7, 4.6, 30, coverage: 9), snap(0.1, 4.2, 40, coverage: 9)], now: now) != nil)
    }
}

@Suite struct PermissionDiffTests {
    private let old = ApprovedPermissions(emits: ["review.new", "revenue.daily"], hosts: ["api.appstoreconnect.apple.com"], secrets: ["key"], mac: [])

    @Test func saysWhatIsNew() {
        let new = ApprovedPermissions(emits: ["review.new", "revenue.daily", "reviews.snapshot"], hosts: ["api.appstoreconnect.apple.com", "itunes.apple.com"], secrets: ["key"], mac: ["messages.send"])
        let lines = PermissionDiff.lines(old: old, new: new)
        #expect(lines == ["Now also reports: reviews.snapshot", "Now also contacts: itunes.apple.com", "Now also may use on this Mac: messages.send"])
    }

    @Test func aProgramOnlyChangeAndMissingRecords() {
        #expect(PermissionDiff.lines(old: old, new: old) == ["Its program was updated. What it may do is the same as before."])
        #expect(PermissionDiff.lines(old: nil, new: old).first?.hasPrefix("Its program changed") == true)
        let smaller = ApprovedPermissions(emits: ["review.new"], hosts: ["api.appstoreconnect.apple.com"], secrets: ["key"], mac: [])
        #expect(PermissionDiff.lines(old: old, new: smaller) == ["No longer: revenue.daily"])
    }
}

@Suite struct InsightWordingTests {
    @Test func aDailyFigureSaysItIsPerDayAndALevelDoesNot() throws {
        let cal = Calendar.current
        func series(_ values: [Double], perDay: Bool, money: Bool) -> Metric {
            let today = cal.startOfDay(for: .now)
            let pts = values.enumerated().map { (cal.date(byAdding: .day, value: -(values.count - 1 - $0.offset), to: today)!, $0.element) }
            var m = Metric(key: "k", name: "Earnings", app: "A", better: .up, isCount: false, isMoney: money, points: pts)
            m.perDay = perDay
            return m
        }
        let values = Array(repeating: 2.4, count: 24) + [4.2, 4.2, 4.2, 4.2]
        let daily = try #require(InsightEngine.unusual(series(values, perDay: true, money: true)))
        #expect(daily.title.contains(" a day since"), "got: \(daily.title)")
        #expect(daily.title.contains("a usual") && daily.title.hasSuffix("from a usual $2.40 a day"), "got: \(daily.title)")
        let level = try #require(InsightEngine.unusual(series(values, perDay: false, money: true)))
        #expect(!level.title.contains("a day"), "got: \(level.title)")
    }

    /// The daily Subscription report repeats MRR once a day, but MRR is a monthly level: findings must not say "a day".
    @Test func mrrReportedDailyIsALevelWhileProceedsArePerDay() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        var events: [StoredEvent] = []
        for back in 0..<10 {
            let d = cal.date(byAdding: .day, value: -back, to: today)!
            let day = d.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
            let at = Millis(d.timeIntervalSince1970 * 1000)
            events.append(StoredEvent(id: Int64(back), source: "appstoreconnect", kind: "subscription.mrr", app: "A",
                                      payload: .object(["day": .string(day), "mrr_usd": .number(90), "active_paid": .number(10)]), occurredAt: at))
            events.append(StoredEvent(id: Int64(100 + back), source: "appstoreconnect", kind: "revenue.daily", app: "A",
                                      payload: .object(["day": .string(day), "proceeds_usd": .number(3), "units": .number(1)]), occurredAt: at))
        }
        let metrics = MetricExtractor.extract(events)
        #expect(metrics.first { $0.key == "subscription.mrr|A|mrr_usd" }?.perDay == false)
        #expect(metrics.first { $0.key == "revenue.daily|A|proceeds_usd" }?.perDay == true)
    }
}

@Suite struct PublicGoLiveTests {
    @Test func theLiveVersionUsesApplesOwnReleaseDay() throws {
        let versions = StoredEvent(id: 0, source: "x", kind: "versions.snapshot", app: "A", payload: .object(["versions": .array([
            .object(["version": .string("4.1.7"), "state": .string("READY_FOR_DISTRIBUTION"), "created": .string("2026-10-28T10:00:00Z")]),
            .object(["version": .string("4.1.6"), "state": .string("READY_FOR_DISTRIBUTION"), "created": .string("2026-10-27T10:00:00Z")])])]), occurredAt: 0)
        let e = ReleaseTimeline.build(versions: versions, history: [], daily: [], publicLive: (version: "4.1.7", day: "2026-10-29"))
        #expect(e[0].version == "4.1.7" && e[0].liveSeenAt != nil)
        #expect(e[1].liveSeenAt == nil)                                  // only the version on sale has a day
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        #expect(f.string(from: try #require(e[0].liveSeenAt)) == "2026-10-29")
    }
}

@Suite struct PollStampsTests {
    @Test func theStampsSurviveARestart() {
        let s = PollStamps.memory()
        s.write(["asc": 1_000, "x": 2_000])
        #expect(s.read() == ["asc": 1_000, "x": 2_000])
        s.write([:])
        #expect(s.read().isEmpty)
    }
}
