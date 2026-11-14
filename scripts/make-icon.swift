// Draws Hmunmawi's app icon ("beautiful place": Mizo hills at sunrise) at 1024 px.
// Usage: swift scripts/make-icon.swift <out.png>
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let cs = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: cs, components: [r, g, b, a])! }
func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

// macOS icon grid: 824 px rounded square centred in 1024, corner radius ~185.
let inset: CGFloat = 100
let body = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Soft drop shadow under the tile.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: c(0, 0, 0, 0.35))
ctx.addPath(shape); ctx.setFillColor(c(0.1, 0.1, 0.2)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape); ctx.clip()

// Sky: deep indigo at the top, violet, rose, then warm gold at the horizon (y grows upward).
ctx.drawLinearGradient(gradient([
    (0.0, c(1.00, 0.78, 0.45)), (0.30, c(0.98, 0.55, 0.52)), (0.55, c(0.62, 0.42, 0.78)), (1.0, c(0.16, 0.18, 0.45)),
]), start: CGPoint(x: 0, y: body.minY + 260), end: CGPoint(x: 0, y: body.maxY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

// Sun with a warm halo, sitting just above the far ridge.
let sun = CGPoint(x: size * 0.60, y: body.minY + 430)
ctx.drawRadialGradient(gradient([(0, c(1, 0.92, 0.70, 0.95)), (0.35, c(1, 0.80, 0.55, 0.45)), (1, c(1, 0.70, 0.50, 0))]),
                       startCenter: sun, startRadius: 0, endCenter: sun, endRadius: 330, options: [])
ctx.setFillColor(c(1.0, 0.96, 0.84)); ctx.fillEllipse(in: CGRect(x: sun.x - 92, y: sun.y - 92, width: 184, height: 184))

// Three ridges, far to near: each a smooth curve filled with a vertical gradient.
func ridge(_ points: [CGPoint], top: CGColor, bottom: CGColor) {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: body.minX - 20, y: body.minY - 20))
    p.addLine(to: points[0])
    for i in 1..<points.count {
        let a = points[i - 1], b = points[i]
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        p.addQuadCurve(to: mid, control: a)
        if i == points.count - 1 { p.addQuadCurve(to: b, control: b) }
    }
    p.addLine(to: CGPoint(x: body.maxX + 20, y: body.minY - 20))
    p.closeSubpath()
    ctx.saveGState(); ctx.addPath(p); ctx.clip()
    let maxY = points.map(\.y).max()!
    ctx.drawLinearGradient(gradient([(0, bottom), (1, top)]), start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: maxY), options: [])
    ctx.restoreGState()
}
let x0 = body.minX - 20, w = body.width + 40
func pts(_ ys: [CGFloat]) -> [CGPoint] { ys.enumerated().map { CGPoint(x: x0 + w * CGFloat($0.offset) / CGFloat(ys.count - 1), y: body.minY + $0.element) } }

ridge(pts([360, 420, 470, 400, 440, 500, 430]), top: c(0.55, 0.42, 0.70), bottom: c(0.40, 0.30, 0.58))
ridge(pts([250, 330, 290, 360, 300, 250, 310]), top: c(0.28, 0.30, 0.58), bottom: c(0.20, 0.22, 0.46))
ridge(pts([150, 190, 240, 170, 130, 200, 230]), top: c(0.10, 0.36, 0.42), bottom: c(0.05, 0.20, 0.28))

// The app's signature: a living-flow line of glowing dots rising over the hills to the sun
// (things running by themselves, numbers climbing).
let flow = [CGPoint(x: body.minX + 110, y: body.minY + 200), CGPoint(x: body.minX + 280, y: body.minY + 280),
            CGPoint(x: body.minX + 410, y: body.minY + 300), CGPoint(x: sun.x - 40, y: sun.y - 70)]
let line = CGMutablePath()
line.move(to: flow[0])
for i in 1..<flow.count {
    let a = flow[i - 1], b = flow[i], dx = (b.x - a.x) * 0.45
    line.addCurve(to: b, control1: CGPoint(x: a.x + dx, y: a.y + (i == 1 ? 10 : 25)), control2: CGPoint(x: b.x - dx, y: b.y - 15))
}
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 22, color: c(1, 0.95, 0.8, 0.9))
ctx.addPath(line); ctx.setStrokeColor(c(1, 0.97, 0.88, 0.95)); ctx.setLineWidth(16); ctx.setLineCap(.round); ctx.strokePath()
for p in flow {
    ctx.drawRadialGradient(gradient([(0, c(1, 0.97, 0.85, 0.9)), (1, c(1, 0.9, 0.7, 0))]),
                           startCenter: p, startRadius: 0, endCenter: p, endRadius: 70, options: [])
    ctx.setFillColor(c(1, 1, 0.96)); ctx.fillEllipse(in: CGRect(x: p.x - 30, y: p.y - 30, width: 60, height: 60))
}
ctx.restoreGState()

// Glass: a light sheen across the top and a thin bright rim.
ctx.drawLinearGradient(gradient([(0, c(1, 1, 1, 0)), (1, c(1, 1, 1, 0.22))]),
                       start: CGPoint(x: 0, y: body.midY), end: CGPoint(x: 0, y: body.maxY), options: [])
ctx.restoreGState()
ctx.addPath(shape); ctx.setStrokeColor(c(1, 1, 1, 0.35)); ctx.setLineWidth(3); ctx.strokePath()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print(out)
