import Foundation
import WiredInKit

let usage = """
    wired — control a Wired In sign from the shell

    USAGE:
      wired list                         List connected signs
      wired status                       Show the current sign state
      wired on | off                     Turn the sign on or off
      wired color <#RRGGBB>              Set the color
      wired brightness <0-100>           Set brightness (percent)
      wired mode <solid|cycle>           Solid color, or cycle through colors
      wired preset <name|emoji|#color>   Apply a saved preset
      wired presets                      List saved presets
      wired raw '<!command;>'            Send a raw protocol command (debugging)

    OPTIONS:
      --port <path>                      Use a specific serial port (default: scan)
      --help                             Show this help
    """

struct CLIError: Error, CustomStringConvertible {
    let description: String
}

func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

func describe(_ status: SignStatus) -> String {
    "power: \(status.isOn ? "on" : "off")  color: \(status.color.hex)  brightness: \(percent(status.brightness))  mode: \(status.mode)"
}

func connect(port: String?) async throws -> [ConnectedSign] {
    if let port {
        guard let sign = await SignScanner.probe(path: port) else { throw CLIError(description: "No Wired In sign on \(port).") }
        return [sign]
    }
    let signs = await SignScanner.scanSerialPorts()
    guard !signs.isEmpty else { throw CLIError(description: "No Wired In sign found. Is it plugged in? Try --port /dev/cu.usbmodem…") }
    return signs
}

/// Applies an action to every connected sign, printing each resulting status.
func eachSign(port: String?, _ action: @escaping @Sendable (SignSession) async throws -> SignStatus) async throws {
    for sign in try await connect(port: port) {
        let status = try await action(sign.session)
        print("\(sign.name): \(describe(status))")
        await sign.session.close()
    }
}

func run(_ arguments: [String]) async throws {
    var args = arguments
    var port: String?
    if let i = args.firstIndex(of: "--port") {
        guard i + 1 < args.count else { throw CLIError(description: "--port needs a path") }
        port = args[i + 1]
        args.removeSubrange(i...(i + 1))
    }
    guard let command = args.first, !["--help", "-h", "help"].contains(command) else {
        print(usage)
        return
    }
    let value = args.dropFirst().joined(separator: " ")

    switch command {
    case "list":
        for sign in try await connect(port: port) {
            print("\(sign.name)\tid: \(sign.info.uniqueIdentifier)\tfirmware: \(sign.info.version)")
            await sign.session.close()
        }
    case "status":
        try await eachSign(port: port) { try await $0.status() }
    case "on", "off":
        let on = command == "on"
        try await eachSign(port: port) { try await $0.setPower(on) }
    case "color":
        guard let color = SignColor(hex: value) else { throw CLIError(description: "Color must look like #FF8800") }
        try await eachSign(port: port) { try await $0.setColor(color) }
    case "brightness":
        guard let pct = Double(value.replacingOccurrences(of: "%", with: "")), (0...100).contains(pct) else {
            throw CLIError(description: "Brightness must be 0–100")
        }
        try await eachSign(port: port) { try await $0.setBrightness(pct / 100) }
    case "mode":
        let modes: [String: SignMode] = ["solid": .solid, "0": .solid, "cycle": .colorCycle, "1": .colorCycle]
        guard let mode = modes[value.lowercased()] else { throw CLIError(description: "Mode must be solid or cycle") }
        try await eachSign(port: port) { try await $0.setMode(mode) }
    case "presets":
        for preset in PresetStore().load() {
            print("\(preset.emoji)  \(preset.name)\t\(preset.color.hex)\(preset.isOn ? "" : " (off)")")
        }
    case "preset", "p":
        guard let preset = Preset.find(value, in: PresetStore().load()) else {
            throw CLIError(description: "Could not find preset matching '\(value)'. Try `wired presets`.")
        }
        try await eachSign(port: port) { session in
            try await session.setColor(preset.color)
            return try await session.setPower(preset.isOn)
        }
    case "raw":
        for sign in try await connect(port: port) {
            try await sign.session.send(.status)  // ensure reading has started
            try sign.session.transport.send(Data(value.utf8))
            try await Task.sleep(for: .milliseconds(500))
            if let status = await sign.session.lastStatus { print("\(sign.name): \(describe(status))") }
            await sign.session.close()
        }
    default:
        throw CLIError(description: "Unknown command '\(command)'.\n\n\(usage)")
    }
}

do {
    try await run(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
