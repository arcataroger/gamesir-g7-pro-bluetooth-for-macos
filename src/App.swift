// App.swift
//
// The SwiftUI wizard: the only user interface. It walks a first-time user from a paired-but-invisible pad
// to a working controller in eight steps, and it does nothing the core does not decide.
//
//   Wizard          Observable state for the whole flow: step, permissions, captures, verify state.
//                   `advanceIfDone()` skips steps whose condition already holds. `isSatisfied()` and
//                   `isDone()` drive the rail; a later satisfied step marks earlier ones done.
//   StepRail        The left column: steps with done/current/pending states, plus the red Uninstall item.
//   Page, Nav       Shared page skeleton: headline, one paragraph, content, footer buttons.
//   *View           One view per step: Welcome, Permission, Detect, Capture, Review, Install, Verify, Done,
//                   and Uninstall. Satisfied steps show one affirmative line instead of their how-to.
//   ControllerView  The pad drawing: data/controller-front.svg with hit targets from data/controls.json.
//   ControlTarget   One target's rendering: pulse, captured state, directional edge highlight, analog travel.
//   Glyphs          Trigger and bumper silhouettes from data/callout-glyphs.json.
//
// Developer flags: `--step <name>` opens a step directly; `--control <id>` picks the capture prompt.
// The bare Swift compiler in the Command Line Tools cannot expand the @State macro, so the pulse runs on a
// TimelineView instead of view state. Keep view bodies small: the CI compiler is older than a dev Mac's.
import SwiftUI
import AppKit

/// Trims the menu bar to what this app actually offers: the app menu, Edit (Undo Capture), Window, Help.
final class MenuTrimmer: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ n: Notification) { trim(); for d in [0.2, 0.8, 2.0] { DispatchQueue.main.asyncAfter(deadline: .now() + d) { self.trim() } } }
  func applicationDidBecomeActive(_ n: Notification) { trim() }
  private func trim() {
    guard let menu = NSApp.mainMenu else { return }
    for title in ["File", "View"] { if let item = menu.items.first(where: { $0.title == title }) { menu.removeItem(item) } }
  }
}

@main
struct G7ProSetupApp: App {
  @NSApplicationDelegateAdaptor(MenuTrimmer.self) private var delegate
  @StateObject private var wiz = Wizard()
  var body: some Scene {
    WindowGroup("GameSir G7 Pro Bluetooth Setup") {
      WizardView().environmentObject(wiz).font(.system(size: 17)).frame(minWidth: 1040, minHeight: 720)
    }
    .windowResizability(.contentSize)
    .commands {
      CommandGroup(replacing: .newItem) {}
      CommandGroup(replacing: .saveItem) {}
      CommandGroup(replacing: .pasteboard) {}
      CommandGroup(replacing: .textEditing) {}
      CommandGroup(replacing: .toolbar) {}
      CommandGroup(replacing: .sidebar) {}
      CommandGroup(replacing: .undoRedo) { Button("Undo Capture") { wiz.undo() }.keyboardShortcut("z", modifiers: .command).disabled(!wiz.canUndo) }
      CommandGroup(replacing: .help) {
        Button("GameSir G7 Pro Bluetooth Setup Help") { NSWorkspace.shared.open(URL(string: "https://github.com/arcataroger/gamesir-g7-pro-bluetooth-for-macos#readme")!) }
      }
    }
  }
}

enum Step: Int, CaseIterable { case welcome, permission, detect, capture, review, install, verify, done
  var title: String { ["Welcome", "Permission", "Find the pad", "Capture", "Review", "Install", "Verify", "Finish"][rawValue] } }

struct VerifyState { var ok = Set<String>(); var bad: [String: String] = [:] }

