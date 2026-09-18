// Extract vector paths from a PDF page region into SVG, skipping dashed strokes and text.
// usage: pdfpaths <pdf> <page> <x> <y> <w> <h> <out.svg>    (crop in PDF points, origin bottom-left)
import Foundation
import CoreGraphics

struct GState { var ctm = CGAffineTransform.identity; var lineWidth: CGFloat = 1; var dashed = false }
final class Extractor {
  var stack: [GState] = []; var g = GState()
  var path = "" ; var pathBox = CGRect.null; var start = CGPoint.zero; var cur = CGPoint.zero
  var out: [String] = []; let crop: CGRect
  var counts: [String: Int] = [:]
  var union = CGRect.null
  var circles: [String] = []
  init(crop: CGRect) { self.crop = crop }
  func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y).applying(g.ctm) }
  func f(_ v: CGFloat) -> String { String(format: "%.2f", v) }
  func svg(_ p: CGPoint) -> String { "\(f(p.x - crop.minX)) \(f(crop.maxY - p.y))" }   // flip y into SVG space
  func move(_ p: CGPoint) { path += "M\(svg(p)) "; start = p; cur = p; pathBox = pathBox.union(CGRect(origin: p, size: .zero)) }
  func line(_ p: CGPoint) { path += "L\(svg(p)) "; cur = p; pathBox = pathBox.union(CGRect(origin: p, size: .zero)) }
  func curve(_ a: CGPoint, _ b: CGPoint, _ p: CGPoint) { path += "C\(svg(a)) \(svg(b)) \(svg(p)) "; cur = p; for q in [a, b, p] { pathBox = pathBox.union(CGRect(origin: q, size: .zero)) } }
  func close() { path += "Z "; cur = start }
  func paint(stroke: Bool, fill: Bool) {
    defer { path = ""; pathBox = .null }
    guard !path.isEmpty, crop.intersects(pathBox) else { return }
    if stroke && g.dashed && !fill { counts["dashed-skipped", default: 0] += 1; return }
    if fill && !stroke && max(pathBox.width, pathBox.height) < 1.2 { counts["dot-skipped", default: 0] += 1; return }
    // leftover callout stubs: a single short straight segment
    if stroke && !fill && !path.contains("C") && path.components(separatedBy: "L").count == 2 && max(pathBox.width, pathBox.height) < 2.5 { counts["stub-skipped", default: 0] += 1; return }
    // circle candidates: closed, near-square bbox, plausible button size
    let ar = pathBox.width / max(pathBox.height, 0.001)
    if path.contains("Z") && ar > 0.85 && ar < 1.18 && pathBox.width > 0.6 && pathBox.width < 7 {
      circles.append(String(format: "{\"cx\": %.3f, \"cy\": %.3f, \"d\": %.3f}", (pathBox.midX - crop.minX) / crop.width, (crop.maxY - pathBox.midY) / crop.height, pathBox.width))
    }
    let scale = sqrt(abs(g.ctm.a * g.ctm.d - g.ctm.b * g.ctm.c))
    let w = max(0.3, g.lineWidth * scale)
    var attrs = ""
    if fill { attrs += " fill=\"currentColor\"" } else { attrs += " fill=\"none\"" }
    if stroke { attrs += " stroke=\"currentColor\" stroke-width=\"\(f(w))\" stroke-linecap=\"round\" stroke-linejoin=\"round\"" }
    union = union.union(pathBox)
    out.append("<path d=\"\(path.trimmingCharacters(in: .whitespaces))\"\(attrs)/>")
    counts[fill ? (stroke ? "fill+stroke" : "fill") : "stroke", default: 0] += 1
  }
}
var X: Extractor!
var csStack: [CGPDFContentStreamRef] = []

func num(_ s: CGPDFScannerRef) -> CGFloat { var v: CGPDFReal = 0; CGPDFScannerPopNumber(s, &v); return CGFloat(v) }
func nums(_ s: CGPDFScannerRef, _ n: Int) -> [CGFloat] { var a: [CGFloat] = []; for _ in 0..<n { a.insert(num(s), at: 0) }; return a }

