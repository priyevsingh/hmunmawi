import Foundation
import Testing
@testable import HmunmawiCore

/// Scale check against a large database (a year of a heavy user's data). Skipped unless HM_BENCH_DB points at
/// a copy of such a database; never touches the live one. Prints how long each step the app runs takes.
@Suite struct BenchTests {
    static let path = ProcessInfo.processInfo.environment["HM_BENCH_DB"]

    private func time<T>(_ label: String, _ work: () async throws -> T) async rethrows -> T {
        let start = ContinuousClock.now
        let value = try await work()
        let ms = (ContinuousClock.now - start).components
        print(String(format: "BENCH %8.0f ms  %@", Double(ms.seconds) * 1000 + Double(ms.attoseconds) / 1e15, label))
        return value
    }

    @Test(.enabled(if: BenchTests.path != nil)) func refreshAtScale() async throws {
        let store = try Store(path: BenchTests.path!)
        let now = Millis(Date.now.timeIntervalSince1970 * 1000)
        let week = try await time("events(since: 8 days) incl. decode") { try await store.events(since: now - 8 * TodayBuilder.day) }
        print("BENCH          rows in 8 days: \(week.count)")
        _ = await time("dedupe one-source-per-day (8 days)") { DailyEvents.oneSourcePerDay(week) }
        _ = try await time("today() card") { try await store.today() }
        _ = try await time("appSummaries()") { try await store.appSummaries() }
        let history = try await time("events(since: 60 days) incl. decode") { try await store.events(since: now - 60 * TodayBuilder.day) }
        print("BENCH          rows in 60 days: \(history.count)")
        let metrics = await time("MetricExtractor.extract (60 days)") { MetricExtractor.extract(DailyEvents.oneSourcePerDay(history)) }
        _ = await time("InsightEngine.run") { InsightEngine.run(metrics) }
        var window = EventWindow(days: 9)
        _ = try await time("window: first load (9 days)") { try await window.update(from: store, now: now) }
        _ = try await time("window: quiet refresh (nothing new)") { try await window.update(from: store, now: now) }
        let rows = window.rows
        _ = try await time("today(recent:) from window") { try await store.today(recent: rows) }
        _ = await time("appSummaries(recent:) from window") { await store.appSummaries(recent: rows) }
        let lean = try await time("insightRows(60 days)") { try await store.insightRows(since: now - 60 * TodayBuilder.day) }
        _ = await time("insights from lean rows (extract + run)") { InsightEngine.run(MetricExtractor.extract(DailyEvents.oneSourcePerDay(lean))) }
        var iw = EventWindow(days: 60, lean: true)
        _ = try await time("insight window: first load (60 days, lean)") { try await iw.update(from: store, now: now) }
        _ = try await time("insight window: quiet refresh") { try await iw.update(from: store, now: now) }
        _ = try await time("recentAudit(400)") { try await store.recentAudit(limit: 400) }
        _ = try await time("ingest one event") {
            try await store.ingest(Event(source: "bench", kind: "review.new", payload: .object([:]), occurredAt: now,
                                         dedupeKey: "bench-\(UUID().uuidString)"), rules: [])
        }
    }
}
