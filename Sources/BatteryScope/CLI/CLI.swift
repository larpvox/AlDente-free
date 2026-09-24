//
//  CLI.swift
//  BatteryScope
//
//  Command line mode (`--ctl`).
//

import Foundation

enum CLI {

    static func usage() -> Never {
        let text = """
        BatteryScope --ctl — charge control helper

          --ctl status             Print current charge-control state
          --ctl get <KEY>          Read a four-character SMC key
          --ctl inhibit on|off     Stop / resume charging while plugged in
          --ctl discharge on|off   Cut the adapter, run off the battery
          --ctl hw80 on|off        Toggle the firmware 80% cap where supported
          --ctl set <KEY> <hex>    Write raw bytes, e.g. set CH0B 02
          --ctl fans               List the fans and their state
          --ctl fans auto          Hand every fan back to the system
          --ctl fan <n> <rpm>      Set fan n to a target speed
          --ctl fan <n> auto       Hand fan n back to the system
          --ctl dump               Everything this Mac exposes, for debugging
          --ctl powermetrics [ms]  One powermetrics sample
          --ctl reset              Return everything to stock behaviour
          --ctl fingerprint        Which helper code this binary was built from

        Writes require root. Run BatteryScope with no arguments for the app.
        """
        FileHandle.standardError.write(Data((text + "\n").utf8))
        exit(2)
    }

    static func requireRoot() {
        guard geteuid() == 0 else {
            FileHandle.standardError.write(Data("batteryscope: this command needs root\n".utf8))
            exit(1)
        }
    }

    static func flag(_ s: String?) -> Bool {
        switch s?.lowercased() {
        case "on", "true", "1", "yes": return true
        case "off", "false", "0", "no": return false
        default: usage()
        }
    }

