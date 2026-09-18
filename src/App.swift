// App.swift — SwiftUI wizard front end over Core.swift. Everything except the two SIP reboots happens here.
import SwiftUI
import AppKit

@main
struct G7ProSetupApp: App {
  @StateObject private var wiz = Wizard()
  var body: some Scene {
    WindowGroup("GameSir G7 Pro Bluetooth Setup") {
      WizardView().environmentObject(wiz).frame(minWidth: 900, minHeight: 620)
    }
    .windowResizability(.contentSize)
    .commands { CommandGroup(replacing: .undoRedo) { Button("Undo Capture") { wiz.undo() }.keyboardShortcut("z", modifiers: .command).disabled(!wiz.canUndo) } }
  }
}

enum Step: Int, CaseIterable { case welcome, permission, detect, capture, review, install, verify, done
  var title: String { ["Welcome", "Permission", "Find the pad", "Capture", "Review", "Install", "Verify", "Finish"][rawValue] } }

struct VerifyState { var ok = Set<String>(); var bad: [String: String] = [:] }

final class Wizard: ObservableObject {
  @Published var step: Step = .welcome
  @Published var sipEnabled: Bool? = nil
  @Published var inputMonitoring = HIDSource.hasInputMonitoring()
  @Published var padConnected = false
  @Published var frameworkSeesPad = false
  @Published var firmware: Int? = nil
  @Published var captures: [Capture] = []
  @Published var currentIndex = 0
  @Published var lastRawText = ""
  @Published var litControl: String? = nil            // control lit by the most recent raw event
  @Published var changes: [PersonalityWriter.Change] = []
  @Published var indexTable: [(String, String)] = []
  @Published var installOutput = ""
  @Published var installing = false
  @Published var installed = false
  @Published var verify = VerifyState()
  @Published var lastFrameworkText = ""
  @Published var errorText: String? = nil

  let device: DeviceSpec
  let controls: [ControlSpec]
  let resourceRoot: URL
  let workDir: URL
  var mappable: [ControlSpec] { controls.filter { $0.isMappable } }
  var current: ControlSpec? { currentIndex < mappable.count ? mappable[currentIndex] : nil }
  var canUndo: Bool { step == .capture && !captures.isEmpty }
  var personalityURL: URL { workDir.appendingPathComponent("GameSir-G7Pro-Bluetooth.plist") }
  /// The bundled `g7pro` CLI, launched as root for install/uninstall.
  var cliURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/g7pro") }
  private var lastRawControlID: String? = nil
  private var lastRawAt = Date.distantPast

  init() {
    // Resources live in the app bundle, or (when run straight from the build directory) in the repo.
    var root = Bundle.main.resourceURL ?? URL(fileURLWithPath: ".")
    if !FileManager.default.fileExists(atPath: root.appendingPathComponent("data/controls.json").path) {
      var u = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
      for _ in 0..<6 { if FileManager.default.fileExists(atPath: u.appendingPathComponent("data/controls.json").path) { root = u; break }; u = u.deletingLastPathComponent() }
    }
    resourceRoot = root
    device = (try? DataFiles.load(DeviceSpec.self, root.appendingPathComponent("data/device.json"))) ?? DeviceSpec(name: "?", vendorID: 0, productID: 0, identifier: "", compatibilityVersion: "", personalityTemplate: "", personalityInstallPath: "", notes: [])
    controls = (try? DataFiles.load([ControlSpec].self, root.appendingPathComponent("data/controls.json"))) ?? []
    workDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("G7Pro Bluetooth Setup")
    try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    if controls.isEmpty { errorText = "Could not load data/controls.json next to the app. Reinstall the app." }
    DispatchQueue.global().async { let s = SystemState.sipEnabled(); DispatchQueue.main.async { self.sipEnabled = s } }
    FrameworkObserver.shared.onConnection = { [weak self] on in self?.frameworkSeesPad = on }
    FrameworkObserver.shared.onElement = { [weak self] name, dir in self?.frameworkEvent(name, dir) }
    FrameworkObserver.shared.start()
    // Developer convenience: `G7ProSetup --step capture` jumps straight to a step (permission must already be granted).
    if let i = CommandLine.arguments.firstIndex(of: "--step"), i + 1 < CommandLine.arguments.count,
       let s = Step.allCases.first(where: { $0.title.lowercased().hasPrefix(CommandLine.arguments[i + 1].lowercased()) }) {
      refreshPermission(); step = s
    }
  }

