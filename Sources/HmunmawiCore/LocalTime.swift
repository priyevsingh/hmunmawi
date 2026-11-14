import Foundation

/// Times are always shown in the Mac's own time zone (or the owner's fixed one), labelled with its short name.
public enum LocalTime {
    /// "IST", "PST", "GMT+2": the zone's short name in the Mac's language.
    public static func zoneLabel(_ zone: TimeZone = OwnerConfig.current.zone, at date: Date = .now, locale: Locale = .current) -> String {
        zone.localizedName(for: zone.isDaylightSavingTime(for: date) ? .shortDaylightSaving : .shortStandard, locale: locale)
            ?? zone.abbreviation(for: date) ?? zone.identifier
    }
}
