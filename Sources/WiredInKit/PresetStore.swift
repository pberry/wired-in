import Foundation

/// Persists presets as JSON. Shared by the app and the `wired` CLI.
public struct PresetStore: Sendable {
    public let fileURL: URL

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Wired In", directoryHint: .isDirectory).appending(path: "presets.json")
    }

    public init(fileURL: URL = PresetStore.defaultURL) {
        self.fileURL = fileURL
    }

    /// Returns the saved presets, or the defaults if nothing has been saved yet.
    public func load() -> [Preset] {
        guard let data = try? Data(contentsOf: fileURL),
              let presets = try? JSONDecoder().decode([Preset].self, from: data)
        else { return Preset.defaults }
        return presets
    }

    public func save(_ presets: [Preset]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(presets).write(to: fileURL, options: .atomic)
    }
}
