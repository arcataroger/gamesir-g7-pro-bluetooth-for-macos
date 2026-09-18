// Install.swift — installing/removing the database entry. Runs as root (the app launches the CLI through the
// admin-password prompt; terminal users run `sudo g7pro install`). Pure Foundation, no shell.
import Foundation
import IOKit.hid

enum InstallError: Error, LocalizedError {
  case sipEnabled, noBundle, notRoot, io(String)
  var errorDescription: String? {
    switch self {
    case .sipEnabled: return "System Integrity Protection is enabled; the controller database is write-protected. Disable SIP from Recovery (csrutil disable), install, then re-enable it."
    case .noBundle: return "Apple's GameControllers-Custom.bundle was not found under /System/Library/AssetsV2."
    case .notRoot: return "Needs to run as root (sudo)."
    case .io(let s): return s
    }
  }
}

enum Database {
  static let daemonLabel = "system/com.apple.GameController.gamecontrollerd"

  /// Every copy of Apple's third-party controller database on this Mac (normally one; more if Apple pushed an update).
  static func bundles() -> [URL] {
    let root = URL(fileURLWithPath: "/System/Library/AssetsV2")
    var out: [URL] = []
    if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
      for case let u as URL in e {
        if u.lastPathComponent == "GameControllers-Custom.bundle" { out.append(u); e.skipDescendants() }
        else if e.level > 7 { e.skipDescendants() }
      }
    }
    return out
  }

  /// Firmware VersionNumber of the connected pad, read from device properties (no Input Monitoring needed).
  static func padVersion(vendorID: Int, productID: Int) -> Int? {
    let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(m, [kIOHIDVendorIDKey: vendorID, kIOHIDProductIDKey: productID] as CFDictionary)
    guard let devs = IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>, let d = devs.first else { return nil }
    return IOHIDDeviceGetProperty(d, kIOHIDVersionNumberKey as CFString) as? Int
  }

  static func restartDaemon() -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = ["kickstart", "-k", daemonLabel]
    let out = Pipe(); p.standardOutput = out; p.standardError = out
    do { try p.run(); p.waitUntilExit() } catch { return "launchctl failed: \(error)" }
    return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
  }

  private static func writeRootFile(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755, .ownerAccountID: 0, .groupOwnerAccountID: 0])
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o644, .ownerAccountID: 0, .groupOwnerAccountID: 0], ofItemAtPath: url.path)
  }

  /// Adds (or replaces) the device entry and installs the personality into every database copy. Returns a log.
  static func install(device: DeviceSpec, version: Int, personality: URL, backupDir: URL) throws -> String {
    guard getuid() == 0 else { throw InstallError.notRoot }
    if SystemState.sipEnabled() == true { throw InstallError.sipEnabled }
    let bundles = Database.bundles(); guard !bundles.isEmpty else { throw InstallError.noBundle }
    let persData = try Data(contentsOf: personality)
    var log = "Firmware VersionNumber \(version)\n"
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    for b in bundles {
      let info = b.appendingPathComponent("Info.plist")
      var plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as! [String: Any]
      var devices = plist["Devices"] as? [[String: Any]] ?? []
      let backup = backupDir.appendingPathComponent(stamp)
      try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: info, to: backup.appendingPathComponent("Info.plist"))
      // We run as root; hand the backup back to the user whose folder this is (SUDO_UID, or the home folder's owner).
      let ownerUID = ProcessInfo.processInfo.environment["SUDO_UID"].flatMap { UInt32($0) }
        ?? (try? FileManager.default.attributesOfItem(atPath: backupDir.deletingLastPathComponent().deletingLastPathComponent().path)[.ownerAccountID] as? UInt32)
      if let uid = ownerUID, let e = FileManager.default.enumerator(atPath: backupDir.path) {
        try? FileManager.default.setAttributes([.ownerAccountID: uid], ofItemAtPath: backupDir.path)
        for case let rel as String in e { try? FileManager.default.setAttributes([.ownerAccountID: uid], ofItemAtPath: backupDir.appendingPathComponent(rel).path) }
      }
      let had = devices.contains { ($0["Identifier"] as? String) == device.identifier }
      devices.removeAll { ($0["Identifier"] as? String) == device.identifier }
      devices.append(["Identifier": device.identifier, "CompatibilityVersion": device.compatibilityVersion,
                      "IOPropertyMatch": ["VendorID": device.vendorID, "ProductID": device.productID, "VersionNumber": version],
                      "Personalities": [device.personalityInstallPath]])
      plist["Devices"] = devices
      try writeRootFile(try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), to: info)
      try writeRootFile(persData, to: b.appendingPathComponent(device.personalityInstallPath))
      log += "\(had ? "Replaced" : "Added") entry in \(b.path)\nBackup: \(backup.path)\n"
    }
    log += "Restarting gamecontrollerd… " + restartDaemon() + "\n"
    return log
  }

  static func uninstall(device: DeviceSpec) throws -> String {
    guard getuid() == 0 else { throw InstallError.notRoot }
    if SystemState.sipEnabled() == true { throw InstallError.sipEnabled }
    var log = ""
    for b in Database.bundles() {
      let info = b.appendingPathComponent("Info.plist")
      var plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as! [String: Any]
      var devices = plist["Devices"] as? [[String: Any]] ?? []
      let before = devices.count
      devices.removeAll { ($0["Identifier"] as? String) == device.identifier }
      if devices.count != before {
        plist["Devices"] = devices
        try writeRootFile(try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), to: info)
        log += "Removed entry from \(b.path)\n"
      } else { log += "No entry in \(b.path)\n" }
      let pers = b.appendingPathComponent(device.personalityInstallPath)
      try? FileManager.default.removeItem(at: pers.deletingLastPathComponent())
    }
    log += "Restarting gamecontrollerd… " + restartDaemon() + "\n"
    return log
  }

  static func isInstalled(device: DeviceSpec) -> Bool {
    for b in bundles() {
      if let plist = try? PropertyListSerialization.propertyList(from: Data(contentsOf: b.appendingPathComponent("Info.plist")), format: nil) as? [String: Any],
         let devices = plist["Devices"] as? [[String: Any]], devices.contains(where: { ($0["Identifier"] as? String) == device.identifier }) { return true }
    }
    return false
  }
}
