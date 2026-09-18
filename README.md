# GameSir G7 Pro over Bluetooth on macOS

Makes the GameSir G7 Pro work as a real game controller on macOS when connected over **Bluetooth**:
it shows up in System Settings › Game Controllers and works in anything that uses Apple's
GameController framework, such as GeForce NOW, Apple Arcade, Safari's Gamepad API, and most Mac games.

Out of the box, macOS pairs the pad and even calls it a "Gamepad", but no game sees it. This project
adds the pad to Apple's own third-party controller database. No kernel extensions, no background
processes, no input remapping software; it is one entry in a plist and one mapping file, installed by
a small wizard app.

Tested on macOS 27.0 with G7 Pro firmware 1.1.11. It should work on macOS 14 and later, which is when
Apple introduced the database this relies on.

## Quick start

1. **Disable System Integrity Protection** for the duration of the install (you turn it back on at
   the end; the change persists). The database lives in a SIP-protected folder.
   - Apple Silicon: shut down, hold the power button until "Loading startup options", choose
     Options › Continue, then Utilities › Terminal, run `csrutil disable`, restart.
   - Intel: restart holding Cmd-R, then Utilities › Terminal, `csrutil disable`, restart.
2. **Download the app** from the [Releases](../../releases) page and unzip it.
3. **Open it past Gatekeeper.** The app is not notarized yet, so macOS blocks it on first launch.
   Double-click it once, dismiss the warning, then open System Settings › Privacy & Security, scroll
   to the bottom, and click **Open Anyway**. (Terminal alternative:
   `xattr -dr com.apple.quarantine "GameSir G7 Pro Bluetooth Setup.app"`.)
4. **Follow the wizard.** It asks for Input Monitoring permission, finds the pad, has you press each
   control once, computes the mapping, installs it with your admin password, and verifies the result
   live on a picture of the pad. Undo a mistaken press with ⌘Z or by clicking the control.
5. **Re-enable SIP** the same way, with `csrutil enable`.

## What the wizard does, step by step

| Step | What happens |
|---|---|
| Welcome | Checks SIP status and shows the Recovery instructions. |
| Permission | Requests Input Monitoring, which is needed to read the pad's raw button stream. |
| Find the pad | Waits for the G7 Pro over Bluetooth and reads its firmware version, which the database entry must match. |
| Capture | Asks for each control in turn and records what the pad actually sends. Sticks and D-pad included. |
| Review | Computes the index macOS will use for every control (see *How it works*) and writes the personality file. |
| Install | Runs the bundled `g7pro install` as admin: patches the database, installs the personality, restarts the controller daemon. Backs up the original plist first. |
| Verify | Press everything. Green = macOS delivered the right control to apps. Red = it delivered something else, with the name of what it saw. |
| Finish | Reminds you to re-enable SIP. Offers uninstall. |

Your capture and the generated personality are kept in
`~/Library/Application Support/G7Pro Bluetooth Setup/`.

## Command line

The app bundles a headless CLI with the same core, also handy for scripting or for people who prefer a terminal:

```sh
APP="/Applications/GameSir G7 Pro Bluetooth Setup.app"
"$APP/Contents/MacOS/g7pro" status                 # SIP, pad, firmware, entry installed, framework adoption
sudo "$APP/Contents/MacOS/g7pro" install           # uses the bundled personality and the connected pad's firmware version
sudo "$APP/Contents/MacOS/g7pro" install --personality my.plist --version 283
sudo "$APP/Contents/MacOS/g7pro" uninstall
```

## How it works

The G7 Pro's Bluetooth mode is its Android mode. It presents a composite HID device: a Consumer
Control collection first (media keys), then gamepad, keyboard, and mouse collections. Apple's
controller daemon, `gamecontrollerd`, adopts a third-party HID pad only if its vendor ID, product ID,
and firmware version appear in a mappings database that ships as a MobileAsset:

```
/System/Library/AssetsV2/…/com_apple_MobileAsset_GameController_DB1/…/GameControllers-Custom.bundle
```

