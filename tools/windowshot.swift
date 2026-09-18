// Screenshot a running app's main window: windowshot <process name> <out.png>
import AppKit
let a = CommandLine.arguments
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
guard let w = list.first(where: { ($0[kCGWindowOwnerName as String] as? String) == a[1] && (($0[kCGWindowLayer as String] as? Int) ?? 1) == 0 }),
      let id = w[kCGWindowNumber as String] as? Int else { print("no window for \(a[1])"); exit(1) }
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture"); p.arguments = ["-x", "-o", "-l", String(id), a[2]]
try! p.run(); p.waitUntilExit(); print("saved", a[2], "window", id)
