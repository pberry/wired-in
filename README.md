# Wired In

A modern, open rebuild of the discontinued **Wired In** desk sign app for macOS.

The original `Wired In.app` (v1.2, 2018) is Intel-only, built against the
macOS 10.14 SDK, and depends on a dead OAuth relay and Crashlytics. This
project reverse engineered its sign protocol (see
[docs/PROTOCOL.md](docs/PROTOCOL.md)) and reimplements it in Swift with no
third-party dependencies. The original's Slack and IFTTT integrations are
intentionally not included.

## Features

- Finds USB serial signs automatically (and Bluetooth signs, optionally)
- Presets with name, emoji, color and on/off; drag-free one-click switching
- Live color picker and brightness slider
- Menu bar extra and global hotkeys (⌃⌥⌘1–9 presets, ⌃⌥⌘0 off, ⌃⌥⌘W window)
- `wiredin://` URLs, compatible with the original shared preset links
- `wired` command line tool
- Launch at login

## Requirements

- macOS 14 or later
- Xcode 16+ / Swift 6 toolchain to build

## Build

```sh
swift test                     # run the test suite
scripts/build-app.sh           # produces build/Wired In.app
scripts/build-app.sh --install # also copies it to /Applications
```

If the original `Wired In.app` is in the project root, its icon is reused.

## Command line

```sh
swift run wired list
swift run wired preset "Wired In"
swift run wired color '#00FF88'
swift run wired brightness 40
swift run wired off
```

The app bundle also contains `Contents/MacOS/wired`; symlink it onto your PATH
(Settings → General shows the exact command). The CLI and the app share
presets (`~/Library/Application Support/Wired In/presets.json`). Avoid running
CLI commands while the app holds the serial port open.

## URL scheme

| URL                                   | Action                          |
|---------------------------------------|---------------------------------|
| `wiredin://preset/<name>`             | Apply a preset                  |
| `wiredin://on`, `wiredin://off`       | Power                           |
| `wiredin://color/<RRGGBB>`            | Set color                       |
| `wiredin://sharedPreset/<json>`       | Import a shared preset          |

Right-click a preset → **Copy Share Link** to share one.

## Layout

```
Sources/WiredInKit   protocol, serial/BLE transports, presets
Sources/WiredIn      SwiftUI app
Sources/wired        CLI
Tests/               swift-testing suite (uses a simulated sign)
docs/PROTOCOL.md     the reverse-engineered protocol
```

## Status

Verified working with a USB sign (firmware 0.4). The meaning of the firmware's
`!modeN;` values is still unknown; see docs/PROTOCOL.md.
