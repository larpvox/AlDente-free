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
        /// macOS 27 firmware: CHTE and friends are still listed but hold no
        /// data and take no writes, even from root. Only CHIE (cutting the
        /// adapter) still works; stopping on mains goes through macOS's own
        /// Charge Limit instead (see SystemChargeLimit).
        case gated
        case unknown
    }

    private static var cachedKeySet: KeySet?
    private static var cachedCutoff: Bool?

    public static var keySet: KeySet {
        if let cached = cachedKeySet { return cached }
        // A key that answers with zero bytes is a placeholder, not a key.
        func live(_ key: String) -> Bool { !(SMC.shared.read(key)?.bytes.isEmpty ?? true) }
        let detected: KeySet
        if live("CHTE") {
            detected = .modern
        } else if live("CH0B") || live("CH0C") {
            detected = .legacy
        } else if live("CHIE") {
            detected = .gated
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
        case .modern, .gated: result = SMC.shared.read("CHIE") != nil
        case .legacy: result = SMC.shared.read("CH0I") != nil
        case .unknown: result = false
        }
        cachedCutoff = result
        return result
    }

    // MARK: Reads (no root needed)

    /// Whether a gate key is set, from its raw bytes: any non-zero byte,
    /// whatever type or byte order the firmware reports it in.
    private static func gateSet(_ key: String) -> Bool? {
        SMC.shared.read(key).map { $0.bytes.contains { $0 != 0 } }
    }

    /// nil when the key can't be read, so nothing acts on a guess.
    public static var chargingInhibited: Bool? {
        switch keySet {
        case .modern: return gateSet("CHTE")
        case .gated: return nil
        case .legacy, .unknown: return gateSet("CH0B") ?? gateSet("CH0C")
        }
    }

    public static var adapterDisabled: Bool? {
        switch keySet {
        case .modern, .gated: return gateSet("CHIE")
        case .legacy, .unknown: return gateSet("CH0I")
        }
    }

    public static var hardware80: Bool {
        (SMC.shared.readDouble(SMCKeys.hardware80) ?? 0) >= 1
    }

    // MARK: Writes (root only)

    /// CHTE is little-endian: the firmware acts on 01 00 00 00 and silently
    /// ignores 00 00 00 01, which is what this used to write.
    private static let chteInhibit: [UInt8] = [1, 0, 0, 0]

    /// Stop or resume charging while the adapter stays connected. The machine
    /// keeps running on wall power either way; only the cell is gated.
    @discardableResult
    public static func setChargingInhibited(_ inhibit: Bool) -> Bool {
        switch keySet {
        case .modern:
            return SMC.shared.write("CHTE", bytes: inhibit ? chteInhibit : [0, 0, 0, 0])
        case .legacy:
            let value: UInt8 = inhibit ? 0x02 : 0x00
            let b = SMC.shared.write("CH0B", bytes: [value])
            let c = SMC.shared.write("CH0C", bytes: [value])
            return b || c
        case .gated:
            // Nothing to write to. Resuming is trivially true; stopping isn't
            // possible from here.
            return !inhibit
        case .unknown:
            // Nothing identified itself; try everything and hope.
            let value: UInt8 = inhibit ? 0x02 : 0x00
            var ok = SMC.shared.write("CH0B", bytes: [value])
            ok = SMC.shared.write("CH0C", bytes: [value]) || ok
            ok = SMC.shared.write("CHTE", bytes: inhibit ? chteInhibit : [0, 0, 0, 0]) || ok
            return ok
        }
    }

    /// Cut the adapter so the machine runs the battery down while plugged in.
    @discardableResult
    public static func setAdapterDisabled(_ disabled: Bool) -> Bool {
        // CHIE takes 08 to cut the adapter, not the 01 that CH0I takes.
        let chie: UInt8 = disabled ? 0x08 : 0x00
        let ch0i: UInt8 = disabled ? 0x01 : 0x00
        switch keySet {
        case .modern, .gated:
            return SMC.shared.write("CHIE", bytes: [chie])
        case .legacy:
            return SMC.shared.write("CH0I", bytes: [ch0i])
        case .unknown:
            let a = SMC.shared.write("CH0I", bytes: [ch0i])
            let b = SMC.shared.write("CHIE", bytes: [chie])
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
