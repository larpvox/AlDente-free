//
//  SMC.swift
//  BatteryScope
//
//  AppleSMC user client: key info, read, write, and the well-known power keys.
//

import AppKit
import Foundation
import IOKit

// MARK: - Raw AppleSMC user client structures
//
// These mirror the C structs used by the AppleSMC kext's user client. The layout
// has to match byte for byte, so don't reorder or retype the fields.

public typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

public let smcBytesZero: SMCBytes = (
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0
)

struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SMCLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = smcBytesZero
}

private let kSMCHandleYPCEvent: UInt32 = 2
private let kSMCReadKey: UInt8 = 5
private let kSMCWriteKey: UInt8 = 6
private let kSMCGetKeyInfo: UInt8 = 9
/// The SMC's own "no such key" result. Anything else non-zero is a transient
/// failure (busy, timed out) and must not be remembered as absence.
private let kSMCKeyNotFound: UInt8 = 0x84

// MARK: - Value

public struct SMCValue {
    public let key: String
    public let type: String
    public let bytes: [UInt8]

    /// Decode the common numeric SMC encodings into a Double.
    public var double: Double? {
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let raw = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: raw))
        case "ui8 ", "hex_":
            guard let first = bytes.first else { return nil }
            return Double(first)
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            var v: UInt32 = 0
            for b in bytes.prefix(4) { v = v << 8 | UInt32(b) }
            return Double(v)
        case "si8 ":
            guard let first = bytes.first else { return nil }
            return Double(Int8(bitPattern: first))
        case "si16":
            guard bytes.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1])))
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            let raw = Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
            return Double(raw) / 256.0
        case "fpe2":
            // Big-endian 14.2 fixed point. Intel fan speeds use this.
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case "sp87":
            guard bytes.count >= 2 else { return nil }
            let raw = Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
            return Double(raw) / 128.0
        default:
            return nil
        }
    }
}

// MARK: - Client

public final class SMC {
    public static let shared = SMC()

    private var connection: io_connect_t = 0
    private let lock = NSLock()
    private var opened = false

    private init() {}

    deinit { closeLocked() }

    /// Sleep invalidates the user client handle. Nothing tells us that
    /// happened; reads just start failing forever. So reads retry once through
    /// a fresh connection, and the app drops the connection on wake.
    public func reset() {
        lock.lock()
        closeLocked()
        missing.removeAll()   // wake can change what's available
        lock.unlock()
    }

    public func close() { reset() }

    /// Forget which keys were missing, without dropping the connection.
    /// Plugging a charger in is the sort of event that can change what's
    /// exposed, and a fifteen-minute memory of "not there" would leave the
    /// charger rows blank.
    public func forgetMissing() {
        lock.lock()
        missing.removeAll()
        lock.unlock()
    }

    private func openLocked() -> Bool {
        if opened { return true }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        opened = (result == kIOReturnSuccess)
        return opened
    }

    private func closeLocked() {
        if opened {
            IOServiceClose(connection)
            opened = false
            connection = 0
        }
    }

    private func call(_ input: inout SMCParamStruct, _ output: inout SMCParamStruct) -> kern_return_t {
        var outSize = MemoryLayout<SMCParamStruct>.stride
        return IOConnectCallStructMethod(
            connection,
            kSMCHandleYPCEvent,
            &input,
            MemoryLayout<SMCParamStruct>.stride,
            &output,
            &outSize
        )
    }

    private enum Outcome {
        case value(SMCValue)
        case missing      // the SMC answered, the key isn't there
        case dead         // the SMC didn't answer: the handle is gone
    }

    /// Keys this Mac has told us it doesn't have. Half the app is probing
    /// for optional keys, and each probe used to be a kernel round trip
    /// followed by a full reconnect on the miss.
    ///
    /// Only a definite "key not found" lands here. Caching every non-zero
    /// result meant one busy moment in the SMC blanked a menu bar reading
    /// for fifteen minutes, and Refresh couldn't bring it back.
    private var missing: [UInt32: Date] = [:]
    private let missingTTL: TimeInterval = 300

    private func readLocked(_ key: String, _ fourCC: UInt32) -> Outcome {
        if let since = missing[fourCC] {
            if Date().timeIntervalSince(since) < missingTTL { return .missing }
            missing[fourCC] = nil
        }
        guard openLocked() else { return .dead }

        var input = SMCParamStruct()
        var output = SMCParamStruct()
        input.key = fourCC
        input.data8 = kSMCGetKeyInfo
        guard call(&input, &output) == kIOReturnSuccess else { return .dead }
        guard output.result == 0 else {
            if output.result == kSMCKeyNotFound { missing[fourCC] = Date() }
            return .missing
        }
        let info = output.keyInfo

        var readIn = SMCParamStruct()
        var readOut = SMCParamStruct()
        readIn.key = fourCC
        readIn.keyInfo.dataSize = info.dataSize
        readIn.data8 = kSMCReadKey
        guard call(&readIn, &readOut) == kIOReturnSuccess else { return .dead }
        guard readOut.result == 0 else { return .missing }

        let size = Int(min(info.dataSize, 32))
        var buffer = readOut.bytes
        let bytes: [UInt8] = withUnsafeBytes(of: &buffer) { Array($0.prefix(size)) }
        return .value(SMCValue(key: key, type: SMC.string(from: info.dataType), bytes: bytes))
    }

