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
  @Published var autoAdvance = true          // cleared when the user navigates backwards by hand
  @Published var entryInstalled = false      // the database already has an entry for this pad

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
    FrameworkObserver.shared.start()
    // Developer convenience: `G7ProSetup --step capture` jumps straight to a step (permission must already be granted).
    if let i = CommandLine.arguments.firstIndex(of: "--step"), i + 1 < CommandLine.arguments.count,
       let s = Step.allCases.first(where: { $0.title.lowercased().hasPrefix(CommandLine.arguments[i + 1].lowercased()) }) {
      autoAdvance = false; refreshPermission(); step = s
    }
  }

  func refreshSystem() {
    DispatchQueue.global().async {
      let sip = SystemState.sipEnabled(), inst = Database.isInstalled(device: self.device)
      DispatchQueue.main.async { self.sipEnabled = sip; self.entryInstalled = inst; self.advanceIfDone() }
    }
  }
  func back(_ to: Step) { autoAdvance = false; step = to }
  /// Called whenever something completes; moves forward past steps that are already satisfied.
  func advanceIfDone() {
    guard autoAdvance else { return }
    switch step {
    case .welcome: if sipEnabled == false { step = .permission; advanceIfDone() }
    case .permission: if inputMonitoring { startHID(); step = .detect; advanceIfDone() }
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
    inputMonitoring = HIDSource.requestInputMonitoring()
    if !inputMonitoring { SystemState.openInputMonitoringSettings() }
    refreshPermission()
  }
  func refreshPermission() { inputMonitoring = HIDSource.hasInputMonitoring(); if inputMonitoring { startHID() }; advanceIfDone() }
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
        let done = s.rawValue < wiz.step.rawValue, current = s == wiz.step
        HStack(spacing: 12) {
          ZStack {
            Circle().fill(current ? Color.accentColor : (done ? Color.green : Color.clear)).frame(width: 22, height: 22)
            Circle().stroke(done || current ? Color.clear : Color.secondary.opacity(0.5), lineWidth: 1.5).frame(width: 22, height: 22)
            if done { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white) }
            if current { Circle().fill(.white).frame(width: 7, height: 7) }
          }
          Text(s.title).font(.system(size: 17, weight: current ? .semibold : .regular))
            .foregroundStyle(current ? .primary : (done ? .primary : .secondary))
          Spacer()
        }
        .padding(.horizontal, 24).padding(.vertical, 9)
        .background(current ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { if done { wiz.back(s) } }
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
  var back: (() -> Void)? = nil; var next: (() -> Void)? = nil; var nextTitle = "Continue"; var nextEnabled = true
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
    Page("Make your G7 Pro work over Bluetooth", "macOS pairs this pad but games can't see it, because it's missing from Apple's controller list. This wizard records how your pad's buttons are wired, adds the missing entry, and checks the result. Nothing keeps running afterwards.") {
      VStack(alignment: .leading, spacing: 18) {
        switch wiz.sipEnabled {
        case .some(false): Status(.ok, "System Integrity Protection is off, which the install step needs.")
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
  private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
  var body: some View {
    Page("Let this app read the pad", "macOS calls this permission Input Monitoring. The wizard only listens for which control you press while it's open.") {
      VStack(alignment: .leading, spacing: 18) {
        if wiz.inputMonitoring { Status(.ok, "Input Monitoring is allowed.") }
        else {
          Button("Allow Input Monitoring…") { wiz.requestPermission() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).controlSize(.large)
          Text("macOS asks the first time. If nothing appears, the Input Monitoring settings open instead: turn on the switch next to this app. This page updates by itself.").font(.system(size: 16)).foregroundStyle(.secondary).frame(maxWidth: 560, alignment: .leading)
        }
        HeroPad(lit: wiz.inputMonitoring)
      }
    } footer: { Nav(back: { wiz.back(.welcome) }, next: { wiz.startHID(); wiz.step = .detect }, nextEnabled: wiz.inputMonitoring) }
    .onAppear { wiz.refreshPermission() }
    .onReceive(poll) { _ in if !wiz.inputMonitoring { wiz.refreshPermission() } }
  }
}

struct DetectView: View {
  @EnvironmentObject var wiz: Wizard
  var body: some View {
    Page("Connect the pad", wiz.padConnected ? nil : "Slide the mode switch to Bluetooth, press the Xbox button, and pair it in System Settings › Bluetooth if you haven't. A solid light means it's connected.") {
      VStack(alignment: .leading, spacing: 18) {
        if wiz.padConnected { Status(.ok, "G7 Pro connected, firmware \(wiz.firmware ?? 0).") } else { Status(.wait, "Looking for the pad…") }
        if wiz.frameworkSeesPad { Status(.info, "macOS already treats it as a game controller, so an entry is installed. Capture again to fix the mapping, or skip to Verify.") }
        HeroPad(lit: wiz.padConnected)
      }
    } footer: {
      HStack { Button("Back") { wiz.back(.permission) }.controlSize(.large); Spacer()
        if wiz.frameworkSeesPad { Button("Skip to Verify") { wiz.beginVerify() }.controlSize(.large) }
        Button("Start capture") { wiz.beginCapture() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).controlSize(.large).disabled(!wiz.padConnected) }
    }
  }
}

struct CaptureView: View {
  @EnvironmentObject var wiz: Wizard
  var body: some View {
    Page(wiz.current.map { "Press \($0.prompt)" } ?? "All captured", wiz.current != nil ? "\(wiz.currentIndex + 1) of \(wiz.mappable.count). Press once, then let go." : nil) {
      VStack(alignment: .leading, spacing: 16) {
        ControllerView(target: wiz.current?.id, lit: wiz.litControl, captured: Set(wiz.captures.map { $0.controlID }), ok: [], bad: [:], showTargets: true) { wiz.recapture($0) }
          .frame(maxWidth: 900)
        HStack(spacing: 10) {
          Button("Undo last") { wiz.undo() }.disabled(!wiz.canUndo)
          Button("Skip this one") { wiz.skip() }
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
    } footer: { Nav(back: { wiz.autoAdvance = false; wiz.currentIndex = max(0, wiz.mappable.count - 1); wiz.step = .capture }, next: { wiz.step = .install }, nextTitle: "Install") }
  }
}

struct InstallView: View {
  @EnvironmentObject var wiz: Wizard
  var body: some View {
    Page(wiz.installed ? "Installed" : "Add the pad to Apple's controller list", wiz.installed ? nil : "This writes the entry and your mapping into the system database and restarts the controller service. macOS asks for an administrator password.") {
      VStack(alignment: .leading, spacing: 18) {
        if wiz.installed {
          Status(wiz.frameworkSeesPad ? .ok : .wait, wiz.frameworkSeesPad ? "macOS now reports the pad as a game controller." : "Waiting for macOS to pick the pad up…")
        } else if wiz.sipEnabled == true {
          Status(.warn, "System Integrity Protection is on, so the write would be refused. Turn it off (Welcome explains how) and reopen the app; your capture is saved.")
        } else {
          Button(wiz.installing ? "Installing…" : "Install") { wiz.install() }.disabled(wiz.installing).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).controlSize(.large)
        }
        if !wiz.installOutput.isEmpty { ScrollView { Text(wiz.installOutput).font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(10) }.frame(maxWidth: 760, maxHeight: 130).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10)) }
        HeroPad(lit: wiz.installed && wiz.frameworkSeesPad)
      }
    } footer: { Nav(back: { wiz.back(.review) }, next: { wiz.beginVerify() }, nextTitle: "Verify", nextEnabled: wiz.installed || wiz.frameworkSeesPad) }
  }
}

struct VerifyView: View {
  @EnvironmentObject var wiz: Wizard
  var body: some View {
    Page("Try every control", "Green means macOS delivered the right control to apps. Red means it delivered something else.") {
      VStack(alignment: .leading, spacing: 16) {
        ControllerView(target: nil, lit: wiz.litControl, captured: [], ok: wiz.verify.ok, bad: wiz.verify.bad, showTargets: true) { _ in }
          .frame(maxWidth: 900)
        HStack(alignment: .firstTextBaseline, spacing: 18) {
          Text("\(wiz.verify.ok.count) of \(wiz.mappable.count) verified").font(.system(size: 20, weight: .semibold))
          if !wiz.frameworkSeesPad { Status(.warn, "macOS isn't reporting the pad as a game controller right now.") }
        }
        ForEach(wiz.verify.bad.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
          Text("\(wiz.controls.first { $0.id == k }?.prompt ?? k): macOS saw \(v)").foregroundStyle(.red).font(.system(size: 16))
        }
        Text(wiz.lastFrameworkText.isEmpty ? " " : "macOS delivered: \(wiz.lastFrameworkText)").font(.system(size: 14, design: .monospaced)).foregroundStyle(.tertiary)
      }
    } footer: {
      HStack { Button("Back") { wiz.back(.install) }; Button("Capture a control again") { wiz.step = .capture }; Spacer(); Button("Finish") { wiz.step = .done }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent) }.controlSize(.large)
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

struct ControllerView: View {
  @EnvironmentObject var wiz: Wizard
  let target: String?; let lit: String?; let captured: Set<String>; let ok: Set<String>; let bad: [String: String]
  var showTargets = true
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
        ForEach(showTargets ? bases : []) { c in
          let sibs = siblings(c)
          let st = stateFor(sibs)
          let dir = sibs.first { $0.id == target }?.gcDir ?? sibs.first { $0.id == lit }?.gcDir
          let d = diameter(c.shape, w)
          ZStack {
            shape(c.shape).fill(st.fill)
            shape(c.shape).stroke(st.stroke, lineWidth: st.width)
            if let text = dir.map({ arrow($0) }) ?? (c.label.isEmpty ? nil : c.label) {
              Text(text).font(.system(size: max(9, d * (c.shape == "stick" || c.shape == "dpad" ? 0.26 : 0.42)), weight: .bold)).foregroundStyle(st.text)
            }
          }
          .frame(width: d * (c.shape == "wide" ? 2.2 : c.shape == "pill" ? 1.6 : c.shape == "bumper" ? 5.2 : c.shape == "trigger" ? 2.6 : 1), height: d)
          .position(x: c.x * w, y: c.y * h)
          .contentShape(Rectangle())
          .onTapGesture { onClick(sibs.first { $0.isMappable }?.id ?? c.id) }
          .help(sibs.map { $0.prompt }.joined(separator: " / "))
        }
      }.frame(width: w, height: h)
    }
    .aspectRatio(1 / aspect, contentMode: .fit)
  }
  private func arrow(_ d: String) -> String { ["up": "↑", "down": "↓", "left": "←", "right": "→"][d] ?? d }
  private func diameter(_ shape: String, _ w: CGFloat) -> CGFloat {
    switch shape { case "stick": return w * 0.135; case "dpad": return w * 0.14; case "small", "circle-sm": return w * 0.05; case "pill": return w * 0.04; case "wide": return w * 0.045; case "bumper": return w * 0.038; case "trigger": return w * 0.032; default: return w * 0.065 }
  }
  private func shape(_ s: String) -> AnyShape {
    switch s { case "small", "wide": return AnyShape(RoundedRectangle(cornerRadius: 8)); case "pill", "bumper", "trigger": return AnyShape(Capsule()); default: return AnyShape(Circle()) }
  }
  private struct S { var fill: Color; var stroke: Color; var width: CGFloat; var text: Color }
  private func stateFor(_ sibs: [ControlSpec]) -> S {
    let ids = Set(sibs.map { $0.id })
    if let t = target, ids.contains(t) { return S(fill: .accentColor.opacity(0.45), stroke: .accentColor, width: 3, text: .white) }
    if let l = lit, ids.contains(l) { return S(fill: .yellow.opacity(0.45), stroke: .orange, width: 3, text: .primary) }
    if !ids.isDisjoint(with: Set(bad.keys)) { return S(fill: .red.opacity(0.4), stroke: .red, width: 2, text: .white) }
    if !ids.isDisjoint(with: ok) { return S(fill: .green.opacity(0.4), stroke: .green, width: 2, text: .white) }
    if !ids.isDisjoint(with: captured) { return S(fill: .green.opacity(0.18), stroke: .green.opacity(0.7), width: 1.5, text: .primary) }
    if sibs.allSatisfy({ !$0.isMappable }) { return S(fill: .clear, stroke: .gray.opacity(0.35), width: 1, text: .secondary) }
    return S(fill: .clear, stroke: .gray.opacity(0.6), width: 1, text: .primary)
  }
}
