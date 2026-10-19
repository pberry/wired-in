import Foundation

/// A named status: what the sign shows and what integrations announce.
public struct Preset: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var emoji: String
    public var color: SignColor
    public var isOn: Bool
    /// Slack wants `:shortcode:` emoji, not Unicode. Optional.
    public var slackEmoji: String?

    public init(
        id: UUID = UUID(),
        name: String,
        emoji: String,
        color: SignColor,
        isOn: Bool = true,
        slackEmoji: String? = nil
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.color = color
        self.isOn = isOn
        self.slackEmoji = slackEmoji
    }

    public static let defaults: [Preset] = [
        Preset(name: "Available", emoji: "👤", color: SignColor(red: 0.098, green: 1, blue: 0), slackEmoji: ":large_green_circle:"),
        Preset(name: "Meeting", emoji: "📅", color: SignColor(red: 1, green: 0.75, blue: 0), slackEmoji: ":calendar:"),
        Preset(name: "Wired In", emoji: "🎧", color: SignColor(red: 1, green: 0, blue: 0), slackEmoji: ":headphones:"),
    ]

    /// Case-insensitive lookup by name, emoji, or hex color, as the original CLI did.
    public static func find(_ query: String, in presets: [Preset]) -> Preset? {
        let q = query.trimmingCharacters(in: .whitespaces)
        if let match = presets.first(where: { $0.name.caseInsensitiveCompare(q) == .orderedSame }) { return match }
        if let match = presets.first(where: { $0.emoji == q }) { return match }
        if let color = SignColor(hex: q) {
            return presets.first { $0.color.hex == color.hex }
        }
        return nil
    }
}

// MARK: - Shared preset URLs

extension Preset {
    public static let urlScheme = "wiredin"

    private struct SharedPayload: Codable {
        struct RGBA: Codable { var red, green, blue: Double; var alpha: Double? }
        var name: String
        var emoji: String
        var on: Bool?
        var color: RGBA
    }

    /// `wiredin://sharedPreset/<percent-encoded JSON>`, compatible with the 2018 app.
    public var sharingURL: URL {
        let payload = SharedPayload(
            name: name, emoji: emoji, on: isOn,
            color: .init(red: color.red, green: color.green, blue: color.blue, alpha: 1)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = String(decoding: (try? encoder.encode(payload)) ?? Data(), as: UTF8.self)
        let encoded = json.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/", "?", "#"])) ?? ""
        return URL(string: "\(Self.urlScheme)://sharedPreset/\(encoded)")!
    }

    /// Decodes a shared preset URL. Repairs the double-encoded emoji the 2018 app produced.
    public init?(sharingURL url: URL) {
        guard url.scheme == Self.urlScheme, url.host() == "sharedPreset" else { return nil }
        let raw = url.absoluteString.components(separatedBy: "sharedPreset/").dropFirst().joined(separator: "sharedPreset/")
        guard let json = raw.removingPercentEncoding,
              let payload = try? JSONDecoder().decode(SharedPayload.self, from: Data(json.utf8))
        else { return nil }
        self.init(
            name: payload.name,
            emoji: Self.repairMojibake(payload.emoji),
            color: SignColor(red: payload.color.red, green: payload.color.green, blue: payload.color.blue),
            isOn: payload.on ?? true
        )
    }

    /// "ð\u{9F}\u{91}¤" (UTF-8 bytes decoded as Latin-1) → "👤". Leaves valid text alone.
    static func repairMojibake(_ s: String) -> String {
        let scalars = s.unicodeScalars
        guard !scalars.isEmpty, scalars.allSatisfy({ $0.value < 0x100 }), scalars.contains(where: { $0.value >= 0x80 }) else {
            return s
        }
        let bytes = scalars.map { UInt8($0.value) }
        return String(bytes: bytes, encoding: .utf8) ?? s
    }
}
