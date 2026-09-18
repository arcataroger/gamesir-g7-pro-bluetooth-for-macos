// Renders the app icon: a simplified controller with wireless arcs on a macOS squircle. usage: icon <out.png> [size]
import AppKit
let a = CommandLine.arguments
let N = CGFloat(Double(a.count > 2 ? a[2] : "1024")!)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(N), pixelsHigh: Int(N), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * N / 1024, y: (1024 - y) * N / 1024) }   // design in 1024 space, y down
func L(_ v: CGFloat) -> CGFloat { v * N / 1024 }

// Squircle background (macOS icon grid: 824 px square inset in 1024, corner ~ 185)
let inset = L(100), side = N - 2 * inset
let bg = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: side, height: side), xRadius: L(185), yRadius: L(185))
let grad = NSGradient(colors: [NSColor(red: 0.16, green: 0.20, blue: 0.36, alpha: 1), NSColor(red: 0.06, green: 0.08, blue: 0.18, alpha: 1)])!
ctx.saveGState(); bg.addClip(); grad.draw(in: bg.bounds, angle: -90); ctx.restoreGState()

// Controller body: top edge, right grip, bottom notch, left grip (a simplified G7 outline)
let body = NSBezierPath()
body.move(to: P(300, 380))
body.curve(to: P(724, 380), controlPoint1: P(420, 350), controlPoint2: P(604, 350))
body.curve(to: P(860, 640), controlPoint1: P(800, 400), controlPoint2: P(870, 540))
body.curve(to: P(760, 730), controlPoint1: P(850, 730), controlPoint2: P(800, 760))
body.curve(to: P(640, 640), controlPoint1: P(720, 700), controlPoint2: P(690, 640))
body.line(to: P(384, 640))
body.curve(to: P(264, 730), controlPoint1: P(334, 640), controlPoint2: P(304, 700))
body.curve(to: P(164, 640), controlPoint1: P(224, 760), controlPoint2: P(174, 730))
body.curve(to: P(300, 380), controlPoint1: P(154, 540), controlPoint2: P(224, 400))
body.close()
NSColor.white.withAlphaComponent(0.96).setFill(); body.fill()

// Face details in the background colour: left stick, d-pad dot cluster, four face buttons
let ink = NSColor(red: 0.10, green: 0.13, blue: 0.28, alpha: 1); ink.setFill()
NSBezierPath(ovalIn: NSRect(x: P(300, 500).x - L(56), y: P(300, 500).y - L(56), width: L(112), height: L(112))).fill()
for (dx, dy) in [(0, -34), (34, 0), (0, 34), (-34, 0)] { let c = P(440 + CGFloat(dx), 560 + CGFloat(dy)); NSBezierPath(ovalIn: NSRect(x: c.x - L(14), y: c.y - L(14), width: L(28), height: L(28))).fill() }
for (dx, dy) in [(0, -50), (50, 0), (0, 50), (-50, 0)] { let c = P(680 + CGFloat(dx), 500 + CGFloat(dy)); NSBezierPath(ovalIn: NSRect(x: c.x - L(24), y: c.y - L(24), width: L(48), height: L(48))).fill() }

// Wireless arcs rising from the top right
NSColor(red: 0.40, green: 0.78, blue: 1.0, alpha: 1).setStroke()
for (i, r) in [70, 130, 190].enumerated() {
  let arc = NSBezierPath(); arc.lineWidth = L(34); arc.lineCapStyle = .round
  arc.appendArc(withCenter: P(724, 330), radius: L(CGFloat(r)), startAngle: 20, endAngle: 70)
  arc.stroke(); _ = i
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[1]))
print("wrote", a[1], Int(N))
