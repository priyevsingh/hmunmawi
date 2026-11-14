import AppKit
import HmunmawiCore
import SwiftUI

extension TodayItem.Kind {
    var label: String {
        switch self {
        case .win: "Win"
        case .worry: "Worry"
        case .next: "Next"
        }
    }

    var symbol: String {
        switch self {
        case .win: "sparkles"
        case .worry: "exclamationmark.triangle.fill"
        case .next: "arrow.right.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .win: Brand.good
        case .worry: Brand.caution
        case .next: .secondary
        }
    }
}
