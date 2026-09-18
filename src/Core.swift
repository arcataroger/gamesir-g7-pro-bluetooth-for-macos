// Core.swift — headless logic shared by any front end (the SwiftUI wizard today, a TUI or CLI tomorrow).
//
//  * DeviceSpec / ControlSpec       – loaded from data/device.json and data/controls.json
//  * HIDSource                       – raw HID stream from the pad, plus its full element list
//  * IndexRule                       – how gamecontrollerd numbers elements (the UsageTypeIndex a personality refers to)
//  * Capture / MappingFile           – what the user pressed, persisted as mapping.json
//  * PersonalityWriter               – turns a capture into a personality plist
//  * FrameworkObserver               – what macOS's GameController framework delivers to apps
//  * SystemState / Installer         – SIP status, Input Monitoring permission, running install/uninstall as admin
import Foundation
import IOKit.hid
import GameController
import AppKit

// MARK: - Data files

struct DeviceSpec: Codable {
  var name: String; var vendorID: Int; var productID: Int; var identifier: String
  var compatibilityVersion: String; var personalityTemplate: String; var personalityInstallPath: String
  var notes: [String]
}

struct ControlSpec: Codable, Identifiable, Hashable {
  var id: String; var prompt: String; var ident: String; var kind: String   // button | axis | hat | system
  var gc: String; var gcDir: String?; var x: Double; var y: Double; var shape: String; var label: String
  var isMappable: Bool { kind != "system" }
}

enum DataFiles {
  static func load<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T { try JSONDecoder().decode(T.self, from: Data(contentsOf: url)) }
}

// MARK: - Raw HID

struct RawEvent {
  let cookie: UInt32; let usagePage: UInt32; let usage: UInt32; let reportID: UInt32; let value: Int
  /// 1 button, 2 axis, 3 hat, 0 other (consumer keys, keyboard...)
  var usageType: Int {
    if usagePage == 9 { return 1 }
    if usagePage == 1 && usage == 0x39 { return 3 }
    if usagePage == 1 && (0x30...0x38).contains(usage) { return 2 }
    return 0
  }
  var describeOther: String? {
    switch usagePage {
    case 12: return "media key 0x\(String(usage, radix: 16)) (macOS handles this as a system key)"
    case 7: return "keyboard key 0x\(String(usage, radix: 16)) (sent as a keystroke)"
    case 2: return "analog trigger 0x\(String(usage, radix: 16))"
    default: return nil
    }
  }
}

struct ElementInfo { let cookie: UInt32; let usagePage: UInt32; let usage: UInt32; let reportID: UInt32 }

final class HIDSource {
  static let shared = HIDSource()
  var onEvent: ((RawEvent) -> Void)?
  var onDeviceChange: ((Bool) -> Void)?
  private(set) var device: IOHIDDevice?
  private(set) var elements: [ElementInfo] = []
  private(set) var firmwareVersion: Int?
  private var manager: IOHIDManager?
  private(set) var openStatus: IOReturn = kIOReturnNotOpen

  /// Ask macOS for Input Monitoring; shows the system prompt the first time.
  static func requestInputMonitoring() -> Bool { IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }
  static func hasInputMonitoring() -> Bool { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted }

  @discardableResult
  func start(vendorID: Int, productID: Int) -> IOReturn {
    if manager != nil { return openStatus }
    let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(m, [kIOHIDVendorIDKey: vendorID, kIOHIDProductIDKey: productID] as CFDictionary)
    IOHIDManagerRegisterDeviceMatchingCallback(m, { _, _, _, dev in HIDSource.shared.attach(dev) }, nil)
    IOHIDManagerRegisterDeviceRemovalCallback(m, { _, _, _, _ in HIDSource.shared.detach() }, nil)
    IOHIDManagerRegisterInputValueCallback(m, { _, _, _, value in
      let e = IOHIDValueGetElement(value)
      let ev = RawEvent(cookie: IOHIDElementGetCookie(e), usagePage: IOHIDElementGetUsagePage(e), usage: IOHIDElementGetUsage(e),
                        reportID: IOHIDElementGetReportID(e), value: IOHIDValueGetIntegerValue(value))
      HIDSource.shared.onEvent?(ev)
    }, nil)
    IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    openStatus = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
    manager = m
    return openStatus
  }

  private func attach(_ dev: IOHIDDevice) {
    device = dev
    firmwareVersion = IOHIDDeviceGetProperty(dev, kIOHIDVersionNumberKey as CFString) as? Int
    var list: [ElementInfo] = []
    if let els = IOHIDDeviceCopyMatchingElements(dev, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] {
      for e in els where IOHIDElementGetType(e).rawValue < 129 {   // inputs only (not output/feature/collection)
        list.append(ElementInfo(cookie: IOHIDElementGetCookie(e), usagePage: IOHIDElementGetUsagePage(e),
                                usage: IOHIDElementGetUsage(e), reportID: IOHIDElementGetReportID(e)))
      }
    }
    elements = list
    onDeviceChange?(true)
  }
  private func detach() { device = nil; elements = []; firmwareVersion = nil; onDeviceChange?(false) }
}

// MARK: - The numbering rule

