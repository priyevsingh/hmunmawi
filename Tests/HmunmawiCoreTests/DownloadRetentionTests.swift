import Foundation
import Testing
@testable import HmunmawiCore

@Suite struct DownloadRetentionTests {
    func row(_ app: String, _ download: String, _ date: String, _ devices: Int) -> [String: String] {
        ["App Name": app, "App Download Date": download, "Date": date, "Unique Devices": String(devices)]
    }

    @Test func dayOneSevenAndTwentyEight() {
        var rows = [row("My App: Photo Editor", "2026-09-01", "2026-09-01", 10),
                    row("My App: Photo Editor", "2026-09-01", "2026-09-02", 3),
                    row("My App: Photo Editor", "2026-09-01", "2026-09-08", 1),
                    row("My App: Photo Editor", "2026-09-29", "2026-09-29", 4),
                    row("My App: Photo Editor", "2026-09-29", "2026-09-30", 2)]
        rows.append(row("My App: Photo Editor", "", "2026-10-06", 50))   // sessions with no download date: only widen the days read
        let r = DownloadRetention.make(rows) { String($0.split(separator: ":").first ?? "") }["My App"]!
        #expect(r.points == [.init(day: 1, kept: 5, of: 14), .init(day: 7, kept: 1, of: 14), .init(day: 28, kept: 0, of: 10)])
        #expect(r.fromDay == "2026-09-01" && r.toDay == "2026-10-06")
    }

    @Test func cohortsTooRecentAreLeftOut() {
        let rows = [row("A", "2026-10-30", "2026-10-30", 8), row("A", "2026-10-30", "2026-10-31", 2)]
        let r = DownloadRetention.make(rows)["A"]!
        #expect(r.points == [.init(day: 1, kept: 2, of: 8)])   // day 7 and 28 aren't due yet
    }

    @Test func parsesTabsAndGzip() throws {
        let text = "Date\tApp Name\tApp Download Date\tUnique Devices\n2026-10-01\tA\t2026-10-01\t3\nbroken line\n"
        #expect(DownloadRetention.parseTSV(text) == [["Date": "2026-10-01", "App Name": "A", "App Download Date": "2026-10-01", "Unique Devices": "3"]])
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = dir.appending(path: "r.tsv")
        try text.write(to: plain, atomically: true, encoding: .utf8)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip"); p.arguments = ["-k", plain.path]
        try p.run(); p.waitUntilExit()
        let unpacked = DownloadRetention.gunzip(try Data(contentsOf: dir.appending(path: "r.tsv.gz")))
        #expect(unpacked.map { String(decoding: $0, as: UTF8.self) } == text)
    }
}
