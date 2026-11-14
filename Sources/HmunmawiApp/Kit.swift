import SwiftUI

/// The few parts every screen is built from, taken from the dashboard's section cards so everything matches:
/// one card, one header, one headline-number style, one outcome line, one icon badge. Buttons are Apple's
/// Liquid Glass styles only (`.glass`, and `.glassProminent` for the single main action). Status colours
/// (green, amber, red) appear only when something is good or wrong; otherwise the section's colour.
enum Kit {
    static let number = Font.system(size: 30, weight: .bold)
    static let outcome = Font.title3
    static let badge: CGFloat = 34
}

/// The card: the dashboard's content card, padded, lifting under the pointer.
struct KitCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background { Color.clear.contentCard(cornerRadius: 22) }
            .hoverLift()
    }
}

/// A card's header, exactly like the dashboard sections: symbol (or the app icon with the symbol as a badge)
/// and the title in the section colour; an optional grey caption on the right.
struct CardHeader: View {
    let symbol: String
    let title: String
    let tint: Color
    var caption: String? = nil
    var app: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            if let app {
                AppIcon(app: app, size: 32, badge: symbol, badgeTint: tint)
            } else {
                IconBadge(symbol: symbol, tint: tint, size: 24)
            }
            Text(title).font(.headline).foregroundStyle(.primary)
            Spacer(minLength: 8)
            if let caption {
                Text(caption).font(.callout.weight(.medium)).foregroundStyle(.secondary)
            }
        }
    }
}

/// A number that rolls to its new value instead of jumping (digits slide, like the Stocks app). The roll runs
/// only when the value really changes, and is skipped under Reduce Motion.
private struct LiveNumber<V: Equatable>: ViewModifier {
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.contentTransition(reduceMotion ? .identity : .numericText())
            .animation(reduceMotion ? nil : .snappy(duration: 0.35), value: value)
    }
}

extension View {
    func liveNumber<V: Equatable>(_ value: V) -> some View { modifier(LiveNumber(value: value)) }
}

/// A headline number with its label underneath, like the dashboard's figures.
struct KitFigure: View {
    let value: String
    let label: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(Kit.number).monospacedDigit().foregroundStyle(Kit.vibrant(tint))
                // Shrinks to fit its column instead of running past the card edge (long values like "5.0★ → none").
                .lineLimit(1).minimumScaleFactor(0.45)
                .liveNumber(value)
            Text(label).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

enum Shaders {
    static let library: ShaderLibrary? = Bundle.main.url(forResource: "Hmunmawi", withExtension: "metallib").map { ShaderLibrary(url: $0) }
}

/// The one icon: no disc behind it; the symbol itself, drawn heavy, is a thick piece of coloured
/// glass (the `iconGel` shader: bevel, key light, rim, specular, soft halo). The light drifts only while the
/// pointer is over it, so at rest it's a still picture and costs nothing.
struct IconBadge: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = Kit.badge
    /// A plain coloured symbol, no glass shader: for dense maps with dozens of icons on one screen (measured: the shader
    /// icons were part of the flow map's scroll cost).
    var flat = false
    @State private var hovering = false
    @State private var start = Date()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if !flat, let library = Shaders.library {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !hovering || reduceMotion)) { timeline in
                    let t = 2.0 + (hovering && !reduceMotion ? timeline.date.timeIntervalSince(start) : 0)
                    glyph.foregroundStyle(.white)
                        .layerEffect(library.iconGel(.float2(CGSize(width: size, height: size)), .color(tint), .float(Float(t)),
                                                     .float2(CGSize.zero), .float(colorScheme == .dark ? 1 : 0)),
                                     maxSampleOffset: CGSize(width: size * 0.2, height: size * 0.2))
                        // Flattened into one bitmap that is only redrawn when the light moves (hover) or the colour changes,
                        // so scrolling past a page of icons moves pictures instead of running a shader on each, every frame.
                        .drawingGroup()
                }
                // (No extra drop shadow: the shader draws its own soft halo, and a blurred shadow behind every one of the many
                // icons on a page was a major drawing cost while scrolling: measured with Instruments, Nov 2026.)
            } else {
                glyph.foregroundStyle(tint)
            }
        }
        .frame(width: size, height: size)
        .onHover { on in if on && ScrollGate.active { return }; hovering = on; if on { start = .now } }
        .accessibilityHidden(true)
    }

    private var glyph: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.64, weight: .black))
            .symbolRenderingMode(.monochrome)
            .frame(width: size, height: size)
    }
}


extension Kit {
    /// Apple's vibrant text: a soft gradient from the colour to a neighbouring hue (as on apple.com).
    /// Bright neighbouring hues, never muddy mixes: green -> mint, orange/red -> pink, blue -> purple.
    static func vibrant(_ tint: Color) -> LinearGradient {
        // Plain numbers stay crisp label colour (no gradient on neutral text).
        if tint == .primary { return LinearGradient(colors: [.primary], startPoint: .leading, endPoint: .trailing) }
        // The far end of each gradient is deeper in light mode and brighter in dark mode, so it reads on both.
        let end: Color = tint == Brand.good ? Brand.adaptive(light: (0.0, 0.52, 0.56), dark: (0.30, 0.86, 0.90))
            : (tint == Brand.caution || tint == Brand.bad) ? Brand.adaptive(light: (0.88, 0.18, 0.45), dark: (1.0, 0.45, 0.64))
            : Brand.adaptive(light: (0.62, 0.35, 1.0), dark: (0.78, 0.60, 1.0))
        return LinearGradient(colors: [tint, end], startPoint: .leading, endPoint: .trailing)
    }
}

