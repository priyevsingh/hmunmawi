import Foundation
import Testing
@testable import HmunmawiCore

@Suite struct RoutineScheduleTests {
    func cal(_ tz: String = "Asia/Kolkata") -> Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: tz)!; return c
    }
    func date(_ s: String, _ c: Calendar) -> Date {
        let f = DateFormatter(); f.calendar = c; f.timeZone = c.timeZone; f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"; return f.date(from: s)!
    }

    @Test func parsesOnlyValidTimes() {
        #expect(RoutineSchedule.time("08:37")! == (8, 37))
        #expect(RoutineSchedule.time("8:05")! == (8, 5))
        for bad in ["24:00", "08:60", "8", "", "08:5", "aa:bb", "08:37:00", nil] { #expect(RoutineSchedule.time(bad) == nil) }
    }

    @Test func dailyTimeIsDueOnlyInsideItsWindow() {
        let c = cal()
        let at = "08:37"
        #expect(RoutineSchedule.due(at: at, everyMinutes: nil, days: [], now: date("2026-11-03 08:36", c), catchUpMinutes: 120, calendar: c) == nil)
        #expect(RoutineSchedule.due(at: at, everyMinutes: nil, days: [], now: date("2026-11-03 08:37", c), catchUpMinutes: 120, calendar: c)
                == date("2026-11-03 08:37", c))
        #expect(RoutineSchedule.due(at: at, everyMinutes: nil, days: [], now: date("2026-11-03 10:36", c), catchUpMinutes: 120, calendar: c)
                == date("2026-11-03 08:37", c))
        // 2 h 1 min late: missed.
        #expect(RoutineSchedule.due(at: at, everyMinutes: nil, days: [], now: date("2026-11-03 10:38", c), catchUpMinutes: 120, calendar: c) == nil)
    }

    @Test func weekdaysAreRespected() {
        let c = cal()   // 2026-11-01 is a Sunday
        let sun = RoutineSchedule.due(at: "10:17", everyMinutes: nil, days: ["Sun"], now: date("2026-11-01 10:20", c), catchUpMinutes: 60, calendar: c)
        let mon = RoutineSchedule.due(at: "10:17", everyMinutes: nil, days: ["Sun"], now: date("2026-11-02 10:20", c), catchUpMinutes: 60, calendar: c)
        #expect(sun == date("2026-11-01 10:17", c))
        #expect(mon == nil)
    }

    @Test func everyNMinutesFromMidnight() {
        let c = cal()
        let s = RoutineSchedule.slots(at: nil, everyMinutes: 30, days: [], after: date("2026-11-03 08:00", c), upTo: date("2026-11-03 09:30", c), calendar: c)
        #expect(s == [date("2026-11-03 08:30", c), date("2026-11-03 09:00", c), date("2026-11-03 09:30", c)])
        // Due = the newest one in the window, so a 3-hour sleep catches up once, not six times.
        #expect(RoutineSchedule.due(at: nil, everyMinutes: 30, days: [], now: date("2026-11-03 11:10", c), catchUpMinutes: 30, calendar: c)
                == date("2026-11-03 11:00", c))
    }

    @Test func crossesMidnight() {
        let c = cal()
        let d = RoutineSchedule.due(at: "23:50", everyMinutes: nil, days: [], now: date("2026-11-04 00:10", c), catchUpMinutes: 30, calendar: c)
        #expect(d == date("2026-11-03 23:50", c))
    }

    @Test func daylightSavingKeepsClockTimes() {
        let c = cal("America/New_York")   // clocks go back at 02:00 on 2026-11-01
        let s = RoutineSchedule.slots(at: "08:00", everyMinutes: nil, days: [], after: date("2026-10-31 09:00", c), upTo: date("2026-11-02 09:00", c), calendar: c)
        #expect(s == [date("2026-11-01 08:00", c), date("2026-11-02 08:00", c)])
        #expect(s.allSatisfy { c.component(.hour, from: $0) == 8 })
    }

    @Test func keysAreStablePerSlot() {
        let c = cal()
        #expect(RoutineSchedule.key("site-watch", date("2026-11-03 08:30", c), calendar: c) == "site-watch@2026-11-03T08:30")
    }

    @Test func overdueOnlyAfterGraceOnItsDays() {
        let c = cal()
        // 2026-11-04 is a Wednesday.
        #expect(RoutineSchedule.overdue(at: "08:22", days: [], lateMinutes: 60, now: date("2026-11-04 09:10", c), calendar: c) == nil)
        #expect(RoutineSchedule.overdue(at: "08:22", days: [], lateMinutes: 60, now: date("2026-11-04 09:22", c), calendar: c) == date("2026-11-04 09:22", c))
        #expect(RoutineSchedule.overdue(at: "08:22", days: ["Mon"], lateMinutes: 60, now: date("2026-11-04 12:00", c), calendar: c) == nil)
        #expect(RoutineSchedule.overdue(at: "08:22", days: ["Wed"], lateMinutes: 60, now: date("2026-11-04 12:00", c), calendar: c) != nil)
        // A deadline past midnight isn't chased; 0 minutes means not watched.
        #expect(RoutineSchedule.overdue(at: "23:30", days: [], lateMinutes: 60, now: date("2026-11-04 23:59", c), calendar: c) == nil)
        #expect(RoutineSchedule.overdue(at: "08:22", days: [], lateMinutes: 0, now: date("2026-11-04 12:00", c), calendar: c) == nil)
    }
}
