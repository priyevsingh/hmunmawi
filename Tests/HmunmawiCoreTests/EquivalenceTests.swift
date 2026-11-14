import Foundation
import Testing
@testable import HmunmawiCore

/// Old way vs new way, on real data. Every performance change must hand the app exactly the same rows.
/// Runs on the databases listed in HM_EQUIV_DB (colon-separated paths to COPIES, never the live file);
/// the small built-in checks below always run.
@Suite struct EquivalenceTests {
    static let paths = (ProcessInfo.processInfo.environment["HM_EQUIV_DB"] ?? "").split(separator: ":").map(String.init)
    static let tickerKinds: Set<String> = ["revenue.purchase", "revenue.renewal", "revenue.refund", "revenue.cancelled",
                                          "revenue.expired", "revenue.billing_issue", "review.new"]

    /// The old purchase-history read, exactly as the app did it (with ties put in a fixed order for comparing).
    static func oldHistory(_ store: Store, since: Millis, limit: Int, keep: (StoredEvent) -> Bool) async throws -> [StoredEvent] {
        let all = try await store.events(since: since)
        return Array(all.filter { tickerKinds.contains($0.kind) && keep($0) }
            .sorted { ($0.occurredAt, $0.id) > ($1.occurredAt, $1.id) }.prefix(limit))
    }

    static func newHistory(_ store: Store, since: Millis, limit: Int, page: Int, keep: (StoredEvent) -> Bool) async throws -> [StoredEvent] {
        var out: [StoredEvent] = [], cursor: (occurredAt: Millis, id: Int64)? = nil
        while out.count < limit {
            let rows = try await store.recentEvents(kinds: tickerKinds, since: since, before: cursor, limit: page)
            guard let last = rows.last else { break }
            out += rows.filter(keep).prefix(limit - out.count)
            if rows.count < page { break }
            cursor = (last.occurredAt, last.id)
        }
        return out
    }

    @Test(.enabled(if: !EquivalenceTests.paths.isEmpty)) func boundedReadsMatchOnRealData() async throws {
        for path in Self.paths {
            let store = try Store(path: path)
            // Lifetime sales: SQL count == the old load-everything-and-filter count.
            let old = try await store.events(since: 0).filter { $0.kind == "revenue.purchase" }.count
            #expect(try await store.countEvents(kind: "revenue.purchase") == old, "count differs in \(path)")
            // Purchase history: same rows, same order, at several sizes, page lengths and filters. The old read
            // (a whole year) is done once and reused, exactly as the app did it.
            let since = Millis(Date.now.timeIntervalSince1970 * 1000) - 365 * TodayBuilder.day
            let year = try await store.events(since: since)
            let apps = Set(year.compactMap(\.app))
            let filters: [(String, (StoredEvent) -> Bool)] = [("all", { _ in true })]
                + apps.sorted().prefix(2).map { a in ("app \(a)", { $0.app == a }) }
            for (name, keep) in filters {
                let oldAll = year.filter { Self.tickerKinds.contains($0.kind) && keep($0) }
                    .sorted { ($0.occurredAt, $0.id) > ($1.occurredAt, $1.id) }
                for limit in [1, 10, 200, 201, 5000] {
                    for page in [7, 200] {
                        let a = oldAll.prefix(limit).map(\.id)
                        let b = try await Self.newHistory(store, since: since, limit: limit, page: page, keep: keep).map(\.id)
                        #expect(a == b, "history differs: \(path) filter=\(name) limit=\(limit) page=\(page)")
                    }
                }
            }
        }
    }

    @Test(.enabled(if: !EquivalenceTests.paths.isEmpty)) func fastReaderMatchesOldReaderOnRealData() async throws {
        for path in Self.paths {
            let store = try Store(path: path)
            // Every event in a small (real) database; the last 60 days of a big one.
            let since: Millis = try await store.eventCount() < 50_000 ? -1 : Millis(Date.now.timeIntervalSince1970 * 1000) - 60 * TodayBuilder.day
            // The old query sorted by time only (ties in whatever order the index gives); compare in the defined order.
            let old = try await store.legacyEvents(since: since).sorted { ($0.occurredAt, $0.id) < ($1.occurredAt, $1.id) }
            let new = try await store.events(since: since)
            #expect(old.count == new.count, "row count differs in \(path)")
            var mismatches = 0
            for (a, b) in zip(old, new) where a != b {
                mismatches += 1
                if mismatches <= 3 { Issue.record("event \(a.id) (\(a.kind)) differs in \(path)") }
            }
            #expect(mismatches == 0, "\(mismatches) of \(old.count) events differ in \(path)")
            print("EQUIV \(path.split(separator: "/").last ?? ""): \(old.count) events identical: \(mismatches == 0)")
        }
    }

    static func dump(_ metrics: [Metric]) -> [String] {
        metrics.map { m in "\(m.key)|\(m.name)|\(m.app ?? "")|\(String(describing: m.better))|\(m.isCount)|\(m.isMoney)|\(m.family)|\(m.additive)|"
            + m.points.map { "\($0.day.timeIntervalSince1970)=\($0.value)" }.joined(separator: ",") + "|\(m.breakdowns.keys.sorted())" }.sorted()
    }

