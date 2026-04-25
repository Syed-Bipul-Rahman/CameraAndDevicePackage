import Foundation

// MARK: - Light Modes

public enum LightMode: CaseIterable {
    case white, candle, pulse, cctloop, flush, lightning, tv, paparazzi, breathing, fireworks, blast, badBulb, welding

    public var code: UInt8 {
        switch self {
        case .white:      return 0x10
        case .candle:     return 0x11
        case .pulse:      return 0x12
        case .cctloop:    return 0x0d
        case .flush:      return 0x0f
        case .lightning:  return 0x03
        case .tv:         return 0x04
        case .paparazzi:  return 0x05
        case .breathing:  return 0x0e
        case .fireworks:  return 0x09
        case .blast:      return 0x06
        case .badBulb:    return 0x08
        case .welding:    return 0x0a
        }
    }

    public var displayName: String {
        switch self {
        case .white:      return "White"
        case .candle:     return "Candle"
        case .pulse:      return "Pulse"
        case .cctloop:    return "CCT Loop"
        case .flush:      return "Flush"
        case .lightning:  return "Lightning"
        case .tv:         return "TV"
        case .paparazzi:  return "Paparazzi"
        case .breathing:  return "Breathing"
        case .fireworks:  return "Fireworks"
        case .blast:      return "Blast"
        case .badBulb:    return "Bad Bulb"
        case .welding:    return "Welding"
        }
    }

    public var hasDaylight: Bool {
        switch self {
        case .cctloop, .fireworks: return false
        default: return true
        }
    }

    public static var effectModes: [LightMode] {
        [.candle, .pulse, .cctloop, .flush, .lightning, .tv, .paparazzi, .breathing, .fireworks, .blast, .badBulb, .welding]
    }
}

// MARK: - Device Protocol

public struct DeviceProtocol {
    // Packet constants from btsnoop analysis
    static let header: [UInt8] = [0x20, 0x00, 0x3a, 0x26]
    static let footer: [UInt8] = [0x0d, 0x0a]
    static let cmdPoll: UInt8    = 0xa2
    static let cmdControl: UInt8 = 0xa3
    static let deviceID: [UInt8] = [0x62, 0xfa]

    static let daylightMinK:   Int = 2700
    static let daylightMaxK:   Int = 6500
    static let daylightMinVal: Int = 0x0A8C   // 2700K
    static let daylightMaxVal: Int = 0x1964   // 6500K

    // UUIDs discovered from device
    public static let writeCharUUID  = "0000ffe9-0000-1000-8000-00805f9b34fb"
    public static let notifyCharUUID = "0000ffe4-0000-1000-8000-00805f9b34fb"
    public static let targetAddress  = "62:FA:DB:F9:85:E9"

    // MARK: - Packet Builders

    /// Heartbeat / poll packet
    public static func buildPollPacket() -> Data {
        Data([0x20, 0x00, 0x3a, 0x26,
              cmdPoll,
              0x02,
              0x62, 0xfa,
              0x26, 0x02,
              0x0d, 0x0a])
    }

    /// White mode packet — type 0x00, mode 0xFF
    public static func buildWhiteModePacket(enabled: Bool, intensity: Int, daylightKelvin: Int) -> Data {
        let intensityVal = UInt8(intensity.clamped(0, 100))
        let daylightVal  = daylightKelvin.clamped(daylightMinK, daylightMaxK)
        let dLow  = UInt8(daylightVal & 0xff)
        let dHigh = UInt8((daylightVal >> 8) & 0xff)

        let data: [UInt8] = [
            enabled ? 0x01 : 0x00,
            0x00, 0xff,
            intensityVal,
            dLow, dHigh,
            0xff, 0xff, 0xff, 0xff
        ]

        // 3-byte checksum matching btsnoop pattern
        let sum = data.reduce(0, { $0 + Int($1) })
        let sumLow  = sum & 0xFF
        let sumHigh = sum >> 8
        let byte2Raw = sumLow + 0x3A
        let byte2  = UInt8(byte2Raw & 0xFF)
        let carry  = byte2Raw >> 8
        let byte1  = UInt8((sumHigh + 0x03 + carry) & 0xFF)

        return Data(header + [cmdControl, 0x0d] + deviceID + data + [byte1, byte2, 0x07] + footer)
    }

    /// Effect mode packet — type 0x02, mode = effect code
    public static func buildEffectModePacket(enabled: Bool, mode: LightMode, intensity: Int,
                                             daylightKelvin: Int, frequency: Int) -> Data {
        let daylightVal = kelvinToDeviceValue(daylightKelvin)
        let intensityVal = UInt8(intensity.clamped(0, 100))
        let freqVal = UInt8(frequency.clamped(1, 10))
        let dLow  = UInt8(daylightVal & 0xff)
        let dHigh = UInt8((daylightVal >> 8) & 0xff)

        let data: [UInt8] = [
            enabled ? 0x01 : 0x00,
            0x02,
            mode.code,
            intensityVal,
            dLow, dHigh,
            0xff, 0xff, 0xff,
            freqVal
        ]

        let checksum = data.reduce(0x08, { $0 + Int($1) }) & 0xFFFF
        let csHigh = UInt8((checksum >> 8) & 0xff)
        let csLow  = UInt8(checksum & 0xff)

        return Data(header + [cmdControl, 0x0d] + deviceID + data + [csHigh, csLow] + footer)
    }

    // MARK: - Helpers

    public static func kelvinToDeviceValue(_ kelvin: Int) -> Int {
        let k = kelvin.clamped(daylightMinK, daylightMaxK)
        let ratio = Double(k - daylightMinK) / Double(daylightMaxK - daylightMinK)
        return Int((Double(daylightMinVal) + Double(daylightMaxVal - daylightMinVal) * ratio).rounded())
    }

    public static func bytesToHex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    public static func parseResponse(_ data: Data) -> [String: Any]? {
        guard data.count >= 6, data[0] == header[0], data[1] == header[1] else { return nil }
        return ["command": data[4], "length": data[5]]
    }
}

// MARK: - Device Commands

public struct DeviceCommands {
    public static var poll: Data { DeviceProtocol.buildPollPacket() }

    public static func whiteMode(daylightKelvin: Int, intensity: Int) -> Data {
        DeviceProtocol.buildWhiteModePacket(enabled: true, intensity: intensity, daylightKelvin: daylightKelvin)
    }

    public static func whiteModeOff() -> Data {
        DeviceProtocol.buildWhiteModePacket(enabled: false, intensity: 0, daylightKelvin: 4600)
    }

    public static func effectMode(mode: LightMode, intensity: Int, daylightKelvin: Int, frequency: Int) -> Data {
        DeviceProtocol.buildEffectModePacket(
            enabled: true, mode: mode,
            intensity: intensity,
            daylightKelvin: mode.hasDaylight ? daylightKelvin : 4600,
            frequency: frequency
        )
    }
}

// MARK: - Utility

private extension Int {
    func clamped(_ lo: Int, _ hi: Int) -> Int { Swift.max(lo, Swift.min(self, hi)) }
}