extension Kit {
    /// Words that start the "what happened" part of a sentence ("downloads *climbing week after week*").
    private static let movement: Set<String> = ["climbing", "climbed", "rising", "rose", "up", "down", "fell", "falling",
        "dropped", "dropping", "grew", "growing", "doubled", "halved", "below", "above", "record", "jumped", "slipped",
        "earned", "lost", "need", "needs", "ran", "gained", "cancel", "cancels", "stopped", "broke", "new", "settled", "steady", "higher", "lower", "rated"]

    /// Apple keynote style: the sentence in normal text, only its key words glowing in a gradient.
    /// The glow runs from the first movement word (or the first number) to the next comma or the end.
    static func glow(_ sentence: String, tint: Color) -> Text {
        let words = sentence.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let start = words.firstIndex { w in
            let bare = w.lowercased().trimmingCharacters(in: .punctuationCharacters)
            return movement.contains(bare) || bare.first?.isNumber == true || w.hasPrefix("+") || w.hasPrefix("$")
        }
        guard let start else { return Text(sentence).foregroundStyle(.primary) }
        // "Last 7 days: 6 visitors" - the period is context; the news is the figure after the colon.
        if let colon = words[start...].firstIndex(where: { $0.hasSuffix(":") }), colon - start < 3,
           let next = words[(colon + 1)...].firstIndex(where: { $0.first?.isNumber == true }) {
            return glowRange(words, from: next, tint: tint)
        }
        return glowRange(words, from: start, tint: tint)
    }

    private static func glowRange(_ words: [String], from start: Int, tint: Color) -> Text {
        var end = words.count
        // Starting at a number: glow just the figure and its noun ("40 people", "14 of 14"), not the whole line.
        let stops: Set<String> = ["used", "have", "has", "are", "is", "was", "were", "need", "needs", "ran", "from", "in", "on", "to"]
        if words[start].first?.isNumber == true || words[start].hasPrefix("+") || words[start].hasPrefix("$") {
            var i = start + 1
            func isNum(_ w: String) -> Bool { w.first?.isNumber == true }
            let ends = !words[start].hasSuffix(",") && !words[start].hasSuffix(":") && !words[start].hasSuffix(";")
            if ends, i + 1 < words.count, words[i].lowercased() == "of", isNum(words[i + 1]) {
                i += 2                                    // "5 of 74", "14 of 14"
            } else if ends, i < words.count, !stops.contains(words[i].lowercased()), words[i].lowercased() != "of",
                      !words[start].hasSuffix("%"), !isNum(words[i]) {
                i += 1                                    // "40 people", "6 product-page"
            }
            end = i
        }
        if let comma = words[start...].firstIndex(where: { $0.hasSuffix(",") || $0.hasSuffix(";") || $0.hasSuffix(".") }) { end = min(end, comma + 1) }
        let before = words[..<start].joined(separator: " ")
        var key = words[start..<end].joined(separator: " ")
        var after = words[end...].joined(separator: " ")
        if key.hasSuffix(":") { key.removeLast(); after = ":" + (after.isEmpty ? "" : " " + after) }
        if let last = key.last, last == "," || last == ";" || last == "." { key.removeLast(); after = String(last) + (after.isEmpty ? "" : " " + after) }
        // Bad news never glows in a happy colour: a key phrase about a failure or a fall turns orange-red.
        let bad = ["failed", "fell", "below", "dropped", "lost", "cancel", "slipped", "overdue", "worse"]
        let keyTint = bad.contains(where: { (before.suffix(12) + " " + key).lowercased().contains($0) }) && tint != Brand.bad ? Brand.caution : tint
        return Text("\(Text(before.isEmpty ? "" : before + " ").foregroundStyle(.primary))\(Text(key).foregroundStyle(vibrant(keyTint)))\(Text(after.isEmpty ? "" : ((after.hasPrefix(",") || after.hasPrefix(";") || after.hasPrefix(":") || after.hasPrefix(".")) ? after : " " + after)).foregroundStyle(.primary))")
    }
}

/// The one style for a statement line: a small coloured label, the key words in vibrant colour, the rest
/// quiet. "NEXT  X numbers read at 15:50 · in 3 h 36 min".
struct Statement: View {
    let label: String
    let key: String
    var rest: String = ""
    var tint: Color = Brand.Category.web

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label.uppercased()).font(.callout.weight(.bold)).tracking(0.8).foregroundStyle(tint)
            (Text(key).font(Kit.outcome).foregroundStyle(.primary)
             + Text(rest.isEmpty ? "" : "  ·  " + rest).font(.title3).foregroundStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The one look for action buttons: "Sort it for me" (tinted) and "Show me how" (plain). Same height, font and
/// icon spacing everywhere, so the two kinds read as a pair on every screen.
struct PillButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(PillLabel())
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .foregroundStyle(prominent ? Color.white : Color.accentColor)
            .background(Capsule().fill(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.accentColor.opacity(0.12))))
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
            .fixedSize()
    }

    private struct PillLabel: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 6) { configuration.icon.imageScale(.small); configuration.title }
        }
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
    static var pillProminent: PillButtonStyle { PillButtonStyle(prominent: true) }
}
