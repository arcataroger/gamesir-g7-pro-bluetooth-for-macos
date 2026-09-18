// App.swift — SwiftUI wizard front end over Core.swift. Everything except the two SIP reboots happens here.
import SwiftUI
import AppKit

@main
struct G7ProSetupApp: App {
  @StateObject private var wiz = Wizard()
  var body: some Scene {
    WindowGroup("GameSir G7 Pro Bluetooth Setup") {
      WizardView().environmentObject(wiz).font(.system(size: 17)).frame(minWidth: 1040, minHeight: 720)
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
  @Published var inputMonitoring = false
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
  @Published var verifyLit: String? = nil        // control macOS just delivered, during Verify
  @Published var verifyLitDir: String? = nil     // its direction for pads/sticks (up/down/left/right)
  @Published var verifySeen = false
  @Published var lastFrameworkText = ""
  @Published var errorText: String? = nil
  @Published var autoAdvance = true          // cleared when the user navigates backwards by hand
  @Published var entryInstalled = false      // the database already has an entry for this pad
  @Published var permissionRequested = false // after asking once, nothing changes until the app is relaunched

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
    refreshSystem()
    Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refreshSystem() }
    FrameworkObserver.shared.onConnection = { [weak self] on in self?.frameworkSeesPad = on; self?.advanceIfDone() }
    FrameworkObserver.shared.onElement = { [weak self] name, dir in self?.frameworkEvent(name, dir) }
    FrameworkObserver.shared.onRelease = { [weak self] name in
      guard let self, self.step == .verify, let lit = self.verifyLit, let c = self.controls.first(where: { $0.id == lit }), c.gc == name else { return }
      self.verifyLit = nil; self.verifyLitDir = nil
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
    // Ask once. macOS shows its own prompt with an "Open System Settings" button. The grant only takes effect
    // for a fresh process, so there is nothing to poll for afterwards.
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
  func beginCapture() { captures = []; currentIndex = 0; step = .capture }
  private func rawEvent(_ ev: RawEvent) {
    if step == .verify {
      if ev.usagePage == 12 && ev.usage == 0x223 {          // AC Home = Xbox button
        if ev.value != 0 { verifyLit = "home"; verifyLitDir = nil; lastFrameworkText = "Xbox button. macOS keeps this as the system button (it opens the Game Overlay); games don't receive it." }
        else if verifyLit == "home" { verifyLit = nil }
      } else if ev.usagePage == 7 && ev.usage == 0x46 {     // keyboard PrintScreen = Share
        if ev.value != 0 { verifyLit = "share"; verifyLitDir = nil; lastFrameworkText = "Share. The pad sends this as a keyboard keystroke, not a gamepad button, so games don't see it." }
        else if verifyLit == "share" { verifyLit = nil }
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
    guard step == .verify else { return }
    verifySeen = true
    // which control did macOS deliver? match the framework element name (and direction for pads/sticks)
    let hit = controls.first { c in c.gc == name && (c.gcDir == nil || c.gcDir == dir) } ?? controls.first { $0.gc == name }
    verifyLit = hit?.id; verifyLitDir = dir     // stays lit until the framework reports the release
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
        let done = wiz.isSatisfied(s), current = s == wiz.step
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
        .onTapGesture { if done || s.rawValue <= wiz.step.rawValue { wiz.back(s) } }
      }
      Spacer()
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
      if let st = subtitle { Text(st).font(.system(size: 17)).foregroundStyle(.secondary).frame(maxWidth: 640, alignment: .leading).padding(.bottom, 26) }
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
    ControllerView(target: nil, lit: nil, captured: [], ok: [], bad: [:], showTargets: false) { _ in }
      .opacity(lit ? 1 : 0.28)
      .animation(.easeOut(duration: 0.6), value: lit)
      .frame(maxWidth: 720)
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
          Text("In macOS's prompt choose Open System Settings, turn on the switch next to this app, then quit and reopen this app. It will continue from here.").font(.system(size: 16)).foregroundStyle(.secondary).frame(maxWidth: 560, alignment: .leading)
          Button("Quit now") { NSApp.terminate(nil) }.controlSize(.large)
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
    Page(wiz.current.map { "Press \($0.prompt)" } ?? "All captured", wiz.current != nil ? "\(wiz.currentIndex + 1) of \(wiz.mappable.count). Press once, then let go." : nil) {
      VStack(alignment: .leading, spacing: 16) {
        ControllerView(target: wiz.current?.id, lit: nil, captured: Set(wiz.captures.map { $0.controlID }), ok: [], bad: [:], showTargets: true) { wiz.recapture($0) }
          .frame(maxWidth: 900)
        HStack(spacing: 10) {
          Button("Undo last") { wiz.undo() }.disabled(!wiz.canUndo)
          Button("Start over") { wiz.beginCapture() }
          Spacer()
          Text("Click any control in the picture to capture it again. ⌘Z undoes.").font(.system(size: 15)).foregroundStyle(.secondary)
        }.controlSize(.large)
        Text(wiz.lastRawText.isEmpty ? " " : "Pad sent: \(wiz.lastRawText)").font(.system(size: 14, design: .monospaced)).foregroundStyle(.tertiary)
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
          Status(wiz.frameworkSeesPad ? .ok : .wait, wiz.frameworkSeesPad ? "Installed. macOS reports the pad as a game controller. You can continue." : "Installed. Waiting for macOS to pick the pad up…")
        } else if wiz.sipEnabled == true {
          Status(.warn, "System Integrity Protection is on, so the write would be refused. Turn it off (Welcome explains how) and reopen the app; your capture is saved.")
        } else {
          Button(wiz.installing ? "Installing…" : "Install") { wiz.install() }.disabled(wiz.installing).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).controlSize(.large)
        }
        if !wiz.installOutput.isEmpty { ScrollView { Text(wiz.installOutput).font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(10) }.frame(maxWidth: 760, maxHeight: 130).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10)) }
        HeroPad(lit: wiz.installed && wiz.frameworkSeesPad)
      }
    } footer: { Nav(back: { wiz.back(.review) }, next: { wiz.beginVerify() }, nextEnabled: wiz.installed || wiz.frameworkSeesPad) }
  }
}

