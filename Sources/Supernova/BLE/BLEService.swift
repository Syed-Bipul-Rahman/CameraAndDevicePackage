import Foundation
import CoreBluetooth
import Combine

// MARK: - BLE State

public enum BLEConnectionState: Equatable {
    case idle
    case scanning
    case connecting(peripheral: String)
    case connected(peripheral: String)
    case disconnected(reason: String?)
    case error(String)
}

public struct DiscoveredDevice: Identifiable, Equatable {
    public let id: UUID
    public let name: String
    public let rssi: Int
    public let peripheral: CBPeripheral

    public static func == (lhs: DiscoveredDevice, rhs: DiscoveredDevice) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Delegate

public protocol BLEServiceDelegate: AnyObject {
    func bleService(_ service: BLEService, didDiscoverDevice device: DiscoveredDevice)
    func bleService(_ service: BLEService, didChangeState state: BLEConnectionState)
    func bleServiceBluetoothUnavailable(_ service: BLEService)
}

// MARK: - BLEService

public final class BLEService: NSObject {

    public weak var delegate: BLEServiceDelegate?

    @Published public private(set) var connectionState: BLEConnectionState = .idle
    @Published public private(set) var discoveredDevices: [DiscoveredDevice] = []
    @Published public private(set) var isBluetoothReady: Bool = false

    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var pendingStartScan = false

    private var heartbeatTimer: Timer?
    private var scanTimer: Timer?

    public override init() {
        super.init()
        // Use main queue so delegate callbacks land on main and Timers fire on the main RunLoop.
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Scanning

    public func startScan(timeout: TimeInterval = 15) {
        guard centralManager.state == .poweredOn else {
            // If BT not yet ready, queue the scan to start once it powers on.
            pendingStartScan = true
            if centralManager.state == .poweredOff || centralManager.state == .unauthorized || centralManager.state == .unsupported {
                updateState(.error("Bluetooth is not available"))
            }
            return
        }
        pendingStartScan = false
        discoveredDevices.removeAll()
        updateState(.scanning)
        // Allow duplicates so iOS keeps delivering peripherals (including scan responses that carry the name).
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )

        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            self?.stopScan()
        }
    }

    public func stopScan() {
        centralManager.stopScan()
        scanTimer?.invalidate()
        scanTimer = nil
        if case .scanning = connectionState {
            updateState(.idle)
        }
    }

    // MARK: - Connection

    public func connect(to device: DiscoveredDevice) {
        stopScan()
        connectedPeripheral = device.peripheral
        device.peripheral.delegate = self
        updateState(.connecting(peripheral: device.name))
        centralManager.connect(device.peripheral, options: nil)
    }

    public func disconnect() {
        stopHeartbeat()
        guard let peripheral = connectedPeripheral else { return }
        centralManager.cancelPeripheralConnection(peripheral)
    }

    // MARK: - Commands

    public func sendWhiteMode(daylightKelvin: Int, intensity: Int) {
        send(DeviceCommands.whiteMode(daylightKelvin: daylightKelvin, intensity: intensity))
    }

    public func sendWhiteModeOff() {
        send(DeviceCommands.whiteModeOff())
    }

    public func sendEffectMode(mode: LightMode, intensity: Int, daylightKelvin: Int, frequency: Int) {
        send(DeviceCommands.effectMode(mode: mode, intensity: intensity, daylightKelvin: daylightKelvin, frequency: frequency))
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.send(DeviceCommands.poll)
        }
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    // MARK: - Internal send

    private func send(_ data: Data) {
        guard let peripheral = connectedPeripheral,
              let characteristic = writeCharacteristic,
              peripheral.state == .connected else { return }
        let writeType: CBCharacteristicWriteType =
            characteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        peripheral.writeValue(data, for: characteristic, type: writeType)
    }

    private func updateState(_ state: BLEConnectionState) {
        connectionState = state
        delegate?.bleService(self, didChangeState: state)
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEService: CBCentralManagerDelegate {

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            isBluetoothReady = true
            if pendingStartScan { startScan() }
        case .poweredOff, .unauthorized, .unsupported:
            isBluetoothReady = false
            stopHeartbeat()
            updateState(.idle)
            delegate?.bleServiceBluetoothUnavailable(self)
        default:
            isBluetoothReady = false
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // Prefer the name from the advertisement (delivered in scan response on iOS) over the cached peripheral name.
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advName ?? peripheral.name ?? ""
        // Skip devices that don't advertise any name — keeps the list clean while still showing all named peripherals.
        guard !name.isEmpty else { return }

        let device = DiscoveredDevice(id: peripheral.identifier, name: name, rssi: RSSI.intValue, peripheral: peripheral)

        if let idx = discoveredDevices.firstIndex(where: { $0.id == device.id }) {
            // Update RSSI / name as scan responses come in.
            if discoveredDevices[idx].rssi != device.rssi || discoveredDevices[idx].name != device.name {
                discoveredDevices[idx] = device
            }
        } else {
            discoveredDevices.append(device)
            delegate?.bleService(self, didDiscoverDevice: device)
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectedPeripheral = nil
        updateState(.error(error?.localizedDescription ?? "Failed to connect"))
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        stopHeartbeat()
        writeCharacteristic = nil
        notifyCharacteristic = nil
        connectedPeripheral = nil
        let reason = error?.localizedDescription
        updateState(.disconnected(reason: reason))
    }
}

// MARK: - CBPeripheralDelegate

extension BLEService: CBPeripheralDelegate {

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else {
            updateState(.error(error?.localizedDescription ?? "Service discovery failed"))
            return
        }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let characteristics = service.characteristics else { return }

        // CBUUID returns the short form for 16-bit UUIDs (e.g. "FFE9"), so match by substring.
        let svcUuid = service.uuid.uuidString.uppercased()
        let isGenericService = svcUuid == "1800" || svcUuid == "1801" || svcUuid == "180A"

        for characteristic in characteristics {
            let charUuid = characteristic.uuid.uuidString.uppercased()
            let props = characteristic.properties

            // WRITE: prefer FFE9; otherwise any writable char in a non-generic service.
            if props.contains(.writeWithoutResponse) || props.contains(.write) {
                if charUuid.contains("FFE9") {
                    writeCharacteristic = characteristic
                } else if writeCharacteristic == nil && !isGenericService {
                    writeCharacteristic = characteristic
                }
            }

            // NOTIFY: prefer FFE4; otherwise the first notify/indicate char in a non-generic service.
            if props.contains(.notify) || props.contains(.indicate) {
                if charUuid.contains("FFE4") {
                    notifyCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                } else if notifyCharacteristic == nil && !isGenericService {
                    notifyCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            }
        }

        // Move to .connected only after the last service finishes discovery and we have a write characteristic.
        let allDiscovered = peripheral.services?.allSatisfy { $0.characteristics != nil } ?? false
        if allDiscovered, writeCharacteristic != nil {
            let name = peripheral.name ?? peripheral.identifier.uuidString
            updateState(.connected(peripheral: name))
            startHeartbeat()
        } else if allDiscovered, writeCharacteristic == nil {
            updateState(.error("No writable characteristic found on this device"))
            centralManager.cancelPeripheralConnection(peripheral)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        _ = DeviceProtocol.parseResponse(data)
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        // No-op: we use writeWithoutResponse when available.
    }
}
