# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed
- Protocol documentation confirmed against real hardware (firmware 0.4):
  responses include spaces after `:`/`,` and a trailing NUL byte.
- Added tests using packets captured from a real sign.
- `!mode` is now typed (`SignMode.solid` / `.colorCycle`); the only modes the
  firmware supports are 0 and 1.
- `wired mode` takes `solid` or `cycle` instead of 0–9.

### Fixed
- The app now follows changes made with the sign's own on/off button, which
  the firmware reports with an unprompted status packet. `SignSession`'s
  `statusUpdates` now yields `StatusUpdate` values flagged `isUnsolicited`.

### Added
- Color cycle toggle in the main window and menu bar. Leaving the cycle, or
  applying a preset or color, switches back to solid and re-sends the color.
- Hardware and history notes in docs/PROTOCOL.md (Kickstarter details,
  bootloader probe results, likely firmware ancestor).

### Removed
- The 0–9 firmware mode picker in Settings → Devices.
- Slack and IFTTT integrations, and the Keychain helper they used.
- Slack emoji field on presets (existing `slackEmoji` keys in saved presets
  are ignored).

## [0.1.0] - 2026-10-19

### Added
- Reverse-engineered protocol documentation from the 2018 Wired In.app.
- `WiredInKit`: command encoding, response parsing, packet framing, POSIX
  serial transport (57600 8N1), Bluetooth LE transport, request/response
  session with timeouts and retries.
- Presets with JSON persistence and `wiredin://sharedPreset/` links
  compatible with the original app (including its double-encoded emoji).
- Slack (user token) and IFTTT webhook integrations; secrets in Keychain.
- SwiftUI app with preset grid, live color/brightness, menu bar extra,
  global hotkeys, settings, launch at login and URL scheme handling.
- `wired` command line tool.
- `scripts/build-app.sh` to assemble and ad-hoc sign the `.app` bundle.
- swift-testing suite with a simulated sign.