final class Wizard: ObservableObject {
  @Published var step: Step = .welcome
  @Published var sipEnabled: Bool? = nil
  @Published var inputMonitoring = false
  @Published var padConnected = false
  @Published var frameworkSeesPad = false
  @Published var firmware: Int? = nil
  @Published var captures: [Capture] = []
  @Published var currentIndex = 0
  @Published var pendingConfirm: Capture? = nil      // a press that disagreed with the reference mapping; awaiting a second press
  /// The verified reference mapping (data/reference-mapping.json): raw usage per control, used to spot mis-presses.
  private lazy var reference: [String: (UInt32, UInt32)] = {
    guard let u = Bundle.main.resourceURL?.appendingPathComponent("data/reference-mapping.json"),
          let d = try? Data(contentsOf: u), let m = try? JSONDecoder().decode(MappingFile.self, from: d) else { return [:] }
    return Dictionary(uniqueKeysWithValues: m.captures.map { ($0.controlID, ($0.usagePage, $0.usage)) })
  }()
  @Published var lastRawText = ""
  @Published var litControl: String? = nil            // control lit by the most recent raw event
  @Published var changes: [PersonalityWriter.Change] = []
  @Published var indexTable: [(String, String)] = []
  @Published var installOutput = ""
  @Published var installing = false
  @Published var installed = false
  @Published var verify = VerifyState()
  @Published var verifyHeld: [String: Held] = [:]   // controls macOS is currently delivering (Verify)
  struct Held { var dir: String?; var value: Double = 1; var x: Double = 0; var y: Double = 0 }
  @Published var verifySeen = false
  @Published var lastFrameworkText = ""
  @Published var errorText: String? = nil
  @Published var autoAdvance = true          // cleared when the user navigates backwards by hand
  @Published var entryInstalled = false      // the database already has an entry for this pad
  @Published var permissionRequested = false // after asking once, nothing changes until the app is relaunched
  @Published var uninstallMode = false       // the red rail item: a screen of its own, outside the step sequence
  @Published var xboxIdentity = true { didSet { if step == .install || step == .review { writePersonality() } } }
  @Published var reportedCategory: String? = nil   // what macOS says the pad is, after install

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
  private var rawActive: [UInt32: Bool] = [:]     // per HID element: was it active at the last report? (edge detection)

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
    refreshSystem()
    Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refreshSystem() }
    FrameworkObserver.shared.onConnection = { [weak self] on in self?.frameworkSeesPad = on; self?.reportedCategory = on ? FrameworkObserver.shared.reportedCategory : nil; self?.advanceIfDone() }
    FrameworkObserver.shared.onElement = { [weak self] name, dir in self?.frameworkEvent(name, dir) }
    FrameworkObserver.shared.onAnalog = { [weak self] name, value, x, y in
      guard let self, self.step == .verify else { return }
      for (id, h) in self.verifyHeld where self.controls.first(where: { $0.id == id })?.gc == name { self.verifyHeld[id] = Held(dir: h.dir, value: value, x: x, y: y) }
    }
    FrameworkObserver.shared.onRelease = { [weak self] name in
      guard let self, self.step == .verify else { return }
      for (id, _) in self.verifyHeld where self.controls.first(where: { $0.id == id })?.gc == name { self.verifyHeld.removeValue(forKey: id) }
    }
    FrameworkObserver.shared.start()
    // Developer convenience: `G7ProSetup --step capture` jumps straight to a step (permission must already be granted).
    if let i = CommandLine.arguments.firstIndex(of: "--step"), i + 1 < CommandLine.arguments.count,
       let s = Step.allCases.first(where: { $0.title.lowercased().hasPrefix(CommandLine.arguments[i + 1].lowercased()) }) {
      autoAdvance = false; refreshPermission(); step = s
      if let j = CommandLine.arguments.firstIndex(of: "--control"), j + 1 < CommandLine.arguments.count,
         let k = mappable.firstIndex(where: { $0.id == CommandLine.arguments[j + 1] }) { currentIndex = k }
    }
  }

  func refreshSystem() {
    DispatchQueue.global().async {
      let sip = SystemState.sipEnabled(), inst = Database.isInstalled(device: self.device)
      DispatchQueue.main.async { self.sipEnabled = sip; self.entryInstalled = inst; self.advanceIfDone() }
    }
  }
  func back(_ to: Step) { autoAdvance = false; step = to }
  /// Done for the rail: satisfied itself, or implied by a later step already being satisfied (e.g. an install on disk).
  func isDone(_ s: Step) -> Bool { Step.allCases.filter { $0.rawValue >= s.rawValue && $0 != .done }.contains { isSatisfied($0) } }
  /// Whether a step's condition currently holds, independent of where the user is.
  func isSatisfied(_ s: Step) -> Bool {
    switch s {
    case .welcome: return sipEnabled == false
    case .permission: return inputMonitoring
    case .detect: return padConnected
    case .capture: return !mappable.isEmpty && mappable.allSatisfy { m in captures.contains { $0.controlID == m.id } }
    case .review: return !captures.isEmpty && FileManager.default.fileExists(atPath: personalityURL.path)
    case .install: return installed || (entryInstalled && frameworkSeesPad)
    case .verify: return verifySeen
    case .done: return false
    }
  }
  /// Called whenever something completes; moves forward past steps that are already satisfied.
  func advanceIfDone() {
    guard autoAdvance else { return }
    switch step {
    case .welcome: if sipEnabled == false { step = .permission; advanceIfDone() }
    case .permission: if inputMonitoring { startHID(); step = .detect; advanceIfDone() }   // never checks; the step requests once
    case .detect:
      if padConnected {
        if entryInstalled && frameworkSeesPad && FileManager.default.fileExists(atPath: MappingFile.url(in: workDir).path) { beginVerify() }
        else { beginCapture() }
      }
    default: break
    }
  }

  // MARK: permission + HID
  func requestPermission() {
    // macOS shows its prompt once per process. Later clicks go straight to the Input Monitoring pane.
    // The grant only takes effect for a fresh process, so there is nothing to poll for afterwards.
    if permissionRequested { SystemState.openInputMonitoringSettings(); return }
    // A request made before the app is active can be dropped silently by macOS; wait for activation first.
    guard NSApp.isActive else {
      var token: NSObjectProtocol?
      token = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
        if let t = token { NotificationCenter.default.removeObserver(t) }
        self?.requestPermission()
      }
      return
    }
    permissionRequested = true
    inputMonitoring = HIDSource.requestInputMonitoring()
    if inputMonitoring { startHID(); advanceIfDone() }
  }
  private var lastPermissionCheck = Date.distantPast
  /// One TCC round-trip at most every 2 s: on this macOS a status check can itself surface the prompt.
  func refreshPermission() {
    guard Date().timeIntervalSince(lastPermissionCheck) > 2 else { return }
    lastPermissionCheck = Date()
    inputMonitoring = HIDSource.hasInputMonitoring(); if inputMonitoring { startHID() }; advanceIfDone()
  }
  func startHID() {
    let src = HIDSource.shared
    src.onDeviceChange = { [weak self] on in DispatchQueue.main.async { self?.padConnected = on; self?.firmware = src.firmwareVersion; self?.advanceIfDone() } }
    src.onEvent = { [weak self] ev in self?.rawEvent(ev) }
    src.start(vendorID: device.vendorID, productID: device.productID)
    padConnected = src.device != nil; firmware = src.firmwareVersion
  }

  // MARK: capture
  func beginCapture() { captures = []; currentIndex = 0; pendingConfirm = nil; step = .capture }
  private func rawEvent(_ ev: RawEvent) {
    if step == .verify {
      if ev.usagePage == 12 && ev.usage == 0x223 {          // AC Home = Xbox button
        if ev.value != 0 { verifyHeld["home"] = Held(dir: nil); lastFrameworkText = "Xbox button. macOS keeps this as the system button (it opens the Game Overlay); games don't receive it." }
        else { verifyHeld.removeValue(forKey: "home") }
      } else if ev.usagePage == 7 && ev.usage == 0x46 {     // keyboard PrintScreen = Share
        if ev.value != 0 { verifyHeld["share"] = Held(dir: nil); lastFrameworkText = "Share. The pad sends this as a keyboard keystroke, not a gamepad button, so games don't see it." }
        else { verifyHeld.removeValue(forKey: "share") }
      }
    }
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
    // Edge detection: a control counts only when it goes from rest to active, so a held trigger, stick or button
    // can't satisfy the next prompt with its continuing stream of reports.
    let activeNow = PressDetector.matches(ev, kind: c_kindFor(ev))
    let wasActive = rawActive[ev.cookie] ?? false
    rawActive[ev.cookie] = activeNow
    guard step == .capture, let c = current, activeNow, !wasActive, PressDetector.matches(ev, kind: c.kind) else { return }
    if c.kind == "axis" && axisDir(ev.value) != expectedAxisDir(c) { return }   // wrong direction on the right axis: ignore
    if c.kind == "hat" && hatDir(ev.value) != hatDir(for: c.id) { return }
    let cap = Capture(controlID: c.id, usageType: ev.usageType, cookie: ev.cookie, usagePage: ev.usagePage, usage: ev.usage, reportID: ev.reportID)
    if let pending = pendingConfirm {
      // second press for a control that disagreed with the reference
      pendingConfirm = nil
      if pending.usagePage == cap.usagePage && pending.usage == cap.usage {
        captures.removeAll { $0.controlID == c.id }; captures.append(cap); litControl = c.id; advance()   // consistent: a real difference
      }
      return   // inconsistent: the first was a mis-press; prompt for this control again from scratch
    }
    if let ref = reference[c.id], ref.0 != cap.usagePage || ref.1 != cap.usage {
      pendingConfirm = cap   // ask once more before accepting a press that differs from the reference
      return
    }
    captures.removeAll { $0.controlID == c.id }
    captures.append(cap)
    litControl = c.id
    advance()
  }
  /// The kind an element belongs to, for rest/active tracking regardless of what is being prompted.
  private func c_kindFor(_ ev: RawEvent) -> String {
    switch ev.usageType { case 1: return "button"; case 3: return "hat"; case 2: return ev.usagePage == 2 ? "trigger" : "axis"; default: return "" }
  }
  private func advance() {
    var i = currentIndex + 1
    while i < mappable.count, captures.contains(where: { $0.controlID == mappable[i].id }) { i += 1 }
    currentIndex = i
    if i >= mappable.count { review() }
  }
  func undo() { pendingConfirm = nil; guard let last = captures.popLast(), let i = mappable.firstIndex(where: { $0.id == last.controlID }) else { return }; currentIndex = i }
  func recapture(_ id: String) { guard step == .capture || step == .review, let i = mappable.firstIndex(where: { $0.id == id }) else { return }; pendingConfirm = nil; captures.removeAll { $0.controlID == id }; currentIndex = i; step = .capture }
  // axis direction: "up" = low value on Y, "right" = high value on X (HID convention: 0 = up/left)
  private func axisDir(_ v: Int) -> String { v < 48 ? "low" : "high" }
  private func expectedAxisDir(_ c: ControlSpec) -> String { c.gcDir == "up" || c.gcDir == "left" ? "low" : "high" }
  private func axisDir(for id: String) -> String { expectedAxisDir(controls.first { $0.id == id }!) }
  private func hatDir(_ v: Int) -> String { switch v { case 0, 1: return "up"; case 2, 3: return "right"; case 4, 5: return "down"; case 6, 7: return "left"; default: return "" } }
  private func hatDir(for id: String) -> String { controls.first { $0.id == id }?.gcDir ?? "" }

  // MARK: review + write
  func review() { step = .review; writePersonality() }
  func writePersonality() {
    let template = resourceRoot.appendingPathComponent(device.personalityTemplate)
    do {
      let (data, ch) = try PersonalityWriter.build(template: template, captures: captures, elements: HIDSource.shared.elements, controls: controls,
                                                    productName: "GameSir-G7 Pro", productCategory: xboxIdentity ? "Xbox One" : "HID")
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
      DispatchQueue.main.async { self.installing = false; self.installOutput = out; if ok { self.installed = false; self.entryInstalled = false }; self.refreshSystem() }
    }
  }

  // MARK: verify
  func beginVerify() { verify = VerifyState(); verifyHeld = [:]; step = .verify }
  var verifyStatusText: String {
    let held = verifyHeld.keys.compactMap { id -> String? in
      guard let c = controls.first(where: { $0.id == id }) else { return nil }
      let base = c.prompt.components(separatedBy: " (").first ?? c.prompt
      let h = verifyHeld[id]!
      let pct = c.kind == "axis" || c.kind == "trigger" ? " \(Int((h.value * 100).rounded()))%" : ""
      if let d = h.dir { return base.replacingOccurrences(of: " UP", with: "").replacingOccurrences(of: " RIGHT", with: "") + " \(d)" + pct }
      return base + pct
    }.sorted()
    if !held.isEmpty { return "macOS sees: " + held.joined(separator: " + ") }
    if lastFrameworkText.contains(".") { return lastFrameworkText }
    return lastFrameworkText.isEmpty ? "Waiting for a press…" : "Released."
  }
  private func frameworkEvent(_ name: String, _ dir: String?) {
    lastFrameworkText = dir.map { "\(name) \($0)" } ?? name
    guard step == .verify else { return }
    verifySeen = true
    // which control did macOS deliver? match the framework element name (and direction for pads/sticks)
    let hit = controls.first { c in c.gc == name && (c.gcDir == nil || c.gcDir == dir) } ?? controls.first { $0.gc == name }
    if let h = hit { let prev = verifyHeld.first { entry in controls.first(where: { $0.id == entry.key })?.gc == name }?.value
      for (id, _) in verifyHeld where controls.first(where: { $0.id == id })?.gc == name { verifyHeld.removeValue(forKey: id) }
      verifyHeld[h.id] = Held(dir: dir, value: prev?.value ?? 1, x: prev?.x ?? 0, y: prev?.y ?? 0) }
  }
}

