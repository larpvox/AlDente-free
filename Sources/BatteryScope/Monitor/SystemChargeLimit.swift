//
//  SystemChargeLimit.swift
//  BatteryScope
//
//  Reads the Charge Limit set in System Settings › Battery (macOS 26.4+).
//

import Foundation

enum SystemChargeLimit {

    /// The limit macOS is enforcing, or nil when there is none. powerd lists
    /// it under `pmset -g battlimit` with the reason `manualChargeLimit`;
    /// no root needed. Older macOS doesn't know the command and returns nil.
    static func read() -> Double? {
        guard let r = ProcessRunner.run("/usr/bin/pmset", ["-g", "battlimit"], timeout: 3),
              !r.timedOut, r.status == 0,
              let text = String(data: r.output, encoding: .utf8) else { return nil }
        return parse(text)
    }

    static func parse(_ text: String) -> Double? {
        let blocks = text.contains("{")
            ? text.components(separatedBy: "{").dropFirst().map { $0.components(separatedBy: "}")[0] }
            : [text]
        for block in blocks where block.localizedCaseInsensitiveContains("manualChargeLimit") {
            guard let range = block.range(of: #"chargeSocLimitSoc\s*=\s*"?(\d+)"#, options: .regularExpression),
                  let digits = block[range].split(whereSeparator: { !$0.isNumber }).last,
                  let value = Double(digits), value > 0, value < 100 else { continue }
            return value
        }
        return nil
    }
}
