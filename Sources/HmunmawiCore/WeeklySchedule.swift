import Foundation

/// When a weekly message is due: the most recent scheduled moment (weekday 1 = Sunday … 7 = Saturday, at `hour`),
/// but only within `grace` after it, so a Mac that was asleep sends it late that day, never days later.
public enum WeeklySchedule {
    public static func dueSlot(now: Date, weekday: Int, hour: Int, grace: TimeInterval = 86_400,
                               calendar: Calendar = .current) -> Date? {
        guard (1...7).contains(weekday), (0...23).contains(hour) else { return nil }
        // Searching back from just after `now`, so a slot exactly at `now` counts (the search skips its start).
        guard var slot = calendar.nextDate(after: now.addingTimeInterval(1), matching: DateComponents(hour: hour, minute: 0, weekday: weekday),
                                           matchingPolicy: .nextTime, direction: .backward) else { return nil }
        if slot > now { slot = calendar.date(byAdding: .day, value: -7, to: slot) ?? slot }
        return now.timeIntervalSince(slot) < grace ? slot : nil
    }
}
