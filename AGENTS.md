# Maintaining this repository

This file is for coding agents and new contributors. It records how the project works, what breaks
easily, and what we learned the hard way. Read it before changing anything.

## Writing rules

Apply these to every reply, commit message, README change, and string in the UI:

1. Every sentence: max 20 words (25 to explain). Split any longer one.
2. No passives. Name the actor.
3. Write instructions as numbered imperative steps: one action per step, condition first.
4. No hedges (may → can; should → must) and no filler.

## What the project is

macOS ignores the GameSir G7 Pro over Bluetooth because Apple's controller database does not list it.
We add a database entry and a mapping ("personality") file. Apple's daemon, `gamecontrollerd`, then
adopts the pad as an extended gamepad. Nothing of ours runs afterwards.

Layers, top to bottom:

1. `src/App.swift`: the SwiftUI wizard. Display only.
2. `src/main.swift`: the `g7pro` CLI. Also the app's privileged helper.
3. `src/Core.swift`: every decision. Raw HID, the index rule, capture → personality, framework observer.
4. `src/Install.swift`: root-side database edits.
5. `data/*.json` and `personality/*.plist`: all pad-specific knowledge.

Rule: put logic in Core or in data, never in a view.

`schemas/` holds a JSON Schema for each data file and describes every field. Update the schema when
you add a field, and keep the Swift Codable structs in Core.swift in step with it.

## Build and run

1. Install the Xcode Command Line Tools. You do not need Xcode.
2. Run `./build-app.sh`. It compiles the app and the CLI, renders the icon, and ad-hoc signs the bundle.
3. Open `build/GameSir G7 Pro Bluetooth Setup.app`.

Developer flags: `--step <name>` opens a step directly. `--control <id>` picks the capture prompt.
Both skip the gates, so the rail can look inconsistent. That is expected.

The build script runs `tccutil reset ListenEvent` after every build. Reason: an ad-hoc signature
changes each build, and macOS ties the Input Monitoring grant to the signature. Without the reset,
the toggle in System Settings stays on while the app reports "not granted".

## Pitfalls we hit

### Permission prompts

1. A status check (`IOHIDCheckAccess`) can itself surface the Input Monitoring prompt on macOS 27.
   Never poll it. We check once when the Permission step appears, and never again.
2. macOS shows the prompt once per process. A second `IOHIDRequestAccess` does nothing. Later clicks
   must open the Input Monitoring pane instead.
3. A request made before the app is active can vanish silently. `requestPermission()` waits for
   `didBecomeActive` first.
4. The grant applies to a fresh process. Tell the user to quit and reopen; do not wait for it.

### The index rule

`UsageTypeIndex` in a personality is not "the Nth button in the gamepad collection". The daemon takes
every input element on the whole device, sorts same-type usages by usage value, and numbers those.
The G7 Pro's mouse collection (buttons 1–5, X, Y) interleaves with the gamepad's. Copying Apple's X3
indexes scrambled every button past A. `IndexRule` computes the index from the live element list.
Analog triggers are the Simulation usages Accelerator (0xC4) and Brake (0xC5); they sort after the
generic-desktop axes, which put LT at axis index 8 and RT at 7 on this pad.

### Capture

1. Analog triggers stream many reports per pull. Without edge detection, one pull satisfied LT, then RT,
   then L3. Capture only accepts a rest-to-active transition per HID element.
2. Any press that disagrees with `data/reference-mapping.json` gets a second press before we keep it.
3. Do not offer a "skip". Every control must be captured for the personality to be complete.

### The daemon and the pad

1. Never disconnect the pad's Bluetooth link from code. The pad powers off, and repeated bounces left
   it stuck with service discovery failing. To re-evaluate, restart the daemon:
   `sudo launchctl kickstart -k system/com.apple.GameController.gamecontrollerd`.
2. The framework hands controllers to clients asynchronously. A check right after launch sees none.
   Wait on `GCControllerDidConnect` for several seconds.
