# Wired In Sign Protocol

Reverse engineered from `Wired In.app` v1.2 (build 8, 2018), specifically
`Contents/Frameworks/WiredIn.framework` (Objective-C, classes `WISerialSign`,
`WISerialSignScanner`, `WISignStatus`, `WIBluetoothSign`). The serial protocol
was confirmed against a real USB sign (firmware 0.4, FTDI `cu.usbserial-*`
port) on 2026-10-19. Items still marked **(unverified)** are inferences.

## Transport

### USB serial

| Setting   | Value                                    |
|-----------|------------------------------------------|
| Baud      | 57600 (`WISerialSignBaudRate` = `0xE100`) |
| Framing   | 8N1, no flow control (ORSSerial defaults) |
| Encoding  | ASCII                                    |

The original app probed every `/dev/cu.*` port **except** ones whose name
contains `bluetooth`, `AirPods` or `Wireless` (case-insensitive).

### Bluetooth LE

| Role                        | UUID                                   |
|-----------------------------|----------------------------------------|
| Primary service             | `9741D001-1EC4-47F4-976B-DB75985F37F1` |
| Receive (sign → host)       | `9741D002-1EC4-47F4-976B-DB75985F37F1` |
| Send (host → sign)          | `9741D003-1EC4-47F4-976B-DB75985F37F1` |
| Disconnect                  | `9741D004-1EC4-47F4-976B-DB75985F37F1` |

The characteristic UUIDs are derived by adding 1/2/3 to the first 32 bits of
the service UUID (big-endian). Peripherals advertise with the local name
`WiredInSign`. Writes use `CBCharacteristicWriteWithoutResponse`.

## Commands (host → sign)

Every command starts with `!` and ends with `;`. Numbers are zero-padded.

| Command  | Format                     | Notes                                             |
|----------|----------------------------|---------------------------------------------------|
| Info     | `!info;`                   | Sent once when probing a port. 1.5 s timeout.     |
| Status   | `!stat;`                   | 0.2 s timeout.                                    |
| On/off   | `!on%01i;`                 | `!on1;` / `!on0;`                                 |
| Color    | `!rgb%03i%03i%03i;`        | Serial. Each channel 0–255, e.g. `!rgb255000000;` |
| Color    | `!rgb255%03i%03i%03i;`     | Bluetooth variant (literal `255` prefix)          |
| Brightness | `!brt%03i;`              | 0–255. App clamps a 0.0–1.0 float, then ×255.      |
| Mode     | `!mode%1i;`                | Single digit. Meaning of modes unknown **(unverified)**. |

Float → integer conversion truncates (`cvttsd2si`), i.e. `Int(value * 255)`.
Colors are converted to the generic RGB color space before conversion.

Serial set-commands (`on`, `rgb`, `brt`, `mode`) expect a status packet back
(0.5 s timeout for color/brightness, 0.2 s for on/mode). A color change
cancels all queued requests first, so dragging a color picker doesn't back up.

## Responses (sign → host)

Responses start with `$` and end with `;`, followed by a NUL (`0x00`) byte.
No output is sent on port open (no boot banner).

### Info

```
$WiredIn:<version>/uid:<unique id>;
```

Captured: `$WiredIn:0.4/uid:2938475202;\0`

Strip `$` and `;`, split on `/`. Component 0, split on `:` must have first
element `WiredIn`; the last element is the firmware version (parsed as float).
Component 1 split on `:` with first element `uid` gives the unique identifier.
Max packet length the app accepted: 30 bytes.

### Status

```
$c: <r>, <g>, <b>/o: <0|1>/b: <brightness>/m: <mode>;
```

Captured: `$c: 255, 000, 000/o: 1/b: 255/m: 0;\0` — note the space after every
`:` and `,`, and zero-padded three-digit values.

Strip `$` and `;`, split on `/` (needs ≥ 3 components; the 4th, mode, is
optional). Each component is `key:value`:

- `c:` — `r,g,b`, each 0–255
- `o:` — on flag (`boolValue`)
- `b:` — brightness 0–255
- `m:` — mode (integer)

The app's packet matcher required a status packet to be **34–35 bytes**. The
spaces explain this: the captured packet is 35 bytes (excluding the NUL). This
rebuild trims whitespace and ignores unknown components rather than relying on
length.

## Other integrations in the original app

- **Slack:** OAuth via `https://slack.com/oauth/authorize` with redirect
  `https://wiredin-auth-redirect.herokuapp.com/` (defunct), then
  `POST /api/users.profile.set` with `{"status_text": ..., "status_emoji": ...}`.
- **IFTTT:** `https://maker.ifttt.com/trigger/<event>/with/key/<key>`.
- **URL scheme** `wiredin://`, including shared presets:
  `wiredin://sharedPreset/<percent-encoded JSON>` where the JSON is
  `{"name": ..., "emoji": ..., "on": bool, "color": {"red","green","blue","alpha"}}`
  (components 0.0–1.0). The 2018 app double-encoded emoji (UTF-8 bytes read as
  Latin-1); the rebuild repairs that on import.
- **Default presets:** Available, Meeting, Wired In.
- **Hotkeys:** global sign-off, window focus, per-preset.
