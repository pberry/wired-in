import AppKit
import CoreBluetooth
import Observation
import ServiceManagement
import WiredInKit

/// One connected sign as shown in the UI.
@MainActor
@Observable
final class SignEntry: Identifiable {
    let id: String
    let name: String
    let info: SignInfo
    let kind: SignTransportKind
    let session: SignSession
    /// Serial device path, used to avoid re-probing an open port.
    let path: String?
    var status: SignStatus?

    init(name: String, info: SignInfo, kind: SignTransportKind, session: SignSession, path: String?) {
        self.id = info.uniqueIdentifier
        self.name = name
        self.info = info
        self.kind = kind
        self.session = session
        self.path = path
    }
}

/// App-wide state: connected signs and presets.
@MainActor
@Observable
final class SignController {
    static let shared = SignController()

    private(set) var signs: [SignEntry] = []
    var presets: [Preset] { didSet { savePresets() } }
    private(set) var activePresetID: Preset.ID?
    private(set) var isScanning = false
    var lastError: String?

    /// The state the user last asked for, shown even before any sign responds.
    private(set) var color: SignColor = .white
    private(set) var isOn = true
    private(set) var isCycling = false
    var brightness: Double {
        didSet { UserDefaults.standard.set(brightness, forKey: Keys.brightness) }
    }

