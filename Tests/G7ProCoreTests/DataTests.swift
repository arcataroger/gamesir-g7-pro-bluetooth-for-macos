// The JSON data files must agree with each other, with the personality, and with their schemas.
import Testing
import Foundation
@testable import G7ProCore

@Suite("Data files")
struct DataTests {
  @Test("control ids are unique") func uniqueIDs() {
    #expect(Set(Repo.controls.map { $0.id }).count == Repo.controls.count)
  }
  @Test("every mappable control names an element in the personality") func idents() {
    for c in Repo.controls where c.isMappable { #expect(Repo.personalityPredicates[c.ident] != nil, Comment(rawValue: c.id)) }
  }
  @Test("callout glyphs exist for every callout control, and only those") func glyphs() {
    let g = Repo.json("data/callout-glyphs.json") as! [String: Any]
    let callouts = Set(Repo.controls.filter { $0.shape == "callout" }.map { $0.id })
    #expect(Set(g.keys) == callouts)
    for c in Repo.controls where c.shape == "callout" { #expect(c.ax != nil && c.ay != nil, "\(c.id) needs a leader anchor") }
  }
  @Test("directional controls declare a direction; nothing else does") func directions() {
    for c in Repo.controls {
      let directional = c.kind == "axis" || c.kind == "hat"
      #expect((c.gcDir != nil) == directional, Comment(rawValue: c.id)) }
  }
  @Test("the reference mapping covers every mappable control with the right usage type") func reference() {
    for c in Repo.controls where c.isMappable {
      let cap = Repo.reference.captures.first { $0.controlID == c.id }
      #expect(cap != nil, Comment(rawValue: c.id))
      if let cap { #expect(cap.usageType == (c.kind == "button" ? 1 : c.kind == "hat" ? 3 : 2), Comment(rawValue: c.id)) }
    }
    #expect(Repo.reference.vendorID == Repo.device.vendorID && Repo.reference.productID == Repo.device.productID)
  }

  /// A minimal validator: required keys, additionalProperties: false, enums, and types for scalars.
  private func validate(_ value: Any, against schema: [String: Any], path: String = "$") -> [String] {
    var errs: [String] = []
    if let t = schema["type"] as? String {
      let ok: Bool
      switch t {
      case "object": ok = value is [String: Any]
      case "array": ok = value is [Any]
      case "string": ok = value is String
      // NSNumber(1) answers `is Bool` with true, so test the CoreFoundation type instead.
      case "integer": ok = (value as? NSNumber).map { CFGetTypeID($0) != CFBooleanGetTypeID() && !CFNumberIsFloatType($0) } ?? false
      case "number": ok = (value as? NSNumber).map { CFGetTypeID($0) != CFBooleanGetTypeID() } ?? false
      case "boolean": ok = (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
      default: ok = true
      }
      if !ok { errs.append("\(path): expected \(t)") }
    }
    if let e = schema["enum"] as? [Any], !e.contains(where: { "\($0)" == "\(value)" }) { errs.append("\(path): not in enum") }
    if let obj = value as? [String: Any] {
      for r in schema["required"] as? [String] ?? [] where obj[r] == nil { errs.append("\(path): missing \(r)") }
      let props = schema["properties"] as? [String: [String: Any]] ?? [:]
      let extra = schema["additionalProperties"]
      for (k, v) in obj {
        if let ps = props[k] { errs += validate(v, against: ps, path: "\(path).\(k)") }
        else if let ap = extra as? [String: Any] { errs += validate(v, against: ap, path: "\(path).\(k)") }
        else if (extra as? Bool) == false { errs.append("\(path): unexpected key \(k)") }
      }
    }
    if let arr = value as? [Any], let items = schema["items"] as? [String: Any] {
      for (i, v) in arr.enumerated() { errs += validate(v, against: items, path: "\(path)[\(i)]") }
    }
    return errs
  }
  @Test("data files conform to their schemas", arguments: [
    ("data/device.json", "schemas/device.schema.json"),
    ("data/controls.json", "schemas/controls.schema.json"),
    ("data/callout-glyphs.json", "schemas/callout-glyphs.schema.json"),
    ("data/reference-mapping.json", "schemas/mapping.schema.json"),
  ])
  func schemas(data: String, schema: String) {
    let errs = validate(Repo.json(data), against: Repo.json(schema) as! [String: Any])
    #expect(errs.isEmpty, Comment(rawValue: errs.joined(separator: "; ")))
  }
}

@Suite("Glyph paths")
struct GlyphPathTests {
  @Test("a closed square fills its rect") func square() {
    let p = GlyphPath.cgPath(["M 0 0 L 1 0 L 1 1 L 0 1 Z"], in: CGRect(x: 10, y: 20, width: 100, height: 50))
    #expect(p.boundingBox == CGRect(x: 10, y: 20, width: 100, height: 50))
  }
  @Test("curves and several subpaths parse") func curves() {
    let p = GlyphPath.cgPath(["M 0 0 C 0.5 0 1 0.5 1 1", "M 0 1 L 0 0 Z"], in: CGRect(x: 0, y: 0, width: 2, height: 2))
    #expect(!p.isEmpty && p.boundingBox.width == 2)
  }
  @Test("every shipped glyph parses to a non-empty path") func shipped() {
    let g = Repo.json("data/callout-glyphs.json") as! [String: [String: Any]]
    for (id, v) in g { #expect(!GlyphPath.cgPath(v["paths"] as! [String], in: CGRect(x: 0, y: 0, width: 1, height: 1)).isEmpty, Comment(rawValue: id)) }
  }
}
