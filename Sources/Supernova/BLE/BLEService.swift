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

    // Published state for SwiftUI / Combine consumers
    @Published public private(set) var connectionState: BLEConnectionState = .idle
    @Published public private(set) var discoveredDevices: [DiscoveredDevice] = []
    @Published public private(set) var isBluetoothReady: Bool = false

    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?

    private var heartbeatTimer: Timer?
    private var scanTimer: Timer?

    // ENSY device name prefix used for filtering during scan
    private let deviceNamePrefix = "ENSY"

    public override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: DispatchQueue(label: "com.supernova.ble", qos: .userInitiated))
    }

    // MARK: - Scanning

    public func startScan(timeout: TimeInterval = 15) {
        guard centralManager.state == .poweredOn else {
            updateState(.error("Bluetooth is not available"))
            return
        }
        discoveredDevices.removeAll()
        updateState(.scanning)
        centralManager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])

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
        peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
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
        guard let name = peripheral.name, name.hasPrefix(deviceNamePrefix) else { return }

        let device = DiscoveredDevice(id: peripheral.identifier, name: name, rssi: RSSI.intValue, peripheral: peripheral)

        if !discoveredDevices.contains(where: { $0.id == device.id }) {
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
        guard error == nil, let services = peripheral.services else { return }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let characteristics = service.characteristics else { return }

        for characteristic in characteristics {
            let uuid = characteristic.uuid.uuidString.lowercased()
            if uuid == DeviceProtocol.writeCharUUID {
                writeCharacteristic = characteristic
            }
            if uuid == DeviceProtocol.notifyCharUUID {
                notifyCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }

        // Ready when write characteristic is found
        if writeCharacteristic != nil {
            let name = peripheral.name ?? peripheral.identifier.uuidString
            updateState(.connected(peripheral: name))
            startHeartbeat()
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        // Response parsing available for future use
        _ = DeviceProtocol.parseResponse(data)
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        // Write-without-response doesn't trigger this; write-with-response would
    }
}