/// gamecontrollerd numbers same-type usages across the WHOLE device, sorted by usage value (stable on descriptor order).
/// A composite pad whose mouse collection also has buttons 1–5 and X/Y axes therefore has those interleaved with the
/// gamepad's own. This is what a personality's `UsageTypeIndex` refers to. Verified empirically on the G7 Pro.
enum IndexRule {
  static func daemonIndex(usageType: Int, cookie: UInt32, in elements: [ElementInfo]) -> Int? {
    let pool: [ElementInfo]
    switch usageType {
    case 1: pool = elements.filter { $0.usagePage == 9 }
    case 2: pool = elements.filter { $0.usagePage == 1 && (0x30...0x38).contains($0.usage) }
    case 3: pool = elements.filter { $0.usagePage == 1 && $0.usage == 0x39 }
    default: return nil
    }
    let sorted = pool.sorted { $0.usage != $1.usage ? $0.usage < $1.usage : $0.cookie < $1.cookie }
    return sorted.firstIndex { $0.cookie == cookie }
  }
  static func predicate(usageType: Int, index: Int) -> String { "UsageType == \(usageType) AND UsageTypeIndex == \(index)" }
}

// MARK: - Capture

struct Capture: Codable, Equatable {
  var controlID: String; var usageType: Int; var cookie: UInt32; var usagePage: UInt32; var usage: UInt32; var reportID: UInt32
}

struct MappingFile: Codable {
  var device: String; var vendorID: Int; var productID: Int; var firmwareVersion: Int?; var capturedAt: Date
  var captures: [Capture]
  static func url(in dir: URL) -> URL { dir.appendingPathComponent("mapping.json") }
  func save(to dir: URL) throws {
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
    try enc.encode(self).write(to: MappingFile.url(in: dir))
  }
}

/// Decide whether a raw event is "the press" for a control of the given kind.
enum PressDetector {
  static func matches(_ ev: RawEvent, kind: String) -> Bool {
    switch kind {
    case "button": return ev.usageType == 1 && ev.value != 0
    case "hat":    return ev.usageType == 3 && (0...8).contains(ev.value) && ev.value != 15
    case "axis":   return ev.usageType == 2 && (ev.value < 48 || ev.value > 208)
    default:       return false
    }
  }
}

// MARK: - Personality

enum PersonalityWriter {
  struct Change { let ident: String; let from: String; let to: String }

  /// Returns the rewritten plist and the list of predicate changes. Elements not captured keep the template's value.
  static func build(template: URL, captures: [Capture], elements: [ElementInfo], controls: [ControlSpec], productName: String)
    throws -> (Data, [Change]) {
    var plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: template), format: nil) as! [String: Any]
    var model = plist["Model"] as! [String: Any]; var driver = model["Driver"] as! [String: Any]
    var els = driver["Elements"] as! [[String: Any]]
    var changes: [Change] = []
    for cap in captures {
      guard let ctl = controls.first(where: { $0.id == cap.controlID }),
            let idx = IndexRule.daemonIndex(usageType: cap.usageType, cookie: cap.cookie, in: elements),
            let i = els.firstIndex(where: { ($0["Identifier"] as? String) == ctl.ident }) else { continue }
      let pred = IndexRule.predicate(usageType: cap.usageType, index: idx)
      let old = els[i]["Predicate"] as? String ?? ""
      if old != pred { changes.append(Change(ident: ctl.ident, from: old, to: pred)); els[i]["Predicate"] = pred }
    }
    driver["Elements"] = els; model["Driver"] = driver; model["ProductName"] = productName; plist["Model"] = model
    return (try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), changes)
  }
}

// MARK: - GameController framework

final class FrameworkObserver {
  static let shared = FrameworkObserver()
  var onElement: ((String, String?) -> Void)?      // (localized element name, direction for pads/sticks)
  var onConnection: ((Bool) -> Void)?
  private(set) var controller: GCController?
  private var token: NSObjectProtocol?, token2: NSObjectProtocol?

  func start() {
    token = NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in self?.attach(n.object as! GCController) }
    token2 = NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
      self?.controller = nil; self?.onConnection?(false) }
    GCController.controllers().forEach(attach)
  }
  private func attach(_ c: GCController) {
    guard let g = c.extendedGamepad else { return }
    controller = c
    g.valueChangedHandler = { [weak self] _, el in
      if let b = el as? GCControllerButtonInput { if b.isPressed { self?.onElement?(b.localizedName ?? "button", nil) } }
      else if let d = el as? GCControllerDirectionPad {
        let x = d.xAxis.value, y = d.yAxis.value
        if abs(x) > 0.6 || abs(y) > 0.6 { self?.onElement?(d.localizedName ?? "pad", y > 0.6 ? "up" : y < -0.6 ? "down" : x > 0.6 ? "right" : "left") }
      }
    }
    onConnection?(true)
  }
}

// MARK: - System

enum SystemState {
  static func sipEnabled() -> Bool? {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/csrutil"); p.arguments = ["status"]
    let out = Pipe(); p.standardOutput = out; p.standardError = out
    do { try p.run() } catch { return nil }
    p.waitUntilExit()
    let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    if s.contains("enabled") { return true }; if s.contains("disabled") { return false }; return nil
  }
  static func openInputMonitoringSettings() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
  }
}

enum Installer {
  /// Runs an executable as root via the standard macOS admin-password prompt. Returns (success, output).
  static func runAsAdmin(executable: URL, args: [String]) -> (Bool, String) {
    func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    let cmd = q(executable.path) + " " + args.map(q).joined(separator: " ") + " 2>&1"
    let src = "do shell script \"\(cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
    var err: NSDictionary?
    let result = NSAppleScript(source: src)?.executeAndReturnError(&err)
    if let err = err { return (false, (err[NSAppleScript.errorMessage] as? String) ?? "\(err)") }
    return (true, result?.stringValue ?? "")
  }
}