  // MARK: permission + HID
  func requestPermission() {
    inputMonitoring = HIDSource.requestInputMonitoring()
    if !inputMonitoring { SystemState.openInputMonitoringSettings() }
    refreshPermission()
  }
  func refreshPermission() { inputMonitoring = HIDSource.hasInputMonitoring(); if inputMonitoring { startHID() } }
  func startHID() {
    let src = HIDSource.shared
    src.onDeviceChange = { [weak self] on in DispatchQueue.main.async { self?.padConnected = on; self?.firmware = src.firmwareVersion } }
    src.onEvent = { [weak self] ev in self?.rawEvent(ev) }
    src.start(vendorID: device.vendorID, productID: device.productID)
    padConnected = src.device != nil; firmware = src.firmwareVersion
  }

  // MARK: capture
  func beginCapture() { captures = []; currentIndex = 0; step = .capture }
  private func rawEvent(_ ev: RawEvent) {
    if let other = ev.describeOther, ev.value != 0 { lastRawText = other }
    else if ev.usageType != 0 && (ev.usageType != 2 || ev.value < 48 || ev.value > 208) && ev.value != 0 {
      lastRawText = "usage page \(ev.usagePage) usage \(ev.usage) value \(ev.value)"
    }
    // which captured control does this event belong to? (for lighting and for verify)
    if let cap = captures.first(where: { $0.cookie == ev.cookie && (ev.usageType != 3 || hatDir(ev.value) == hatDir(for: $0.controlID)) &&
                                          (ev.usageType != 2 || axisDir(ev.value) == axisDir(for: $0.controlID)) }),
       PressDetector.matches(ev, kind: controls.first { $0.id == cap.controlID }?.kind ?? "") {
      litControl = cap.controlID; lastRawControlID = cap.controlID; lastRawAt = Date()
    }
    guard step == .capture, let c = current, PressDetector.matches(ev, kind: c.kind) else { return }
    if c.kind == "axis" && axisDir(ev.value) != expectedAxisDir(c) { return }   // wrong direction on the right axis: ignore
    if c.kind == "hat" && hatDir(ev.value) != hatDir(for: c.id) { return }
    captures.removeAll { $0.controlID == c.id }
    captures.append(Capture(controlID: c.id, usageType: ev.usageType, cookie: ev.cookie, usagePage: ev.usagePage, usage: ev.usage, reportID: ev.reportID))
    litControl = c.id
    advance()
  }
  private func advance() {
    var i = currentIndex + 1
    while i < mappable.count, captures.contains(where: { $0.controlID == mappable[i].id }) { i += 1 }
    currentIndex = i
    if i >= mappable.count { review() }
  }
  func skip() { advance() }
  func undo() { guard let last = captures.popLast(), let i = mappable.firstIndex(where: { $0.id == last.controlID }) else { return }; currentIndex = i }
  func recapture(_ id: String) { guard step == .capture || step == .review, let i = mappable.firstIndex(where: { $0.id == id }) else { return }; captures.removeAll { $0.controlID == id }; currentIndex = i; step = .capture }
  // axis direction: "up" = low value on Y, "right" = high value on X (HID convention: 0 = up/left)
  private func axisDir(_ v: Int) -> String { v < 48 ? "low" : "high" }
  private func expectedAxisDir(_ c: ControlSpec) -> String { c.gcDir == "up" || c.gcDir == "left" ? "low" : "high" }
  private func axisDir(for id: String) -> String { expectedAxisDir(controls.first { $0.id == id }!) }
  private func hatDir(_ v: Int) -> String { switch v { case 0, 1: return "up"; case 2, 3: return "right"; case 4, 5: return "down"; case 6, 7: return "left"; default: return "" } }
  private func hatDir(for id: String) -> String { controls.first { $0.id == id }?.gcDir ?? "" }

