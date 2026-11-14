import Foundation

/// How close the payday forecast came: the forecast recorded mid-month against Apple's finance report for the same
/// fiscal month (both in USD).
public enum ForecastCheck {
    public struct Row: Sendable, Equatable {
        public let month: String
        public let forecastUSD: Double
        public let appleUSD: Double
        /// (forecast - Apple) / Apple: +0.05 = forecast 5% too high.
        public let error: Double
    }

    /// Months that have both, newest first; months where Apple's figure is 0 are left out (no meaningful %).
    public static func rows(forecasts: [String: Double], apple: [String: Double]) -> [Row] {
        forecasts.compactMap { m, f in
            guard let a = apple[m], a > 0 else { return nil }
            return Row(month: m, forecastUSD: f, appleUSD: a, error: (f - a) / a)
        }.sorted { $0.month > $1.month }
    }

    /// Average size of the miss across months (0.04 = off by 4% on average), nil with no months.
    public static func averageMiss(_ rows: [Row]) -> Double? {
        rows.isEmpty ? nil : rows.map { abs($0.error) }.reduce(0, +) / Double(rows.count)
    }
}
