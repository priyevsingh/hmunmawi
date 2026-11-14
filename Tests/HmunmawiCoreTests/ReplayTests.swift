import Foundation
import Testing
@testable import HmunmawiCore

/// Replays the app's startup database steps on copies (HM_REPLAY_DIR), printing each step, to find where it stops.
@Suite struct ReplayTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HM_REPLAY_DIR"] != nil)) func startup() async throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HM_REPLAY_DIR"]!)
        let live = dir.appending(path: "hmunmawi.sqlite").path, backups = dir.appending(path: "Backups")
        print("REPLAY prepare:", try Resilience.prepare(databaseAt: live, backups: backups))
        print("REPLAY upgrade backup:", (try? Resilience.backUpBeforeUpgrade(databaseAt: live, backups: backups)) ?? "error")
        let store = try Store(path: live); print("REPLAY live opened")
        let demo = try Store(path: dir.appending(path: "demo.sqlite").path); print("REPLAY demo opened")
        try await DemoData.seedIfEmpty(demo); print("REPLAY demo seeded")
        print("REPLAY backup due:", try await Resilience.backUpIfDue(store: store, settings: nil, backups: backups))
        print("REPLAY events 8d:", try await store.events(since: Millis(Date.now.timeIntervalSince1970 * 1000) - 8 * TodayBuilder.day).count)
        print("REPLAY today:", try await store.today().win.title)
    }
}