3. The entry matches on firmware `VersionNumber`. A pad firmware update needs a new install.
4. Apple can replace the database bundle in a macOS update. The installer patches every copy it finds.

### What the pad cannot do over Bluetooth

1. Rumble. The descriptor has no force-feedback output. `createEngine` returns nil. Do not promise it.
2. The Xbox button reaches macOS as a Consumer "AC Home" key, not a gamepad button.
3. Share reaches macOS as a keyboard PrintScreen keystroke.
4. M sends nothing. It is a firmware modifier.
5. L4, R4, L5, R5 mirror other buttons. Only GameSir's Windows software reassigns them.

### The drawing

1. `data/controller-front.svg` is the manual's own vector art, extracted with `tools/pdfpaths.swift`.
   The manual draws the product in black and callouts in grey, so the extractor keeps only black paint.
   Do not add shape heuristics; they removed real glyphs before.
2. Button centres in `data/controls.json` come from the SVG's geometry: each button is four quarter arcs,
   and their combined bounding box gives the centre. Do not measure by eye.
3. Directional controls (D-pad, sticks) share one position with their base and carry a `gcDir`.
4. Trigger and bumper callouts sit above the art. Their silhouettes come from the manual's top view,
   traced by rasterising, flood-filling, and rotating upright.

### Compilers

1. The CI runner's Swift is older than a current Mac's. Keep view bodies small; the daemon-drawing view
   once failed to type-check there. Qualify `Double.pi`.
2. The bare Command Line Tools compiler cannot expand the `@State` macro. Use `TimelineView` for
   animation, or `@StateObject` and plain properties.

### Release

1. Tag `vX.Y.Z` and push the tag. The workflow builds on a macOS runner and attaches a zip.
2. The zip is ad-hoc signed. Browser downloads hit Gatekeeper; `curl` and `git` do not.
3. Notarization needs a Developer ID. The workflow has a marked spot for it.

## Tests

`swift test` runs the unit tests in `Tests/G7ProCoreTests` with Swift Testing. The Command Line Tools
are enough; you do not need Xcode. `Package.swift` exists only for this: it exposes Core.swift and
Install.swift as a library. `build-app.sh` still builds the shipped app with swiftc.

What the tests pin down:

1. The index rule, against `Tests/G7ProCoreTests/Fixtures/g7pro-elements.json`, a recording of the pad's
   HID elements. Every reference capture must reproduce the bundled personality's predicate.
2. The personality writer: predicates, product category, untouched model keys.
3. Press detection and edge detection, including the one-pull-one-capture rule for triggers.
4. The data files: unique ids, personality identifiers, glyph keys, directions, and schema conformance.
5. Glyph path parsing.

Re-record the fixture when the pad's firmware changes its descriptor. The recorder is a ten-line
IOKit program: match the pad by vendor and product ID, copy its input elements, write cookie, usage
page, usage, and report ID as JSON. Keep the recorded firmware version in the file.

CI runs `swift test`, builds the app, and runs `g7pro status` on every push and pull request.
Nothing in CI needs a pad, root, or SIP off.

End-to-end tests stay manual. Apple's UI testing needs Xcode, and the real path needs a paired pad,
SIP off, and root, which no runner provides.

## Testing a change by hand

1. Run `swift test`. Fix anything red before you touch the app.
2. Run `./build-app.sh`.
2. Reset to a new-user state when the change touches the flow: `tccutil reset ListenEvent
   com.arcataroger.g7pro-bluetooth-setup`, delete `~/Library/Application Support/G7Pro Bluetooth Setup`,
   and run the app's Uninstall.
3. Walk every step with the pad connected. Verify must light the right control for every press,
   including chords and analog travel.
4. Check `g7pro status` reports the pad as "Xbox One" when the option is on.

## Screenshots for review

`screencapture -l <windowID>` works once the terminal has Screen Recording permission. A small helper
that finds the window by owner name lives in the session history; write one if you need it. Verify
alignment by drawing your hit targets over the SVG offline before trusting the app's rendering.
