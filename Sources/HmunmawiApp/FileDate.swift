import Darwin
import Foundation

/// A file's last-change date via plain stat(): unlike FileManager.attributesOfItem it never reads extended
/// attributes, which can hang indefinitely on some files (seen on files in ~/Documents).
func fileModified(_ path: String) -> Date? {
    var st = stat()
    guard stat(path, &st) == 0 else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
}

extension Date {
    /// This Mac's calendar day as YYYY-MM-DD (local time, not UTC: at 02:00 in India it's already the new day).
    var localDay: String { formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day()) }
}
