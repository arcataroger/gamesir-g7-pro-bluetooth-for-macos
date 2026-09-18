// main.swift
//
// `g7pro`: the command-line front end over Core.swift and Install.swift. The app bundles it at
// Contents/MacOS/g7pro and runs it as its privileged helper. Terminal users can run it directly.
//
//   g7pro status       Prints SIP state, pad presence and firmware, whether the entry is installed,
//                      and what Apple's framework reports (name, category, extendedGamepad).
//   g7pro install      Installs the entry and mapping. Run with sudo and SIP off.
//                      Options: --personality <plist>  --version <firmware VersionNumber>  --backup-dir <dir>
//   g7pro uninstall    Removes them. Run with sudo and SIP off.
//
// Resources (data/*.json, personality/) resolve relative to the executable: the app bundle's Resources
// folder, or the repo root when run from build/.
import Foundation
import GameController

func usage() -> Never { print("usage: g7pro status | install [--personality P] [--version N] [--backup-dir D] | uninstall"); exit(64) }

// Resources: next to the executable inside the app bundle (../Resources), or the repo root when run from build/.
func resourceRoot() -> URL {
  let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
  for cand in [exe.deletingLastPathComponent().appendingPathComponent("Resources"), exe, exe.deletingLastPathComponent(), exe.deletingLastPathComponent().deletingLastPathComponent()] {
    if FileManager.default.fileExists(atPath: cand.appendingPathComponent("data/device.json").path) { return cand }
  }
  return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
}
let root = resourceRoot()
guard let device = try? DataFiles.load(DeviceSpec.self, root.appendingPathComponent("data/device.json")) else { print("data/device.json not found (looked under \(root.path))"); exit(1) }
var args = Array(CommandLine.arguments.dropFirst()); guard let cmd = args.first else { usage() }; args.removeFirst()
func opt(_ name: String) -> String? { if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }; return nil }

switch cmd {
case "status":
  print("SIP:        \(SystemState.sipEnabled().map { $0 ? "enabled" : "disabled" } ?? "unknown")")
  let v = Database.padVersion(vendorID: device.vendorID, productID: device.productID)
  print("Pad:        \(v.map { "connected, firmware VersionNumber \($0)" } ?? "not connected over Bluetooth")")
  print("Entry:      \(Database.isInstalled(device: device) ? "installed" : "not installed") (\(Database.bundles().count) database copy/copies)")
  
  var seen: GCController? = nil
  let obs = NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { seen = ($0.object as! GCController) }
  seen = GCController.controllers().first
  var waited = 0.0; while seen == nil && waited < 6 { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25)); waited += 0.25 }
  NotificationCenter.default.removeObserver(obs)
  print("Framework:  \(seen.map { "sees \($0.vendorName ?? "?") as \"\($0.productCategory)\" (extendedGamepad: \($0.extendedGamepad != nil))" } ?? "does not see the pad (waited 6 s)")")
case "install":
  let pers = URL(fileURLWithPath: opt("--personality") ?? root.appendingPathComponent(device.personalityTemplate).path)
  let version = opt("--version").flatMap(Int.init) ?? Database.padVersion(vendorID: device.vendorID, productID: device.productID)
  guard let version = version else { print("No pad connected and no --version given. Connect the pad over Bluetooth or pass --version N."); exit(1) }
  // Under sudo, NSHomeDirectory() is root's; keep backups in the invoking user's home.
  let home = ProcessInfo.processInfo.environment["SUDO_USER"].flatMap { getpwnam($0).map { String(cString: $0.pointee.pw_dir) } } ?? NSHomeDirectory()
  let backup = URL(fileURLWithPath: opt("--backup-dir") ?? (home + "/Library/Application Support/G7Pro Bluetooth Setup/backup"))
  do { print(try Database.install(device: device, version: version, personality: pers, backupDir: backup)) } catch { print("error: \(error.localizedDescription)"); exit(1) }
case "uninstall":
  do { print(try Database.uninstall(device: device)) } catch { print("error: \(error.localizedDescription)"); exit(1) }
default: usage()
}