// MARK: - Views

struct WizardView: View {
  @EnvironmentObject var wiz: Wizard
  var body: some View {
    HStack(spacing: 0) {
      StepRail().frame(width: 236)
      Divider()
      Group {
        if wiz.uninstallMode { UninstallView() } else {
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
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(.horizontal, 40).padding(.top, 36).padding(.bottom, 28)
    }
    .overlay(alignment: .bottom) { if let e = wiz.errorText { Text(e).foregroundStyle(.red).padding(10).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10)).padding(.bottom, 12) } }
  }
}

/// Vertical list of steps, Setup-Assistant style. Done steps are clickable to look back.
struct StepRail: View {
  @EnvironmentObject var wiz: Wizard
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("G7 Pro Bluetooth Setup").font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
        .padding(.horizontal, 24).padding(.top, 28).padding(.bottom, 18)
      ForEach(Step.allCases, id: \.rawValue) { s in
        let done = wiz.isDone(s), current = s == wiz.step && !wiz.uninstallMode
        HStack(spacing: 12) {
          ZStack {
            Circle().fill(current ? Color.accentColor : (done ? Color.green : Color.clear)).frame(width: 22, height: 22)
            Circle().stroke(done || current ? Color.clear : Color.secondary.opacity(0.5), lineWidth: 1.5).frame(width: 22, height: 22)
            if done { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white) }
            else if current { Circle().fill(.white).frame(width: 7, height: 7) }
          }
          Text(s.title).font(.system(size: 17, weight: current ? .semibold : .regular))
            .foregroundStyle(current ? .primary : (done ? .primary : .secondary))
          Spacer()
        }
        .padding(.horizontal, 24).padding(.vertical, 9)
        .background(current ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { wiz.uninstallMode = false; if done || s.rawValue <= wiz.step.rawValue { wiz.back(s) } }
      }
      Spacer()
      if wiz.entryInstalled || wiz.uninstallMode {
      HStack(spacing: 12) {
        Image(systemName: "trash").font(.system(size: 15, weight: .semibold)).frame(width: 22, height: 22)   // same slot as the step circles
        Text("Uninstall").font(.system(size: 17, weight: wiz.uninstallMode ? .semibold : .regular))
        Spacer()
      }
      .foregroundStyle(.red)
      .padding(.horizontal, 24).padding(.vertical, 9)   // same row metrics as the steps
      .background(wiz.uninstallMode ? Color.red.opacity(0.12) : Color.clear)
      .contentShape(Rectangle())
      .onTapGesture { wiz.autoAdvance = false; wiz.uninstallMode = true }
      .padding(.bottom, 28 + 6)   // the content column's bottom padding, so it sits level with the Back button
      }
    }
    .background(Color.primary.opacity(0.035))
  }
}

