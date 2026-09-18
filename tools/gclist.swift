import GameController
import Foundation
var seen = false
NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { n in
  seen = true; let c = n.object as! GCController
  print("CONNECT notification:", c.vendorName ?? "nil", "| category:", c.productCategory, "| extended:", c.extendedGamepad != nil)
}
GCController.startWirelessControllerDiscovery {}
RunLoop.main.run(until: Date(timeIntervalSinceNow: 6))
let cs = GCController.controllers()
print("GameController framework sees \(cs.count) controller(s)")
for c in cs {
  print("- vendorName:", c.vendorName ?? "nil", "| productCategory:", c.productCategory, "| extendedGamepad:", c.extendedGamepad != nil)
  if let g = c.extendedGamepad { print("  buttons live: A=\(g.buttonA.isPressed) B=\(g.buttonB.isPressed) LX=\(g.leftThumbstick.xAxis.value)") }
}