  // MARK: review + write
  func review() {
    step = .review
    let template = resourceRoot.appendingPathComponent(device.personalityTemplate)
    do {
      let (data, ch) = try PersonalityWriter.build(template: template, captures: captures, elements: HIDSource.shared.elements, controls: controls, productName: "GameSir-G7 Pro")
      try data.write(to: personalityURL)
      changes = ch
      indexTable = captures.compactMap { cap in
        guard let c = controls.first(where: { $0.id == cap.controlID }), let idx = IndexRule.daemonIndex(usageType: cap.usageType, cookie: cap.cookie, in: HIDSource.shared.elements) else { return nil }
        return (c.prompt, "raw usage \(cap.usage) → \(IndexRule.predicate(usageType: cap.usageType, index: idx))")
      }
      try? MappingFile(device: device.name, vendorID: device.vendorID, productID: device.productID, firmwareVersion: firmware, capturedAt: Date(), captures: captures).save(to: workDir)
    } catch { errorText = "Could not build the personality: \(error.localizedDescription)" }
  }

  // MARK: install
  func install() {
    installing = true; installOutput = ""
    var args = ["install", "--personality", personalityURL.path, "--backup-dir", workDir.appendingPathComponent("backup").path]
    if let v = firmware { args += ["--version", String(v)] }
    DispatchQueue.global().async {
      let (ok, out) = Installer.runAsAdmin(executable: self.cliURL, args: args)
      DispatchQueue.main.async { self.installing = false; self.installOutput = out; self.installed = ok; if ok { self.sipEnabled = SystemState.sipEnabled() } }
    }
  }
  func uninstall() {
    installing = true
    DispatchQueue.global().async {
      let (ok, out) = Installer.runAsAdmin(executable: self.cliURL, args: ["uninstall"])
      DispatchQueue.main.async { self.installing = false; self.installOutput = out; if ok { self.installed = false } }
    }
  }

  // MARK: verify
  func beginVerify() { verify = VerifyState(); step = .verify }
  private func frameworkEvent(_ name: String, _ dir: String?) {
    lastFrameworkText = dir.map { "\(name) \($0)" } ?? name
    guard step == .verify, let pressed = lastRawControlID, Date().timeIntervalSince(lastRawAt) < 1.0,
          let c = controls.first(where: { $0.id == pressed }) else { return }
    let expected = c.gcDir.map { "\(c.gc) \($0)" } ?? c.gc
    let seen = dir.map { "\(name) \($0)" } ?? name
    if seen == expected { verify.ok.insert(c.id); verify.bad.removeValue(forKey: c.id) }
    else { verify.bad[c.id] = seen }
  }
}

// MARK: - Views

struct WizardView: View {
  @EnvironmentObject var wiz: Wizard
  var body: some View {
    VStack(spacing: 0) {
      StepBar().padding(.horizontal).padding(.top, 10)
      Divider().padding(.top, 8)
      Group {
        switch wiz.step {
        case .welcome: WelcomeView()
        case .permission: PermissionView()
        case .detect: DetectView()
        case .capture: CaptureView()
        case .review: ReviewView()
        case .install: InstallView()
        case .verify: VerifyView()
        case .done: DoneView()
        }
      }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(20)
      if let e = wiz.errorText { Text(e).foregroundStyle(.red).padding(.bottom, 8) }
    }
  }
}