/// Shared page skeleton: headline, one paragraph, content, footer.
struct Page<Content: View, Footer: View>: View {
  let title: String; let subtitle: String?; @ViewBuilder let content: () -> Content; @ViewBuilder let footer: () -> Footer
  init(_ title: String, _ subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content, @ViewBuilder footer: @escaping () -> Footer) {
    self.title = title; self.subtitle = subtitle; self.content = content; self.footer = footer
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(title).font(.system(size: 34, weight: .bold)).padding(.bottom, 10)
      if let st = subtitle { Text(st).font(.system(size: 17)).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: 640, minHeight: 46, alignment: .topLeading).padding(.bottom, 26) }
      content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      footer().padding(.top, 20)
    }
  }
}

struct Nav: View {
  var back: (() -> Void)? = nil; var next: (() -> Void)? = nil; var nextTitle = "Next"; var nextEnabled = true
  var body: some View {
    HStack {
      if let b = back { Button("Back", action: b).controlSize(.large) }
      Spacer()
      if let n = next { Button(nextTitle, action: n).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).controlSize(.large).disabled(!nextEnabled) }
    }
  }
}

/// A status line with the right icon and tint for the situation.
struct Status: View {
  enum Kind { case ok, warn, wait, info }
  let kind: Kind; let text: String
  init(_ kind: Kind, _ text: String) { self.kind = kind; self.text = text }
  var body: some View {
    Label(text, systemImage: kind == .ok ? "checkmark.circle.fill" : kind == .warn ? "exclamationmark.triangle.fill" : kind == .wait ? "clock" : "info.circle")
      .font(.system(size: 17, weight: .medium))
      .foregroundStyle(kind == .ok ? Color.green : kind == .warn ? Color.orange : Color.secondary)
  }
}

/// The pad as hero: dimmed until `lit`, then full. Used on the non-capture steps.
struct HeroPad: View {
  let lit: Bool
  var body: some View {
    ControllerView(target: nil, captured: [], ok: [], bad: [:], showTargets: false) { _ in }
      .opacity(lit ? 1 : 0.28)
      .animation(.easeOut(duration: 0.6), value: lit)
      .frame(maxWidth: 720, maxHeight: 440)
  }
}

struct WelcomeView: View {
  @EnvironmentObject var wiz: Wizard
  var body: some View {
    Page("Make your G7 Pro work over Bluetooth", wiz.sipEnabled == false ? nil : "macOS pairs this pad but games can't see it, because it's missing from Apple's controller list. This wizard records how your pad's buttons are wired, adds the missing entry, and checks the result. Nothing keeps running afterwards.") {
      VStack(alignment: .leading, spacing: 18) {
        switch wiz.sipEnabled {
        case .some(false): Status(.ok, "System Integrity Protection is off. You can continue.")
        case .some(true):
          Status(.warn, "System Integrity Protection is on. The list this wizard edits is locked while it is.")
          VStack(alignment: .leading, spacing: 8) {
            Text("Turn it off for the install, then back on at the end:").font(.system(size: 17))
            Text("1. Shut down. Hold the power button until “Loading startup options”.\n2. Choose Options, then Continue.\n3. Open Utilities › Terminal and run  csrutil disable\n4. Restart and open this app again. It will notice.").font(.system(size: 16)).foregroundStyle(.secondary)
            Text("Intel Macs: restart holding Cmd-R instead of the power button.").font(.system(size: 15)).foregroundStyle(.tertiary)
          }
        case .none: Status(.info, "Couldn't read System Integrity Protection status.")
        }
        HeroPad(lit: wiz.sipEnabled == false)
      }
    } footer: { Nav(next: { wiz.step = .permission }) }
  }
}

