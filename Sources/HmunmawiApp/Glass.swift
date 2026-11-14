import AppKit
import SwiftUI

/// Monochrome chrome that follows the system light/dark appearance. Colour only carries meaning:
/// green up or healthy, orange worth watching, red down or bad.
enum Brand {
    /// Meaning colours tuned for contrast on frosted glass: deeper in light mode, brighter in dark mode.
    static let good = adaptive(light: (0.0, 0.45, 0.17), dark: (0.38, 0.86, 0.48))
    static let caution = adaptive(light: (0.62, 0.27, 0.0), dark: (1.0, 0.72, 0.30))
    static let bad = adaptive(light: (0.75, 0.10, 0.09), dark: (1.0, 0.45, 0.42))

    static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }

    static let accent = Color.primary
    /// Secondary text that stays readable on the light cards (about 7:1 in light mode); replaces the faint system grey.
    static let secondaryText = adaptive(light: (0.33, 0.33, 0.36), dark: (0.80, 0.80, 0.83))

    /// Category colours, Apple Health style: five clearly different hues, one per kind of data.
    /// Like Health, the colour marks a card's header (icon + name) and its charts; the numbers stay black.
    /// Green, orange and red are never categories: they mean up/ok, watch, bad.
    enum Category {
        private static func adaptive(_ light: (Double, Double, Double), _ dark: (Double, Double, Double)) -> Color {
            Brand.adaptive(light: light, dark: dark)
        }
        static let web = adaptive((0.0, 0.45, 0.98), (0.30, 0.64, 1.0))       // search, website, reach
        static let money = adaptive((0.0, 0.56, 0.62), (0.30, 0.86, 0.90))   // revenue, renewals, programs
        static let users = adaptive((0.62, 0.20, 0.86), (0.82, 0.56, 1.0))   // people, downloads, apps
        static let video = adaptive((0.92, 0.12, 0.42), (1.0, 0.45, 0.64))   // YouTube
        static let social = Brand.secondaryText               // X, Discord, messages

        /// The colour for a section id, or a category named by the sender ("web", "money", "users", "video", "social").
        static func named(_ name: String?) -> Color? {
            switch name?.lowercased() {
            case "web", "search", "this-week", "site", "site-pulse", "blue": web
            case "money", "retention", "revenue", "subscribers", "programs", "teal": money
            case "users", "apps", "purple": users
            case "video", "youtube", "pink": video
            case "social", "x", "messages", "graphite": social
            default: nil
            }
        }
    }
    /// Content cards: near-white in light mode, near-black in dark mode.
    static let surface = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.13, alpha: 0.86) : NSColor(white: 1.0, alpha: 0.86)
    })
    /// The one data colour: every bar and graph line. Green/orange/red stay for meaning.
    static let data = Category.web
    /// The neutral frost behind the glass.
    /// Muted sage: soft enough to read as frost, coloured enough for the glass to have depth.
    static let frost = Color(red: 0.60, green: 0.68, blue: 0.64)
}

/// Remembers a card's on-screen frame for the open animation WITHOUT being observed: a plain @State CGRect fed by
/// `frame(in: .global)` changed on every scroll tick and re-evaluated every card each frame.
final class FrameBox { var rect: CGRect = .zero }

/// True while the mouse wheel or trackpad is scrolling. Content sliding under a resting pointer fires "pointer entered"
/// for every card, icon and node it passes; each one would change state and redraw mid-scroll. Hover handlers ignore
/// "entered" while this is on (leaving still works), so scrolling only moves pictures.
@MainActor
enum ScrollGate {
    private static var until: CFAbsoluteTime = 0
    private static var monitor: Any?
    static var active: Bool { CFAbsoluteTimeGetCurrent() < until }
    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
            // Momentum included: the glide after a flick is still scrolling.
            until = CFAbsoluteTimeGetCurrent() + 0.18
            return e
        }
    }
}

/// Cards rise very slightly under the pointer, like macOS widgets.
private struct HoverLift: ViewModifier {
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering && !reduceMotion ? 1.012 : 1)
            .animation(.smooth(duration: 0.25), value: hovering)
            .onHover { if $0 && ScrollGate.active { return }; hovering = $0 }
    }
}

extension View {
    func hoverLift() -> some View { modifier(HoverLift()) }

    /// Content surface (Apple puts Liquid Glass on controls and navigation, not on content).
    func contentCard(tint: Color? = nil, cornerRadius: CGFloat = 20) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // A near-solid surface: black text on near-white (white on near-black) for full contrast,
        // with just enough translucency that the wallpaper's colour still warms the edges.
        return background(Brand.surface, in: shape)
            .overlay(shape.strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5))
    }

    /// Small label chip on content: a quiet fill, not glass.
    func glassCapsule() -> some View {
        background(.quaternary.opacity(0.55), in: Capsule())
    }

}

