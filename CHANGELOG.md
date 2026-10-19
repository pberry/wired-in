# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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
