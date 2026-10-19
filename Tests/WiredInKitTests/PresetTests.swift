import CoreBluetooth
import Foundation
import Testing
@testable import WiredInKit

@Suite struct PresetTests {
    /// The URL embedded in the 2018 binary, including its double-encoded emoji.
    static let legacyURL = "wiredin://sharedPreset/%7B%22emoji%22:%22%C3%B0%C2%9F%C2%91%C2%A4%22,%22name%22:%22Available%22,%22on%22:true,%22color%22:%7B%22green%22:1,%22alpha%22:1,%22red%22:0.09803921568627451,%22blue%22:0%7D%7D"

    @Test func importsLegacySharedPreset() throws {
        let preset = try #require(Preset(sharingURL: URL(string: Self.legacyURL)!))
        #expect(preset.name == "Available")
        #expect(preset.emoji == "👤")
        #expect(preset.isOn)
        #expect(preset.color.bytes == (25, 255, 0))
    }

    @Test func sharingURLRoundTrip() throws {
        let original = Preset(name: "Deep / Work?", emoji: "🧠", color: SignColor(red: 0.2, green: 0.4, blue: 0.6), isOn: false)
        let url = original.sharingURL
        #expect(url.absoluteString.hasPrefix("wiredin://sharedPreset/"))
        let decoded = try #require(Preset(sharingURL: url))
        #expect(decoded.name == original.name)
        #expect(decoded.emoji == original.emoji)
        #expect(decoded.color == original.color)
        #expect(decoded.isOn == false)
    }

    @Test func rejectsOtherURLs() {
        #expect(Preset(sharingURL: URL(string: "https://example.com/sharedPreset/x")!) == nil)
        #expect(Preset(sharingURL: URL(string: "wiredin://sharedPreset/notjson")!) == nil)
    }

    @Test func mojibakeRepairLeavesValidTextAlone() {
        #expect(Preset.repairMojibake("🎧") == "🎧")
        #expect(Preset.repairMojibake("café") == "café")
        #expect(Preset.repairMojibake("plain") == "plain")
    }

    @Test func find() {
        let presets = Preset.defaults
        #expect(Preset.find("meeting", in: presets)?.name == "Meeting")
        #expect(Preset.find("🎧", in: presets)?.name == "Wired In")
        #expect(Preset.find("#FF0000", in: presets)?.name == "Wired In")
        #expect(Preset.find("nothing", in: presets) == nil)
    }

    @Test func decodesPresetsSavedWithSlackEmoji() throws {
        let json = #"[{"id":"3271C2AC-84F1-4949-BEDB-A135E4A0847E","name":"Lunch","emoji":"🥪","isOn":true,"slackEmoji":":sandwich:","color":{"red":1,"green":1,"blue":1}}]"#
        let presets = try JSONDecoder().decode([Preset].self, from: Data(json.utf8))
        #expect(presets.map(\.name) == ["Lunch"])
    }

    @Test func storeRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "wiredin-\(UUID())/presets.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = PresetStore(fileURL: url)
        #expect(store.load() == Preset.defaults)
        let custom = [Preset(name: "Lunch", emoji: "🥪", color: .white)]
        try store.save(custom)
        #expect(store.load() == custom)
    }
}

@Suite struct BluetoothTests {
    @Test func characteristicUUIDs() {
        #expect(WiredInBluetooth.receiveUUID.uuidString == "9741D002-1EC4-47F4-976B-DB75985F37F1")
        #expect(WiredInBluetooth.sendUUID.uuidString == "9741D003-1EC4-47F4-976B-DB75985F37F1")
        #expect(WiredInBluetooth.disconnectUUID.uuidString == "9741D004-1EC4-47F4-976B-DB75985F37F1")
    }
}