struct PermissionView: View {
  @EnvironmentObject var wiz: Wizard
  var body: some View {
    Page("Let this app read the pad", wiz.inputMonitoring ? nil : "macOS calls this permission Input Monitoring. The wizard only listens for which control you press while it's open.") {
      VStack(alignment: .leading, spacing: 18) {
        if wiz.inputMonitoring { Status(.ok, "Input Monitoring is allowed. You can continue.") }
        else if wiz.permissionRequested {
          Status(.wait, "Waiting for you to turn it on.")
          Text("Turn on the switch next to this app in System Settings › Privacy & Security › Input Monitoring, then quit and reopen this app. It will continue from here. If the app isn't in that list, click + under the list and choose it.").font(.system(size: 16)).foregroundStyle(.secondary).frame(maxWidth: 560, alignment: .leading)
          Button("Open Input Monitoring settings…") { wiz.requestPermission() }.buttonStyle(.borderedProminent).controlSize(.large)
        } else {
          Button("Ask again") { wiz.requestPermission() }.controlSize(.large)
        }
        HeroPad(lit: wiz.inputMonitoring)
      }
    } footer: { Nav(back: { wiz.back(.welcome) }, next: { wiz.startHID(); wiz.step = .detect }, nextEnabled: wiz.inputMonitoring) }
    .onAppear { if !wiz.permissionRequested && !wiz.inputMonitoring { wiz.requestPermission() } }
  }
}

struct DetectView: View {
  @EnvironmentObject var wiz: Wizard
  var body: some View {
    Page("Connect the pad", wiz.padConnected ? nil : "Slide the mode switch to Bluetooth, press the Xbox button, and pair it in System Settings › Bluetooth if you haven't. A solid light means it's connected.") {
      VStack(alignment: .leading, spacing: 18) {
        if wiz.padConnected { Status(.ok, "G7 Pro connected (firmware \(wiz.firmware ?? 0)). You can continue.") } else { Status(.wait, "Looking for the pad…") }
        if wiz.frameworkSeesPad { Status(.info, "macOS already treats it as a game controller, so an entry is installed. Capture again to fix the mapping, or skip to Verify.") }
        HeroPad(lit: wiz.padConnected)
      }
    } footer: {
      HStack { Button("Back") { wiz.back(.permission) }.controlSize(.large); Spacer()
        if wiz.frameworkSeesPad { Button("Skip to Verify") { wiz.beginVerify() }.controlSize(.large) }
        Button("Next") { wiz.beginCapture() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).controlSize(.large).disabled(!wiz.padConnected) }
    }
  }
}

struct CaptureView: View {
  @EnvironmentObject var wiz: Wizard
  var body: some View {
    Page(wiz.current.map { wiz.pendingConfirm != nil ? "Let's double-check that" : "Press \($0.prompt)" } ?? "All captured",
         wiz.current.map { c in wiz.pendingConfirm != nil ? "That wasn't what this pad usually sends for \(c.prompt). Press \(c.prompt) once more; if it matches, it's kept." : "\(wiz.currentIndex + 1) of \(wiz.mappable.count). Press once, then let go." } ?? " ") {
      VStack(alignment: .leading, spacing: 16) {
        ControllerView(target: wiz.current?.id, captured: Set(wiz.captures.map { $0.controlID }), ok: [], bad: [:], showTargets: true) { wiz.recapture($0) }
          .frame(maxWidth: 900, maxHeight: 620)
        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 10) {
            Button("Undo last") { wiz.undo() }.disabled(!wiz.canUndo)
            Button("Start over") { wiz.beginCapture() }
            Spacer()
            Text("Click any control in the picture to capture it again. ⌘Z undoes.").font(.system(size: 15)).foregroundStyle(.secondary)
          }.controlSize(.large)
          Text("The back buttons (L4, R4, L5, R5) mirror other buttons, so they aren't captured here. They can only be reassigned in GameSir's own software, Windows only for now.").font(.system(size: 15)).foregroundStyle(.secondary).frame(maxWidth: 900, alignment: .leading)
          Text(wiz.lastRawText.isEmpty ? " " : "Pad sent: \(wiz.lastRawText)").font(.system(size: 14, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1)
        }.frame(height: 110, alignment: .topLeading)
      }
    } footer: { Nav(back: { wiz.back(.detect) }) }
  }
}

struct ReviewView: View {
  @EnvironmentObject var wiz: Wizard
  var body: some View {
    Page("Here's the mapping", "Each control you pressed, and the index macOS will use for it. macOS numbers controls across the whole pad, so this pad's mouse collection interleaves with the gamepad's; that's why the numbers aren't 0, 1, 2.") {
      VStack(alignment: .leading, spacing: 14) {
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(wiz.indexTable.enumerated()), id: \.offset) { i, row in
              HStack { Text(row.0).frame(width: 260, alignment: .leading); Text(row.1).font(.system(size: 15, design: .monospaced)).foregroundStyle(.secondary) }
                .padding(.vertical, 7).padding(.horizontal, 12)
                .background(i.isMultiple(of: 2) ? Color.primary.opacity(0.04) : Color.clear)
            }
          }
        }.frame(maxWidth: 760).clipShape(RoundedRectangle(cornerRadius: 10))
        Text(wiz.changes.isEmpty ? "Matches the bundled mapping." : "\(wiz.changes.count) control(s) differ from the bundled mapping; yours wins.").font(.system(size: 16)).foregroundStyle(.secondary)
      }
    } footer: { Nav(back: { wiz.autoAdvance = false; wiz.currentIndex = max(0, wiz.mappable.count - 1); wiz.step = .capture }, next: { wiz.step = .install }) }
  }
}