    var bluetoothEnabled: Bool {
        didSet {
            UserDefaults.standard.set(bluetoothEnabled, forKey: Keys.bluetooth)
            updateBluetooth()
        }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                lastError = "Could not change login item: \(error.localizedDescription)"
            }
        }
    }

    var activePreset: Preset? { presets.first { $0.id == activePresetID } }

    private enum Keys {
        static let brightness = "DefaultBrightness"
        static let bluetooth = "BluetoothEnabled"
    }

    private let store = PresetStore()
    private var scanTask: Task<Void, Never>?
    private var colorTask: Task<Void, Never>?
    private var bluetooth: BluetoothScanner?

    private init() {
        let defaults = UserDefaults.standard
        presets = store.load()
        brightness = defaults.object(forKey: Keys.brightness) as? Double ?? 1
        bluetoothEnabled = defaults.bool(forKey: Keys.bluetooth)
    }

    // MARK: - Discovery

    /// Polls for newly attached serial signs every few seconds.
    func start() {
        guard scanTask == nil else { return }
        updateBluetooth()
        scanTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.scanSerialPorts()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func scanSerialPorts() async {
        let candidates = SerialPort.candidatePaths()
        let known = Set(signs.compactMap(\.path))
        let fresh = candidates.filter { !known.contains($0) }
        guard !fresh.isEmpty else { return }
        isScanning = true
        defer { isScanning = false }
        for sign in await SignScanner.scanSerialPorts(paths: fresh) {
            let port = sign.session.transport as? SerialPort
            add(SignEntry(name: sign.name, info: sign.info, kind: .serial, session: sign.session, path: port?.path))
        }
    }

    private func updateBluetooth() {
        if bluetoothEnabled, bluetooth == nil {
            let scanner = BluetoothScanner()
            scanner.onConnect = { [weak self] peripheral, transport in
                let session = SignSession(transport: transport)
                let info = SignInfo(version: 0, uniqueIdentifier: peripheral.identifier.uuidString)
                self?.add(SignEntry(
                    name: peripheral.name ?? WiredInBluetooth.advertisedName,
                    info: info, kind: .bluetooth, session: session, path: nil))
            }
            scanner.onDisconnect = { [weak self] peripheral in
                self?.signs.removeAll { $0.id == peripheral.identifier.uuidString }
            }
            bluetooth = scanner
        } else if !bluetoothEnabled, let scanner = bluetooth {
            scanner.stopScanning()
            for sign in signs where sign.kind == .bluetooth {
                Task { await sign.session.close() }
            }
            signs.removeAll { $0.kind == .bluetooth }
            bluetooth = nil
        }
    }

    private func add(_ entry: SignEntry) {
        guard !signs.contains(where: { $0.id == entry.id }) else {
            Task { await entry.session.close() }
            return
        }
        signs.append(entry)
        // Track status, and drop the sign when its connection ends.
        Task { [weak self, weak entry] in
            guard let stream = entry?.session.statusUpdates else { return }
            for await status in stream {
                entry?.status = status
                if status.mode == SignMode.colorCycle.rawValue { self?.isCycling = true }
            }
            self?.signs.removeAll { $0 === entry }
        }
        // Bring a newly attached sign in line with the current state.
        Task {
            var signIsCycling = false
            if entry.kind == .serial, let status = try? await entry.session.status() {
                signIsCycling = status.mode == SignMode.colorCycle.rawValue
                if signIsCycling { isCycling = true }
            }
            let (brightness, color, isOn, skipColor) = (brightness, color, isOn, signIsCycling)
            await push(to: entry.session, kind: entry.kind) { session in
                try await session.setBrightness(brightness)
                if !skipColor { try await session.setColor(color) }
                try await session.setPower(isOn)
            }
        }
    }

    // MARK: - Control

    func apply(_ preset: Preset) {
        activePresetID = preset.id
        color = preset.color
        isOn = preset.isOn
        let wasCycling = isCycling
        isCycling = false
        broadcast { [brightness] session in
            if wasCycling { try await session.setMode(.solid) }
            try await session.setColor(preset.color)
            try await session.setBrightness(brightness)
            try await session.setPower(preset.isOn)
        }
    }

    func turnOff() {
        isOn = false
        activePresetID = nil
        broadcast { try await $0.setPower(false) }
    }

    func setPower(_ on: Bool) {
        if on, let preset = activePreset {
            apply(preset)
        } else if on {
            isOn = true
            broadcast { try await $0.setPower(true) }
        } else {
            turnOff()
        }
    }

    /// Live color changes (e.g. dragging a picker). Coalesced so the serial line doesn't back up.
    func setColor(_ newColor: SignColor) {
        color = newColor
        activePresetID = nil
        colorTask?.cancel()
        let wasCycling = isCycling
        isCycling = false
        colorTask = Task {
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            broadcast { session in
                if wasCycling { try await session.setMode(.solid) }
                try await session.setColor(newColor)
            }
        }
    }

    func commitBrightness() {
        broadcast { [brightness] in try await $0.setBrightness(brightness) }
    }

    /// Leaving the cycle freezes the sign on a random color, so the chosen color is re-sent.
    func setCycling(_ cycling: Bool) {
        isCycling = cycling
        if cycling { activePresetID = nil }
        broadcast { [color] session in
            if cycling {
                try await session.setMode(.colorCycle)
            } else {
                try await session.setMode(.solid)
                try await session.setColor(color)
            }
        }
    }

    /// Runs commands against every sign. BLE signs don't answer, so those are fire-and-forget.
    private func broadcast(_ commands: @escaping @Sendable (SignSession) async throws -> Void) {
        for sign in signs {
            Task { await push(to: sign.session, kind: sign.kind, commands) }
        }
    }

    private func push(
        to session: SignSession, kind: SignTransportKind,
        _ commands: @escaping @Sendable (SignSession) async throws -> Void
    ) async {
        do {
            try await commands(session)
        } catch SignError.timeout where kind == .bluetooth {
            // Expected: BLE writes are unacknowledged.
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Presets

    func savePresets() {
        do { try store.save(presets) } catch { lastError = "Could not save presets: \(error.localizedDescription)" }
    }

    func saveCurrentAsPreset(name: String, emoji: String) {
        let preset = Preset(name: name, emoji: emoji, color: color, isOn: true)
        presets.append(preset)
        activePresetID = preset.id
    }

    func preset(matching query: String) -> Preset? {
        Preset.find(query.removingPercentEncoding ?? query, in: presets)
    }

    // MARK: - URLs

    /// Handles `wiredin://` URLs:
    /// `preset/<name>`, `on`, `off`, `color/<RRGGBB>`, and `sharedPreset/<json>` (imports).
    func handle(_ url: URL) {
        guard url.scheme == Preset.urlScheme else { return }
        if let shared = Preset(sharingURL: url) {
            if !presets.contains(where: { $0.name == shared.name && $0.color == shared.color }) {
                presets.append(shared)
            }
            return
        }
        let argument = url.pathComponents.dropFirst().joined(separator: "/")
        switch url.host() {
        case "preset", "p":
            if let preset = preset(matching: argument) { apply(preset) } else { lastError = "No preset named \(argument)" }
        case "on": setPower(true)
        case "off": turnOff()
        case "color":
            if let color = SignColor(hex: argument) { setColor(color) }
        default:
            lastError = "Unrecognized URL: \(url.absoluteString)"
        }
    }
}

extension SignColor {
    init(_ color: NSColor) {
        let rgb = color.usingColorSpace(.genericRGB) ?? .white
        self.init(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
    }

    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
}
