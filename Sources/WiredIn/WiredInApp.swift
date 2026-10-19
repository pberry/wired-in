import AppKit
import SwiftUI
import WiredInKit

@main
struct WiredInApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var controller = SignController.shared

    var body: some Scene {
        Window("Wired In", id: "main") {
            ContentView()
                .environment(controller)
                .onOpenURL { controller.handle($0) }
        }
        .windowResizability(.contentSize)
        .handlesExternalEvents(matching: ["*"])

        MenuBarExtra {
            MenuBarView()
                .environment(controller)
        } label: {
            Image(systemName: controller.isOn && !controller.signs.isEmpty ? "light.beacon.max.fill" : "light.beacon.min")
        }

        Settings {
            SettingsView()
                .environment(controller)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            let controller = SignController.shared
            controller.start()
            let hotKeys = HotKeys.shared
            hotKeys.onPreset = { index in
                if controller.presets.indices.contains(index) { controller.apply(controller.presets[index]) }
            }
            hotKeys.onOff = { controller.turnOff() }
            hotKeys.onShowWindow = {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.identifier?.rawValue == "main" }?.makeKeyAndOrderFront(nil)
            }
            hotKeys.register()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
