@preconcurrency import CoreBluetooth
import Foundation

/// Bluetooth LE identifiers from docs/PROTOCOL.md.
public enum WiredInBluetooth {
    public static let advertisedName = "WiredInSign"
    public static let serviceUUID = CBUUID(string: "9741D001-1EC4-47F4-976B-DB75985F37F1")
    public static let receiveUUID = incrementing(serviceUUID, by: 1)
    public static let sendUUID = incrementing(serviceUUID, by: 2)
    public static let disconnectUUID = incrementing(serviceUUID, by: 3)

    /// Adds `amount` to the first 32 bits (big-endian) of a UUID, as the original
    /// `-[CBUUID wi_UUIDByIncrementingFirst16BitsBy:]` did.
    public static func incrementing(_ uuid: CBUUID, by amount: UInt32) -> CBUUID {
        var bytes = [UInt8](uuid.data)
        let first = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
        let sum = first &+ amount
        bytes[0] = UInt8(sum >> 24 & 0xFF)
        bytes[1] = UInt8(sum >> 16 & 0xFF)
        bytes[2] = UInt8(sum >> 8 & 0xFF)
        bytes[3] = UInt8(sum & 0xFF)
        return CBUUID(data: Data(bytes))
    }
}

/// A connected BLE sign exposed as a byte transport. Created by `BluetoothScanner`.
public final class BluetoothTransport: NSObject, SignTransport, CBPeripheralDelegate, @unchecked Sendable {
    public let kind: SignTransportKind = .bluetooth
    public let incoming: AsyncStream<Data>
    public let peripheral: CBPeripheral
    private let continuation: AsyncStream<Data>.Continuation
    private var sendCharacteristic: CBCharacteristic?
    private var ready: CheckedContinuation<Void, Error>?
    private let onClose: @Sendable (CBPeripheral) -> Void

    init(peripheral: CBPeripheral, onClose: @escaping @Sendable (CBPeripheral) -> Void) {
        self.peripheral = peripheral
        self.onClose = onClose
        (incoming, continuation) = AsyncStream.makeStream()
        super.init()
        peripheral.delegate = self
    }

    /// Discovers the service and characteristics.
    func prepare() async throws {
        try await withCheckedThrowingContinuation { continuation in
            ready = continuation
            peripheral.discoverServices([WiredInBluetooth.serviceUUID])
        }
    }

    public func send(_ data: Data) throws {
        guard let characteristic = sendCharacteristic, peripheral.state == .connected else { throw SignError.closed }
        peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
    }

    public func close() {
        continuation.finish()
        onClose(peripheral)
    }

    func disconnected() {
        continuation.finish()
        ready?.resume(throwing: SignError.closed)
        ready = nil
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == WiredInBluetooth.serviceUUID }) else {
            ready?.resume(throwing: SignError.notASign)
            ready = nil
            return
        }
        peripheral.discoverCharacteristics([WiredInBluetooth.receiveUUID, WiredInBluetooth.sendUUID], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == WiredInBluetooth.sendUUID { sendCharacteristic = characteristic }
            if characteristic.uuid == WiredInBluetooth.receiveUUID { peripheral.setNotifyValue(true, for: characteristic) }
        }
        if sendCharacteristic != nil {
            ready?.resume()
        } else {
            ready?.resume(throwing: SignError.notASign)
        }
        ready = nil
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let value = characteristic.value { continuation.yield(value) }
    }
}

/// Finds and connects to Bluetooth signs. Create once and keep it alive.
@MainActor
public final class BluetoothScanner: NSObject, CBCentralManagerDelegate {
    public private(set) var isPoweredOn = false
    /// Called on the main actor for each sign that connects.
    public var onConnect: ((CBPeripheral, BluetoothTransport) -> Void)?
    public var onDisconnect: ((CBPeripheral) -> Void)?

    private var central: CBCentralManager!
    private var transports: [UUID: BluetoothTransport] = [:]
    private var pending: Set<CBPeripheral> = []

    public override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    public func scan() {
        guard isPoweredOn else { return }
        central.scanForPeripherals(withServices: [WiredInBluetooth.serviceUUID])
    }

    public func stopScanning() { central.stopScan() }

    nonisolated public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            isPoweredOn = central.state == .poweredOn
            if isPoweredOn { scan() }
        }
    }

    nonisolated public func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        MainActor.assumeIsolated {
            guard transports[peripheral.identifier] == nil, !pending.contains(peripheral) else { return }
            pending.insert(peripheral)
            central.connect(peripheral)
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            pending.remove(peripheral)
            let transport = BluetoothTransport(peripheral: peripheral) { [weak self] p in
                Task { @MainActor in self?.central.cancelPeripheralConnection(p) }
            }
            transports[peripheral.identifier] = transport
            Task {
                do {
                    try await transport.prepare()
                    onConnect?(peripheral, transport)
                } catch {
                    central.cancelPeripheralConnection(peripheral)
                }
            }
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { _ = pending.remove(peripheral) }
    }

    nonisolated public func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
    ) {
        MainActor.assumeIsolated {
            transports.removeValue(forKey: peripheral.identifier)?.disconnected()
            onDisconnect?(peripheral)
        }
    }
}
