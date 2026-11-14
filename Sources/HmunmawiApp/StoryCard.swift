import HmunmawiCore
import SwiftUI

/// Today's story as one card: the day in a sentence, then the engine's wins, worries and next steps.
struct TodaysStoryCard: View {
    let model: AppModel

    var body: some View {
        let summary = storySummary(model)
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) { IconBadge(symbol: "text.book.closed.fill", tint: Brand.Category.web, size: 22); Text("TODAY'S STORY").font(.callout.weight(.bold)).foregroundStyle(Brand.Category.web) }
            headline(summary).font(.title).fixedSize(horizontal: false, vertical: true)
            if let n = summary.number { Text(n).font(.callout).foregroundStyle(.secondary) }
            StoryBoard(model: model)
        }
    }

    /// The win's key words glow green, the worry's orange-red; the rest is normal text.
    private func headline(_ s: (statement: String, number: String?, win: String?, worry: String?)) -> Text {
        switch (s.win, s.worry) {
        case let (w?, b?): Text("\(Kit.glow(w, tint: Brand.good))\(Text(", but ").foregroundStyle(.primary))\(Kit.glow(b, tint: Brand.caution))")
        case let (w?, nil): Kit.glow(w, tint: Brand.good)
        case let (nil, b?): Kit.glow(b, tint: Brand.caution)
        default: Text(s.statement)
        }
    }
}
