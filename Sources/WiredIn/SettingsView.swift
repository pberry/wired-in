import SwiftUI
import WiredInKit

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            DevicesSettings().tabItem { Label("Devices", systemImage: "cable.connector") }
            IntegrationsSettings().tabItem { Label("Integrations", systemImage: "link") }
        }
        .frame(width: 480)
    }
}

private struct GeneralSettings: View {
    @Environment(SignController.self) private var controller

    var body: some View {
        @Bindable var controller = controller
        Form {
            Toggle("Launch at login", isOn: Binding(
                get: { controller.launchAtLogin },
                set: { controller.launchAtLogin = $0 }
            ))
            LabeledContent("Default brightness") {
                Slider(value: $controller.brightness, in: 0.05...1) { editing in
                    if !editing { controller.commitBrightness() }
                }
            }
            Section("Keyboard shortcuts") {
                LabeledContent("Apply preset 1–9", value: "⌃⌥⌘1 … ⌃⌥⌘9")
                LabeledContent("Turn sign off", value: "⌃⌥⌘0")
                LabeledContent("Show window", value: "⌃⌥⌘W")
            }
            Section("Command line") {
                Text("The `wired` tool ships inside the app. Link it onto your PATH with:")
                    .foregroundStyle(.secondary)
                Text(verbatim: "ln -s \"\(Bundle.main.bundlePath)/Contents/MacOS/wired\" /usr/local/bin/wired")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }
}

private struct DevicesSettings: View {
    @Environment(SignController.self) private var controller
    @State private var mode = 0

    var body: some View {
        @Bindable var controller = controller
        Form {
            Section("Connected signs") {
                if controller.signs.isEmpty {
                    Text(controller.isScanning ? "Scanning…" : "No signs found. Plug one in via USB.")
                        .foregroundStyle(.secondary)
                }
                ForEach(controller.signs) { sign in
                    LabeledContent {
                        Text(sign.kind == .bluetooth ? "Bluetooth" : "Firmware \(sign.info.version, format: .number)")
                    } label: {
                        Text(sign.name)
                        Text("ID \(sign.id)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("Scan Now") { Task { await controller.scanSerialPorts() } }
            }
            Section {
                Toggle("Look for Bluetooth signs", isOn: $controller.bluetoothEnabled)
            } footer: {
                Text("Bluetooth support is untested; the original app shipped it but most signs are USB.")
            }
            Section {
                Picker("Firmware mode", selection: $mode) {
                    ForEach(0..<10) { Text("\($0)").tag($0) }
                }
                .onChange(of: mode) { controller.setMode(mode) }
            } header: {
                Text("Advanced")
            } footer: {
                Text("The firmware accepts `!mode0;`–`!mode9;`, but what each mode does is unknown.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct IntegrationsSettings: View {
    @Environment(SignController.self) private var controller

    var body: some View {
        @Bindable var controller = controller
        Form {
            Section {
                SecureField("User token (xoxp-…)", text: $controller.slackToken)
            } header: {
                Text("Slack")
            } footer: {
                Text("Create a Slack app at api.slack.com/apps, add the `users.profile:write` user scope, install it to your workspace and paste the User OAuth Token. Set a Slack emoji on each preset.")
            }
            Section {
                SecureField("Webhooks key", text: $controller.iftttKey)
                TextField("Event name", text: $controller.iftttEvent)
            } header: {
                Text("IFTTT")
            } footer: {
                Text("Fires on every status change with value1 = name, value2 = emoji, value3 = hex color.")
            }
        }
        .formStyle(.grouped)
    }
}
