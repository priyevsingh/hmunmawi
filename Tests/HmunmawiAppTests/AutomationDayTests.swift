import CoreGraphics
import Foundation
import Testing
@testable import HmunmawiApp

@MainActor @Suite struct AutomationDayTests {
    @Test func futureJobListSlotsStayLaterWhenEarlierRunSucceeded() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let day = cal.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 8, minute: 33))!
        let slot04 = cal.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 4, minute: 0))!
        let slot10 = cal.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 10, minute: 0))!
        let slot16 = cal.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 16, minute: 0))!
        let slot22 = cal.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 22, minute: 0))!

        #expect(AutomationDay.jobListStatus(lastStatus: "ran", slotAt: slot04, latestPastSlot: slot04, now: day) == "ran")
        #expect(AutomationDay.jobListStatus(lastStatus: "ran", slotAt: slot10, latestPastSlot: slot04, now: day) == "later")
        #expect(AutomationDay.jobListStatus(lastStatus: "ran", slotAt: slot16, latestPastSlot: slot04, now: day) == "later")
        #expect(AutomationDay.jobListStatus(lastStatus: "ran", slotAt: slot22, latestPastSlot: slot04, now: day) == "later")
        #expect(AutomationDay.jobListStatus(lastStatus: "failed", slotAt: slot16, latestPastSlot: slot04, now: day) == "later")
    }

    @Test func failedJobListMarksOnlyLatestPastSlot() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 11, minute: 0))!
        let slot04 = cal.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 4, minute: 0))!
        let slot10 = cal.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 10, minute: 0))!
        let slot16 = cal.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 16, minute: 0))!

        #expect(AutomationDay.jobListStatus(lastStatus: "failed", slotAt: slot04, latestPastSlot: slot10, now: now) == "untracked")
        #expect(AutomationDay.jobListStatus(lastStatus: "failed", slotAt: slot10, latestPastSlot: slot10, now: now) == "failed")
        #expect(AutomationDay.jobListStatus(lastStatus: "failed", slotAt: slot16, latestPastSlot: slot10, now: now) == "later")
    }

    @Test func crowdedMidnightRunsNeverOverlapAndStayIndividuallyHoverable() {
        let runs = (0..<10).map { i in
            AutomationDay.Run(minute: 0, title: "Midnight job \(i)", detail: "Runs at 00:00", bot: false, status: "ran", sourceID: "job.\(i)")
        }
        let width: CGFloat = 760
        let layout = AutomationDay.layoutBeads(runs: runs, width: width)
        #expect(layout.positions.count == runs.count)
        #expect(layout.height > 110)

        let points = runs.compactMap { layout.positions[$0.id] }
        #expect(points.count == runs.count)
        for pt in points {
            #expect(pt.x >= AutomationDay.stripInset)
            #expect(pt.x <= width - AutomationDay.stripInset)
            #expect(pt.y >= 16 && pt.y <= layout.height - 16)
        }
        for i in 0..<points.count {
            for j in (i + 1)..<points.count {
                #expect(hypot(points[i].x - points[j].x, points[i].y - points[j].y) >= 15.5)
            }
        }
        // Every individual midnight dot resolves to its own Run under 2D hover.
        for r in runs {
            let pt = layout.positions[r.id]!
            let hit = AutomationDay.nearestRun(to: CGPoint(x: pt.x + 2, y: pt.y - 2), in: layout.positions, runs: runs)
            #expect(hit?.id == r.id)
        }
    }
}