struct StepBar: View {
  @EnvironmentObject var wiz: Wizard
  var body: some View {
    HStack(spacing: 6) {
      ForEach(Step.allCases, id: \.rawValue) { s in
        Text(s.title).font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
          .background(s == wiz.step ? Color.accentColor : (s.rawValue < wiz.step.rawValue ? Color.green.opacity(0.35) : Color.gray.opacity(0.15)))
          .foregroundStyle(s == wiz.step ? .white : .primary).clipShape(Capsule())
      }
      Spacer()
    }
  }
}

struct Nav: View {
  var back: (() -> Void)? = nil; var next: (() -> Void)? = nil; var nextTitle = "Continue"; var nextEnabled = true
  var body: some View {
    HStack { if let b = back { Button("Back", action: b) }; Spacer(); if let n = next { Button(nextTitle, action: n).keyboardShortcut(.defaultAction).disabled(!nextEnabled) } }
  }
}

struct WelcomeView: View {
  @EnvironmentObject var wiz: Wizard
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Make the \(wiz.device.name) work on macOS").font(.title)
      Text("macOS pairs this pad but no game sees it, because the pad is missing from Apple's controller database. This wizard captures how your pad's buttons are wired, builds the missing database entry, installs it, and verifies the result. Nothing runs in the background afterwards.")
      GroupBox("Before you start: System Integrity Protection must be off during the install step") {
        VStack(alignment: .leading, spacing: 6) {
          switch wiz.sipEnabled {
          case .some(false): Label("SIP is currently disabled. You can go through the whole wizard.", systemImage: "checkmark.circle").foregroundStyle(.green)
          case .some(true):
            Label("SIP is enabled. You can capture and review now, but the install step will be blocked.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
          case .none: Text("Could not read SIP status.")
          }
          Text("To disable it on Apple Silicon: shut down, hold the power button until “Loading startup options”, choose Options › Continue, then Utilities › Terminal and run:  csrutil disable  — then restart. (Intel: restart holding Cmd-R.) You will turn it back on at the end with  csrutil enable.").font(.callout).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
      }
      Spacer()
      Nav(next: { wiz.step = .permission })
    }
  }
}

struct PermissionView: View {
  @EnvironmentObject var wiz: Wizard
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Allow this app to read the controller").font(.title2)
      Text("Reading the pad's raw button stream needs the Input Monitoring permission. macOS will ask; if it doesn't, the Settings pane opens so you can add this app yourself. Nothing is recorded except which button you press during the wizard.")
      HStack {
        Button("Request permission") { wiz.requestPermission() }
        Button("Open Input Monitoring settings") { SystemState.openInputMonitoringSettings() }
        Button("Re-check") { wiz.refreshPermission() }
      }
      Label(wiz.inputMonitoring ? "Granted" : "Not granted yet", systemImage: wiz.inputMonitoring ? "checkmark.circle" : "xmark.circle").foregroundStyle(wiz.inputMonitoring ? .green : .red)
      Text("If you granted it in Settings but it still says not granted, quit and reopen the app.").font(.callout).foregroundStyle(.secondary)
      Spacer()
      Nav(back: { wiz.step = .welcome }, next: { wiz.startHID(); wiz.step = .detect }, nextEnabled: wiz.inputMonitoring)
    }.onAppear { wiz.refreshPermission() }
  }
}

struct DetectView: View {
  @EnvironmentObject var wiz: Wizard
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Connect the pad over Bluetooth").font(.title2)
      Text("Set the pad's mode switch to Bluetooth, power it on, and pair it in System Settings › Bluetooth if you haven't. The light should be solid, not blinking.")
      Label(wiz.padConnected ? "Pad found (firmware version \(wiz.firmware ?? 0))" : "Waiting for the pad…", systemImage: wiz.padConnected ? "gamecontroller.fill" : "gamecontroller").foregroundStyle(wiz.padConnected ? .green : .secondary)
      Label(wiz.frameworkSeesPad ? "macOS already treats it as a game controller (an entry is installed). You can re-capture to fix the mapping, or skip to Verify." : "macOS does not treat it as a game controller yet (expected before install).", systemImage: wiz.frameworkSeesPad ? "checkmark.circle" : "info.circle").foregroundStyle(.secondary)
      Spacer()
      HStack { Button("Back") { wiz.step = .permission }; Spacer()
        if wiz.frameworkSeesPad { Button("Skip to Verify") { wiz.beginVerify() } }
        Button("Start capture") { wiz.beginCapture() }.keyboardShortcut(.defaultAction).disabled(!wiz.padConnected) }
    }
  }
}

