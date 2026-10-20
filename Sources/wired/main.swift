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
      --port <path>                      Talk to this serial port directly (default: go
                                         through the Wired In app if it's running,
                                         otherwise scan for signs)
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
        do {
            return [try await SignScanner.connect(path: port)]
        } catch SignError.portBusy {
            throw CLIError(description: "\(port) is in use by another program. If the Wired In app is running, quit it or leave out --port.")
        } catch {
            throw CLIError(description: "No Wired In sign on \(port).")
        }
    }
    let signs = await SignScanner.scanSerialPorts()
    guard !signs.isEmpty else { throw CLIError(description: "No Wired In sign found. Is it plugged in? Try --port /dev/cu.usbserial…") }
    return signs
}

func print(_ reports: [SignReport], list: Bool) {
    if reports.isEmpty { print("No sign connected to the Wired In app.") }
    for report in reports {
        if list {
            print("\(report.name)\tid: \(report.id)\tfirmware: \(report.firmware)")
        } else {
            print("\(report.name): \(report.status.map(describe) ?? "no response")")
        }
    }
}

/// Asks the running app to perform the request. Returns nil if the app isn't running.
func viaApp(_ request: ControlRequest) throws -> ControlResponse? {
    do {
        return try ControlClient.send(request)
    } catch SignError.closed {
        return nil
    }
}

/// Talks to the sign(s) directly. Used when the app isn't running or --port is given.
func direct(_ request: ControlRequest, port: String?) async throws {
    for sign in try await connect(port: port) {
        defer { Task { await sign.session.close() } }
        let session = sign.session
        let status: SignStatus
        switch request {
        case .list:
            print("\(sign.name)\tid: \(sign.info.uniqueIdentifier)\tfirmware: \(sign.info.version)")
            continue
        case .status: status = try await session.status()
        case .power(let on): status = try await session.setPower(on)
        case .color(let color): status = try await session.setColor(color)
        case .brightness(let value): status = try await session.setBrightness(value)
        case .mode(let mode): status = try await session.setMode(mode)
        case .preset(let query):
            guard let preset = Preset.find(query, in: PresetStore().load()) else {
                throw CLIError(description: "Could not find preset matching '\(query)'. Try `wired presets`.")
            }
            try await session.setMode(.solid)
            try await session.setColor(preset.color)
            status = try await session.setPower(preset.isOn)
        }
        print("\(sign.name): \(describe(status))")
    }
}

func request(for command: String, _ value: String) throws -> ControlRequest? {
    switch command {
    case "list": return .list
    case "status": return .status
    case "on", "off": return .power(command == "on")
    case "color":
        guard let color = SignColor(hex: value) else { throw CLIError(description: "Color must look like #FF8800") }
        return .color(color)
    case "brightness":
        guard let pct = Double(value.replacingOccurrences(of: "%", with: "")), (0...100).contains(pct) else {
            throw CLIError(description: "Brightness must be 0–100")
        }
        return .brightness(pct / 100)
    case "mode":
        let modes: [String: SignMode] = ["solid": .solid, "0": .solid, "cycle": .colorCycle, "1": .colorCycle]
        guard let mode = modes[value.lowercased()] else { throw CLIError(description: "Mode must be solid or cycle") }
        return .mode(mode)
    case "preset", "p":
        return .preset(value)
    default:
        return nil
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

    if let request = try request(for: command, value) {
        // The app owns the serial port while it runs, so route through it.
        if port == nil, let response = try viaApp(request) {
            if let error = response.error { throw CLIError(description: error) }
            print(response.signs, list: request == .list)
        } else {
            try await direct(request, port: port)
        }
        return
    }

    switch command {
    case "presets":
        for preset in PresetStore().load() {
            print("\(preset.emoji)  \(preset.name)\t\(preset.color.hex)\(preset.isOn ? "" : " (off)")")
        }
    case "raw":
        if try viaApp(.list) != nil {
            throw CLIError(description: "`raw` needs the serial port to itself. Quit the Wired In app first.")
        }
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
