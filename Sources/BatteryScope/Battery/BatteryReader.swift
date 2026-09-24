//
//  BatteryReader.swift
//  BatteryScope
//
//  AppleSmartBattery IORegistry reader and the snapshot model.
//

import AppKit
import Foundation
import IOKit

public struct AdapterInfo: Equatable {
    public var ratedWatts: Int?
    public var name: String?
    public var description: String?
    public var manufacturer: String?
    public var negotiatedVoltage: Double?   // volts
    public var negotiatedCurrent: Double?   // amps
    public var familyCode: Int?
    public var serial: String?

    public var negotiatedWatts: Double? {
        guard let v = negotiatedVoltage, let a = negotiatedCurrent else { return nil }
        return v * a
    }
}

public struct BatterySnapshot: Equatable {
    public var timestamp = Date()

    // Charge
    public var displayedPercent: Double?      // what macOS shows
    public var hardwarePercent: Double?       // what the BMS actually reports
    public var isCharging = false
    public var isPluggedIn = false
    public var fullyCharged = false
    public var batteryInstalled = true

    // Capacity, all mAh
    public var designCapacity: Double?
    public var rawMaxCapacity: Double?
    public var nominalChargeCapacity: Double?
    public var rawCurrentCapacity: Double?

    // Health
    public var macOSHealthPercent: Double?    // the System Settings number
    /// True when that figure came from system_profiler, i.e. it is literally
    /// the number System Settings shows rather than our arithmetic.
    public var macOSHealthFromSettings = false
    public var trueHealthPercent: Double?     // uncapped raw-capacity ratio

    // Cycles
    public var cycleCount: Int?
    public var designCycleCount: Int?

    // Electrical
    public var voltage: Double?               // volts
    public var amperage: Double?              // amps, signed (+ into battery)
    public var batteryWatts: Double?          // volts * amps, signed
    public var temperatureC: Double?

    // SMC-sourced power rails
    public var systemWatts: Double?           // total system draw
    public var adapterWatts: Double?          // actually delivered by the charger
    public var adapterWattsIsRated = false    // true when that's the label, not a measurement
    public var smcBatteryWatts: Double?
    public var cpuWatts: Double?
    public var gpuWatts: Double?
    public var chargerTempC: Double?

    // Time estimates, minutes
    public var minutesToEmpty: Int?
    public var minutesToFull: Int?

    // Identity
    public var serial: String?
    public var deviceName: String?
    public var manufacturer: String?
    public var manufactureDate: String?

    public var adapter: AdapterInfo?

    // Charge control state as reported by the SMC
    /// True when macOS's own charge limiter is holding the battery back. When
    /// it is, BatteryScope stays out of the way.
    public var systemChargeLimitActive = false
    public var systemChargeLimitPercent: Double?

    public var hardware80Enabled: Bool?
    public var chargingInhibited: Bool?
    public var adapterDisabled: Bool?

    public init() {}

    /// Percentage of design cycles used up.
    public var cycleWearPercent: Double? {
        guard let c = cycleCount, let d = designCycleCount, d > 0 else { return nil }
        return Double(c) / Double(d) * 100
    }

    /// Wear, i.e. the capacity you've lost against the day it left the factory.
    public var wearPercent: Double? {
        guard let h = trueHealthPercent ?? macOSHealthPercent else { return nil }
        return max(0, 100 - h)
    }

    public var stateLabel: String {
        if !batteryInstalled { return "No battery" }
        if isCharging { return "Charging" }
        if isPluggedIn && fullyCharged { return "Charged" }
        if isPluggedIn { return "Plugged in, not charging" }
        return "On battery"
    }
}

public enum BatteryReader {

