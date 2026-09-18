// The numbering rule is the project's central finding. These tests pin it to the recorded pad.
import Testing
import Foundation
@testable import G7ProCore

@Suite("Index rule", .enabled(if: Fixture.exists, "record Tests/…/Fixtures/g7pro-elements.json with the pad connected"))
struct IndexRuleTests {
  private func index(_ controlID: String) -> Int? {
    guard let cap = Repo.reference.captures.first(where: { $0.controlID == controlID }), let cookie = Fixture.cookie(for: cap) else { return nil }
    return IndexRule.daemonIndex(usageType: cap.usageType, cookie: cookie, in: Fixture.elements)
  }

  @Test("gamepad buttons interleave with the mouse collection's buttons 1–5")
  func buttonsInterleave() {
    #expect(index("a") == 0)
    #expect(index("b") == 2)
    #expect(index("x") == 6)
    #expect(index("y") == 8)
    #expect(index("lb") == 11)
    #expect(index("rb") == 12)
    #expect(index("view") == 15)
    #expect(index("menu") == 16)
    #expect(index("l3") == 18)
    #expect(index("r3") == 19)
  }

  @Test("stick axes interleave with the mouse's X and Y; triggers sort after the generic-desktop axes")
  func axes() {
    #expect(index("ls.right") == 0)   // gamepad X
    #expect(index("ls.up") == 2)      // gamepad Y (mouse X sits at 1)
    #expect(index("rs.right") == 4)   // Z
    #expect(index("rs.up") == 5)      // Rz
    #expect(index("rt") == 7)         // Simulation Accelerator
    #expect(index("lt") == 8)         // Simulation Brake
  }

  @Test("the D-pad is the only hat")
  func hat() { #expect(index("dpad.up") == 0) }

  @Test("every reference capture reproduces the bundled personality's predicate")
  func matchesBundledPersonality() throws {
    for cap in Repo.reference.captures {
      let ctl = try #require(Repo.controls.first { $0.id == cap.controlID })
      let cookie = try #require(Fixture.cookie(for: cap), "no fixture element for \(cap.controlID)")
      let idx = try #require(IndexRule.daemonIndex(usageType: cap.usageType, cookie: cookie, in: Fixture.elements) as Int?)
      #expect(IndexRule.predicate(usageType: cap.usageType, index: idx) == Repo.personalityPredicates[ctl.ident], "\(cap.controlID)")
    }
  }
}