struct CaptureView: View {
  @EnvironmentObject var wiz: Wizard
  var body: some View {
    HStack(alignment: .top, spacing: 20) {
      VStack(alignment: .leading, spacing: 10) {
        if let c = wiz.current {
          Text("Press \(c.prompt)").font(.title)
          Text("\(wiz.currentIndex + 1) of \(wiz.mappable.count). Press it once, then release.").foregroundStyle(.secondary)
        } else { Text("All captured").font(.title) }
        HStack { Button("Undo last") { wiz.undo() }.disabled(!wiz.canUndo); Button("Skip this one") { wiz.skip() }; Button("Start over") { wiz.beginCapture() } }
        Text("Click any control in the picture to capture it again. ⌘Z undoes the last capture.").font(.callout).foregroundStyle(.secondary)
        Divider()
        Text("Last raw event: \(wiz.lastRawText)").font(.caption.monospaced()).foregroundStyle(.secondary)
        Spacer()
        Nav(back: { wiz.step = .detect })
      }.frame(width: 300)
      ControllerView(target: wiz.current?.id, lit: wiz.litControl, captured: Set(wiz.captures.map { $0.controlID }), ok: [], bad: [:]) { wiz.recapture($0) }
    }
  }
}

struct ReviewView: View {
  @EnvironmentObject var wiz: Wizard
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Computed mapping").font(.title2)
      Text("Each captured control's raw HID usage, and the index macOS will use for it. The rule: macOS numbers same-type usages across the whole device sorted by usage value, so this pad's mouse collection interleaves with the gamepad's buttons and axes.").font(.callout).foregroundStyle(.secondary)
      List { ForEach(wiz.indexTable, id: \.0) { row in HStack { Text(row.0).frame(width: 220, alignment: .leading); Text(row.1).font(.caption.monospaced()) } } }
      Text(wiz.changes.isEmpty ? "No differences from the bundled personality." : "\(wiz.changes.count) predicate(s) differ from the bundled personality.").font(.callout)
      Text("Written to \(wiz.personalityURL.path)").font(.caption).foregroundStyle(.secondary)
      Nav(back: { wiz.currentIndex = max(0, wiz.mappable.count - 1); wiz.step = .capture }, next: { wiz.step = .install }, nextTitle: "Install")
    }
  }
}

struct InstallView: View {
  @EnvironmentObject var wiz: Wizard
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Install into Apple's controller database").font(.title2)
      Text("This writes the entry and personality into the GameControllers-Custom bundle and restarts the controller daemon. macOS will ask for an administrator password.")
      switch wiz.sipEnabled {
      case .some(true): Label("SIP is enabled, so the write will be refused. Disable it from Recovery (see the Welcome step) and come back; your capture is saved.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
      case .some(false): Label("SIP is disabled. Ready to install.", systemImage: "checkmark.circle").foregroundStyle(.green)
      case .none: Text("SIP status unknown.")
      }
      HStack { Button(wiz.installing ? "Installing…" : (wiz.installed ? "Install again" : "Install")) { wiz.install() }.disabled(wiz.installing || wiz.sipEnabled == true)
        Button("Re-check SIP") { wiz.sipEnabled = SystemState.sipEnabled() } }
      ScrollView { Text(wiz.installOutput).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading) }.frame(minHeight: 120).background(Color.gray.opacity(0.08))
      if wiz.installed { Label(wiz.frameworkSeesPad ? "macOS now reports the pad as a game controller." : "Installed. Waiting for macOS to pick the pad up…", systemImage: wiz.frameworkSeesPad ? "checkmark.circle" : "clock").foregroundStyle(wiz.frameworkSeesPad ? .green : .secondary) }
      Spacer()
      Nav(back: { wiz.step = .review }, next: { wiz.beginVerify() }, nextTitle: "Verify", nextEnabled: wiz.installed || wiz.frameworkSeesPad)
    }
  }
}

