import HmunmawiCore
import SwiftUI

/// Apps on their way to the App Store: one launch track per app that isn't live yet, or that has a new
/// version in progress. Everything comes from App Store Connect (`release.snapshot`); nothing is typed by hand.
struct ComingSoon: View {
    let model: AppModel
    /// Which releases to show (all by default).
    var only: (Release) -> Bool = { _ in true }

    struct Release: Identifiable {
        let id: String
        let app: String
        let version: String?
        let live: Bool
        let stage: Int          // 0 Building · 1 TestFlight · 2 Submitted · 3 In review · 4 Live
        let status: String
        let problem: Bool
        let facts: [String]
        /// No build or version change for 30+ days (and not with Apple): shown as one quiet line, not checked.
        var parked = false
        var lastWork: Date?
    }

    /// The newest sign of work on a version: a build upload or the version itself being created or changed.
    static func lastWork(_ p: JSONValue) -> Date? {
        ["build_uploaded", "version_created"].compactMap { p[path: $0]?.string.flatMap { try? Date($0, strategy: .iso8601) } }.max()
    }

    static func isParked(_ p: JSONValue) -> Bool {
        let withApple: Set<String> = ["WAITING_FOR_REVIEW", "READY_FOR_REVIEW", "IN_REVIEW", "PENDING_DEVELOPER_RELEASE",
                                      "PENDING_APPLE_RELEASE", "ACCEPTED", "PROCESSING_FOR_DISTRIBUTION", "REJECTED", "METADATA_REJECTED"]
        if withApple.contains(p[path: "state"]?.string ?? "") { return false }
        guard let last = lastWork(p) else { return true }
        return Date.now.timeIntervalSince(last) > 30 * 86_400
    }

    static let stages = ["Building", "TestFlight", "Submitted", "In review", "Live"]

    var body: some View {
        let list = Self.releases(model).filter(only)
        if !list.isEmpty {
            KitCard {
                CardHeader(symbol: "shippingbox.fill", title: "Coming soon", tint: Brand.Category.users)
                ForEach(list) { r in
                    LaunchTrack(release: r)
                    if r.id != list.last?.id { Divider() }
                }
            }
        }
    }

    /// "My App: Photo Editor" → "My App".
    static func shortName(_ full: String) -> String {
        String(full.split(separator: ":", maxSplits: 1).first ?? Substring(full)).trimmingCharacters(in: .whitespaces)
    }

    static func releases(_ model: AppModel) -> [Release] {
        // A script feed and the App Store Connect add-on both send these; Apple names apps by their full store name
        // ("My App: Photo Editor, Filters"), so names are matched on the part before the colon and the newest wins.
        var newest: [String: StoredEvent] = [:]
        for e in model.snapshots("release.snapshot") {
            guard let name = e.app.map(shortName) else { continue }
            if let have = newest[name], have.occurredAt >= e.occurredAt { continue }
            newest[name] = e
        }
        return newest.compactMap { name, e in
            let app = name
            let p = e.payload
            let live = p[path: "live"] == .bool(true)
            let state = p[path: "state"]?.string
            // A live app shows here only while a new version is on its way.
            // Shown while a version is on its way, or for an unreleased app that has builds (e.g. still in TestFlight).
            // A removed or abandoned app with neither has nothing to track.
            // An app that has never had a build uploaded (an abandoned listing) has nothing to track.
            guard state != nil || !live else { return nil }
            if isParked(p) {
                // Parked: nothing new for 30+ days. One quiet line saying so, no checks, until work starts again.
                return Release(id: app, app: app, version: p[path: "version"]?.string, live: live, stage: 0,
                               status: "Parked", problem: false, facts: [], parked: true, lastWork: lastWork(p))
            }
            guard p[path: "build"]?.string != nil || state != nil else { return nil }
            let internalTF = p[path: "testflight_internal"]?.string ?? ""
            let externalTF = p[path: "testflight_external"]?.string ?? ""
            let testing = [internalTF, externalTF].contains { $0.contains("TESTING") || $0.contains("READY") }
            let (stage, status, problem): (Int, String, Bool) = switch state ?? "" {
            case "WAITING_FOR_REVIEW", "READY_FOR_REVIEW": (2, "Waiting for Apple's review", false)
            case "IN_REVIEW": (3, "Apple is reviewing it", false)
            case "PENDING_DEVELOPER_RELEASE", "PENDING_APPLE_RELEASE", "ACCEPTED": (3, "Approved, ready for you to release", false)
            case "PROCESSING_FOR_DISTRIBUTION", "PROCESSING_FOR_APP_STORE": (3, "Approved, Apple is preparing it", false)
            case "REJECTED", "METADATA_REJECTED", "INVALID_BINARY": (3, "Apple sent it back, see Resolution Center", true)
            case "DEVELOPER_REJECTED": (testing ? 1 : 0, "Pulled back from review", false)
            default: testing ? (1, "Testing on TestFlight", false) : (0, "Being built", false)
            }
            var facts: [String] = []
            if let b = p[path: "build"]?.string {
                let when = p[path: "build_uploaded"]?.string.flatMap { try? Date($0, strategy: .iso8601) }
                facts.append("Build \(b)" + (when.map { " · uploaded \($0.formatted(.relative(presentation: .named)))" } ?? ""))
            }
            if let lv = p[path: "live_version"]?.string { facts.append("Live now: \(lv)") }
            return Release(id: app, app: app, version: p[path: "version"]?.string, live: live, stage: stage,
                           status: status, problem: problem, facts: facts)
        }
        .sorted { $0.live == $1.live ? $0.app < $1.app : !$0.live }
    }
}

