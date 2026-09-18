// swift-tools-version:5.9
// Test harness only. build-app.sh builds the shipped app and CLI directly with swiftc; this package exposes
// the headless core as a library so `swift test` can exercise it. See Tests/.
import PackageDescription

let package = Package(
  name: "G7ProCore",
  platforms: [.macOS(.v14)],
  targets: [
    .target(name: "G7ProCore", path: "src", sources: ["Core.swift", "Install.swift"]),
    .testTarget(name: "G7ProCoreTests", dependencies: ["G7ProCore"], path: "Tests/G7ProCoreTests", resources: [.copy("Fixtures")]),
  ]
)
