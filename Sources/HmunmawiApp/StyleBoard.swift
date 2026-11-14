import Charts
import HmunmawiCore
import SwiftUI

/// Developer screen (never shown to users): a board comparing chart styles on real data, opened with
/// `open Hmunmawi.app --args -HMStyleBoard YES`. Used to pick the house style; kept for future design work.
struct StyleBoard: View {
    let model: AppModel

    enum Variant: String, CaseIterable, Identifiable {
        case latest = "1 · Latest month vs before"
        case everyStep = "2 · Every month vs the one before"
        case trendLine = "3 · Line with direction"
        var id: String { rawValue }

        var note: String {
            switch self {
            case .latest: "Grey history; only the newest bar is green (up) or red (down), with the change."
            case .everyStep: "Each bar green if it beat the month before, red if it fell. Like a stock chart."
            case .trendLine: "A calm grey line; the end point and the change chip are green or red."
            }
        }
    }

    var body: some View {
        let months = model.snapshots("earnings.months").first?.payload[path: "months"]?.array ?? []
        let points: [(String, Double)] = months.map {
            (String(($0[path: "label"]?.string ?? "").prefix(3)), $0[path: "usd"]?.number ?? 0)
        }
        ScrollView {
            VStack(spacing: 18) {
                ForEach(Variant.allCases) { variant in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(variant.rawValue).font(.title3.weight(.bold))
                        Text(variant.note).font(.callout).foregroundStyle(.secondary)
                        DirectionChart(points: points, variant: variant)
                    }
                    .padding(22)
                    .contentCard(cornerRadius: 24)
                }
            }
            .padding(28)
        }
        .task { await model.load() }
    }
}

struct DirectionChart: View {
    let points: [(String, Double)]
    let variant: StyleBoard.Variant

    var body: some View {
        let peak = max(points.map(\.1).max() ?? 1, 1)
        let last = points.count - 1
        let change = last > 0 && points[last - 1].1 > 0 ? (points[last].1 - points[last - 1].1) / points[last - 1].1 : 0
        let changeColor: Color = change >= 0 ? Brand.good : Brand.bad

        HStack(alignment: .bottom, spacing: 24) {
            if variant == .trendLine {
                Chart(Array(points.enumerated()), id: \.offset) { index, point in
                    AreaMark(x: .value("Month", index), y: .value("USD", point.1))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(LinearGradient(colors: [.primary.opacity(0.10), .clear], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Month", index), y: .value("USD", point.1))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(.primary.opacity(0.75))
                        .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    if index == last {
                        PointMark(x: .value("Month", index), y: .value("USD", point.1))
                            .symbolSize(140)
                            .foregroundStyle(changeColor)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: Array(points.indices)) { value in
                        AxisValueLabel { if let i = value.as(Int.self), points.indices.contains(i) { Text(points[i].0) } }
                    }
                }
                .chartYAxis(.hidden)
                .frame(height: 150)
            } else {
                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                        let color: Color = {
                            switch variant {
                            case .latest: return index == last ? changeColor : Color.primary.opacity(0.22)
                            default:
                                guard index > 0 else { return Color.primary.opacity(0.22) }
                                return point.1 >= points[index - 1].1 ? Brand.good : Brand.bad
                            }
                        }()
                        VStack(spacing: 6) {
                            Text(point.1.formatted(.currency(code: "USD").precision(.fractionLength(0))))
                                .font(.caption2.weight(index == last ? .bold : .medium)).monospacedDigit()
                                .foregroundStyle(index == last ? .primary : .secondary)
                            ZStack(alignment: .bottom) {
                                Capsule().fill(.quaternary.opacity(0.4))
                                Capsule().fill(color.gradient).frame(height: max(6, 130 * point.1 / peak))
                            }
                            .frame(width: 26, height: 130)
                            Text(point.0).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Latest").font(.caption).foregroundStyle(.secondary)
                Text(points.last.map { $0.1.formatted(.currency(code: "USD").precision(.fractionLength(0))) } ?? "Not in yet")
                    .font(.system(size: 30, weight: .bold))
                Label("\(change >= 0 ? "+" : "")\(Int((change * 100).rounded()))% vs month before",
                      systemImage: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(changeColor)
            }
            .frame(width: 210, alignment: .leading)
        }
    }
}
