import SwiftUI

/// About Hmunmawi as a short film: the name, its meaning, Mizoram, why it exists, what it does.
/// The words are the author's own. Layered blue hills drift at different depths
/// behind each scene (GPU transforms only); words rise in as a scene arrives. Swipe, arrow keys or dots.
struct AboutStory: View {
    struct Scene: Identifiable {
        let id: Int
        let kicker: String
        let title: String
        let body: String
    }

    static let scenes: [Scene] = [
        Scene(id: 0, kicker: "HMUNMAWI", title: "hmoon-MAH-wee",
              body: "Mizo for \u{201C}beautiful place\u{201D}."),
        Scene(id: 1, kicker: "HEY", title: "Just a tinkerer",
              body: "I\u{2019}m an engineer who likes to tinker. I build iOS apps, and when I\u{2019}m not at the keyboard I\u{2019}m probably playing soccer or doing CrossFit."),
        Scene(id: 2, kicker: "WHY", title: "Too many tabs",
              body: "Running a few small apps meant checking App Store Connect, analytics, search, crash reports, social and email every day. The tools that tie it all together cost more than an indie budget wants to spend. So I made my own."),
        Scene(id: 3, kicker: "THE NAME", title: "Hmun \u{00B7} mawi",
              body: "\u{201C}Hmun\u{201D} means place and \u{201C}mawi\u{201D} means beautiful. One beautiful place for everything about your apps."),
        Scene(id: 4, kicker: "MIZORAM", title: "Blue hills, bamboo forests",
              body: "Mizo is the language of Mizoram, a small, green, hilly state in the far north-east of India, tucked between Myanmar and Bangladesh. Its name means \u{201C}land of the hill people\u{201D}. Mornings start early there, with mist sitting in the valleys and rolling blue hills fading into the distance, bamboo forests on every slope and orchids in the woods. People are warm and close-knit, look out for each other (they call it tlawmngaihna), and the state has one of the highest literacy rates in India. Its capital, Aizawl, sits along a ridge with houses stacked down the hillsides, looking out over the hills. Life moves at a calm, easy pace. That calm is the idea here."),
        Scene(id: 5, kicker: "WHAT IT DOES", title: "Win, Worry, Next",
              body: "It keeps an eye on your apps, works out what matters and tells you each day what went well, what to watch and what to do next. It can run jobs and let AI help, but only when you say so."),
        Scene(id: 6, kicker: "FOR YOU", title: "Free, take it",
              body: "It\u{2019}s free, open source and runs on your own Mac. Billion-dollar ideas, ramen budget? It\u{2019}s for you. Enjoy."),
    ]

