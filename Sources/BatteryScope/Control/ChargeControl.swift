//
//  ChargeControl.swift
//  BatteryScope
//
//  Charge control: the SMC charge keys and the sudo client wrapper.
//

import Foundation

/// Low-level charge control.
///
/// Every write here needs root, which is why the app never calls these directly —
/// it shells out to `bsctl`. The SMC keys are reverse-engineered, not documented
/// by Apple, and differ between Intel and Apple silicon. Treat as experimental.
public enum ChargeControl {

    public enum Platform {
        case appleSilicon
        case intel
    }

    public static var platform: Platform {
        #if arch(arm64)
        return .appleSilicon
        #else
        return .intel
        #endif
    }

    /// Which set of charge-control keys this Mac speaks.
    ///
    /// M1 through M3 and Intel use the CH0B/CH0C pair to gate charging and
    /// CH0I to cut the adapter. Chips from roughly 2023 on use CHTE and CHIE
    /// instead. Nothing about this is documented; probe and use what answers.
    public enum KeySet: String {
        case modern    // CHTE / CHIE
        case legacy    // CH0B + CH0C / CH0I
        case unknown
    }

    private static var cachedKeySet: KeySet?
    private static var cachedCutoff: Bool?

    public static var keySet: KeySet {
        if let cached = cachedKeySet { return cached }
        let detected: KeySet
        if SMC.shared.read("CHTE") != nil {
            detected = .modern
        } else if SMC.shared.read("CH0B") != nil || SMC.shared.read("CH0C") != nil {
            detected = .legacy
        } else {
            detected = .unknown
        }
        cachedKeySet = detected
        return detected
    }

    public static func forgetKeySet() {
        cachedKeySet = nil
        cachedCutoff = nil
    }

    /// Whether cutting the adapter is possible on this machine.
    public static var supportsAdapterCutoff: Bool {
        if let cached = cachedCutoff { return cached }
        let result: Bool
        switch keySet {
        case .modern: result = SMC.shared.read("CHIE") != nil
        case .legacy: result = SMC.shared.read("CH0I") != nil
        case .unknown: result = false
        }
        cachedCutoff = result
        return result
    }

    // MARK: Reads (no root needed)

    public static var chargingInhibited: Bool {
        switch keySet {
        case .modern:
            return (SMC.shared.readDouble("CHTE") ?? 0) != 0
        case .legacy, .unknown:
            if let v = SMC.shared.readDouble("CH0B") { return v != 0 }
            if let v = SMC.shared.readDouble("CH0C") { return v != 0 }
            return false
        }
    }

    public static var adapterDisabled: Bool {
        switch keySet {
        case .modern: return (SMC.shared.readDouble("CHIE") ?? 0) != 0
        case .legacy, .unknown: return (SMC.shared.readDouble("CH0I") ?? 0) != 0
        }
    }

    public static var hardware80: Bool {
        (SMC.shared.readDouble(SMCKeys.hardware80) ?? 0) >= 1
    }

    // MARK: Writes (root only)

    /// Stop or resume charging while the adapter stays connected. The machine
    /// keeps running on wall power either way; only the cell is gated.
    @discardableResult
    public static func setChargingInhibited(_ inhibit: Bool) -> Bool {
        switch keySet {
        case .modern:
            return SMC.shared.write("CHTE", bytes: inhibit ? [0, 0, 0, 1] : [0, 0, 0, 0])
        case .legacy:
            let value: UInt8 = inhibit ? 0x02 : 0x00
            let b = SMC.shared.write("CH0B", bytes: [value])
            let c = SMC.shared.write("CH0C", bytes: [value])
            return b || c
        case .unknown:
            // Nothing identified itself; try everything and hope.
            let value: UInt8 = inhibit ? 0x02 : 0x00
            var ok = SMC.shared.write("CH0B", bytes: [value])
            ok = SMC.shared.write("CH0C", bytes: [value]) || ok
            ok = SMC.shared.write("CHTE", bytes: inhibit ? [0, 0, 0, 1] : [0, 0, 0, 0]) || ok
            return ok
        }
    }

    /// Cut the adapter so the machine runs the battery down while plugged in.
    @discardableResult
    public static func setAdapterDisabled(_ disabled: Bool) -> Bool {
        let byte: UInt8 = disabled ? 0x01 : 0x00
        switch keySet {
        case .modern:
            return SMC.shared.write("CHIE", bytes: [byte])
        case .legacy:
            return SMC.shared.write("CH0I", bytes: [byte])
        case .unknown:
            let a = SMC.shared.write("CH0I", bytes: [byte])
            let b = SMC.shared.write("CHIE", bytes: [byte])
            return a || b
        }
    }

    /// Apple's own firmware 80% cap, where the hardware supports it.
    @discardableResult
    public static func setHardware80(_ enabled: Bool) -> Bool {
        SMC.shared.write(SMCKeys.hardware80, bytes: [enabled ? 0x01 : 0x00])
    }

    /// Put everything back the way a stock machine behaves.
    @discardableResult
    public static func resetAll() -> Bool {
        let a = setChargingInhibited(false)
        let b = setAdapterDisabled(false)
        return a || b
    }
}

/// The app-side wrapper. The helper is a root-owned copy of this very binary,
/// re-invoked with `--ctl`. `sudo -n` succeeds silently once the sudoers rule is
/// in place and fails harmlessly otherwise.
public enum ChargeControlClient {

    public static let helperPath = "/usr/local/bin/batteryscope-helper"

    public static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: helperPath)
    }

    @discardableResult
    public static func run(_ args: [String]) -> (ok: Bool, output: String) {
        guard isInstalled else { return (false, "helper not installed") }
        // Some of these run on the main thread, so they get a hard deadline.
        // Fan takeover on M3 and later can legitimately take a few seconds.
        guard let result = ProcessRunner.run("/usr/bin/sudo", ["-n", helperPath, "--ctl"] + args,
                                             timeout: 15, mergeStderr: true) else {
            return (false, "could not launch sudo")
        }
        if result.timedOut { return (false, "helper timed out") }
        let text = String(data: result.output, encoding: .utf8) ?? ""
        return (result.status == 0, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func setChargingInhibited(_ on: Bool) -> Bool {
        run(["inhibit", on ? "on" : "off"]).ok
    }

    public static func setAdapterDisabled(_ on: Bool) -> Bool {
        run(["discharge", on ? "on" : "off"]).ok
    }

    public static func setHardware80(_ on: Bool) -> Bool {
        run(["hw80", on ? "on" : "off"]).ok
    }

    public static func reset() -> Bool {
        run(["reset"]).ok
    }
}
