import SwiftUI
import WiredInKit

struct MenuBarView: View {
    @Environment(SignController.self) private var controller
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(Array(controller.presets.prefix(9).enumerated()), id: \.element.id) { index, preset in
            Button {
                controller.apply(preset)
            } label: {
                Text("\(controller.activePresetID == preset.id ? "✓ " : "")\(preset.emoji) \(preset.name)")
            }
            .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.control, .option, .command])
        }
        Toggle("Color Cycle", isOn: Binding(get: { controller.isCycling }, set: { controller.setCycling($0) }))
        Divider()
        Button("Turn Off") { controller.turnOff() }
            .keyboardShortcut("0", modifiers: [.control, .option, .command])
        Divider()
        Text(controller.signs.isEmpty ? "No sign connected" : controller.signs.map(\.name).joined(separator: ", "))
        Button("Open Wired In…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Wired In") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