    @State private var current: Int? = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Hills(depth: Double(current ?? 0))
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(Self.scenes) { s in
                        SceneText(scene: s, active: current == s.id)
                            .containerRelativeFrame([.horizontal, .vertical])
                            .scrollTransition(.interactive, axis: .horizontal) { v, phase in
                                v.opacity(phase.isIdentity ? 1 : 0)
                                    .offset(x: reduceMotion ? 0 : phase.value * 120)
                                    .blur(radius: reduceMotion ? 0 : abs(phase.value) * 6)
                            }
                            .id(s.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $current)
            .scrollIndicators(.hidden)
            VStack {
                Spacer()
                HStack(spacing: 10) {
                    // Real buttons (not tap gestures) so VoiceOver and keyboard users can jump to any scene.
                    ForEach(Self.scenes) { s in
                        Button { withAnimation(.smooth(duration: 0.6)) { current = s.id } } label: {
                            Capsule().fill(current == s.id ? Color.white : Color.white.opacity(0.45))
                                .frame(width: current == s.id ? 24 : 8, height: 8)
                                .contentShape(Rectangle().inset(by: -6))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Scene \(s.id + 1) of \(Self.scenes.count): \(s.title)")
                        .accessibilityAddTraits(current == s.id ? .isSelected : [])
                        .help(s.title)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: step(1)
                    case .decrement: step(-1)
                    @unknown default: break
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .glassEffect(.regular, in: Capsule())
                .padding(.bottom, 22)
                .animation(.smooth, value: current)
            }
        }
        .frame(minWidth: 820, minHeight: 540)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
    }

    private func step(_ by: Int) {
        withAnimation(.smooth(duration: 0.6)) { current = max(0, min(Self.scenes.count - 1, (current ?? 0) + by)) }
    }
}

private struct SceneText: View {
    let scene: AboutStory.Scene
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(scene.kicker).font(.callout.weight(.bold)).tracking(3).foregroundStyle(.white.opacity(0.85))
                .modifier(Rise(active: active, delay: 0.05))
            Text(scene.id == 0 ? "Hmunmawi" : scene.title)
                .font(.system(size: scene.id == 0 ? 72 : 46, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
                .modifier(Rise(active: active, delay: 0.15))
            if scene.id == 0 {
                Text(scene.title).font(.title2.weight(.medium)).foregroundStyle(.white.opacity(0.9))
                    .modifier(Rise(active: active, delay: 0.25))
            }
            Text(scene.body)
                .font(.title3).foregroundStyle(.white.opacity(0.92)).lineSpacing(5)
                .frame(maxWidth: 640, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .modifier(Rise(active: active, delay: 0.35))
        }
        .padding(.horizontal, 70)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

private struct Rise: ViewModifier {
    let active: Bool
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(active || reduceMotion ? 1 : 0)
            .offset(y: active || reduceMotion ? 0 : 24)
            .blur(radius: active || reduceMotion ? 0 : 4)
            .animation(.spring(response: 0.9, dampingFraction: 0.85).delay(active ? delay : 0), value: active)
    }
}

/// Dawn over layered blue hills: far ridges move least, near ones most (parallax as scenes change),
/// and each ridge drifts very slowly on its own. Mist sits between the ridges.
struct Hills: View {
    let depth: Double
    @State private var drift = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .bottom) {
                LinearGradient(colors: [Color(red: 0.98, green: 0.78, blue: 0.62), Color(red: 0.55, green: 0.66, blue: 0.86),
                                        Color(red: 0.20, green: 0.32, blue: 0.55)], startPoint: .top, endPoint: .bottom)
                Circle().fill(Color(red: 1, green: 0.93, blue: 0.80).opacity(0.85)).frame(width: 120)
                    .blur(radius: 6)
                    .position(x: g.size.width * 0.72, y: g.size.height * 0.28 - depth * 6)
                // Each ridge is wide enough for the whole parallax trip (last scene, nearest ridge: about
                // 6 × 98 pt) plus the drift, starting just past the left edge, so no ridge ever runs out
                // and leaves a hard vertical edge on the right.
                let travel = Double(AboutStory.scenes.count - 1) * (10 + 4 * 22) + 60
                ForEach(0..<5, id: \.self) { i in
                    let layer = Double(i)
                    // Far ridges (lighter, drawn first) stand tallest; each nearer, darker one is lower, so all
                    // five layers show as hills fading into the distance.
                    Ridge(seed: layer, height: 0.62 - layer * 0.08)
                        .fill(Color(red: 0.16 + 0.05 * (4 - layer), green: 0.26 + 0.06 * (4 - layer), blue: 0.48 + 0.05 * (4 - layer)))
                        .frame(width: g.size.width + travel + 60)
                        .offset(x: (travel + 60) / 2 - 30
                                - depth * (10 + layer * 22) + (drift && !reduceMotion ? (layer.truncatingRemainder(dividingBy: 2) == 0 ? 18 : -18) : 0))
                        .overlay(alignment: .top) {
                            LinearGradient(colors: [.white.opacity(0.18), .clear], startPoint: .top, endPoint: .bottom).frame(height: 60)
                        }
                        .animation(.smooth(duration: 1.0), value: depth)
                }
            }
            .frame(width: g.size.width, height: g.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 14).repeatForever(autoreverses: true)) { drift = true }
        }
    }
}

/// One soft ridge line across the bottom of the frame.
private struct Ridge: Shape {
    let seed: Double
    let height: Double
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let base = rect.maxY - rect.height * height
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: base))
        let steps = 60
        for i in 0...steps {
            let x = rect.minX + rect.width * CGFloat(i) / CGFloat(steps)
            let t = Double(i) / Double(steps) * .pi * 2
            let y = base - CGFloat(sin(t * (1.3 + seed * 0.3) + seed * 1.7) * 28 + sin(t * (3.1 + seed * 0.5) + seed) * 12) * (1 + CGFloat(seed) * 0.15)
            p.addLine(to: CGPoint(x: x, y: y))
        }
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
