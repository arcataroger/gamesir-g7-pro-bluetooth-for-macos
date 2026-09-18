import Testing
import Foundation
@testable import G7ProCore

@Suite("Personality writer", .enabled(if: Fixture.exists))
struct PersonalityWriterTests {
  private func build(category: String?) throws -> [String: Any] {
    // rebase the reference captures onto the fixture's cookies
    let caps = Repo.reference.captures.compactMap { c -> Capture? in
      guard let k = Fixture.cookie(for: c) else { return nil }
      return Capture(controlID: c.controlID, usageType: c.usageType, cookie: k, usagePage: c.usagePage, usage: c.usage, reportID: c.reportID)
    }
    let (data, _) = try PersonalityWriter.build(template: Repo.url(Repo.device.personalityTemplate), captures: caps, elements: Fixture.elements,
                                                controls: Repo.controls, productName: "GameSir-G7 Pro", productCategory: category)
    return try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
  }
  private func model(_ p: [String: Any]) -> [String: Any] { p["Model"] as! [String: Any] }

  @Test("writes the same predicates the bundled personality carries")
  func predicates() throws {
    let els = (model(try build(category: nil))["Driver"] as! [String: Any])["Elements"] as! [[String: Any]]
    for e in els { #expect(e["Predicate"] as? String == Repo.personalityPredicates[e["Identifier"] as! String], Comment(rawValue: e["Identifier"] as! String)) }
    #expect(els.count == Repo.personalityPredicates.count)
  }

  @Test("sets the product category and name; leaves the rest of the model alone")
  func category() throws {
    let m = model(try build(category: "Xbox One"))
    #expect(m["ProductCategory"] as? String == "Xbox One")
    #expect(m["ProductName"] as? String == "GameSir-G7 Pro")
    #expect(m["FormFitting"] as? Bool == true)
    #expect(m["PhysicalInput"] != nil)
    #expect(model(try build(category: "HID"))["ProductCategory"] as? String == "HID")
  }
}