/// One app's track: icon and name, five steps with the current one glowing, and where it stands.
struct LaunchTrack: View {
    let release: ComingSoon.Release
    @Environment(AppModel.self) private var model: AppModel?
    @Environment(\.sceneActive) private var sceneActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var reached = 4

    var body: some View {
        if release.parked {
            HStack(spacing: 12) {
                AppIcon(app: release.app, size: 28).saturation(0.3)
                Text("\(release.app)\(release.version.map { " " + $0 } ?? "")").foregroundStyle(.secondary)
                Text(release.lastWork.map { "Parked · napping since \($0.formatted(.dateTime.day().month(.abbreviated).year()))" } ?? "Parked · still a twinkle in your eye")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "moon.zzz.fill").foregroundStyle(.secondary).help("Wakes up the moment you upload a build or change the version")
            }
        } else {
            track
        }
    }

    private var track: some View {
        let tint = release.problem ? Brand.caution : Brand.Category.users
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                AppIcon(app: release.app, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(release.app).font(Kit.outcome)
                    Text(release.version.map { (release.live ? "Update " : "Version ") + $0 } ?? "First version")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                Label(release.status, systemImage: release.problem ? "exclamationmark.triangle.fill" : "sparkles")
                    .font(.callout.weight(.semibold)).foregroundStyle(tint)
                    .fixedSize()
            }
            HStack(spacing: 0) {
                ForEach(ComingSoon.stages.indices, id: \.self) { i in
                    let done = i < release.stage && i < reached
                    let now = i == release.stage && i <= reached
                    VStack(spacing: 8) {
                        ZStack {
                            Circle().fill(done || now ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Brand.secondaryText.opacity(0.18)))
                                .frame(width: now ? 22 : 16, height: now ? 22 : 16)
                            if done { Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(.white) }
                        }
                        .frame(width: 30, height: 30)
                        .ripple(tint, trigger: now, breathes: now)
                        Text(ComingSoon.stages[i]).font(.callout.weight(now ? .bold : .medium))
                            .foregroundStyle(now ? tint : done ? Color.primary : Brand.secondaryText).fixedSize()
                    }
                    if i < ComingSoon.stages.count - 1 {
                        ZStack(alignment: .leading) {
                            Capsule().fill(Brand.secondaryText.opacity(0.15)).frame(height: 3)
                            Capsule().fill(tint.gradient).frame(height: 3)
                                .scaleEffect(x: done ? 1 : 0, anchor: .leading)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 24)
                    }
                }
            }
            if !release.facts.isEmpty {
                Text(release.facts.joined(separator: "  ·  ")).font(.callout).foregroundStyle(.secondary)
            }
            if !release.live || release.version != nil { ShieldView(app: release.app) }
            if let model { TestFlightTidy(app: release.app, model: model); if !release.live { NominationsPart(app: release.app, model: model) } }
        }
        .onAppear { arrive() }
        .onChange(of: sceneActive) { _, on in if on { arrive() } }
    }

    /// The track fills step by step up to where the app is.
    private func arrive() {
        guard !reduceMotion else { reached = 4; return }
        reached = -1
        for i in 0...4 {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85).delay(0.2 + Double(i) * 0.18)) { reached = i }
        }
    }
}

/// Apps not on the App Store yet, one slim row each above the app pages: icon, name, a small five-step track,
/// where it stands and the latest build. Click for the full launch track.
struct ComingSoonStrip: View {
    let model: AppModel
    var only: (ComingSoon.Release) -> Bool = { _ in true }
    @Environment(DetailPresenter.self) private var presenter: DetailPresenter?
    @State private var box = FrameBox()

    var body: some View {
        let list = ComingSoon.releases(model).filter(only)
        if !list.isEmpty {
            VStack(spacing: 8) {
                ForEach(list) { r in row(r) }
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background { Color.clear.contentCard(cornerRadius: 18) }
            .hoverLift()
            .contentShape(.rect)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { box.rect = $0 }
            .onTapGesture {
                presenter?.show(view: AnyView(ComingSoon(model: model, only: only).environment(model)), from: box.rect, width: 900)
            }
            .help("Click for the launch track")
        }
    }

    private func row(_ r: ComingSoon.Release) -> some View {
        let tint = r.problem ? Brand.caution : Brand.Category.users
        return HStack(spacing: 14) {
            AppIcon(app: r.app, size: 30)
            VStack(alignment: .leading, spacing: 0) {
                Text(r.app).font(.headline)
                Text(r.version.map { "Version \($0)" } ?? "Coming soon").font(.callout).foregroundStyle(.secondary)
            }
            .fixedSize()
            // The five steps in miniature: done steps filled, the current one larger.
            HStack(spacing: 4) {
                ForEach(ComingSoon.stages.indices, id: \.self) { i in
                    if i > 0 { Capsule().fill(i <= r.stage ? tint : Color.secondary.opacity(0.25)).frame(width: 18, height: 2.5) }
                    Circle().fill(i <= r.stage ? tint : Color.secondary.opacity(0.25))
                        .frame(width: i == r.stage ? 11 : 7, height: i == r.stage ? 11 : 7)
                        .shadow(color: i == r.stage ? tint.opacity(0.6) : .clear, radius: 4)
                        .help(ComingSoon.stages[i])
                }
            }
            .padding(.horizontal, 6)
            Text(r.status).font(.callout.weight(.semibold)).foregroundStyle(tint).fixedSize()
            Spacer(minLength: 8)
            if let fact = r.facts.first {
                Text(fact).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Image(systemName: "chevron.right").font(.callout.weight(.semibold)).foregroundStyle(.tertiary)
        }
    }
}
