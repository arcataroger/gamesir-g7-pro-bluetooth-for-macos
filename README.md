# GameSir G7 Pro over Bluetooth on macOS

Makes the GameSir G7 Pro work as a real game controller on macOS when connected over **Bluetooth**,
so it shows up in System Settings › Game Controllers and works in apps that use Apple's
GameController framework: GeForce NOW (native app), Safari's Gamepad API, Apple Arcade, and most
Mac games.

Out of the box, macOS pairs the pad and even calls it a "Gamepad" in the Bluetooth menu, but no
game sees it. This repo fixes that by adding the pad to Apple's own third-party controller database.
No kernel extensions, no background processes, no input remapping software.

Tested on macOS 27.0 (26A428) with G7 Pro firmware 1.1.11. It should work on macOS 14 and later,
which is when Apple introduced the database this relies on.

## Why the pad doesn't work by default

The G7 Pro's Bluetooth mode is its Android mode. It advertises a composite HID device whose first
collection is *Consumer Control* (media keys), with the gamepad, keyboard, and mouse collections
after it. macOS's controller daemon (`gamecontrollerd`) will adopt a third-party HID pad only if the
pad's vendor ID, product ID, and firmware version appear in a mappings database that Apple ships as
a MobileAsset:

```
/System/Library/AssetsV2/…/com_apple_MobileAsset_GameController_DB1/…/GameControllers-Custom.bundle
```

That bundle's `Info.plist` lists supported pads and points each at a "personality" plist describing
how HID buttons and axes map to the standard gamepad layout. The GameSir X3 is in it. The G7 Pro is
not, so the daemon logs `is NOT a supported game controller` and drops it.

The X3 uses the same GameSir Android HID layout as the G7 Pro, so this repo:

1. appends one entry to the Custom bundle's `Info.plist` matching your pad's vendor, product, and
   firmware version, and
2. installs a personality for it, which is Apple's own X3 personality with the product name changed.

After a daemon restart the pad is adopted as a full `extendedGamepad`. Everything is data; the code
paths that read it are Apple's.

## Requirements

- Apple Silicon or Intel Mac on macOS 14 or later
- GameSir G7 Pro, mode switch set to **Bluetooth**, paired with the Mac
- A short window with **System Integrity Protection (SIP) disabled** for the install. The database
  lives in a SIP-protected directory. You can, and should, turn SIP back on afterwards; the installed
  files stay.
- Xcode Command Line Tools are optional. If `swiftc` is present, `check.sh` compiles a small tool that
  asks the framework directly; otherwise it reads the daemon's log.

## Install

1. Pair the pad over Bluetooth and leave it connected. The installer reads the firmware version from
   the connected pad so the database entry matches exactly.
2. Disable SIP:
   - **Apple Silicon:** shut down, hold the power button until "Loading startup options", choose
     Options › Continue, then Utilities › Terminal and run `csrutil disable`. Restart.
   - **Intel:** restart holding Cmd-R, then Utilities › Terminal, `csrutil disable`, restart.
3. Run the installer:

   ```sh
   git clone https://github.com/arcataroger/gamesir-g7-pro-bluetooth-for-macos.git
   cd gamesir-g7-pro-bluetooth-for-macos
   ./install.sh
   ```

   It asks for your password (sudo), backs up the original `Info.plist` into `backup/`, patches every
   copy of the database it finds, restarts `gamecontrollerd`, and runs the check. You want:

   ```
   CONNECT notification: GameSir-G7 Pro | category: HID | extended: true
   GameController framework sees 1 controller(s)
   ```

4. Open System Settings › General › Game Controllers. The pad should be listed, and the pane has a
   live input tester. Press everything and confirm the mapping.
5. Re-enable SIP the same way you disabled it, with `csrutil enable`.

If the pad wasn't connected during install, the entry is written for firmware 1.1.11 and a warning is
printed. Connect it and re-run, or pass the version number: `./install.sh 283`.

## Check at any time

```sh
./check.sh
```

No sudo, no SIP change. Reports what the framework currently sees, or the daemon's last verdict.

## Uninstall

With SIP disabled, `./uninstall.sh`. It removes the entry and the personality and restarts the
daemon. The originals are also in `backup/` if you'd rather restore by hand.

## Back buttons, turbo, profiles

The pad's Bluetooth descriptor has 16 buttons and no separate codes for R4/L4/R5/L5. Those are
mirrors of face buttons assigned in the pad's firmware, and they keep working here. Assign them on the
pad: hold **M + R4** (or L4/L5/R5) until the Xbox light blinks slowly, press the button to mirror,
light goes solid. Pressing the back button itself in that mode clears it. Profiles (M + A/B/X/Y) and
hair-trigger mode (M + LT/RT for 2 s) are likewise firmware features and unaffected.

## Fixing a wrong button

The mapping lives in `personality/GameSir-G7Pro-Bluetooth.plist` under
`Model › Driver › Elements`. Each element has a predicate like

```
UsageType == 1 AND UsageTypeIndex == 3
```

where `UsageType` 1 = button, 2 = axis, 3 = hat, and `UsageTypeIndex` is the zero-based order of
that usage inside the gamepad collection. The G7 Pro's gamepad report is, in order: axes X, Y, Z, Rz
(0–3); one hat; buttons 1–16 (indexes 0–15); then Accelerator and Brake. Edit the index, re-run
`./install.sh` (SIP off), and re-test in Game Controllers. Pull requests with corrections are welcome.

Triggers are digital in this personality, as in Apple's X3 entry. Analog triggers would map
Accelerator/Brake as axes; untested.

## Troubleshooting

- **`csrutil: This tool needs to be executed from Recovery OS`**: you ran it from normal macOS. See
  step 2.
- **Pad's light keeps blinking though macOS says "Connected", then it powers off**: the pad's
  Bluetooth stack is stuck and service discovery is timing out. Hold the Xbox button until the pad is
  fully off, Forget the device in Bluetooth settings, hold the pairing button, pair again.
- **Worked, then stopped after a macOS update**: Apple may have shipped a new controller database
  asset, replacing the patched bundle. Re-run `./install.sh` (SIP off). If Apple adds the G7 Pro
  themselves, `install.sh` is no longer needed.
- **Worked, then stopped after a pad firmware update**: the entry matches on firmware version.
  Re-run `./install.sh` with the pad connected.
- **`check.sh` says 0 controllers right after install**: the daemon hands devices to clients
  asynchronously; wait a few seconds and run `./check.sh` again. If it stays at 0, run
  `/usr/bin/log show --last 2m --predicate 'process == "gamecontrollerd"' --style compact | grep 'supported game controller'`
  and open an issue with the output.

## What this does not do

- It does not create a virtual controller or inject input. Apple restricts virtual HID devices to
  entitled binaries, and AMFI kills ad-hoc attempts, which is why the database route is the only
  workable one without disabling SIP permanently.
- It does not touch the sealed system volume. The database is on the data volume; only the
  `restricted` flag needs SIP off to bypass.
- It does not help wired or 2.4 GHz modes. Wired mode uses the Xbox protocol and already works on
  macOS.

## How it was found

Streaming `gamecontrollerd`'s debug log while the pad reconnected showed it trying the
`com.GameSir.X3` entry and rejecting the device. Following the config service to its MobileAsset
revealed the plist database and its personality format. The patched bundle was validated with the
framework's own `_GCConfigurationBundle` and `_GCDeviceDBBundle` classes before touching the system.

## License

MIT. Apple's personality format and the X3 mapping this derives from belong to Apple; this repo ships a
derived data file for interoperability.