/// A ring that ripples out from a status icon when it appears or its state changes; live statuses ripple again
/// every 6 seconds while the window is in front. Played by Core Animation in the render server, so the app does
/// no per-frame work.
struct Ripple: ViewModifier {
    let tint: Color
    var trigger: AnyHashable = 0
    var breathes = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState

    func body(content: Content) -> some View {
        content.background {
            if !reduceMotion {
                RippleRing(color: NSColor(tint), repeating: breathes && activeState != .inactive, trigger: trigger)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct RippleRing: NSViewRepresentable {
    let color: NSColor
    let repeating: Bool
    let trigger: AnyHashable

    final class RingView: NSView {
        let ring = CAShapeLayer()
        var signature: (AnyHashable, Bool)?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            // A soft halo behind the dot (no expanding rings): it gently brightens and fades.
            ring.lineWidth = 0
            ring.opacity = 0
            ring.shadowOpacity = 1
            ring.shadowRadius = 5
            ring.shadowOffset = .zero
            layer?.addSublayer(ring)
            layer?.masksToBounds = false
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            ring.frame = bounds
            let halo = bounds.insetBy(dx: -bounds.width * 0.45, dy: -bounds.height * 0.45)
            ring.path = CGPath(ellipseIn: halo, transform: nil)
        }

        /// A slow glow: brightens and fades back (once for a new moment, gently forever for a live point).
        /// Only opacity animates, which Core Animation composites on the GPU.
        func play(repeating: Bool) {
            let glow = CABasicAnimation(keyPath: "opacity")
            glow.fromValue = 0.05
            glow.toValue = repeating ? 0.32 : 0.45
            glow.duration = repeating ? 2.4 : 0.6
            glow.autoreverses = true
            glow.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            glow.repeatCount = repeating ? .infinity : 1
            ring.removeAllAnimations()
            ring.add(glow, forKey: "glow")
        }
    }

    func makeNSView(context: Context) -> RingView { RingView() }

    func updateNSView(_ view: RingView, context: Context) {
        view.ring.fillColor = color.withAlphaComponent(0.55).cgColor
        view.ring.shadowColor = color.cgColor
        let signature = (trigger, repeating)
        guard view.signature.map({ $0.0 != signature.0 || $0.1 != signature.1 }) ?? true else { return }
        view.signature = signature
        view.play(repeating: repeating)
    }
}

extension View {
    func ripple(_ tint: Color, trigger: AnyHashable = 0, breathes: Bool = false) -> some View {
        modifier(Ripple(tint: tint, trigger: trigger, breathes: breathes))
    }
}

/// Rows arrive once: a short staggered fade-and-rise, and their icon gives a single bounce.
/// Nothing moves after that, and with Reduce Motion the rows simply appear.
private struct Arrival: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 6)
            .task {
                guard !shown else { return }
                try? await Task.sleep(for: .milliseconds(60 * min(index, 8)))
                withAnimation(.smooth(duration: 0.35)) { shown = true }
            }
    }
}

/// The icon half of an arrival: one bounce after the row has landed.
private struct ArrivalBounce: ViewModifier {
    let index: Int
    @State private var bounced = false

    func body(content: Content) -> some View {
        content
            .symbolEffect(.bounce.up, options: .nonRepeating, value: bounced)
            .task {
                guard !bounced else { return }
                try? await Task.sleep(for: .milliseconds(60 * min(index, 8) + 250))
                bounced = true
            }
    }
}

extension View {
    func arrival(_ index: Int) -> some View { modifier(Arrival(index: index)) }
    func arrivalBounce(_ index: Int) -> some View { modifier(ArrivalBounce(index: index)) }
}

/// Depth while scrolling (like the Apple TV app): a card rising out of the bottom edge lifts in from slightly
/// smaller and dimmer; one leaving at the top sinks back. Pure GPU transforms, computed only while scrolling.
private struct DepthOnScroll: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion { content } else {
            content.visualEffect { v, proxy in
                let f = proxy.frame(in: .scrollView(axis: .vertical))
                let h = proxy.bounds(of: .scrollView(axis: .vertical))?.height ?? 1000
                // 0 when fully inside; up to 1 as the card passes the top or bottom edge.
                let below = max(0, min(1, (f.minY + min(f.height, 160) - h) / 160))
                let above = max(0, min(1, -f.minY / max(f.height, 1)))
                let t = max(below, above * 0.8)
                return v.scaleEffect(1 - 0.05 * t, anchor: above > below ? .bottom : .top)
                    .opacity(1 - 0.45 * t)
                    .offset(y: below * 24)
            }
        }
    }
}

extension View {
    func depthOnScroll() -> some View { modifier(DepthOnScroll()) }
}
