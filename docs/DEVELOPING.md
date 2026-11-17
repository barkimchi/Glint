# Developing Glint

## Build from source

Needs Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen && xcodebuild -project Glint.xcodeproj -scheme Glint -derivedDataPath build build
```

The app lands in `build/Build/Products/Debug/Glint.app`. By default it is ad hoc signed, so no Apple developer account is needed. To sign with your own certificate, which keeps the Screen Recording grant across rebuilds, put it in `Config/Local.xcconfig` (see `Config/Signing.xcconfig`).

## Launch flags

Pass these to `Glint.app/Contents/MacOS/Glint`. Tests and demos log to `/tmp/glint-scrolltest.log`.

| Flag | What it does |
|---|---|
| `--selftest <dir>` | Runs capture, crop, every annotation tool, OCR, a short recording, GIF export and the stitching tests headlessly |
| `--editor-selftest <png>` | Select, move, resize, recolour, delete, undo and redo on the editor model, plus a framed export |
| `--ring-selftest` | Long press, drag, remove, add and Done on the popup with synthetic mouse events (never touches your saved layout) |
| `--pile-test <dir>` | Takes three made-up screenshots in a row, renders the stacked and fanned-out pile into `<dir>`, clicks it, and logs what a drag and Copy all carry (Copy all goes to a private pasteboard) |
| `--emoji-selftest` | Checks the keystroke the Emoji Picker sends (without sending it), the default shortcuts, and the one-time popup migration that adds new actions |
| `--trackpad-selftest` | Feeds made-up touches through the trackpad edge gestures and logs what fired, plus whether a trackpad was found |
| `--scrolltest x,y,w,h` | Runs a real auto-scrolling capture on a screen region |
| `--pickertest <window title>` | Runs the real Keep on Top action through the picker and clicks that window |
| `--toptest <App or window title>` | Locks that window on top and logs frames, placement and visibility for 12 s (clicks the live view at 7 s) |
| `--edit <png>` | Opens the editor on an image |
| `--pin <png>` | Pins an image |
| `--frame <in.png> <out.png> <preset>` | Writes the image framed on a background (sunrise, ocean, mint, grape, slate, paper) |
| `--settings`, `--widget-open`, `--ring-open`, `--ring-edit` | Open that surface at launch |
| `--tour`, `--whats-new` | Open the welcome tour or the What's New card (add `-tour.startStep N` to start the tour at step N) |
| `--tour --tour-capture-test -tour.startStep 2` | Runs a real area capture while the tour sits on "Try it" and logs whether the step reacted (logs the saved files so you can remove them) |
| `-onboarding.simulateNewUser YES`, `-onboarding.simulateVersion 0.2.0` | Normal launch, but decide tour / What's New / nothing as a new user or for that version. Logs the decision and writes nothing to your settings |
| `--shots <dir>` | Renders every open Glint window to a PNG |
| `--demo <popup\|capture\|annotate> <scene.png> <x,y,w,h>` | Plays a scripted walkthrough on a stage window, for the README GIFs |

## README GIFs

```bash
docs/demo/record.sh
```

Records the three walkthroughs from `--demo` on a stage window showing a made-up dashboard (`docs/demo/scene.png`), refuses any clip that is cut short or has a frame showing anything but the demo, and writes `docs/popup-edit.gif`, `docs/capture.gif` and `docs/annotate.gif`. Pass `"" popup` (or `capture`, `annotate`) to redo one. Keep hands off the Mac for the minute it runs.

## Cutting a release

Bump `CFBundleShortVersionString` and `CFBundleVersion` in `project.yml` and `version` in `package.json`. If the release has something worth showing, add an entry for the new version to `WhatsNew.notes` in `Sources/Onboarding.swift` (media goes in `Sources/Resources/WhatsNew/`); people updating see it on their first two launches of that version. New users get the welcome tour instead. Commit, then push a version tag:

```bash
git tag v0.1.9 && git push origin v0.1.9
```

The release workflow (`.github/workflows/release.yml`) builds on a macOS runner, signs with the Developer ID, has Apple notarize and staple it, signs the update for Sparkle, and publishes the zip. It then adds the appcast entry and pins the tag and checksum into `bin/RELEASE` and `bin/SHA256`, so the installer fetches exactly that release. `scripts/release.sh` does the build, sign and notarize steps locally.

For a beta, push a tag with a hyphen ending in a number (`v0.2.3-beta.3`). It is signed and notarized the same way, published as a pre-release, and added to the appcast on Sparkle's `beta` channel, so only copies with Settings > Updates > Get beta builds on are offered it (a beta build has it on by default). It gets build number `<last release build>.<N>`, so leave `project.yml` alone until the real release. The installer pin is not touched.

## Diagnostic log

`defaults write com.barkimchi.glint debug.log -bool YES`, relaunch, and Glint writes each step (shortcuts registered and pressed, actions, picker shown or blocked, selections, Keep on Top locks) to `~/Library/Logs/Glint/glint.log`. Turn it off with `-bool NO`.
