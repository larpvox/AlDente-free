//
//  FanController.swift
//  BatteryScope
//
//  Fan readings and control.
//

import Foundation

public struct FanInfo: Identifiable, Equatable {
    public let index: Int
    public var rpm: Double = 0
    public var minimum: Double = 0
    public var maximum: Double = 0
    public var target: Double = 0
    public var manual: Bool = false
    public var id: Int { index }

    /// M3 and later switch fans fully off when the machine is cool, so zero is
    /// a normal reading rather than a fault.
    public var stopped: Bool { rpm < 1 }
}

/// Fan discovery and control through the SMC.
///
/// Detection is by hardware, not by model name: `FNum` reports how many fans
/// exist, and a fanless MacBook Air answers zero. Per-fan state lives in
/// four-character keys numbered from zero — F0Ac for the current speed, F0Mn
/// and F0Mx for the firmware's own limits, F0Tg for the target.
///
/// Three things vary and all three have bitten other tools:
///
/// 1. The mode key is `F0Md` on some drivers and lowercase `F0md` on others.
///    Probe both. Older Intel Macs have neither and use the `FS!` bitmask.
/// 2. Apple silicon stores speeds as little-endian floats; Intel uses
///    big-endian 14.2 fixed point. The encoder handles both off the key type.
/// 3. On M3 and later, thermalmonitord holds the fans and quietly discards
///    manual writes until `Ftst` is set. That unlock takes a few seconds, and
///    some Macs don't have the key at all, so don't sit in a retry loop
///    waiting for a machine that will never answer.
public enum FanController {

    private static var cachedCount: Int?
    private static var cachedLimits: [Int: (min: Double, max: Double)] = [:]
    private static var touched: Set<Int> = []

    public static func forget() {
        cachedCount = nil
        cachedLimits.removeAll()
        modeKeys.removeAll()
    }

    /// How many fans this Mac has. Zero on the fanless machines.
    public static var count: Int {
        if let cached = cachedCount { return cached }
        var found = 0
        if let n = SMC.shared.readDouble("FNum"), n > 0, n < 10 {
            found = Int(n)
        } else if SMC.shared.read("F0Ac") != nil {
            // A few machines don't publish FNum but do have fans.
            found = SMC.shared.read("F1Ac") != nil ? 2 : 1
        }
        cachedCount = found
        return found
    }

    public static var isSupported: Bool { count > 0 }

    private static var modeKeys: [Int: String?] = [:]

    private static func modeKey(_ index: Int) -> String? {
        if let known = modeKeys[index] { return known }
        let upper = "F\(index)Md"
        let lower = "F\(index)md"
        let found: String? = SMC.shared.read(upper) != nil ? upper
            : (SMC.shared.read(lower) != nil ? lower : nil)
        modeKeys[index] = found
        return found
    }

    public static func read() -> [FanInfo] {
        guard count > 0 else { return [] }
        return (0..<count).map { index in
            var fan = FanInfo(index: index)
            fan.rpm = SMC.shared.readDouble("F\(index)Ac") ?? 0
            fan.target = SMC.shared.readDouble("F\(index)Tg") ?? 0

            // The firmware's own limits never change; read them once.
            if let limits = cachedLimits[index] {
                fan.minimum = limits.min
                fan.maximum = limits.max
            } else {
                let lo = SMC.shared.readDouble("F\(index)Mn") ?? 0
                let hi = SMC.shared.readDouble("F\(index)Mx") ?? 0
                if hi > lo, hi > 0 {
                    cachedLimits[index] = (lo, hi)
                }
                fan.minimum = lo
                fan.maximum = hi
            }

            if let key = modeKey(index) {
                fan.manual = (SMC.shared.readDouble(key) ?? 0) >= 1
            } else if let bits = SMC.shared.readDouble("FS! ") {
                fan.manual = (UInt16(max(0, bits)) >> UInt16(index)) & 1 == 1
            }
            return fan
        }
    }

    // MARK: Writes (root only)