struct InstallView: View {
  @EnvironmentObject var wiz: Wizard
  var body: some View {
    Page(wiz.installed ? "Installed" : "Add the pad to Apple's controller list", wiz.installed ? nil : "This writes the entry and your mapping into the system database and restarts the controller service. macOS asks for an administrator password.") {
      VStack(alignment: .leading, spacing: 18) {
        if wiz.installed {
          Status(wiz.frameworkSeesPad ? .ok : .wait, wiz.frameworkSeesPad ? "Installed. macOS reports the pad as a game controller (\(wiz.reportedCategory ?? "category unknown")). You can continue." : "Installed. Waiting for macOS to pick the pad up…")
        } else if wiz.sipEnabled == true {
          Status(.warn, "System Integrity Protection is on, so the write would be refused. Turn it off (Welcome explains how) and reopen the app; your capture is saved.")
        } else {
          VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $wiz.xboxIdentity) { Text("Try to self-identify as an Xbox One controller so games show the right glyphs.").font(.system(size: 17)) }.toggleStyle(.checkbox)
            Text("May not work in all games, or in Steam Input.").font(.system(size: 14)).foregroundStyle(.secondary).padding(.leading, 22)
          }
          Button(action: { wiz.install() }) {
            HStack(spacing: 12) {
              if wiz.installing { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.down.circle.fill").font(.system(size: 24)) }
              Text(wiz.installing ? "Installing…" : "Install").font(.system(size: 24, weight: .semibold))
            }
            .padding(.horizontal, 36).padding(.vertical, 16)
          }
          .disabled(wiz.installing).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).controlSize(.large)
          .padding(.top, 12)
        }
        if !wiz.installOutput.isEmpty { ScrollView { Text(wiz.installOutput).font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(10) }.frame(maxWidth: 760, maxHeight: 130).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10)) }
        if wiz.installed { HeroPad(lit: wiz.frameworkSeesPad) }
      }
    } footer: { Nav(back: { wiz.back(.review) }, next: { wiz.beginVerify() }, nextEnabled: wiz.installed || wiz.frameworkSeesPad) }
  }
}

struct VerifyView: View {
  @EnvironmentObject var wiz: Wizard
  var body: some View {
    Page("Try it out", "Press anything on the pad. The control macOS delivers to apps lights up, so you can check every button reads the way it should.") {
      VStack(alignment: .leading, spacing: 16) {
        ControllerView(target: nil, lit: wiz.verifyHeld, captured: [], ok: [], bad: [:], showTargets: true) { _ in }
          .frame(maxWidth: 900, maxHeight: 620)
        VStack(alignment: .leading, spacing: 8) {
          Text(wiz.verifyStatusText).font(.system(size: 20, weight: .semibold)).lineLimit(2).frame(maxWidth: 900, alignment: .leading)
          if !wiz.frameworkSeesPad { Status(.warn, "macOS isn't reporting the pad as a game controller right now.") }
          Text("If something lights up in the wrong place, go back to Capture and press that control again. The Xbox and Share buttons are handled by macOS and never reach games. The back buttons (L4, R4, L5, R5) mirror other buttons and can only be reassigned in GameSir's own software, Windows only for now.").font(.system(size: 15)).foregroundStyle(.secondary).frame(maxWidth: 900, alignment: .leading)
        }.frame(height: 130, alignment: .topLeading)
      }
    } footer: {
      HStack { Button("Back") { wiz.back(.install) }; Button("Capture again") { wiz.autoAdvance = false; wiz.step = .capture }; Spacer(); Button("Next") { wiz.step = .done }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent) }.controlSize(.large)
    }
  }
}

struct DoneView: View {
  @EnvironmentObject var wiz: Wizard
  var body: some View {
    Page("Ready to play", "The pad now shows up in System Settings › Game Controllers and works in games that use Apple's controller support, including GeForce NOW.") {
      VStack(alignment: .leading, spacing: 18) {
        if wiz.sipEnabled == true { Status(.ok, "System Integrity Protection is back on.") }
        else {
          Status(.warn, "One thing left: turn System Integrity Protection back on.")
          Text("Restart into Recovery the same way as before, open Utilities › Terminal, run  csrutil enable  and restart. Everything installed stays in place.").font(.system(size: 16)).foregroundStyle(.secondary).frame(maxWidth: 600, alignment: .leading)
        }
        Text("Run this wizard again if a macOS update replaces Apple's controller list or you update the pad's firmware. Your capture is saved.").font(.system(size: 15)).foregroundStyle(.tertiary).frame(maxWidth: 600, alignment: .leading)
        HeroPad(lit: true)
      }
    } footer: {
      HStack { Spacer(); Button("All done. Game on!") { NSApp.terminate(nil) }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent) }.controlSize(.large)
    }
  }
}

struct UninstallView: View {
  @EnvironmentObject var wiz: Wizard
  var body: some View {
    Page("Uninstall", "Removes the G7 Pro from Apple's controller list and deletes the mapping this wizard installed, then restarts the controller service. The pad goes back to being paired but invisible to games. Your saved capture stays on disk, so reinstalling later is quick.") {
      VStack(alignment: .leading, spacing: 18) {
        if !wiz.entryInstalled {
          Status(.ok, "Nothing is installed.")
        } else if wiz.sipEnabled == true {
          Status(.warn, "System Integrity Protection is on, so the list can't be edited. Turn it off from Recovery (the Welcome step explains how) and come back.")
        } else {
          Status(.info, "macOS will ask for an administrator password.")
          Button(wiz.installing ? "Uninstalling…" : "Uninstall") { wiz.uninstall() }.disabled(wiz.installing).buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
        }
        if !wiz.installOutput.isEmpty { ScrollView { Text(wiz.installOutput).font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(10) }.frame(maxWidth: 760, maxHeight: 130).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10)) }
        HeroPad(lit: false)
      }
    } footer: { HStack { Button("Back") { wiz.uninstallMode = false }.controlSize(.large); Spacer() } }
  }
}

// MARK: - Controller drawing: the manual's line art (data/controller-front.svg) with hit targets from controls.json

/// Silhouettes for the shoulder/trigger callouts, extracted from the manual's top view (data/callout-glyphs.json).
struct Glyph: Decodable { var aspect: Double; var paths: [String]; var solid: Bool? }
enum Glyphs {
  static let all: [String: Glyph] = {
    guard let u = Bundle.main.resourceURL?.appendingPathComponent("data/callout-glyphs.json"),
          let d = try? Data(contentsOf: u), let g = try? JSONDecoder().decode([String: Glyph].self, from: d) else { return [:] }
    return g
  }()
}
/// Dashed leader from a callout label to its spot on the art.
struct CalloutLeader: View {
  let from: CGPoint, to: CGPoint, color: Color
  var body: some View {
    ZStack(alignment: .topLeading) {
      Path { p in p.move(to: from); p.addLine(to: to) }.stroke(color, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
      Circle().fill(color).frame(width: 7, height: 7).position(to)
    }
  }
}

/// One hit target: a button, stick, pad or callout silhouette, in its current state. Kept small so older
/// Swift compilers can type-check it.
struct ControlTarget: View {
  let control: ControlSpec; let state: ControllerView.S; let dir: String?; let held: Wizard.Held?
  let isTarget: Bool; let isLit: Bool; let glyph: Glyph?; let shape: AnyShape; let d: CGFloat; let w: CGFloat
  let pulse: Double; let ripple: Double