    public static func rawProperties() -> [String: Any]? {
        let matching = IOServiceMatching("AppleSmartBattery")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0)
        guard result == KERN_SUCCESS, let dict = unmanaged?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        return dict
    }

    /// `slow: false` skips the readings that don't change minute to minute
    /// (capacity, health, cycles, adapter identity, charge-control flags) and
    /// carries them forward from the previous snapshot instead.
    public static func snapshot(slow: Bool = true,
                                health: Bool = true,
                                carryOver: BatterySnapshot? = nil) -> BatterySnapshot {
        var snap = BatterySnapshot()
        guard let p = rawProperties() else {
            snap.batteryInstalled = false
            applySMC(to: &snap, slow: slow)
            return snap
        }

        let data = (p["BatteryData"] as? [String: Any]) ?? [:]

        /// Look for a key at the top level, then inside BatteryData. Which of
        /// the two a Mac uses varies by model and by macOS version.
        func find(_ names: String...) -> Double? {
            for name in names {
                if let v = num(p[name]) { return v }
                if let v = num(data[name]) { return v }
            }
            return nil
        }

        /// Same, but skip zeros — some models publish a key and leave it at 0
        /// while the real reading sits under a different name.
        func findNonZero(_ names: String...) -> Double? {
            var fallback: Double?
            for name in names {
                for source in [p, data] {
                    guard let v = num(source[name]) else { continue }
                    if v != 0 { return v }
                    if fallback == nil { fallback = v }
                }
            }
            return fallback
        }

        snap.batteryInstalled = (p["BatteryInstalled"] as? Bool) ?? true
        snap.isCharging = (p["IsCharging"] as? Bool) ?? false
        snap.isPluggedIn = (p["ExternalConnected"] as? Bool) ?? false
        snap.fullyCharged = (p["FullyCharged"] as? Bool) ?? false

        let currentCapacity = num(p["CurrentCapacity"])
        let maxCapacity = num(p["MaxCapacity"])
        // Capacities are in mAh. Anything under 500 is a percentage wearing a
        // capacity's name, so don't let it through as one.
        func mAh(_ v: Double?) -> Double? { (v ?? 0) > 500 ? v : nil }
        let rawCurrent = mAh(find("AppleRawCurrentCapacity", "CurrentCapacity"))
        let rawMax = mAh(find("AppleRawMaxCapacity", "MaxCapacity", "FullChargeCapacity"))
        let design = mAh(find("DesignCapacity", "AppleRawDesignCapacity"))
        let nominal = mAh(find("NominalChargeCapacity"))

        snap.designCapacity = design
        snap.rawMaxCapacity = rawMax
        snap.rawCurrentCapacity = rawCurrent
        snap.nominalChargeCapacity = nominal

        // Apple silicon reports CurrentCapacity as a percentage with MaxCapacity == 100.
        // Intel reports both in mAh. Detect and normalise.
        let appleSiliconStyle = (maxCapacity ?? 0) == 100 && rawMax != nil

        if appleSiliconStyle {
            snap.displayedPercent = currentCapacity
        } else if let c = currentCapacity, let m = maxCapacity, m > 0 {
            snap.displayedPercent = c / m * 100
        }

        // The number the battery management system itself believes.
        if let rc = rawCurrent, let rm = rawMax, rm > 0 {
            snap.hardwarePercent = rc / rm * 100
        }
        if snap.hardwarePercent == nil, let soc = find("StateOfCharge"), soc > 0, soc <= 100 {
            snap.hardwarePercent = soc
        }
        if let smcSoC = SMC.shared.readDouble(SMCKeys.hardwareSoC), smcSoC > 0, smcSoC <= 100 {
            snap.hardwarePercent = smcSoC
        }

        // Health. macOS shows nominal-vs-design, clamped at 100.
        if let d = design, d > 0 {
            if let n = nominal {
                snap.macOSHealthPercent = min(100, n / d * 100)
            } else if let m = maxCapacity, !appleSiliconStyle {
                snap.macOSHealthPercent = min(100, m / d * 100)
            }
            if let rm = rawMax {
                snap.trueHealthPercent = rm / d * 100
            } else if let n = nominal {
                snap.trueHealthPercent = n / d * 100
            }
            // Same underlying number dressed two ways is not two readings.
            if let a = snap.trueHealthPercent, let b = snap.macOSHealthPercent,
               abs(a - b) < 0.01, nominal == rawMax {
                snap.macOSHealthPercent = nil
            }
        }

        snap.cycleCount = int(p["CycleCount"]) ?? find("CycleCount").map { Int($0) }
        snap.designCycleCount = int(p["DesignCycleCount9C"]) ?? int(p["DesignCycleCount70"]) ?? 1000

        if let mv = find("Voltage", "AppleRawBatteryVoltage") { snap.voltage = mv / 1000 }
        if let mA = findNonZero("InstantAmperage", "Amperage", "BatteryCurrent") {
            snap.amperage = mA / 1000
        }
        if let v = snap.voltage, let a = snap.amperage { snap.batteryWatts = v * a }

        snap.temperatureC = resolveTemperature(p)

        if let t = int(p["AvgTimeToEmpty"]), t > 0, t < 65535 { snap.minutesToEmpty = t }
        if let t = int(p["AvgTimeToFull"]), t > 0, t < 65535 { snap.minutesToFull = t }
        if let t = int(p["TimeRemaining"]), t > 0, t < 65535 {
            if snap.isCharging { snap.minutesToFull = snap.minutesToFull ?? t }
            else { snap.minutesToEmpty = snap.minutesToEmpty ?? t }
        }

        snap.serial = p["Serial"] as? String ?? p["BatterySerialNumber"] as? String
        snap.deviceName = p["DeviceName"] as? String
        snap.manufacturer = p["Manufacturer"] as? String
        snap.manufactureDate = manufactureDateString(p)

        // Apple's native limiter surfaces under a few different names
        // depending on the macOS version.
        for name in ["ChargeLimit", "MaxChargeLimit", "AppleChargeLimit",
                     "ChargeLimitPercent", "TargetChargeLimit"] {
            if let v = find(name), v > 0, v < 100 {
                snap.systemChargeLimitActive = true
                snap.systemChargeLimitPercent = v
                break
            }
        }

        if let ad = p["AdapterDetails"] as? [String: Any], !ad.isEmpty {
            var info = AdapterInfo()
            info.ratedWatts = int(ad["Watts"])
            info.name = ad["Name"] as? String
            info.description = ad["Description"] as? String
            info.manufacturer = ad["Manufacturer"] as? String
            if let mv = num(ad["AdapterVoltage"]) { info.negotiatedVoltage = mv / 1000 }
            if let ma = num(ad["Current"]) { info.negotiatedCurrent = ma / 1000 }
            info.familyCode = int(ad["FamilyCode"])
            info.serial = ad["SerialString"] as? String
            snap.adapter = info
        }

        applySMC(to: &snap, slow: slow)

        // Charge-control state: refreshed on the slow clock or when the
        // Control tab is up.
        if !slow, let old = carryOver {
            snap.systemChargeLimitActive = old.systemChargeLimitActive
            snap.systemChargeLimitPercent = old.systemChargeLimitPercent
            snap.hardware80Enabled = old.hardware80Enabled
            snap.chargingInhibited = old.chargingInhibited
            snap.adapterDisabled = old.adapterDisabled
        }

        // Health and capacity: only while the Health tab is open. These move
        // over weeks, and a figure that quietly changes behind a closed panel
        // is a figure you can't trust when you do look at it.
        if !health, let old = carryOver {
            snap.designCapacity = old.designCapacity
            snap.rawMaxCapacity = old.rawMaxCapacity
            snap.nominalChargeCapacity = old.nominalChargeCapacity
            snap.macOSHealthPercent = old.macOSHealthPercent
            snap.macOSHealthFromSettings = old.macOSHealthFromSettings
            snap.trueHealthPercent = old.trueHealthPercent
            snap.cycleCount = old.cycleCount
            snap.designCycleCount = old.designCycleCount
            snap.serial = old.serial
            snap.deviceName = old.deviceName
            snap.manufacturer = old.manufacturer
            snap.manufactureDate = old.manufactureDate
        }
        return snap
    }

    /// Which candidate key answered last time, per rail. Probing eight keys
    /// five times a second adds up; once we know the answer, read one.
    private static var resolvedKeys: [String: String] = [:]
    private static var deadRails: [String: Date] = [:]

    private static func firstSMC(_ rail: String, _ keys: [String], _ plausible: ClosedRange<Double>) -> Double? {
        if let known = resolvedKeys[rail] {
            if let v = SMC.shared.readDouble(known), plausible.contains(v) { return v }
            resolvedKeys[rail] = nil   // it stopped answering; probe again
        }

        // A rail this Mac simply doesn't have shouldn't be re-probed forever.
        // Short, because a rail that read implausibly once (a sensor at 0 W for
        // a moment) is otherwise indistinguishable from one that isn't there.
        if let since = deadRails[rail], Date().timeIntervalSince(since) < 60 { return nil }

        for key in keys {
            if let v = SMC.shared.readDouble(key), plausible.contains(v) {
                resolvedKeys[rail] = key
                deadRails[rail] = nil
                return v
            }
        }
        deadRails[rail] = Date()
        return nil
    }

    /// Called on wake, when everything needs rediscovering.
    public static func forgetResolvedKeys() {
        resolvedKeys.removeAll()
        deadRails.removeAll()
    }

    private static func applySMC(to snap: inout BatterySnapshot, slow: Bool = true) {
        snap.cpuWatts = firstSMC("cpu", SMCKeys.cpuPowerKeys, 0.01...200)
        snap.gpuWatts = firstSMC("gpu", SMCKeys.gpuPowerKeys, 0.01...300)
        snap.chargerTempC = firstSMC("chargerTemp", SMCKeys.chargerTempKeys, 1...120)
        if snap.temperatureC == nil {
            snap.temperatureC = firstSMC("batteryTemp", SMCKeys.batteryTempKeys, 1...100)
        }

        let smcSystem = firstSMC("system", SMCKeys.systemPowerKeys, 0.05...400)
        let smcAdapter = firstSMC("adapter", SMCKeys.adapterPowerKeys, 0.05...500)
        snap.smcBatteryWatts = firstSMC("batteryRail", SMCKeys.batteryPowerKeys, -500...500)

        resolvePower(&snap, smcSystem: smcSystem, smcAdapter: smcAdapter)

        guard slow else { return }

        if let v = SMC.shared.readDouble(SMCKeys.hardware80) {
            snap.hardware80Enabled = v >= 1
            // CHWA is the same firmware cap macOS drives from System Settings,
            // so if it's set and we didn't set it, macOS did.
            if v >= 1, !snap.systemChargeLimitActive {
                snap.systemChargeLimitActive = true
                snap.systemChargeLimitPercent = snap.systemChargeLimitPercent ?? 80
            }
        }
        if let v = SMC.shared.readDouble(SMCKeys.chargeInhibitB) { snap.chargingInhibited = v != 0 }
        if let v = SMC.shared.readDouble(SMCKeys.adapterDisable) { snap.adapterDisabled = v != 0 }
    }

    /// Work out the three power figures from whatever the machine actually
    /// exposes. The arithmetic that ties them together:
    ///
    ///     charger output = system load + power going into the battery
    ///
    /// Battery watts are signed: positive means charging. Knowing any two
    /// gives the third. Knowing only the battery figure tells you nothing
    /// about system load while plugged in, so that stays blank rather than
    /// quietly showing the charge rate under the wrong label.
    private static func resolvePower(_ snap: inout BatterySnapshot, smcSystem: Double?, smcAdapter: Double?) {
        // The gauge's voltage and current (and so V×I) only change when the
        // battery driver republishes its registry properties, which is every
        // thirty seconds to a minute. Anything built on them sits still for
        // that long. The SMC rails are live, so they win wherever they exist
        // and the gauge figure is the fallback.
        let gauge = snap.batteryWatts
        let rail = snap.smcBatteryWatts.map { abs($0) }

        guard snap.isPluggedIn else {
            snap.adapterWatts = 0
            snap.adapterWattsIsRated = false
            // On battery the battery is the only source, so system draw and
            // battery draw are one quantity and are shown as exactly that.
            if let live = smcSystem ?? rail {
                snap.systemWatts = live
                snap.batteryWatts = -live
            } else {
                snap.systemWatts = gauge.map { abs($0) }
            }
            return
        }

        // Plugged in. The battery rail only measures power drawn out of the
        // battery, so it reads near zero while charging. Charging power is
        // what the adapter delivers beyond the system load, both live SMC
        // figures; the gauge's V×I is the fallback. Discharging (an adapter
        // that can't keep up) is what the rail does measure.
        let charging = (gauge ?? 0) > 0.05 || snap.isCharging
        if charging {
            if let a = smcAdapter, let sys = smcSystem, a - sys > 0.5 {
                snap.batteryWatts = a - sys
            }
        } else if let rail, let g = gauge, g < -0.05 {
            snap.batteryWatts = -rail
        }
        let battery = snap.batteryWatts

        var system = smcSystem
        var adapter = smcAdapter

        if system == nil, let a = adapter, let b = battery { system = max(0, a - b) }
        if adapter == nil, let sys = system, let b = battery { adapter = max(0, sys + b) }

        if adapter == nil {
            adapter = snap.adapter?.negotiatedWatts
                ?? snap.adapter?.ratedWatts.map(Double.init)
            snap.adapterWattsIsRated = adapter != nil
        }

        snap.systemWatts = system
        snap.adapterWatts = adapter
    }

    /// Different Macs report battery temperature in different places and in
    /// different units. Try each in turn and take the first plausible answer.
    private static func resolveTemperature(_ p: [String: Any]) -> Double? {
        var raw: [Double] = []
        if let t = num(p["Temperature"]) { raw.append(t) }
        if let bd = p["BatteryData"] as? [String: Any] {
            if let t = num(bd["Temperature"]) { raw.append(t) }
            if let t = num(bd["VirtualTemperature"]) { raw.append(t) }
            if let t = num(bd["BatteryTemperature"]) { raw.append(t) }
        }
        if let t = num(p["VirtualTemperature"]) { raw.append(t) }
        if let t = num(p["AppleRawBatteryTemperature"]) { raw.append(t) }

        for value in raw {
            // Centi-Celsius is what AppleSmartBattery uses: 3021 means 30.21 C.
            if value > 500, value < 9000 { return value / 100 }
            // Some report plain Celsius.
            if value > 0, value < 100 { return value }
            // A few report deci-Kelvin.
            if value > 2500, value < 3800 { return value / 10 - 273.15 }
        }
        return nil
    }

    // MARK: Coercion helpers

    private static func num(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        return nil
    }

    private static func int(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let d = any as? Double { return Int(d) }
        return nil
    }

    private static func manufactureDateString(_ p: [String: Any]) -> String? {
        // Smart Battery packs the date into 16 bits: yyyyyyymmmmddddd since 1980.
        guard let raw = int(p["ManufactureDate"]), raw > 0 else { return nil }
        let day = raw & 0x1F
        let month = (raw >> 5) & 0x0F
        let year = 1980 + (raw >> 9)
        guard month >= 1, month <= 12, day >= 1, day <= 31 else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}
