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
        /// Newer firmware (macOS 27, and the 26.6+ / 15.8 updates): CHTE and
        /// friends are still listed but hold no data and take no writes, even
        /// from root. What's left, depending on the exact firmware: macOS's
        /// own Charge Limit (SystemChargeLimit), a firmware-enforced charge
        /// range (bfD0/bfE0/bfF0, below), and CHIE to cut the adapter.
        case gated
        case unknown
    }

    private static var cachedKeySet: KeySet?
    private static var cachedCutoff: Bool?

    public static var keySet: KeySet {
        if let cached = cachedKeySet { return cached }
        let detected: KeySet
        if live("CHTE") {
            detected = .modern
        } else if live("CH0B") || live("CH0C") {
            detected = .legacy
        } else if live("CHIE") || supportsFirmwareRange {
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
        cachedRange = nil
    }

    /// A key that answers with zero bytes is a placeholder, not a key.
    private static func live(_ key: String) -> Bool {
        !(SMC.shared.read(key)?.bytes.isEmpty ?? true)
    }

    // MARK: Firmware charge range

    // Firmware from the macOS 26.6 / 15.8 era enforces a charge range by
    // itself, sleep included: bfD0 is the upper percentage, bfE0 the lower
    // (both ui32, little-endian, lower strictly under upper), bfF0 switches
    // it on (02) and off (00). Above the upper bound the firmware lets the
    // battery run down to it. Later firmware locks these keys away even from
    // root, so they only count if they actually read.
    private static var cachedRange: Bool?

    public static var supportsFirmwareRange: Bool {
        if let cachedRange { return cachedRange }
        let ok = live("bfF0") && live("bfD0") && live("bfE0")
        cachedRange = ok
        return ok
    }

    private static func le32(_ key: String) -> Int? {
        guard let b = SMC.shared.read(key)?.bytes, !b.isEmpty else { return nil }
        return b.prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
    }

    /// The upper bound of the firmware range while it's switched on, nil
    /// when it's off or can't be read.
    public static var firmwareRangeUpper: Int? {
        guard supportsFirmwareRange,
              let flag = SMC.shared.read("bfF0")?.bytes.first, flag != 0 else { return nil }
        return le32("bfD0")
    }

    /// Hold the battery at `upper` (lower bound one point under), or switch
    /// the range off with nil. **Requires root.**
    @discardableResult
    public static func setFirmwareRange(upper: Int?) -> Bool {
        guard supportsFirmwareRange else { return false }
        // Off first: the firmware doesn't take new bounds while it's on.
        guard SMC.shared.write("bfF0", bytes: [0x00]) else { return false }
        guard let upper else { return true }
        let high = min(100, max(2, upper))
        func bytes(_ v: Int) -> [UInt8] { [UInt8(v), 0, 0, 0] }
        guard SMC.shared.write("bfD0", bytes: bytes(high)),
              SMC.shared.write("bfE0", bytes: bytes(high - 1)),
              SMC.shared.write("bfF0", bytes: [0x02]) else { return false }
        return firmwareRangeUpper == high && le32("bfE0") == high - 1
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

    public static func setFirmwareRange(upper: Int?) -> Bool {
        run(["range", upper.map(String.init) ?? "off"]).ok
    }

    public static func reset() -> Bool {
        run(["reset"]).ok
    }
}
