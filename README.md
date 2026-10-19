# Wired In

A modern, open rebuild of the discontinued **Wired In** desk sign app for macOS.

The original `Wired In.app` (v1.2, 2018) is Intel-only, built against the
macOS 10.14 SDK, and depends on a dead OAuth relay and Crashlytics. This
project reverse engineered its sign protocol (see
[docs/PROTOCOL.md](docs/PROTOCOL.md)) and reimplements it in Swift with no
third-party dependencies.

## Features

- Finds USB serial signs automatically (and Bluetooth signs, optionally)
- Presets with name, emoji, color and on/off; drag-free one-click switching
- Live color picker and brightness slider
- Menu bar extra and global hotkeys (⌃⌥⌘1–9 presets, ⌃⌥⌘0 off, ⌃⌥⌘W window)
- Slack status updates (bring your own user token) and IFTTT webhooks
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

## Slack

The original app's OAuth redirect (`wiredin-auth-redirect.herokuapp.com`) is
gone, so you use your own Slack app:

1. Create an app at <https://api.slack.com/apps>.
2. Under **OAuth & Permissions**, add the **user** scope `users.profile:write`.
3. Install it to your workspace and copy the **User OAuth Token** (`xoxp-…`).
4. Paste it into Settings → Integrations. Give each preset a Slack emoji
   such as `:headphones:`.

Tokens are stored in the Keychain.

## Layout

```
Sources/WiredInKit   protocol, serial/BLE transports, presets, integrations
Sources/WiredIn      SwiftUI app
Sources/wired        CLI
Tests/               swift-testing suite (uses a simulated sign)
docs/PROTOCOL.md     the reverse-engineered protocol
```

## Status

Built and tested against a simulated sign only. Real hardware verification is
pending; see the **(unverified)** notes in the protocol doc.
