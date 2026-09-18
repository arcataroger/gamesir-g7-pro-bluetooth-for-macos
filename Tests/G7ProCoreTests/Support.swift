// Shared helpers: locate the repo's data files and the recorded fixtures.
import Foundation
@testable import G7ProCore

enum Repo {
  static let root: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  static func url(_ rel: String) -> URL { root.appendingPathComponent(rel) }
  static func json(_ rel: String) -> Any { try! JSONSerialization.jsonObject(with: Data(contentsOf: url(rel))) }
  static let device: DeviceSpec = try! DataFiles.load(DeviceSpec.self, url("data/device.json"))
  static let controls: [ControlSpec] = try! DataFiles.load([ControlSpec].self, url("data/controls.json"))
  static let reference: MappingFile = {
    let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
    return try! d.decode(MappingFile.self, from: Data(contentsOf: url("data/reference-mapping.json")))
  }()
  /// Predicates by element identifier from the bundled personality.
  static let personalityPredicates: [String: String] = {
    let plist = try! PropertyListSerialization.propertyList(from: Data(contentsOf: url(device.personalityTemplate)), format: nil) as! [String: Any]
    let els = ((plist["Model"] as! [String: Any])["Driver"] as! [String: Any])["Elements"] as! [[String: Any]]
    return Dictionary(uniqueKeysWithValues: els.map { ($0["Identifier"] as! String, $0["Predicate"] as! String) })
  }()
}

/// The pad's input elements, recorded by tools while the pad was connected (Tests/…/Fixtures/g7pro-elements.json).
enum Fixture {
  static let url = Repo.url("Tests/G7ProCoreTests/Fixtures/g7pro-elements.json")
  static var exists: Bool { FileManager.default.fileExists(atPath: url.path) }
  static let elements: [ElementInfo] = {
    guard exists, let j = try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
          let list = j["elements"] as? [[String: Any]] else { return [] }
    return list.map { ElementInfo(cookie: UInt32($0["cookie"] as! Int), usagePage: UInt32($0["usagePage"] as! Int), usage: UInt32($0["usage"] as! Int), reportID: UInt32($0["reportID"] as! Int)) }
  }()
  /// Cookies differ between recording sessions in principle; match a capture to the fixture by usage instead.
  static func cookie(for cap: Capture) -> UInt32? {
    elements.first { $0.usagePage == cap.usagePage && $0.usage == cap.usage && $0.reportID == cap.reportID }?.cookie
  }
}

func rawEvent(page: UInt32, usage: UInt32, value: Int, cookie: UInt32 = 1, report: UInt32 = 7) -> RawEvent {
  RawEvent(cookie: cookie, usagePage: page, usage: usage, reportID: report, value: value)
}