struct VerifyView: View {
  @EnvironmentObject var wiz: Wizard
  var body: some View {
    HStack(alignment: .top, spacing: 20) {
      VStack(alignment: .leading, spacing: 10) {
        Text("Verify").font(.title)
        Text("Press every button and move the sticks. Green means macOS delivered the right control to apps; red means it delivered something else.")
        Text("Verified: \(wiz.verify.ok.count) of \(wiz.mappable.count)").font(.headline)
        if !wiz.verify.bad.isEmpty { ForEach(wiz.verify.bad.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in Text("\(wiz.controls.first { $0.id == k }?.prompt ?? k): macOS saw \(v)").foregroundStyle(.red).font(.callout) } }
        Divider()
        Text("Last from macOS: \(wiz.lastFrameworkText)").font(.caption.monospaced()).foregroundStyle(.secondary)
        Text("Last raw: \(wiz.lastRawText)").font(.caption.monospaced()).foregroundStyle(.secondary)
        if !wiz.frameworkSeesPad { Label("macOS is not reporting the pad as a game controller right now.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
        Spacer()
        HStack { Button("Back") { wiz.step = .install }; Button("Re-capture a control") { wiz.step = .capture }; Spacer(); Button("Finish") { wiz.step = .done }.keyboardShortcut(.defaultAction) }
      }.frame(width: 320)
      ControllerView(target: nil, lit: wiz.litControl, captured: [], ok: wiz.verify.ok, bad: wiz.verify.bad) { _ in }
    }
  }
}

struct DoneView: View {
  @EnvironmentObject var wiz: Wizard
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Done").font(.title)
      Text("The pad should now appear in System Settings › General › Game Controllers and work in games that use Apple's GameController framework, including GeForce NOW.")
      GroupBox("Turn System Integrity Protection back on") {
        Text("Restart into Recovery the same way as before, open Utilities › Terminal, run  csrutil enable  and restart. The installed files stay in place.").frame(maxWidth: .infinity, alignment: .leading).padding(4)
      }
      Text("If a macOS update replaces Apple's controller database, or you update the pad's firmware, run this wizard again. Your capture is saved in \(wiz.workDir.path).").font(.callout).foregroundStyle(.secondary)
      HStack { Button("Uninstall (remove the entry)") { wiz.uninstall() }.disabled(wiz.installing || wiz.sipEnabled == true); Spacer(); Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut(.defaultAction) }
      if !wiz.installOutput.isEmpty { ScrollView { Text(wiz.installOutput).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 120) }
      Spacer()
    }
  }
}

// MARK: - Controller drawing: the manual's line art (data/controller-front.svg) with hit targets from controls.json

struct ControllerView: View {
  @EnvironmentObject var wiz: Wizard
  let target: String?; let lit: String?; let captured: Set<String>; let ok: Set<String>; let bad: [String: String]
  let onClick: (String) -> Void
  @Environment(\.colorScheme) private var scheme

  private static let art: NSImage? = {
    let candidates = [Bundle.main.resourceURL?.appendingPathComponent("data/controller-front.svg")].compactMap { $0 }
    for u in candidates { if let i = NSImage(contentsOf: u) { i.isTemplate = true; return i } }
    return nil
  }()
  private var aspect: CGFloat { (Self.art?.size.height ?? 52.5) / (Self.art?.size.width ?? 76.5) }