struct VerifyView: View {
  @EnvironmentObject var wiz: Wizard
  var body: some View {
    Page("Try it out", "Press anything on the pad. The control macOS delivers to apps lights up, so you can check every button reads the way it should.") {
      VStack(alignment: .leading, spacing: 16) {
        ControllerView(target: nil, lit: wiz.verifyLit, litDir: wiz.verifyLitDir, captured: [], ok: [], bad: [:], showTargets: true) { _ in }
          .frame(maxWidth: 900)
        HStack(spacing: 18) {
          Text(wiz.lastFrameworkText.isEmpty ? "Waiting for a press…" : (wiz.lastFrameworkText.contains(".") ? wiz.lastFrameworkText : "macOS saw: \(wiz.lastFrameworkText)")).font(.system(size: 20, weight: .semibold)).frame(maxWidth: 900, alignment: .leading)
          if !wiz.frameworkSeesPad { Status(.warn, "macOS isn't reporting the pad as a game controller right now.") }
        }
        Text("If something lights up in the wrong place, go back to Capture and press that control again. The Xbox and Share buttons and M are handled by macOS or the pad itself and never reach games.").font(.system(size: 16)).foregroundStyle(.secondary).frame(maxWidth: 900, alignment: .leading)
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
        if !wiz.installOutput.isEmpty && wiz.installing == false && !wiz.installed { Text(wiz.installOutput).font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary) }
        HeroPad(lit: true)
      }
    } footer: {
      HStack { Button("Remove the entry") { wiz.uninstall() }.disabled(wiz.installing || wiz.sipEnabled == true); Spacer(); Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent) }.controlSize(.large)
    }
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
  let target: String?; let lit: String?; var litDir: String? = nil; let captured: Set<String>; let ok: Set<String>; let bad: [String: String]
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
      body(pulse: (sin(t * 2 * .pi / 1.4) + 1) / 2, ripple: (t / 1.4).truncatingRemainder(dividingBy: 1))
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
          // callout leaders first, so targets draw over them
          ForEach(bases.filter { $0.ax != nil }) { c in
            Path { p in p.move(to: CGPoint(x: c.x * w, y: top + c.y * artH)); p.addLine(to: CGPoint(x: (c.ax ?? c.x) * w, y: top + (c.ay ?? c.y) * artH)) }
              .stroke(stateFor(siblings(c)).stroke, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            Circle().fill(stateFor(siblings(c)).stroke).frame(width: 7, height: 7).position(x: (c.ax ?? c.x) * w, y: top + (c.ay ?? c.y) * artH)
          }
          ForEach(bases) { c in
            let sibs = siblings(c), st = stateFor(sibs)
            let dir = sibs.first { $0.id == target }?.gcDir ?? (sibs.contains { $0.id == lit } ? (litDir ?? sibs.first { $0.id == lit }?.gcDir) : nil)
            let d = diameter(c.shape, w), isTarget = sibs.contains { $0.id == target }
            let glyph = c.shape == "callout" ? Glyphs.all[c.id] : nil
            let shp: AnyShape = glyph.map { AnyShape(GlyphShape(glyph: $0)) } ?? shape(c.shape)
            let fw = glyph.map { _ in c.id.hasSuffix("t") ? w * 0.07 : w * 0.11 } ?? d * widthFactor(c.shape)
            let fh = glyph.map { fw * CGFloat($0.aspect) } ?? d
            let active = isTarget || sibs.contains { $0.id == lit }
            let vec: CGPoint? = dir.map { ["up": CGPoint(x: 0, y: -1), "down": CGPoint(x: 0, y: 1), "left": CGPoint(x: -1, y: 0), "right": CGPoint(x: 1, y: 0)][$0] ?? .zero }
            ZStack {
              if let v = vec, active {
                // a direction on a pad/stick: highlight just that edge, arrow beyond it; the base stays quiet
                shp.stroke(Color.secondary.opacity(0.5), lineWidth: 1)
                let r = d * 0.32, off = d * 0.34
                Group {
                  if isTarget { Circle().stroke(Color.accentColor, lineWidth: 3).scaleEffect(1 + 0.8 * pulseRipple).opacity(1 - pulseRipple) }
                  Circle().fill(Color.accentColor.opacity(0.5))
                  Circle().stroke(Color.accentColor, lineWidth: 2.5)
                }
                .frame(width: r, height: r).scaleEffect(isTarget ? 1 + 0.12 * pulse : 1)
                .offset(x: v.x * off, y: v.y * off)
                Text(arrow(dir!)).font(.system(size: max(12, d * 0.3), weight: .bold)).foregroundStyle(Color.accentColor)
                  .offset(x: v.x * d * 0.72, y: v.y * d * 0.72)
              } else if let g = glyph, g.solid != true {
                // line-art silhouettes: a capsule carries the state; the outline is a stroke on top
                if isTarget { Capsule().stroke(Color.accentColor, lineWidth: 3).scaleEffect(1 + 0.5 * pulseRipple).opacity(1 - pulseRipple) }
                Capsule().fill(st.fill).padding(-w * 0.008)
                shp.stroke(isTarget ? Color.white : st.stroke, lineWidth: isTarget ? 2 : 1.4)
              } else {
                if isTarget { shp.stroke(Color.accentColor, lineWidth: 3).scaleEffect(1 + 0.7 * pulseRipple).opacity(1 - pulseRipple) }
                shp.fill(st.fill)
                shp.stroke(st.stroke, lineWidth: st.width)
              }
              if vec != nil && active {
                if glyph == nil, !c.label.isEmpty { Text(c.label).font(.system(size: max(9, d * 0.26), weight: .bold)).foregroundStyle(.primary) }
              } else if st.check { Image(systemName: "checkmark").font(.system(size: max(9, min(fw, fh) * 0.45), weight: .bold)).foregroundStyle(st.text) }
              else if glyph == nil, !c.label.isEmpty {
                Text(c.label).font(.system(size: max(9, d * (c.shape == "stick" || c.shape == "dpad" ? 0.26 : 0.42)), weight: .bold)).foregroundStyle(st.text)
              }
            }
            .overlay(alignment: .top) { if glyph != nil { Text(c.label).font(.system(size: max(10, w * 0.019), weight: .bold)).foregroundStyle(.secondary).offset(y: -w * 0.03) } }
            .frame(width: fw, height: fh)
            .scaleEffect(isTarget && vec == nil ? 1 + 0.12 * pulse : 1)
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
  private struct S { var fill: Color; var stroke: Color; var width: CGFloat; var text: Color; var check = false }
  private func stateFor(_ sibs: [ControlSpec]) -> S {
    let ids = Set(sibs.map { $0.id })
    let bg = scheme == .dark ? Color.black : Color.white
    if let t = target, ids.contains(t) { return S(fill: .accentColor.opacity(0.45), stroke: .accentColor, width: 2.5, text: .white) }
    if let l = lit, ids.contains(l) {
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
