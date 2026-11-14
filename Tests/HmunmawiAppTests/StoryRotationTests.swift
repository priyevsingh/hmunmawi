import Foundation
import HmunmawiCore
import Testing
@testable import HmunmawiApp

@Suite struct StoryRotationTests {
    func f(_ id: String, _ score: Double) -> Finding {
        Finding(id: id, lane: .win, detector: .unusual, app: nil, title: id, evidence: "", why: "", score: score)
    }
    let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()

    @Test func rotatesAwayFromRecentHeadlines() {
        let all = [f("a", 9), f("b", 5)]
        #expect(StoryCards.today(all, shown: [:], today: "2026-11-14", calendar: cal)?.id == "a")
        // "a" was the headline yesterday: today it's "b".
        #expect(StoryCards.today(all, shown: ["a": "2026-11-13"], today: "2026-11-14", calendar: cal)?.id == "b")
        // Both shown recently: the one shown longest ago.
        #expect(StoryCards.today(all, shown: ["a": "2026-11-13", "b": "2026-11-12"], today: "2026-11-14", calendar: cal)?.id == "b")
        // After 3 days "a" can come back.
        #expect(StoryCards.today(all, shown: ["a": "2026-11-10"], today: "2026-11-14", calendar: cal)?.id == "a")
    }
    @Test func staysTheSameWithinADay() {
        let all = [f("a", 9), f("b", 5)]
        #expect(StoryCards.today(all, shown: ["b": "2026-11-14"], today: "2026-11-14", calendar: cal)?.id == "b")
    }
}