  private var active: Bool { isTarget || isLit }
  private var vec: CGPoint? { dir.map { ["up": CGPoint(x: 0, y: -1), "down": CGPoint(x: 0, y: 1), "left": CGPoint(x: -1, y: 0), "right": CGPoint(x: 1, y: 0)][$0] ?? .zero } }
  private var shp: AnyShape { glyph.map { AnyShape(GlyphShape(glyph: $0)) } ?? shape }
  private var fw: CGFloat { glyph.map { _ in control.id.hasSuffix("t") ? w * 0.07 : w * 0.11 } ?? d * (control.shape == "pill" ? 1.6 : 1) }
  private var fh: CGFloat { glyph.map { fw * CGFloat($0.aspect) } ?? d }
  private var isStick: Bool { control.shape == "stick" }

  var body: some View {
    ZStack {
      if vec != nil && active { directional }
      else if let h = held, glyph?.solid == true, control.id.hasSuffix("t") { trigger(h) }
      else if let g = glyph, g.solid != true { lineArtCallout }
      else { plain }
      label
    }
    .overlay(alignment: .top) { if glyph != nil { Text(control.label).font(.system(size: max(10, w * 0.019), weight: .bold)).foregroundStyle(.secondary).offset(y: -w * 0.03) } }
    .frame(width: fw, height: fh)
    .scaleEffect(isTarget && vec == nil ? 1 + 0.12 * pulse : 1)
  }

  private var plain: some View {
    ZStack {
      if isTarget { shp.stroke(Color.accentColor, lineWidth: 3).scaleEffect(1 + 0.7 * ripple).opacity(1 - ripple) }
      shp.fill(state.fill)
      shp.stroke(state.stroke, lineWidth: state.width)
    }
  }
  private var lineArtCallout: some View {
    ZStack {
      if isTarget { Capsule().stroke(Color.accentColor, lineWidth: 3).scaleEffect(1 + 0.5 * ripple).opacity(1 - ripple) }
      Capsule().fill(state.fill).padding(-w * 0.008)
      shp.stroke(isTarget ? Color.white : state.stroke, lineWidth: isTarget ? 2 : 1.4)
    }
  }
  private func trigger(_ h: Wizard.Held) -> some View {
    ZStack {
      shp.fill(Color.accentColor.opacity(0.18))
      shp.fill(Color.accentColor.opacity(0.65)).mask(VStack(spacing: 0) { Spacer(minLength: 0); Rectangle().frame(height: fh * CGFloat(h.value)) })
      shp.stroke(Color.accentColor, lineWidth: 2)
      Text("\(Int((h.value * 100).rounded()))%").font(.system(size: max(11, w * 0.017), weight: .semibold, design: .rounded)).foregroundStyle(.primary).fixedSize()
        .offset(x: control.id == "lt" ? -fw * 1.1 : fw * 1.1)
    }
  }
  private var directional: some View {
    let v0 = vec ?? .zero
    let mag = held.map { isStick ? $0.value : 1 } ?? 1
    let v = (held != nil && isStick && mag > 0.05) ? CGPoint(x: held!.x / max(mag, 0.001), y: -held!.y / max(mag, 0.001)) : v0
    let r = d * 0.32, off = d * 0.34
    let reach = d * (0.72 + (held != nil && isStick ? 0.6 * mag : 0))
    return ZStack {
      shp.stroke(Color.secondary.opacity(0.5), lineWidth: 1)
      Group {
        if isTarget { Circle().stroke(Color.accentColor, lineWidth: 3).scaleEffect(1 + 0.8 * ripple).opacity(1 - ripple) }
        Circle().fill(Color.accentColor.opacity(0.5))
        Circle().stroke(Color.accentColor, lineWidth: 2.5)
      }
      .frame(width: r, height: r).scaleEffect(isTarget ? 1 + 0.12 * pulse : 1)
      .offset(x: v.x * off, y: v.y * off)
      Image(systemName: "arrow.up").font(.system(size: max(12, d * 0.3), weight: .bold)).foregroundStyle(Color.accentColor)
        .rotationEffect(.radians(atan2(v.y, v.x) + Double.pi / 2))
        .offset(x: v.x * reach, y: v.y * reach)
      if held != nil && isStick {
        Text("\(Int((mag * 100).rounded()))%").font(.system(size: max(11, d * 0.2), weight: .semibold, design: .rounded)).foregroundStyle(.primary).fixedSize()
          .offset(x: v.x * (reach + d * 0.28), y: v.y * (reach + d * 0.28))
      }
    }
  }
  @ViewBuilder private var label: some View {
    if vec != nil && active {
      if glyph == nil, !control.label.isEmpty { Text(control.label).font(.system(size: max(9, d * 0.26), weight: .bold)).foregroundStyle(.primary) }
    } else if state.check {
      Image(systemName: "checkmark").font(.system(size: max(9, min(fw, fh) * 0.45), weight: .bold)).foregroundStyle(state.text)
    } else if glyph == nil, !control.label.isEmpty {
      Text(control.label).font(.system(size: max(9, d * (control.shape == "stick" || control.shape == "dpad" ? 0.26 : 0.42)), weight: .bold)).foregroundStyle(state.text)
    }
  }
}

/// A SwiftUI Shape from normalized "M x y L x y C … Z" path data (0…1 in both axes, scaled to the rect).
struct GlyphShape: Shape {
  let glyph: Glyph
  func path(in r: CGRect) -> Path {
    var out = Path()
    func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: r.minX + CGFloat(x) * r.width, y: r.minY + CGFloat(y) * r.height) }
    for d in glyph.paths {
      let t = d.split(separator: " ").map(String.init); var i = 0
      func n() -> Double { let v = Double(t[i])!; i += 1; return v }
      while i < t.count {
        switch t[i] {
        case "M": i += 1; let x = n(), y = n(); out.move(to: pt(x, y))
        case "L": i += 1; let x = n(), y = n(); out.addLine(to: pt(x, y))
        case "C": i += 1; let x1 = n(), y1 = n(), x2 = n(), y2 = n(), x = n(), y = n(); out.addCurve(to: pt(x, y), control1: pt(x1, y1), control2: pt(x2, y2))
        case "Z": i += 1; out.closeSubpath()
        default: i += 1
        }
      }
    }
    return out
  }
}