    /// Ask the thermal manager to let go. Absent on plenty of Macs, in which
    /// case there was nothing holding the fans anyway.
    @discardableResult
    private static func unlockThermalManager() -> Bool {
        guard SMC.shared.read("Ftst") != nil else { return false }
        return SMC.shared.writeValue("Ftst", 1)
    }

    /// True when at least one fan is still under manual control.
    private static func anyManual(excluding index: Int? = nil) -> Bool {
        guard count > 0 else { return false }
        for i in 0..<count where i != index {
            guard let key = modeKey(i) else { continue }
            if (SMC.shared.readDouble(key) ?? 0) >= 1 { return true }
        }
        return false
    }

    @discardableResult
    public static func setManual(_ index: Int, _ manual: Bool) -> Bool {
        if manual { unlockThermalManager() }

        if let key = modeKey(index) {
            var ok = SMC.shared.writeValue(key, manual ? 1 : 0)
            let satisfied: () -> Bool = {
                let v = SMC.shared.readDouble(key) ?? 0
                return manual ? v >= 1 : v < 1
            }

            // Taking a fan over on M3 and later needs the unlock to land
            // first, and handing one back needs the unlock cleared or the
            // thermal manager just re-asserts forced mode. Either way the
            // write needs verifying, not assuming.
            if !satisfied() {
                for attempt in 0..<3 {
                    if !manual, attempt == 0, !anyManual(excluding: index),
                       SMC.shared.read("Ftst") != nil {
                        SMC.shared.writeValue("Ftst", 0)
                    }
                    Thread.sleep(forTimeInterval: 1.0)
                    ok = SMC.shared.writeValue(key, manual ? 1 : 0)
                    if satisfied() { ok = true; break }
                }
            }
            ok = ok && satisfied()

            if ok {
                if manual {
                    touched.insert(index)
                } else {
                    touched.remove(index)
                    if touched.isEmpty, SMC.shared.read("Ftst") != nil {
                        SMC.shared.writeValue("Ftst", 0)
                    }
                }
            }
            return ok
        }

        // Older Intel: one bit per fan in a single mask.
        let current = UInt16(max(0, SMC.shared.readDouble("FS! ") ?? 0))
        let bit = UInt16(1) << UInt16(index)
        let updated = manual ? (current | bit) : (current & ~bit)
        let ok = SMC.shared.writeValue("FS! ", Double(updated))
        if ok, manual { touched.insert(index) }
        return ok
    }

    /// Set a target speed. Always clamped to the firmware's own range: F0Mn is
    /// the floor the hardware considers safe, and it is never written to.
    @discardableResult
    public static func setTarget(_ index: Int, rpm: Double) -> Bool {
        let fans = read()
        guard let fan = fans.first(where: { $0.index == index }) else { return false }
        let lower = fan.minimum > 0 ? fan.minimum : 0
        let upper = fan.maximum > 0 ? fan.maximum : rpm
        let clamped = min(max(rpm, lower), upper)
        guard setManual(index, true) else { return false }
        let ok = SMC.shared.writeValue("F\(index)Tg", clamped)
        if ok { touched.insert(index) }
        return ok
    }

    /// Hand every fan we took back to the system.
    @discardableResult
    public static func restoreAuto() -> Bool {
        guard count > 0 else { return false }
        var ok = false
        for index in 0..<count {
            if setManual(index, false) { ok = true }
        }
        if SMC.shared.read("Ftst") != nil { SMC.shared.writeValue("Ftst", 0) }
        touched.removeAll()
        return ok
    }
}

/// App-side fan commands, routed through the root helper like everything else.
public enum FanControlClient {
    @discardableResult
    public static func setAuto(_ index: Int) -> Bool {
        ChargeControlClient.run(["fan", "\(index)", "auto"]).ok
    }

    @discardableResult
    public static func setTarget(_ index: Int, rpm: Double) -> Bool {
        ChargeControlClient.run(["fan", "\(index)", String(Int(rpm))]).ok
    }

    @discardableResult
    public static func restoreAll() -> Bool {
        ChargeControlClient.run(["fans", "auto"]).ok
    }
}