    @Test(.enabled(if: !EquivalenceTests.paths.isEmpty)) func insightRowsGiveSameMetricsAndFindings() async throws {
        for path in Self.paths {
            let store = try Store(path: path)
            let since = Millis(Date.now.timeIntervalSince1970 * 1000) - 60 * TodayBuilder.day
            let old = MetricExtractor.extract(DailyEvents.oneSourcePerDay(try await store.events(since: since)))
            let new = MetricExtractor.extract(DailyEvents.oneSourcePerDay(try await store.insightRows(since: since)))
            #expect(Self.dump(old) == Self.dump(new), "metrics differ in \(path)")
            let f1 = InsightEngine.run(old).map { "\($0.id)|\($0.title)|\($0.evidence)" }
            let f2 = InsightEngine.run(new).map { "\($0.id)|\($0.title)|\($0.evidence)" }
            let again = InsightEngine.run(MetricExtractor.extract(DailyEvents.oneSourcePerDay(try await store.events(since: since))))
                .map { "\($0.id)|\($0.title)|\($0.evidence)" }
            print("EQUIV old-vs-old same order: \(f1 == again); same set: \(Set(f1) == Set(again)); old-vs-new same set: \(Set(f1) == Set(f2))")
            #expect(f1 == again, "old path not stable in \(path)")
            #expect(f1 == f2, "findings differ in \(path)")
            print("EQUIV insights \(path.split(separator: "/").last ?? ""): \(old.count) metrics, \(f1.count) findings identical: \(Self.dump(old) == Self.dump(new) && Set(f1) == Set(f2))")
        }
    }

    @Test func fastParseMatchesDecoderOnTrickyValues() throws {
        let samples = [#"{"a":true,"b":false,"c":1,"d":0,"e":1.5,"f":-0.0,"g":1e21,"h":12345678901234567890,"i":0.1}"#,
                       #"{"s":"é\u00e9\n\"q\"","n":null,"arr":[1,true,"x",null,{"k":[]}],"o":{}}"#,
                       #"[1,2,3]"#, #""just text""#, #"42"#, #"true"#, #"null"#,
                       #"{"big":9007199254740993,"tiny":5e-324,"neg":-123.456e-7}"#]
        for text in samples {
            #expect(try JSONValue.fastParse(Data(text.utf8)) == JSONValue.parse(text), "\(text)")
        }
    }

    @Test func pagingHandlesTiesAndPageEdges() async throws {
        let store = try Store(path: ":memory:")
        // 25 purchases sharing 5 timestamps (ties), plus other kinds that must be skipped.
        for i in 0..<25 {
            _ = try await store.ingest(Event(source: "t", kind: "revenue.purchase", app: i % 2 == 0 ? "A" : "B",
                                             payload: .object([:]), occurredAt: Millis(1_000 + (i / 5)), dedupeKey: "p\(i)"), rules: [])
            _ = try await store.ingest(Event(source: "t", kind: "app.snapshot", payload: .object([:]),
                                             occurredAt: Millis(1_000 + i), dedupeKey: "s\(i)"), rules: [])
        }
        for page in [1, 3, 5, 24, 25, 100] {
            for limit in [1, 4, 25, 30] {
                let a = try await Self.oldHistory(store, since: 0, limit: limit, keep: { $0.app == "A" }).map(\.id)
                let b = try await Self.newHistory(store, since: 0, limit: limit, page: page, keep: { $0.app == "A" }).map(\.id)
                #expect(a == b, "page=\(page) limit=\(limit)")
            }
        }
        #expect(try await store.countEvents(kind: "revenue.purchase") == 25)
    }

    @Test func upgradeKeepsDataAddsIndexAndBacksUpFirst() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hm-upgrade-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: "db.sqlite").path
        do {   // a database one version behind, with data
            let store = try Store(path: path)
            for i in 0..<20 { _ = try await store.ingest(Event(source: "t", kind: "review.new", payload: .object(["n": .number(Double(i))]),
                                                           occurredAt: Millis(i), dedupeKey: "r\(i)"), rules: []) }
            _ = try await store.ingest(Event(source: "t", kind: "x.days", payload: .object(["days": .array([])]), occurredAt: 30, dedupeKey: "d"), rules: [])
            // Back to version 4's layout (two upgrades behind): no flag column, the plain time index.
            try await store.rawExecute("DROP INDEX events_time_cover")
            try await store.rawExecute("ALTER TABLE events DROP COLUMN has_day")
            try await store.rawExecute("ALTER TABLE plugin_approvals DROP COLUMN signature")
            try? await store.rawExecute("ALTER TABLE plugin_approvals DROP COLUMN permissions_sha")
            try await store.rawExecute("CREATE INDEX events_time ON events (occurred_at)")
            try await store.rawExecute("PRAGMA user_version = 4")
        }
        #expect(Resilience.needsUpgrade(databaseAt: path))
        let backup = try Resilience.backUpBeforeUpgrade(databaseAt: path, backups: dir.appending(path: "Backups"))
        #expect(backup?.hasPrefix("pre-upgrade-v4-") == true)
        let upgraded = try Store(path: path)
        #expect(try await upgraded.events(since: -1).count == 21)
        #expect(!Resilience.needsUpgrade(databaseAt: path))
        #expect(try await upgraded.eventCount() == 21)
        // The upgrade marked the stored "days" payload, so insights still read it in full.
        #expect(try await upgraded.insightRows(since: -1).first { $0.kind == "x.days" }?.payload == .object(["days": .array([])]))
        #expect(try await upgraded.insightRows(since: -1).first { $0.kind == "review.new" }?.payload == .object([:]))
        // The backup is a full, healthy copy of the data before the upgrade.
        let copy = dir.appending(path: "Backups").appending(path: backup ?? "").path
        #expect(Resilience.isHealthy(copy))
        #expect(try await Store(path: copy).eventCount() == 21)
    }
}