struct ControllerView: View {
  @EnvironmentObject var wiz: Wizard
  let target: String?; var lit: [String: Wizard.Held] = [:]; let captured: Set<String>; let ok: Set<String>; let bad: [String: String]
  var showTargets = true
  let onClick: (String) -> Void
  @Environment(\.colorScheme) private var scheme

  private static let art: NSImage? = {
    let candidates = [Bundle.main.resourceURL?.appendingPathComponent("data/controller-front.svg")].compactMap { $0 }
    for u in candidates { if let i = NSImage(contentsOf: u) { i.isTemplate = true; return i } }
    return nil
  }()
  private var artAspect: CGFloat { (Self.art?.size.height ?? 54.5) / (Self.art?.size.width ?? 76.5) }
  /// Room above the art for the shoulder/trigger callouts.
  private let topInset: CGFloat = 0.17

  private var bases: [ControlSpec] {
    var seen = Set<String>(); var out: [ControlSpec] = []
    for c in wiz.controls { let key = "\(c.x),\(c.y)"; if !seen.contains(key) { seen.insert(key); out.append(c) } }
    return out
  }
  private func siblings(_ c: ControlSpec) -> [ControlSpec] { wiz.controls.filter { $0.x == c.x && $0.y == c.y } }

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in
      let t = tl.date.timeIntervalSinceReferenceDate
      body(pulse: (sin(t * 2 * Double.pi / 1.4) + 1) / 2, ripple: (t / 1.4).truncatingRemainder(dividingBy: 1))
    }
    .aspectRatio(1 / (artAspect + topInset), contentMode: .fit)
  }
  private func body(pulse: Double, ripple pulseRipple: Double) -> some View {
    GeometryReader { g in
      let w = g.size.width, artH = w * artAspect, top = w * topInset
      ZStack(alignment: .topLeading) {
        if let art = Self.art {
          Image(nsImage: art).resizable().interpolation(.high)
            .foregroundStyle(scheme == .dark ? Color.white.opacity(0.85) : Color.black.opacity(0.85))
            .frame(width: w, height: artH).offset(y: top)
        }
        if showTargets {
          ForEach(bases.filter { $0.ax != nil }) { c in
            CalloutLeader(from: CGPoint(x: c.x * w, y: top + c.y * artH), to: CGPoint(x: (c.ax ?? c.x) * w, y: top + (c.ay ?? c.y) * artH), color: stateFor(siblings(c)).stroke)
          }
          ForEach(bases) { c in
            let sibs = siblings(c)
            let litSib = sibs.first { lit.keys.contains($0.id) }
            let held = litSib.flatMap { lit[$0.id] }
            let dir = sibs.first { $0.id == target }?.gcDir ?? litSib.flatMap { held?.dir ?? $0.gcDir }
            ControlTarget(control: c, state: stateFor(sibs), dir: dir, held: held, isTarget: sibs.contains { $0.id == target }, isLit: litSib != nil,
                          glyph: c.shape == "callout" ? Glyphs.all[c.id] : nil, shape: shape(c.shape), d: diameter(c.shape, w), w: w, pulse: pulse, ripple: pulseRipple)
              .position(x: c.x * w, y: top + c.y * artH)
              .contentShape(Rectangle())
              .onTapGesture { onClick(sibs.first { $0.isMappable }?.id ?? c.id) }
              .help(sibs.map { $0.prompt }.joined(separator: " / "))
          }
        }
      }.frame(width: w, height: artH + top)
    }
  }
  private func arrow(_ d: String) -> String { ["up": "↑", "down": "↓", "left": "←", "right": "→"][d] ?? d }
  private func diameter(_ shape: String, _ w: CGFloat) -> CGFloat {
    switch shape { case "stick": return w * 0.118; case "dpad": return w * 0.156; case "small", "circle-sm": return w * 0.046; case "pill": return w * 0.04; case "callout": return w * 0.04; default: return w * 0.062 }
  }
  private func widthFactor(_ shape: String) -> CGFloat { shape == "pill" ? 1.6 : shape == "callout" ? 1.9 : 1 }
  private func shape(_ s: String) -> AnyShape {
    switch s { case "pill", "callout": return AnyShape(Capsule()); default: return AnyShape(Circle()) }
  }
  struct S { var fill: Color; var stroke: Color; var width: CGFloat; var text: Color; var check = false }
  func stateFor(_ sibs: [ControlSpec]) -> S {
    let ids = Set(sibs.map { $0.id })
    let bg = scheme == .dark ? Color.black : Color.white
    if let t = target, ids.contains(t) { return S(fill: .accentColor.opacity(0.45), stroke: .accentColor, width: 2.5, text: .white) }
    if !ids.isDisjoint(with: Set(lit.keys)) {
      if sibs.allSatisfy({ !$0.isMappable }) { return S(fill: .secondary.opacity(0.35), stroke: .secondary, width: 2, text: .primary) }
      return S(fill: .accentColor.opacity(0.45), stroke: .accentColor, width: 2.5, text: .white)
    }
    if !ids.isDisjoint(with: Set(bad.keys)) { return S(fill: .red.opacity(0.5), stroke: .red, width: 2, text: .white) }
    if !ids.isDisjoint(with: ok) { return S(fill: .green.opacity(0.35), stroke: .green, width: 2, text: .white, check: true) }
    // captured: recede into the background and mark done
    if !ids.isDisjoint(with: captured) { return S(fill: bg.opacity(0.5), stroke: .secondary.opacity(0.35), width: 1, text: .secondary.opacity(0.7), check: true) }
    if sibs.allSatisfy({ !$0.isMappable }) { return S(fill: .clear, stroke: .clear, width: 0, text: .secondary) }
    return S(fill: .clear, stroke: .secondary.opacity(0.5), width: 1, text: .primary)
  }
}
