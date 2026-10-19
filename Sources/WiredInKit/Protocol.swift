import Foundation

/// An RGB color with 0.0–1.0 components, independent of AppKit.
public struct SignColor: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Creates a color from 0–255 channel values.
    public init(red255: Int, green255: Int, blue255: Int) {
        self.init(red: Double(red255) / 255, green: Double(green255) / 255, blue: Double(blue255) / 255)
    }

    /// Parses `#RRGGBB` or `RRGGBB`.
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red255: Int(v >> 16 & 0xFF), green255: Int(v >> 8 & 0xFF), blue255: Int(v & 0xFF))
    }

    /// Channel values as sent to the sign. Truncates like the original app.
    public var bytes: (red: Int, green: Int, blue: Int) {
        (SignColor.byte(red), SignColor.byte(green), SignColor.byte(blue))
    }

    public var hex: String {
        let b = bytes
        return String(format: "#%02X%02X%02X", b.red, b.green, b.blue)
    }

    static func byte(_ value: Double) -> Int {
        Int(min(max(value, 0), 1) * 255)
    }

    public static let red = SignColor(red: 1, green: 0, blue: 0)
    public static let green = SignColor(red: 0, green: 1, blue: 0)
    public static let blue = SignColor(red: 0, green: 0, blue: 1)
    public static let white = SignColor(red: 1, green: 1, blue: 1)
}

/// Which wire dialect to speak. Bluetooth signs use a different color command.
public enum SignTransportKind: String, Codable, Sendable {
    case serial
    case bluetooth
}

/// Commands the host can send to a sign. See docs/PROTOCOL.md.
public enum SignCommand: Equatable, Sendable {
    case info
    case status
    case power(Bool)
    case color(SignColor)
    /// 0.0–1.0, clamped.
    case brightness(Double)
    case mode(Int)

    public func encoded(for kind: SignTransportKind = .serial) -> String {
        switch self {
        case .info:
            return "!info;"
        case .status:
            return "!stat;"
        case .power(let on):
            return "!on\(on ? 1 : 0);"
        case .color(let color):
            let b = color.bytes
            let prefix = kind == .bluetooth ? "!rgb255" : "!rgb"
            return prefix + String(format: "%03d%03d%03d;", b.red, b.green, b.blue)
        case .brightness(let value):
            return String(format: "!brt%03d;", SignColor.byte(value))
        case .mode(let mode):
            return "!mode\(min(max(mode, 0), 9));"
        }
    }

    public func data(for kind: SignTransportKind = .serial) -> Data {
        Data(encoded(for: kind).utf8)
    }
}

/// Firmware identity returned by `!info;`.
public struct SignInfo: Equatable, Sendable {
    public var version: Double
    public var uniqueIdentifier: String

    public init(version: Double, uniqueIdentifier: String) {
        self.version = version
        self.uniqueIdentifier = uniqueIdentifier
    }

    /// Parses `$WiredIn:<version>/uid:<id>;`.
    public init?(response: String) {
        guard let body = Self.body(of: response) else { return nil }
        let parts = body.components(separatedBy: "/")
        guard parts.count >= 2 else { return nil }
        let head = parts[0].components(separatedBy: ":")
        guard head.first == "WiredIn", let versionString = head.last, let version = Double(versionString) else {
            return nil
        }
        let uid = parts[1].components(separatedBy: ":")
        guard uid.first == "uid", uid.count >= 2, let id = uid.last, !id.isEmpty else { return nil }
        self.init(version: version, uniqueIdentifier: id)
    }

    /// Strips the `$` prefix and `;` suffix.
    static func body(of response: String) -> String? {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("$"), trimmed.hasSuffix(";"), trimmed.count >= 2 else { return nil }
        return String(trimmed.dropFirst().dropLast())
    }
}

/// Sign state returned by `!stat;` and by every set-command.
public struct SignStatus: Equatable, Sendable {
    public var color: SignColor
    /// 0.0–1.0
    public var brightness: Double
    public var isOn: Bool
    public var mode: Int

    public init(color: SignColor, brightness: Double, isOn: Bool, mode: Int = 0) {
        self.color = color
        self.brightness = brightness
        self.isOn = isOn
        self.mode = mode
    }

    /// Parses `$c:r,g,b/o:1/b:255/m:0;`. Unknown components are ignored.
    public init?(response: String) {
        guard let body = SignInfo.body(of: response) else { return nil }
        let parts = body.components(separatedBy: "/")
        guard parts.count >= 3 else { return nil }

        var color: SignColor?
        var isOn: Bool?
        var brightness: Double?
        var mode = 0
        for part in parts {
            let kv = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "c":
                let rgb = kv[1].components(separatedBy: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                guard rgb.count >= 3 else { return nil }
                color = SignColor(red255: rgb[0], green255: rgb[1], blue255: rgb[2])
            case "o":
                // Mirrors NSString.boolValue: leading digit 1-9 or Y/y/T/t is true.
                isOn = kv[1].first.map { "123456789YyTt".contains($0) } ?? false
            case "b":
                brightness = Double(kv[1]).map { $0 / 255 }
            case "m":
                mode = Int(kv[1]) ?? 0
            default:
                continue
            }
        }
        guard let color, let isOn, let brightness else { return nil }
        self.init(color: color, brightness: brightness, isOn: isOn, mode: mode)
    }
}

/// A `$...;` packet received from the sign.
public enum SignResponse: Equatable, Sendable {
    case info(SignInfo)
    case status(SignStatus)
    case unknown(String)

    public init(_ packet: String) {
        if let info = SignInfo(response: packet) {
            self = .info(info)
        } else if let status = SignStatus(response: packet) {
            self = .status(status)
        } else {
            self = .unknown(packet)
        }
    }
}

/// Splits a byte stream into `$...;` packets. Bytes outside a packet are dropped.
public struct PacketFramer: Sendable {
    public static let maxPacketLength = 128
    private var buffer: [UInt8] = []
    private var inPacket = false

    public init() {}

    public mutating func append(_ data: Data) -> [String] {
        var packets: [String] = []
        for byte in data {
            switch byte {
            case UInt8(ascii: "$"):
                buffer = [byte]
                inPacket = true
            case UInt8(ascii: ";") where inPacket:
                buffer.append(byte)
                if let s = String(bytes: buffer, encoding: .ascii) { packets.append(s) }
                buffer.removeAll()
                inPacket = false
            default:
                guard inPacket else { continue }
                buffer.append(byte)
                if buffer.count > Self.maxPacketLength {
                    buffer.removeAll()
                    inPacket = false
                }
            }
        }
        return packets
    }
}
