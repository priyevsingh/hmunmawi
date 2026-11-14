import Foundation
import Testing
@testable import HmunmawiCore

/// The in-memory window must always equal a fresh `events(since:)` read, and the card/summary builders fed from
/// it must equal the ones that read the database themselves.
@Suite struct WindowTests {
    @Test func leanInsightWindowEqualsFreshInsightRead() async throws {
        let clock = TestClockW()
        let store = try Store(path: ":memory:", now: { clock.now })
        let day = TodayBuilder.day
        func add(_ key: String, _ at: Millis, kind: String, _ payload: JSONValue) async throws {
            _ = try await store.ingest(Event(source: "t", kind: kind, app: "A", payload: payload, occurredAt: at, dedupeKey: key), rules: [])
        }
        let mix: [(String, JSONValue)] = [("review.new", .object(["k": .string("x")])), ("crash.daily", .object(["n": .number(2)])),
                                          ("history.series", .object(["days": .array([.number(1)])])), ("revenue.purchase", .object(["amount": .number(4.99)])),
                                          ("app.snapshot", .object(["day": .null])), ("section.snapshot", .object(["s": .string("a")])),
                                          ("growth.x", .object(["day": .string("2026-11-01")]))]
        for i in 0..<70 { let m = mix[i % mix.count]; try await add("o\(i)", clock.now - Millis(i) * day, kind: m.0, m.1) }
        var w = EventWindow(days: 60, lean: true)
        try await w.update(from: store, now: clock.now)
        #expect(w.rows == (try await store.insightRows(since: clock.now - 60 * day)))
        for (i, m) in mix.enumerated() { try await add("n\(i)", clock.now - Millis(i % 3) * day, kind: m.0, m.1) }
        clock.advance(3 * day)
        try await w.update(from: store, now: clock.now)
        #expect(w.rows == (try await store.insightRows(since: clock.now - 60 * day)))
        // The flag and the extractor agree: a "day" key, even null, keeps the full payload.
        #expect(w.rows.first { $0.kind == "app.snapshot" }?.payload == .object(["day": .null]))
        #expect(w.rows.first { $0.kind == "growth.x" }?.payload == .object(["day": .string("2026-11-01")]))
        // Insights from the lean rows equal insights from full rows.
        let full = try await store.events(since: clock.now - 60 * day)
        let a = MetricExtractor.extract(DailyEvents.oneSourcePerDay(full), now: Date(timeIntervalSince1970: Double(clock.now) / 1000))
        let b = MetricExtractor.extract(DailyEvents.oneSourcePerDay(w.rows), now: Date(timeIntervalSince1970: Double(clock.now) / 1000))
        #expect(a.map(\.key).sorted() == b.map(\.key).sorted())
        #expect(a.sorted { $0.key < $1.key }.map { $0.points.map(\.1) } == b.sorted { $0.key < $1.key }.map { $0.points.map(\.1) })
    }

    @Test func windowReloadsWhenPruneFreesIDs() async throws {
        // A backfill stores 120-day-old rows as the newest ids; prune deletes them and SQLite hands those ids out
        // again. The window must still pick up the next event.
        let clock = TestClockW()
        let store = try Store(path: ":memory:", now: { clock.now })
        let day = TodayBuilder.day
        func add(_ key: String, _ at: Millis) async throws {
            _ = try await store.ingest(Event(source: "t", kind: "app.snapshot", app: "A", payload: .object(["k": .string(key)]),
                                             occurredAt: at, dedupeKey: key), rules: [])
        }
        try await add("a", clock.now - day)
        var w = EventWindow(days: 9)
        try await w.update(from: store, now: clock.now)
        for i in 0..<3 { try await add("ancient\(i)", clock.now - 120 * day) }
        try await w.update(from: store, now: clock.now)
        let pruned = try await store.prune(olderThanDays: 90)
        #expect(pruned.events == 3)
        try await add("b", clock.now)            // reuses a freed id
        try await w.update(from: store, now: clock.now)
        #expect(w.rows == (try await store.events(since: clock.now - 9 * day)))
        #expect(w.rows.count == 2)
    }

    @Test func nullDayCountsAsPresentInSwiftAndSQL() async throws {
        #expect(Store.hasDay(.object(["day": .null])))
        #expect(!Store.hasDay(.object(["other": .null])))
        let store = try Store(path: ":memory:")
        _ = try await store.ingest(Event(source: "t", kind: "x.y", payload: .object(["day": .null]), occurredAt: 1, dedupeKey: "n"), rules: [])
        try await store.rawExecute("UPDATE events SET has_day = 0")
        // Migration 6's statement re-flags it.
        try await store.rawExecute(Schema.migrations[5])
        #expect(try await store.insightRows(since: 0).first?.payload == .object(["day": .null]))
    }

    @Test func windowEqualsFreshReadThroughArrivalsBackfillsAndAging() async throws {
        let clock = TestClockW()
        let store = try Store(path: ":memory:", now: { clock.now })
        func add(_ key: String, _ at: Millis, kind: String = "review.new") async throws {
            _ = try await store.ingest(Event(source: "t", kind: kind, app: "A", payload: .object(["k": .string(key)]),
                                             occurredAt: at, dedupeKey: key), rules: [])
        }
        let day = TodayBuilder.day
        for i in 0..<30 { try await add("old\(i)", clock.now - Millis(i) * day / 2) }
        var w = EventWindow(days: 9)
        try await w.update(from: store, now: clock.now)
        #expect(w.rows == (try await store.events(since: clock.now - 9 * day)))
        // New arrivals, a late report about an older day, ties on the same time, and time passing.
        try await add("new1", clock.now)
        try await add("late", clock.now - 5 * day)
        try await add("tie1", clock.now - day); try await add("tie2", clock.now - day)
        try await add("tooOld", clock.now - 20 * day)
        clock.advance(2 * day)
        try await w.update(from: store, now: clock.now)
        #expect(w.rows == (try await store.events(since: clock.now - 9 * day)))
        #expect(!(try await w.update(from: store, now: clock.now)))   // nothing new: no change reported
        #expect(try await store.today(recent: w.rows) == store.today())
        #expect(await store.appSummaries(recent: w.rows) == (try await store.appSummaries()))
    }
}

final class TestClockW: @unchecked Sendable {
    var now: Millis = 400 * TodayBuilder.day
    func advance(_ ms: Millis) { now += ms }
}
