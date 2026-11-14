import HmunmawiCore
import SwiftUI

/// Apps → one app: its versions, newest first, with what the numbers did in the week around each go-live
/// (see ReleaseTimeline for why a go-live time is only known for versions Hmunmawi saw change).
struct ReleaseTimelinePart: View {
    let app: String
    let model: AppModel
    @State private var entries: [ReleaseEntry] = []

    var body: some View {
        let versionsEvent = model.snapshots("versions.snapshot").first { ComingSoon.shortName($0.app ?? "") == ComingSoon.shortName(app) }
        VStack(alignment: .leading, spacing: 8) {
            Label("Release timeline", systemImage: "clock.arrow.circlepath").font(.headline)
            if entries.isEmpty {
                Text(versionsEvent == nil ? "Your versions appear after the next App Store Connect check." : "No versions to show yet.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(entries.prefix(6), id: \.version) { e in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("Version \(e.version)").font(.callout.weight(.semibold))
                        if let s = e.state { Text(Self.readable(s)).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if let live = e.liveSeenAt { Text("Went live \(live.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary) }
                        else if let c = e.created { Text("Started \(c.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary) }
                    }
                    if let line = e.effectLine(money: { Money.shared.format($0, from: "USD", decimals: 2) }) { Text(line).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    else if e.liveSeenAt != nil { Text("Measuring: needs a few days of numbers on each side.").font(.caption).foregroundStyle(.secondary) }
                }
            }
            if !entries.isEmpty {
                Text("Go-live days come from Apple's public App Store page (for the version on sale now) or from when Hmunmawi saw the live version change. Other versions show when they were started.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .task(id: versionsEvent?.id) { await load(versionsEvent) }
    }

    private func load(_ versions: StoredEvent?) async {
        guard let store = model.liveStore else { return }
        let since = Millis(Date.now.addingTimeInterval(-180 * 86_400).timeIntervalSince1970 * 1000)
        let history = ((try? await store.events(kind: "release.snapshot", since: since)) ?? []).filter { ComingSoon.shortName($0.app ?? "") == ComingSoon.shortName(app) }
        let daily = ((try? await store.events(kind: "revenue.daily", since: since)) ?? []).filter { ComingSoon.shortName($0.app ?? "") == ComingSoon.shortName(app) }
        let live = ReleaseDates.shared.live[ComingSoon.shortName(app)].map { (version: $0.version, day: $0.day) }
        entries = ReleaseTimeline.build(versions: versions, history: history, daily: daily, publicLive: live)
    }

    private static func readable(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "_", with: " ").lowercased()
        return t.prefix(1).uppercased() + t.dropFirst()
    }
}
