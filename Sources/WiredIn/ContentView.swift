import SwiftUI
import WiredInKit

struct ContentView: View {
    @Environment(SignController.self) private var controller
    @State private var editing: Preset?
    @State private var savingCurrent = false

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 12)]

    var body: some View {
        @Bindable var controller = controller
        VStack(spacing: 0) {
            StatusHeader()
            Divider()
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(Array(controller.presets.enumerated()), id: \.element.id) { index, preset in
                        PresetTile(preset: preset, index: index, isActive: controller.activePresetID == preset.id)
                            .onTapGesture { controller.apply(preset) }
                            .contextMenu {
                                Button("Edit…") { editing = preset }
                                Button("Copy Share Link") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(preset.sharingURL.absoluteString, forType: .string)
                                }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    controller.presets.removeAll { $0.id == preset.id }
                                }
                            }
                    }
                    Button { savingCurrent = true } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "plus").font(.title2)
                            Text("Save Current").font(.caption)
                        }
                        .frame(width: 88, height: 104)
                        .foregroundStyle(.secondary)
                        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary, style: .init(lineWidth: 1.5, dash: [4])))
                    }
                    .buttonStyle(.plain)
                }
                .padding()
            }
            if let error = controller.lastError {
                Divider()
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    Text(error).font(.caption).lineLimit(2)
                    Spacer()
                    Button("Dismiss") { controller.lastError = nil }.controlSize(.small)
                }
                .padding(8)
            }
        }
        .frame(width: 380, height: 480)
        .sheet(item: $editing) { preset in
            PresetEditor(preset: preset) { updated in
                if let i = controller.presets.firstIndex(where: { $0.id == updated.id }) {
                    controller.presets[i] = updated
                }
            }
        }
        .sheet(isPresented: $savingCurrent) {
            PresetEditor(preset: Preset(name: "", emoji: "💡", color: controller.color)) { new in
                controller.presets.append(new)
            }
        }
    }
}

/// Current state plus live color, brightness and power controls.
struct StatusHeader: View {
    @Environment(SignController.self) private var controller

    var body: some View {
        @Bindable var controller = controller
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Circle()
                    .fill(Color(nsColor: controller.displayColor.nsColor).opacity(controller.isOn ? 1 : 0.15))
                    .overlay(Circle().strokeBorder(.quaternary))
                    .frame(width: 44, height: 44)
                    .shadow(color: controller.isOn ? Color(nsColor: controller.displayColor.nsColor).opacity(0.6) : .clear, radius: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(.headline)
                    Text(signSummary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Power", isOn: Binding(get: { controller.isOn }, set: { controller.setPower($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            HStack {
                ColorPicker("Color", selection: Binding(
                    get: { Color(nsColor: controller.displayColor.nsColor) },
                    set: { new in
                        // The picker hands back the colors it's given (lossily, via another
                        // color space). Treating those echoes as picks would end the cycle.
                        let picked = SignColor(NSColor(new))
                        guard !picked.isClose(to: SignColor(controller.displayColor.nsColor)) else { return }
                        controller.setColor(picked)
                    }
                ), supportsOpacity: false)
                .labelsHidden()
                Image(systemName: "sun.min")
                Slider(value: $controller.brightness, in: 0.05...1) { editing in
                    if !editing { controller.commitBrightness() }
                }
                Image(systemName: "sun.max")
                Toggle(isOn: Binding(get: { controller.isCycling }, set: { controller.setCycling($0) })) {
                    Image(systemName: "rainbow")
                }
                .toggleStyle(.button)
                .help("Cycle through colors")
            }
        }
        .padding()
    }

    private var headline: String {
        guard controller.isOn else { return "Off" }
        if controller.isCycling { return "🌈 Color cycle" }
        return controller.activePreset.map { "\($0.emoji) \($0.name)" } ?? "Custom"
    }

    private var signSummary: String {
        switch controller.signs.count {
        case 0: controller.isScanning ? "Looking for signs…" : "No sign connected"
        case 1: controller.signs[0].name
        default: "\(controller.signs.count) signs connected"
        }
    }
}

struct PresetTile: View {
    let preset: Preset
    let index: Int
    let isActive: Bool

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().fill(Color(nsColor: preset.color.nsColor))
                Text(preset.emoji).font(.system(size: 30))
            }
            .frame(width: 64, height: 64)
            .overlay(Circle().strokeBorder(isActive ? Color.accentColor : .clear, lineWidth: 3).padding(-4))
            Text(preset.name).font(.caption).lineLimit(1)
            if index < 9 {
                Text("⌃⌥⌘\(index + 1)").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(width: 88, height: 104)
        .contentShape(Rectangle())
    }
}

struct PresetEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var preset: Preset
    let onSave: (Preset) -> Void

    var body: some View {
        Form {
            TextField("Name", text: $preset.name)
            TextField("Emoji", text: $preset.emoji)
            ColorPicker("Color", selection: Binding(
                get: { Color(nsColor: preset.color.nsColor) },
                set: { preset.color = SignColor(NSColor($0)) }
            ), supportsOpacity: false)
            Toggle("Sign on", isOn: $preset.isOn)
        }
        .formStyle(.grouped)
        .frame(width: 340)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    onSave(preset)
                    dismiss()
                }
                .disabled(preset.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}