    static func run(_ args: [String]) -> Never {
        guard let command = args.first else { usage() }

        switch command {

        case "status":
            let snap = BatteryReader.snapshot()
            print("platform          : \(ChargeControl.platform == .appleSilicon ? "Apple silicon" : "Intel")")
    print("charge key set    : \(ChargeControl.keySet.rawValue)")
    print("fans              : \(FanController.count)")
    print("adapter cutoff    : \(ChargeControl.supportsAdapterCutoff ? "supported" : "unavailable")")
            print("charging inhibited: \(ChargeControl.chargingInhibited)")
            print("adapter disabled  : \(ChargeControl.adapterDisabled)")
            print("firmware 80% cap  : \(ChargeControl.hardware80)")
            if let p = snap.displayedPercent { print(String(format: "displayed charge  : %.0f%%", p)) }
            if let p = snap.hardwarePercent { print(String(format: "hardware charge   : %.1f%%", p)) }
            if let w = snap.systemWatts { print(String(format: "system draw       : %.2f W", w)) }
            if let w = snap.adapterWatts { print(String(format: "charger output    : %.2f W", w)) }
            if let c = snap.cycleCount { print("cycles            : \(c)") }
            if let h = snap.trueHealthPercent { print(String(format: "true health       : %.1f%%", h)) }
            if let h = snap.macOSHealthPercent { print(String(format: "macOS health      : %.1f%%", h)) }
            exit(0)

        case "get":
            guard args.count >= 2 else { usage() }
            guard let value = SMC.shared.read(args[1]) else {
                FileHandle.standardError.write(Data("batteryscope: key not readable\n".utf8))
                exit(1)
            }
            let hex = value.bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            if let d = value.double {
                print("\(value.key) [\(value.type)] = \(d)  (\(hex))")
            } else {
                print("\(value.key) [\(value.type)] = \(hex)")
            }
            exit(0)

        case "inhibit":
            requireRoot()
            exit(ChargeControl.setChargingInhibited(flag(args.count > 1 ? args[1] : nil)) ? 0 : 1)

        case "discharge":
            requireRoot()
            exit(ChargeControl.setAdapterDisabled(flag(args.count > 1 ? args[1] : nil)) ? 0 : 1)

        case "hw80":
            requireRoot()
            exit(ChargeControl.setHardware80(flag(args.count > 1 ? args[1] : nil)) ? 0 : 1)

        case "set":
            requireRoot()
            guard args.count >= 3 else { usage() }
            let hex = args[2].replacingOccurrences(of: " ", with: "")
            var bytes: [UInt8] = []
            var index = hex.startIndex
            while index < hex.endIndex {
                let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
                guard let byte = UInt8(hex[index..<next], radix: 16) else { usage() }
                bytes.append(byte)
                index = next
            }
            exit(SMC.shared.write(args[1], bytes: bytes) ? 0 : 1)

        case "fans":
            guard FanController.isSupported else {
                print("no fans on this Mac")
                exit(0)
            }
            if args.count > 1, args[1] == "auto" {
                requireRoot()
                exit(FanController.restoreAuto() ? 0 : 1)
            }
            for fan in FanController.read() {
                print(String(format: "fan %d: %.0f rpm (target %.0f, range %.0f-%.0f, %@)",
                             fan.index, fan.rpm, fan.target, fan.minimum, fan.maximum,
                             fan.manual ? "manual" : "system"))
            }
            exit(0)

        case "fan":
            requireRoot()
            guard args.count >= 3, let index = Int(args[1]) else { usage() }
            if args[2] == "auto" {
                exit(FanController.setManual(index, false) ? 0 : 1)
            }
            guard let rpm = Double(args[2]) else { usage() }
            exit(FanController.setTarget(index, rpm: rpm) ? 0 : 1)

        case "dump":
            print("=== AppleSmartBattery ===")
            if let props = BatteryReader.rawProperties() {
                for key in props.keys.sorted() {
                    if let nested = props[key] as? [String: Any] {
                        print("\(key):")
                        for inner in nested.keys.sorted() {
                            print("    \(inner) = \(nested[inner] ?? "nil")")
                        }
                    } else {
                        print("\(key) = \(props[key] ?? "nil")")
                    }
                }
            } else {
                print("(not readable)")
            }

            print("")
            print("=== SMC probe ===")
            let probe = SMCKeys.systemPowerKeys + SMCKeys.adapterPowerKeys
                + SMCKeys.batteryPowerKeys + SMCKeys.cpuPowerKeys + SMCKeys.gpuPowerKeys
                + SMCKeys.batteryTempKeys + SMCKeys.chargerTempKeys
                + [SMCKeys.hardwareSoC, SMCKeys.hardware80, SMCKeys.chargeTimer,
                   SMCKeys.chargeInhibitB, SMCKeys.chargeInhibitC, SMCKeys.adapterDisable,
                   "B0AV", "B0AC", "B0FC", "B0RM", "B0CT", "B0TF", "ACEN", "AC-W",
                   "CH0J", "CHBI", "CHBV", "CHLC", "BSIn",
                   "FNum", "Ftst", "FS! ",
                   "F0Ac", "F0Mn", "F0Mx", "F0Tg", "F0Md", "F0md",
                   "F1Ac", "F1Mn", "F1Mx", "F1Tg", "F1Md", "F1md"]
            for key in probe {
                guard let value = SMC.shared.read(key) else {
                    print("\(key) = (absent)")
                    continue
                }
                let hex = value.bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
                if let d = value.double {
                    print("\(key) [\(value.type)] = \(d)   (\(hex))")
                } else {
                    print("\(key) [\(value.type)] = \(hex)")
                }
            }
            exit(0)

        case "powermetrics":
            requireRoot()
            let interval = args.count > 1 ? args[1] : "800"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/powermetrics")
            process.arguments = ["--samplers", "cpu_power,gpu_power", "-i", interval, "-n", "1"]
            do { try process.run() } catch { exit(1) }
            process.waitUntilExit()
            exit(process.terminationStatus)

        case "fingerprint":
            // Read from the Info.plist embedded in the executable, which a
            // bare helper copy still carries. No root needed.
            print(Bundle.main.object(forInfoDictionaryKey: "BSHelperFingerprint") as? String ?? "unknown")
            exit(0)

        case "reset":
            requireRoot()
            exit(ChargeControl.resetAll() ? 0 : 1)

        default:
            usage()
        }
    }
}