  /// One hit target per physical position; directional controls share their stick/pad.
  private var bases: [ControlSpec] {
    var seen = Set<String>(); var out: [ControlSpec] = []
    for c in wiz.controls { let key = "\(c.x),\(c.y)"; if !seen.contains(key) { seen.insert(key); out.append(c) } }
    return out
  }
  private func siblings(_ c: ControlSpec) -> [ControlSpec] { wiz.controls.filter { $0.x == c.x && $0.y == c.y } }

  var body: some View {
    GeometryReader { g in
      let w = g.size.width, h = w * aspect
      ZStack(alignment: .topLeading) {
        if let art = Self.art {
          Image(nsImage: art).resizable().interpolation(.high)
            .foregroundStyle(scheme == .dark ? Color.white.opacity(0.85) : Color.black.opacity(0.85))
            .frame(width: w, height: h)
        } else {
          RoundedRectangle(cornerRadius: 24).fill(Color.gray.opacity(0.15)).frame(width: w, height: h)
        }
        ForEach(bases) { c in
          let sibs = siblings(c)
          let st = stateFor(sibs)
          let dir = sibs.first { $0.id == target }?.gcDir ?? sibs.first { $0.id == lit }?.gcDir
          let d = diameter(c.shape, w)
          ZStack {
            shape(c.shape).fill(st.fill)
            shape(c.shape).stroke(st.stroke, lineWidth: st.width)
            if let text = dir.map({ arrow($0) }) ?? (c.label.isEmpty ? nil : c.label) {
              Text(text).font(.system(size: max(9, d * 0.42), weight: .bold)).foregroundStyle(st.text)
            }
          }
          .frame(width: d * (c.shape == "wide" ? 2.2 : c.shape == "pill" ? 1.6 : 1), height: d)
          .position(x: c.x * w, y: c.y * h)
          .contentShape(Rectangle())
          .onTapGesture { onClick(sibs.first { $0.isMappable }?.id ?? c.id) }
          .help(sibs.map { $0.prompt }.joined(separator: " / "))
        }
      }.frame(width: w, height: h)
    }
  }
  private func arrow(_ d: String) -> String { ["up": "↑", "down": "↓", "left": "←", "right": "→"][d] ?? d }
  private func diameter(_ shape: String, _ w: CGFloat) -> CGFloat {
    switch shape { case "stick": return w * 0.135; case "dpad": return w * 0.14; case "small", "circle-sm": return w * 0.05; case "pill": return w * 0.04; case "wide": return w * 0.045; default: return w * 0.065 }
  }
  private func shape(_ s: String) -> AnyShape {
    switch s { case "small", "wide": return AnyShape(RoundedRectangle(cornerRadius: 8)); case "pill": return AnyShape(Capsule()); default: return AnyShape(Circle()) }
  }
  private struct S { var fill: Color; var stroke: Color; var width: CGFloat; var text: Color }
  private func stateFor(_ sibs: [ControlSpec]) -> S {
    let ids = Set(sibs.map { $0.id })
    if let t = target, ids.contains(t) { return S(fill: .accentColor.opacity(0.75), stroke: .accentColor, width: 3, text: .white) }
    if let l = lit, ids.contains(l) { return S(fill: .yellow.opacity(0.7), stroke: .orange, width: 3, text: .black) }
    if !ids.isDisjoint(with: Set(bad.keys)) { return S(fill: .red.opacity(0.55), stroke: .red, width: 2, text: .white) }
    if !ids.isDisjoint(with: ok) { return S(fill: .green.opacity(0.55), stroke: .green, width: 2, text: .white) }
    if !ids.isDisjoint(with: captured) { return S(fill: .green.opacity(0.18), stroke: .green.opacity(0.7), width: 1.5, text: .primary) }
    if sibs.allSatisfy({ !$0.isMappable }) { return S(fill: .clear, stroke: .gray.opacity(0.35), width: 1, text: .secondary) }
    return S(fill: .clear, stroke: .gray.opacity(0.6), width: 1, text: .primary)
  }
}
