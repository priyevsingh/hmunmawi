import Foundation
import Testing
@testable import HmunmawiCore

@Suite struct BankTests {
    @Test func nextSkipsRecentlyUsedAndEmpty() {
        let items = [BankItem(id: "a", text: "A", used_on: "2026-11-01"),
                     BankItem(id: "b", text: "  "),
                     BankItem(id: "c", text: "C"),
                     BankItem(id: "d", text: "D", used_on: "2026-10-01")]
        // "c" (never used) comes before "d" (used 33 days ago); "a" is too recent; "b" is empty.
        #expect(Bank.next(items, today: "2026-11-03")?.id == "c")
        #expect(Bank.next(items, today: "2026-11-03", allowed: { $0.id != "c" })?.id == "d")
        #expect(Bank.available(items, today: "2026-11-03") == 3)
    }

    @Test func guardRefusesAnOldVersion() {
        let v = ["AppA": "4.1.7"]
        #expect(DraftGuard.problem("AppA 4.1.5 is out!", versions: v) == "mentions AppA 4.1.5, but 4.1.7 is current")
        #expect(DraftGuard.problem("AppA 4.1.7 is out!", versions: v) == nil)
        #expect(DraftGuard.problem("AppA 4.1 brings widgets", versions: v) == nil)   // the family of the current version
        #expect(DraftGuard.problem("Sleep 7.5 hours", versions: v) == nil)                   // not about the app
        #expect(DraftGuard.problem("AppA 4.1.7 now on iOS 26.1", versions: v) == nil)  // another product's version
        #expect(DraftGuard.problem("New in AppA version 4.0.2: widgets", versions: v) == "mentions AppA 4.0.2, but 4.1.7 is current")
        #expect(DraftGuard.problem(String(repeating: "x", count: 300), versions: v, maxLength: 280) == "longer than 280 characters")
    }

    @Test func followUpIsDueOnceUntilDone() {
        var e = OutreachEntry(outlet: "MacStories", app: "My App", type: "press pitch", status: "submitted", date: "2026-10-30", follow_up: "2026-11-06")
        #expect(!e.due(today: "2026-11-05"))
        #expect(e.due(today: "2026-11-06") && e.due(today: "2026-11-09"))
        e.followed_up = true
        #expect(!e.due(today: "2026-11-09"))
    }
}

@Suite struct KeyTroubleTests {
    @Test func tellsKeysFromOutages() {
        #expect(KeyTrouble.isKeyProblem("poll: Search Console answered 401: invalid_grant"))
        #expect(KeyTrouble.isKeyProblem("The token was revoked"))
        #expect(KeyTrouble.isKeyProblem("Apple refused the key (403)"))
        #expect(!KeyTrouble.isKeyProblem("The request timed out."))
        #expect(!KeyTrouble.isKeyProblem("Could not reach localhost: Connection refused"))
        #expect(KeyTrouble.isKeyProblem("The server refused the API key"))
        #expect(!KeyTrouble.isKeyProblem("Server answered 503"))
        #expect(!KeyTrouble.isKeyProblem("read 14010 bytes then the connection reset"))
        // A server-error number inside an id or a duration isn't an outage; a bad key there is still a key problem.
        #expect(KeyTrouble.isKeyProblem("Forbidden (403), request 7f500a1c"))
        #expect(KeyTrouble.isKeyProblem("invalid api key (took 1500 ms)"))
        #expect(!KeyTrouble.isKeyProblem("502 Bad Gateway"))
    }
}

@Suite struct CountZeroFillTests {
    /// One review 15 days ago and the connection working all 40 days: the quiet days before it count as zeros.
    @Test func quietDaysBeforeTheFirstEventCount() {
        let cal = Calendar.current
        let now = Date.now
        func at(_ daysAgo: Int) -> Millis { Millis(cal.date(byAdding: .day, value: -daysAgo, to: now)!.timeIntervalSince1970 * 1000) }
        var events = (0..<40).map { i in
            StoredEvent(id: Int64(i), source: "appstoreconnect", kind: "sales.daily", app: "A",
                        payload: .object(["day": .string("x"), "units": .number(1)]), occurredAt: at(i))
        }
        events.append(StoredEvent(id: 999, source: "appstoreconnect", kind: "review.new", app: "A", payload: .object([:]), occurredAt: at(15)))
        let m = MetricExtractor.extract(events, now: now).first { $0.key == "count|review.new|A" }
        #expect(m != nil)
        #expect((m?.points.count ?? 0) >= 40)
        #expect(m?.points.reduce(0) { $0 + $1.1 } == 1)
    }
}

@Suite struct ArgLineTests {
    @Test func splitsLikeAShell() {
        #expect(ArgLine.split("scripts/job.py --force") == ["scripts/job.py", "--force"])
        #expect(ArgLine.split(#"a "b c" 'd e' "" f"#) == ["a", "b c", "d e", "", "f"])
        #expect(ArgLine.split("  ") == [])
        #expect(ArgLine.split("$HOME; rm -rf x") == ["$HOME;", "rm", "-rf", "x"])   // no shell: just words
    }
}

@Suite struct SalesGapTests {
    /// A day with no sales report at all (nothing sold) counts as 0 between the first and last sales day.
    @Test func noReportDayIsZero() {
        let cal = Calendar.current
        let now = Date.now
        var events: [StoredEvent] = []
        for back in [10, 9, 8, 6, 5, 4, 3, 2] {   // day 7 missing
            let d = cal.date(byAdding: .day, value: -back, to: now)!
            events.append(StoredEvent(id: Int64(back), source: "appstoreconnect", kind: "revenue.daily", app: "A",
                                      payload: .object(["day": .string(d.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())), "units": .number(2)]), occurredAt: Millis(d.timeIntervalSince1970 * 1000)))
        }
        let m = MetricExtractor.extract(events, now: now).first { $0.key == "revenue.daily|A|units" }
        #expect(m?.points.count == 9)
        #expect(m?.points.contains { $0.1 == 0 } == true)
    }
}

@Suite struct OutreachBatchTests {
    @Test func newestBatchOnly() {
        func ev(_ id: Int64, _ kind: String, _ at: Millis, _ outlet: String = "") -> StoredEvent {
            StoredEvent(id: id, source: "scriptfeed", kind: kind, app: "A", payload: .object(["outlet": .string(outlet)]), occurredAt: at)
        }
        let morning: Millis = 1_793_700_000_000, later = morning + 3_600_000
        let events = [ev(1, "outreach.due", morning, "Old"), ev(2, "outreach.due", morning, "Stays"), ev(3, "outreach.batch", morning),
                      ev(4, "outreach.due", later, "Stays"), ev(5, "outreach.batch", later)]
        #expect(TodayBuilder.latestOutreach(events).map { $0.payload[path: "outlet"]?.string } == ["Stays"])
        let empty = events.filter { $0.id != 4 }   // everything closed: the newest list is empty
        #expect(TodayBuilder.latestOutreach(empty).isEmpty)
        #expect(TodayBuilder.latestOutreach([ev(1, "outreach.due", morning, "X")]).count == 1)   // no marker: as before
    }
}
