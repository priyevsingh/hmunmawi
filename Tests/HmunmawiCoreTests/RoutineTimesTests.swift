import Foundation
import Testing
@testable import HmunmawiCore

@Suite struct RoutineTimesTests {
    let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Kolkata")!; return c }()

    @Test func severalTimesADay() {
        #expect(RoutineSchedule.times("22:00, 04:00,10:00,16:00,04:00,25:00,x").map { $0.hour } == [4, 10, 16, 22])
        let day = cal.date(from: DateComponents(year: 2026, month: 11, day: 14))!
        let slots = RoutineSchedule.slots(at: "04:00,10:00,16:00,22:00", everyMinutes: nil, days: [], after: day,
                                          upTo: day.addingTimeInterval(86_399), calendar: cal)
        #expect(slots.map { cal.component(.hour, from: $0) } == [4, 10, 16, 22])
        let now = cal.date(bySettingHour: 10, minute: 3, second: 0, of: day)!
        let due = RoutineSchedule.due(at: "04:00,10:00", everyMinutes: nil, days: [], now: now, catchUpMinutes: 30, calendar: cal)
        #expect(due.map { cal.component(.hour, from: $0) } == 10)
    }

    @Test func everyFiveMinutes() {
        let day = cal.date(from: DateComponents(year: 2026, month: 11, day: 14))!
        let slots = RoutineSchedule.slots(at: nil, everyMinutes: 5, days: [], after: day, upTo: day.addingTimeInterval(3600), calendar: cal)
        #expect(slots.count == 12)
    }
}
