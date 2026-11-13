// Generates the FIRSTofFIFTH app icon (1024 px PNG).
//   swift VintageSequencer/Tools/make_app_icon.swift out.png
// Motif: the sequencer itself. Three tracks of step pads in the track colours
// share one width with 4, 5 and 3 steps (polyrhythm); the first step of every
// track is lit, the downbeat where all cycles meet.
import AppKit
import CoreGraphics

let N: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(N), height: Int(N), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func col(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: cs, components: [r, g, b, a])! }
func grad(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: stops.map { $0.1 } as CFArray, locations: stops.map { $0.0 })!
}
func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil) }

// ── Gehäuse: gebürstetes dunkles Metall ────────────────────────────────
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = rounded(body, 186)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: col(0, 0, 0, 0.45))
ctx.addPath(bodyPath); ctx.setFillColor(col(0.1, 0.1, 0.11)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(bodyPath); ctx.clip()
ctx.drawLinearGradient(grad([(0, col(0.25, 0.245, 0.24)), (0.5, col(0.15, 0.15, 0.16)), (1, col(0.08, 0.08, 0.09))]),
                       start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
var seed: UInt64 = 42
func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat((seed >> 33) % 1000) / 1000 }
var y = body.minY
while y < body.maxY {
    ctx.setFillColor(col(1, 1, 1, 0.012 + rnd() * 0.03))
    ctx.fill(CGRect(x: body.minX, y: y, width: body.width, height: 1)); y += 1 + rnd() * 3
}
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(rounded(body.insetBy(dx: 3, dy: 3), 183)); ctx.setLineWidth(6)
ctx.replacePathWithStrokedPath(); ctx.clip()
ctx.drawLinearGradient(grad([(0, col(1, 1, 1, 0.32)), (0.45, col(1, 1, 1, 0.03)), (1, col(0, 0, 0, 0.5))]),
                       start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
ctx.restoreGState()

// ── Vertieftes Feld für die Spuren ─────────────────────────────────────
let well = CGRect(x: 168, y: 196, width: 688, height: 632)
ctx.saveGState()
ctx.addPath(rounded(well, 56)); ctx.clip()
ctx.setFillColor(col(0.065, 0.065, 0.072)); ctx.fill(well)
// Innenschatten oben, Lichtkante unten
ctx.drawLinearGradient(grad([(0, col(0, 0, 0, 0.75)), (0.12, col(0, 0, 0, 0))]),
                       start: CGPoint(x: 0, y: well.maxY), end: CGPoint(x: 0, y: well.minY), options: [])
ctx.restoreGState()
ctx.addPath(rounded(well.insetBy(dx: -2, dy: -2), 58)); ctx.setLineWidth(3)
ctx.setStrokeColor(col(1, 1, 1, 0.10)); ctx.strokePath()

// ── Step-Taste wie im Sequencer: LED oben, Farbbalken unten ────────────
struct Tint { let r, g, b: CGFloat }
func pad(_ rect: CGRect, _ t: Tint, lit: Bool) {
    let path = rounded(rect, 18)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -5), blur: 10, color: col(0, 0, 0, 0.75))
    if lit { ctx.setShadow(offset: .zero, blur: 46, color: col(t.r, t.g, t.b, 0.75)) }
    ctx.addPath(path); ctx.setFillColor(col(0.12, 0.12, 0.13)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    if lit {
        ctx.drawLinearGradient(grad([(0, col(t.r * 0.78, t.g * 0.78, t.b * 0.78)), (1, col(t.r * 0.42, t.g * 0.42, t.b * 0.42))]),
                               start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
    } else {
        ctx.drawLinearGradient(grad([(0, col(0.24, 0.24, 0.25)), (1, col(0.15, 0.15, 0.16))]),
                               start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
    }
    // Glanz oben
    ctx.drawLinearGradient(grad([(0, col(1, 1, 1, lit ? 0.30 : 0.10)), (0.45, col(1, 1, 1, 0))]),
                           start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
    // Farbbalken unten
    let bar = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.17)
    ctx.setFillColor(lit ? col(t.r, t.g, t.b) : col(t.r * 0.32, t.g * 0.32, t.b * 0.32))
    ctx.fill(bar)
    ctx.restoreGState()
    ctx.addPath(rounded(rect.insetBy(dx: 1.5, dy: 1.5), 17)); ctx.setLineWidth(3)
    ctx.setStrokeColor(col(0, 0, 0, 0.6)); ctx.strokePath()

    // LED
    let lr: CGFloat = 13
    let lc = CGPoint(x: rect.midX, y: rect.maxY - 30)
    let led = CGRect(x: lc.x - lr, y: lc.y - lr, width: 2 * lr, height: 2 * lr)
    ctx.setFillColor(col(0.03, 0.03, 0.035)); ctx.fillEllipse(in: led.insetBy(dx: -4, dy: -4))
    if lit {
        ctx.saveGState(); ctx.setShadow(offset: .zero, blur: 22, color: col(t.r, t.g, t.b, 1))
        ctx.setFillColor(col(min(1, t.r + 0.35), min(1, t.g + 0.35), min(1, t.b + 0.35))); ctx.fillEllipse(in: led)
        ctx.restoreGState()
    } else {
        ctx.setFillColor(col(t.r * 0.35, t.g * 0.35, t.b * 0.35)); ctx.fillEllipse(in: led)
    }
}

// ── Drei Spuren: 4 gegen 5 gegen 3 auf derselben Breite ────────────────
let tracks: [(Tint, Int, Set<Int>)] = [
    (Tint(r: 1.00, g: 0.55, b: 0.00), 4, [0, 2]),     // Bernstein
    (Tint(r: 0.20, g: 0.70, b: 1.00), 5, [0, 3]),     // Blau
    (Tint(r: 0.90, g: 0.25, b: 0.65), 3, [0]),        // Magenta
]
let inner = well.insetBy(dx: 40, dy: 44)
let rowGap: CGFloat = 34, padGap: CGFloat = 18
let rowH = (inner.height - rowGap * CGFloat(tracks.count - 1)) / CGFloat(tracks.count)
for (i, (tint, steps, lit)) in tracks.enumerated() {
    let rowY = inner.maxY - CGFloat(i + 1) * rowH - CGFloat(i) * rowGap
    let w = (inner.width - padGap * CGFloat(steps - 1)) / CGFloat(steps)
    for s in 0..<steps {
        let r = CGRect(x: inner.minX + CGFloat(s) * (w + padGap), y: rowY, width: w, height: rowH)
        pad(r, tint, lit: lit.contains(s))
    }
}

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