    /// Read a four-character SMC key. No privileges needed.
    public func read(_ key: String) -> SMCValue? {
        guard let fourCC = SMC.fourCharCode(key) else { return nil }
        lock.lock()
        defer { lock.unlock() }

        switch readLocked(key, fourCC) {
        case .value(let v):
            return v
        case .missing:
            return nil
        case .dead:
            // Only a dead handle earns a reconnect. A missing key never did.
            closeLocked()
            if case .value(let v) = readLocked(key, fourCC) { return v }
            return nil
        }
    }

    public func readDouble(_ key: String) -> Double? {
        read(key)?.double
    }

    /// Write raw bytes to an SMC key. **Requires root.**
    @discardableResult
    public func write(_ key: String, bytes payload: [UInt8]) -> Bool {
        guard let fourCC = SMC.fourCharCode(key) else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard openLocked() else { return false }
        var probe = SMCParamStruct()
        var probeOut = SMCParamStruct()
        probe.key = fourCC
        probe.data8 = kSMCGetKeyInfo
        guard call(&probe, &probeOut) == kIOReturnSuccess, probeOut.result == 0 else { return false }
        let info = probeOut.keyInfo

        var input = SMCParamStruct()
        var output = SMCParamStruct()
        input.key = fourCC
        input.keyInfo.dataSize = info.dataSize
        input.data8 = kSMCWriteKey
        withUnsafeMutableBytes(of: &input.bytes) { raw in
            for (i, byte) in payload.enumerated() where i < 32 {
                raw[i] = byte
            }
        }
        return call(&input, &output) == kIOReturnSuccess && output.result == 0
    }

    /// Encode a number into an SMC key's native type.
    public static func encode(_ value: Double, as type: String) -> [UInt8]? {
        switch type {
        case "flt ":
            // Apple silicon: little-endian IEEE-754.
            let bits = Float(value).bitPattern
            return [
                UInt8(bits & 0xFF),
                UInt8((bits >> 8) & 0xFF),
                UInt8((bits >> 16) & 0xFF),
                UInt8((bits >> 24) & 0xFF),
            ]
        case "fpe2":
            // Intel: big-endian 14.2 fixed point.
            let raw = UInt16(max(0, min(16383, value)) * 4)
            return [UInt8(raw >> 8), UInt8(raw & 0xFF)]
        case "ui8 ", "hex_":
            return [UInt8(max(0, min(255, value)))]
        case "ui16":
            let raw = UInt16(max(0, min(65535, value)))
            return [UInt8(raw >> 8), UInt8(raw & 0xFF)]
        case "ui32":
            let raw = UInt32(max(0, value))
            return [
                UInt8((raw >> 24) & 0xFF),
                UInt8((raw >> 16) & 0xFF),
                UInt8((raw >> 8) & 0xFF),
                UInt8(raw & 0xFF),
            ]
        default:
            return nil
        }
    }

    /// Write a number to a key, encoding it however that key expects.
    @discardableResult
    public func writeValue(_ key: String, _ value: Double) -> Bool {
        guard let existing = read(key),
              let payload = SMC.encode(value, as: existing.type) else { return false }
        return write(key, bytes: payload)
    }

    // MARK: Helpers

    static func fourCharCode(_ s: String) -> UInt32? {
        let scalars = Array(s.utf8)
        guard scalars.count == 4 else { return nil }
        var v: UInt32 = 0
        for b in scalars { v = v << 8 | UInt32(b) }
        return v
    }

    static func string(from code: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "?"
    }
}

// MARK: - Well-known power keys

public enum SMCKeys {
    // Which rails and sensors exist varies by model, so each of these is a
    // list of candidates tried in order until one returns a sane value.

    /// Total system power draw, watts.
    public static let systemPowerKeys = ["PSTR", "PSVR", "PDTR"]
    /// Power delivered by the DC-in / adapter, watts.
    public static let adapterPowerKeys = ["PDTR", "PD0R", "PHPC", "PZ0R"]
    /// Battery rail power, watts.
    public static let batteryPowerKeys = ["PPBR", "B0AP"]
    /// CPU package power, watts.
    public static let cpuPowerKeys = ["PCPC", "PCPT", "PC0C", "PCTR"]
    /// GPU power, watts.
    public static let gpuPowerKeys = ["PGTR", "PG0R", "PCPG"]
    /// Battery temperature sensors.
    public static let batteryTempKeys = ["TB0T", "TB1T", "TB2T", "TB3T", "TBXT", "TB0P"]
    /// Charger / adapter temperature.
    public static let chargerTempKeys = ["TCHP", "TW0P", "Th0H"]
    /// Apple silicon: hardware 80% charge cap toggle.
    public static let hardware80 = "CHWA"
    /// Apple silicon: charge inhibit timer.
    public static let chargeTimer = "CHTE"
    /// Intel: charge inhibit pair.
    public static let chargeInhibitB = "CH0B"
    public static let chargeInhibitC = "CH0C"
    /// Disable the power adapter so the machine runs on battery while plugged in.
    public static let adapterDisable = "CH0I"
    /// Hardware state of charge, percent.
    public static let hardwareSoC = "BRSC"
}
