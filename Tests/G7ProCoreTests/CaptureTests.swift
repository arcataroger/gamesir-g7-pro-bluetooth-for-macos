// Press detection and edge detection: the rules that decide when a raw report counts.
import Testing
@testable import G7ProCore

@Suite("Press detection")
struct PressDetectorTests {
  @Test("buttons count when non-zero") func button() {
    #expect(PressDetector.matches(rawEvent(page: 9, usage: 1, value: 1), kind: "button"))
    #expect(!PressDetector.matches(rawEvent(page: 9, usage: 1, value: 0), kind: "button"))
  }
  @Test("sticks count only near the ends of travel") func axis() {
    #expect(!PressDetector.matches(rawEvent(page: 1, usage: 0x30, value: 128), kind: "axis"))
    #expect(!PressDetector.matches(rawEvent(page: 1, usage: 0x30, value: 100), kind: "axis"))
    #expect(PressDetector.matches(rawEvent(page: 1, usage: 0x30, value: 20), kind: "axis"))
    #expect(PressDetector.matches(rawEvent(page: 1, usage: 0x30, value: 240), kind: "axis"))
  }
  @Test("triggers are the simulation usages, past half travel") func trigger() {
    #expect(PressDetector.matches(rawEvent(page: 2, usage: 0xC5, value: 200), kind: "trigger"))
    #expect(!PressDetector.matches(rawEvent(page: 2, usage: 0xC5, value: 60), kind: "trigger"))
    #expect(!PressDetector.matches(rawEvent(page: 9, usage: 9, value: 1), kind: "trigger"), "a trigger's digital button is not the analog trigger")
  }
  @Test("hat values 0–8 are presses; 15 is centre") func hat() {
    #expect(PressDetector.matches(rawEvent(page: 1, usage: 0x39, value: 2), kind: "hat"))
    #expect(!PressDetector.matches(rawEvent(page: 1, usage: 0x39, value: 15), kind: "hat"))
  }
  @Test("kind is derived from the usage") func kinds() {
    #expect(PressDetector.kind(of: rawEvent(page: 9, usage: 3, value: 1)) == "button")
    #expect(PressDetector.kind(of: rawEvent(page: 1, usage: 0x39, value: 1)) == "hat")
    #expect(PressDetector.kind(of: rawEvent(page: 1, usage: 0x31, value: 1)) == "axis")
    #expect(PressDetector.kind(of: rawEvent(page: 2, usage: 0xC4, value: 1)) == "trigger")
    #expect(PressDetector.kind(of: rawEvent(page: 12, usage: 0x223, value: 1)) == "")
  }
}

@Suite("Edge detection")
struct EdgeDetectorTests {
  /// Feeds a value stream through one detector and returns the rising-edge flags. (#expect captures
  /// immutably, so the mutation happens outside it.)
  private func edges(_ values: [Int], page: UInt32 = 2, usage: UInt32 = 0xC5, cookie: UInt32 = 42) -> [Bool] {
    var e = EdgeDetector()
    return values.map { e.isRisingEdge(rawEvent(page: page, usage: usage, value: $0, cookie: cookie)) }
  }

  @Test("one trigger pull is one edge, however many reports it streams")
  func onePull() {
    let flags = edges([0, 40, 140, 200, 255, 255, 250, 180, 90, 20, 0])
    #expect(flags.filter { $0 }.count == 1)
  }
  @Test("two pulls with a release between are two edges")
  func twoPulls() {
    let flags = edges([0, 200, 255, 0, 10, 220, 0])
    #expect(flags.filter { $0 }.count == 2)
  }
  @Test("elements are tracked independently")
  func independent() {
    var e = EdgeDetector()
    let a1 = e.isRisingEdge(rawEvent(page: 9, usage: 1, value: 1, cookie: 1))
    let b1 = e.isRisingEdge(rawEvent(page: 9, usage: 2, value: 1, cookie: 2))
    let a2 = e.isRisingEdge(rawEvent(page: 9, usage: 1, value: 1, cookie: 1))
    let a3 = e.isRisingEdge(rawEvent(page: 9, usage: 1, value: 0, cookie: 1))
    let a4 = e.isRisingEdge(rawEvent(page: 9, usage: 1, value: 1, cookie: 1))
    #expect(a1 && b1 && !a2 && !a3 && a4)
  }
}