The bundle's `Info.plist` lists supported pads and points each at a "personality" plist that maps HID
elements to the standard gamepad layout with predicates like `UsageType == 1 AND UsageTypeIndex == 6`.
The GameSir X3 is in the database; the G7 Pro is not, so the daemon logs
`is NOT a supported game controller` and ignores it.

Two things had to be discovered to make the entry work:

1. **The pad's wiring.** Which HID usage each physical button sends. The wizard captures this rather
   than assuming it, so a firmware change that reorders buttons is handled by re-running it.
2. **How `UsageTypeIndex` is numbered.** It is *not* "the Nth button in the gamepad collection". The
   daemon takes every input element on the whole device, sorts same-type usages by usage value, and
   numbers those. The G7 Pro's mouse collection has buttons 1–5 and X/Y axes, which interleave with
   the gamepad's: gamepad button 1 is index 0, mouse button 1 is index 1, gamepad button 2 is index 2,
   and so on. Copying the X3's numbers therefore scrambled everything past A. The app computes the
   index from the pad's real element list, so it holds for any firmware and would for other composite
   pads too.

The Xbox button is sent as a Consumer Control "AC Home" key and is handled by macOS as the system
button outside the personality. Share is sent as a keyboard PrintScreen keystroke and cannot be
mapped. Back buttons R4/L4/R5/L5 have no codes of their own; they mirror face buttons assigned on the
pad (hold **M** + the back button until the Xbox light blinks, press the face button to mirror).

## Repository layout

```
data/device.json          pad identity, database identifier, personality paths
data/controls.json        the controls the wizard walks through, with prompts, personality identifiers,
                          expected framework elements, and drawing positions
personality/…plist        the personality template (derived from Apple's GameSir X3 entry)
src/Core.swift            headless logic: raw HID, framework observer, the index rule, capture → personality
src/Install.swift         database patching, daemon restart (runs as root)
src/main.swift            the `g7pro` CLI
src/App.swift             the SwiftUI wizard
build-app.sh              builds the .app (needs Xcode Command Line Tools); ad-hoc signed
.github/workflows         builds and publishes the zip on tags
```

The UI is deliberately thin. Anything that decides something lives in `src/Core.swift` or the JSON
files, so a different front end can reuse it unchanged.

## Building from source

```sh
git clone https://github.com/arcataroger/gamesir-g7-pro-bluetooth-for-macos.git
cd gamesir-g7-pro-bluetooth-for-macos
./build-app.sh          # → build/GameSir G7 Pro Bluetooth Setup.app  and  build/g7pro
open build/*.app
```

Requires the Xcode Command Line Tools (`xcode-select --install`); full Xcode is not needed. A locally
built app carries no quarantine flag, so Gatekeeper does not object to it.

## Troubleshooting

- **The pad's light keeps blinking though macOS says "Connected", then it powers off.** The pad's
  Bluetooth stack is stuck and service discovery times out. Hold the Xbox button until the pad is fully
  off, Forget it in Bluetooth settings, hold the pairing button, pair again.
- **Worked, then stopped after a macOS update.** Apple may have shipped a new controller database,
  replacing the patched bundle. Run the wizard again (SIP off). If Apple adds the G7 Pro themselves,
  this project becomes unnecessary.
- **Worked, then stopped after a pad firmware update.** The entry matches on firmware version. Run the
  wizard again with the pad connected.
- **Verify shows red for a control.** Click "Re-capture a control", press it again, Review, Install.
  If it stays red, open an issue with the red line's text and `g7pro status` output.
- **Buttons work in Verify but are wrong in one game.** Check System Settings › Game Controllers for
  a per-app or per-controller remap and reset it; check the game's own controller settings.

## What this does not do

- It does not create a virtual controller or inject input. Apple restricts virtual HID devices to
  entitled binaries, and AMFI kills ad-hoc attempts.
- It does not touch the sealed system volume. The database is on the data volume; only the
  `restricted` flag needs SIP off to bypass.
- It does not help wired or 2.4 GHz modes. Wired mode uses the Xbox protocol and already works.

## License

MIT. Apple's personality format and the X3 mapping this derives from belong to Apple; this repo ships a
derived data file for interoperability.
