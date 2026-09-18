// Renders the app icon: the extracted controller art (data/controller-front.svg), tinted white with heavier
// line weights, fitted on a squircle with wireless arcs. usage: icon <controller-front.svg> <out.png> [size]
import AppKit
let a = CommandLine.arguments
let N = CGFloat(Double(a.count > 3 ? a[3] : "1024")!)
// Thicken every stroke ×3 so the drawing holds up at Dock sizes; fills (letters, wordmark) stay as they are.
var svg = try! String(contentsOfFile: a[1], encoding: .utf8)
let re = try! NSRegularExpression(pattern: #"stroke-width="([\d.]+)""#)
let ms = re.matches(in: svg, range: NSRange(svg.startIndex..., in: svg))
for m in ms.reversed() { let r = Range(m.range(at: 1), in: svg)!; let v = Double(svg[r])! * 3; svg.replaceSubrange(r, with: String(format: "%.2f", v)) }
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("icon-art.svg"); try! svg.write(to: tmp, atomically: true, encoding: .utf8)
let art = NSImage(contentsOf: tmp)!
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(N), pixelsHigh: Int(N), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
func L(_ v: CGFloat) -> CGFloat { v * N / 1024 }
let inset = L(100), side = N - 2 * inset
let bg = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: side, height: side), xRadius: L(185), yRadius: L(185))
let grad = NSGradient(colors: [NSColor(red: 0.16, green: 0.20, blue: 0.36, alpha: 1), NSColor(red: 0.06, green: 0.08, blue: 0.18, alpha: 1)])!
ctx.saveGState(); bg.addClip(); grad.draw(in: bg.bounds, angle: -90); ctx.restoreGState()
// art: 72% wide, centred, sitting low so the arcs have the top-right corner; tinted white via a transparency layer
let artW = N * 0.62, artH = artW * art.size.height / art.size.width
let artRect = NSRect(x: (N - artW) / 2, y: N * 0.19, width: artW, height: artH)
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
art.draw(in: artRect)
ctx.setBlendMode(.sourceIn); NSColor.white.setFill(); artRect.fill()
ctx.endTransparencyLayer()
// arcs
NSColor(red: 0.40, green: 0.78, blue: 1.0, alpha: 1).setStroke()
for r in [52, 100, 148] { let arc = NSBezierPath(); arc.lineWidth = L(26); arc.lineCapStyle = .round
  arc.appendArc(withCenter: CGPoint(x: L(640), y: N - L(330)), radius: L(CGFloat(r)), startAngle: 25, endAngle: 75); arc.stroke() }
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