func scan(_ cs: CGPDFContentStreamRef) {
  let table = CGPDFOperatorTableCreate()!
  CGPDFOperatorTableSetCallback(table, "q") { _, _ in X.stack.append(X.g) }
  CGPDFOperatorTableSetCallback(table, "Q") { _, _ in if let s = X.stack.popLast() { X.g = s } }
  CGPDFOperatorTableSetCallback(table, "cm") { s, _ in let v = nums(s, 6); X.g.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(X.g.ctm) }
  CGPDFOperatorTableSetCallback(table, "w") { s, _ in X.g.lineWidth = num(s) }
  CGPDFOperatorTableSetCallback(table, "d") { s, _ in _ = num(s); var arr: CGPDFArrayRef?; if CGPDFScannerPopArray(s, &arr), let a = arr { X.g.dashed = CGPDFArrayGetCount(a) > 0 } else { X.g.dashed = false } }
  CGPDFOperatorTableSetCallback(table, "m") { s, _ in let v = nums(s, 2); X.move(X.pt(v[0], v[1])) }
  CGPDFOperatorTableSetCallback(table, "l") { s, _ in let v = nums(s, 2); X.line(X.pt(v[0], v[1])) }
  CGPDFOperatorTableSetCallback(table, "c") { s, _ in let v = nums(s, 6); X.curve(X.pt(v[0], v[1]), X.pt(v[2], v[3]), X.pt(v[4], v[5])) }
  CGPDFOperatorTableSetCallback(table, "v") { s, _ in let v = nums(s, 4); X.curve(X.cur, X.pt(v[0], v[1]), X.pt(v[2], v[3])) }
  CGPDFOperatorTableSetCallback(table, "y") { s, _ in let v = nums(s, 4); let p = X.pt(v[2], v[3]); X.curve(X.pt(v[0], v[1]), p, p) }
  CGPDFOperatorTableSetCallback(table, "h") { _, _ in X.close() }
  CGPDFOperatorTableSetCallback(table, "re") { s, _ in let v = nums(s, 4)
    X.move(X.pt(v[0], v[1])); X.line(X.pt(v[0] + v[2], v[1])); X.line(X.pt(v[0] + v[2], v[1] + v[3])); X.line(X.pt(v[0], v[1] + v[3])); X.close() }
  CGPDFOperatorTableSetCallback(table, "S")  { _, _ in X.paint(stroke: true, fill: false) }
  CGPDFOperatorTableSetCallback(table, "s")  { _, _ in X.close(); X.paint(stroke: true, fill: false) }
  CGPDFOperatorTableSetCallback(table, "f")  { _, _ in X.paint(stroke: false, fill: true) }
  CGPDFOperatorTableSetCallback(table, "F")  { _, _ in X.paint(stroke: false, fill: true) }
  CGPDFOperatorTableSetCallback(table, "f*") { _, _ in X.paint(stroke: false, fill: true) }
  CGPDFOperatorTableSetCallback(table, "B")  { _, _ in X.paint(stroke: true, fill: true) }
  CGPDFOperatorTableSetCallback(table, "B*") { _, _ in X.paint(stroke: true, fill: true) }
  CGPDFOperatorTableSetCallback(table, "b")  { _, _ in X.close(); X.paint(stroke: true, fill: true) }
  CGPDFOperatorTableSetCallback(table, "b*") { _, _ in X.close(); X.paint(stroke: true, fill: true) }
  CGPDFOperatorTableSetCallback(table, "n")  { _, _ in X.path = ""; X.pathBox = .null }
  CGPDFOperatorTableSetCallback(table, "Do") { s, info in
    var name: UnsafePointer<CChar>? = nil
    guard CGPDFScannerPopName(s, &name), let n = name else { return }
    let cs = csStack.last!
    guard let obj = CGPDFContentStreamGetResource(cs, "XObject", n) else { return }
    var stream: CGPDFStreamRef? = nil
    guard CGPDFObjectGetValue(obj, .stream, &stream), let st = stream, let dict = CGPDFStreamGetDictionary(st) else { return }
    var sub: UnsafePointer<CChar>? = nil
    if CGPDFDictionaryGetName(dict, "Subtype", &sub), let sb = sub, String(cString: sb) == "Form" {
      X.stack.append(X.g)
      var arr: CGPDFArrayRef? = nil
      if CGPDFDictionaryGetArray(dict, "Matrix", &arr), let a = arr, CGPDFArrayGetCount(a) == 6 {
        var v = [CGFloat](repeating: 0, count: 6); for i in 0..<6 { var r: CGPDFReal = 0; CGPDFArrayGetNumber(a, i, &r); v[i] = CGFloat(r) }
        X.g.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(X.g.ctm)
      }
      let inner = CGPDFContentStreamCreateWithStream(st, dict, cs)
      scan(inner)
      if let g = X.stack.popLast() { X.g = g }
    }
  }
  csStack.append(cs)
  let scanner = CGPDFScannerCreate(cs, table, nil)
  CGPDFScannerScan(scanner)
  csStack.removeLast()
  CGPDFScannerRelease(scanner); CGPDFOperatorTableRelease(table)
}

let a = CommandLine.arguments
let doc = CGPDFDocument(URL(fileURLWithPath: a[1]) as CFURL)!, page = doc.page(at: Int(a[2])!)!
let crop = CGRect(x: Double(a[3])!, y: Double(a[4])!, width: Double(a[5])!, height: Double(a[6])!)
X = Extractor(crop: crop)
scan(CGPDFContentStreamCreateWithPage(page))
let svg = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(X.f(crop.width)) \(X.f(crop.height))" width="\(X.f(crop.width))" height="\(X.f(crop.height))">
<g color="black">
\(X.out.joined(separator: "\n"))
</g>
</svg>
"""
try! svg.write(toFile: a[7], atomically: true, encoding: .utf8)
print("paths:", X.counts, "-> \(a[7])"); print("content bbox (PDF pts):", X.union)
print("circles (normalized cx, cy in viewBox; d = diameter pt):"); X.circles.forEach { print("  " + $0) }
