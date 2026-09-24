//
//  SystemChargeLimit.swift
//  BatteryScope
//
//  Reads the Charge Limit set in System Settings › Battery (macOS 26.4+).
//

import Foundation

/// The subset of PowerUI's PowerUISmartChargeClient we call. The class is
/// private and loaded at runtime, so the object is cast to this protocol.
@objc private protocol PowerUIClient {
    @objc(initWithClientName:) func initWithClientName(_ name: String) -> AnyObject
    @objc(isMCLSupported) func isMCLSupported() -> Bool
    @objc(isMCLCurrentlyEnabled:) func isMCLCurrentlyEnabled(_ error: NSErrorPointer) -> UInt64
    @objc(getMCLLimitWithError:) func getMCLLimit(_ error: NSErrorPointer) -> UInt8
}

enum SystemChargeLimit {

    enum Reading: Equatable {
        case off
        case on(Double)
        /// Couldn't tell this time. Keep whatever was known before.
        case unknown
    }

    private static var client: PowerUIClient?
    private static var triedClient = false

    /// Asks PowerUIAgent directly, the same service System Settings uses, and
    /// falls back to `pmset -g battlimit` where that isn't available. No root
    /// needed for either.
    static func read() -> Reading {
        if let client = powerUI() {
            var error: NSError?
            let enabled = client.isMCLCurrentlyEnabled(&error)
            if error == nil {
                guard enabled != 0 else { return .off }
                var limitError: NSError?
                let limit = Double(client.getMCLLimit(&limitError))
                if limitError == nil {
                    return limit > 0 && limit < 100 ? .on(limit) : .off
                }
            }
        }
        return readPmset()
    }

    private static func powerUI() -> PowerUIClient? {
        if triedClient { return client }
        triedClient = true
        let path = "/System/Library/PrivateFrameworks/PowerUI.framework/Versions/A/PowerUI"
        guard dlopen(path, RTLD_NOW) != nil,
              let cls = NSClassFromString("PowerUISmartChargeClient") as? NSObject.Type else { return nil }
        for selector in ["initWithClientName:", "isMCLSupported",
                         "isMCLCurrentlyEnabled:", "getMCLLimitWithError:"]
        where !cls.instancesRespond(to: NSSelectorFromString(selector)) {
            return nil
        }
        guard let allocated = cls.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() else { return nil }
        let object = unsafeBitCast(allocated, to: PowerUIClient.self)
            .initWithClientName(Bundle.main.bundleIdentifier ?? "com.local.batteryscope")
        let made = unsafeBitCast(object, to: PowerUIClient.self)
        guard made.isMCLSupported() else { return nil }
        client = made
        return made
    }

    /// powerd lists the limit with the reason `manualChargeLimit`. It doesn't
    /// always list it, so a missing entry only means "don't know".
    private static func readPmset() -> Reading {
        guard let r = ProcessRunner.run("/usr/bin/pmset", ["-g", "battlimit"], timeout: 3),
              !r.timedOut, r.status == 0,
              let text = String(data: r.output, encoding: .utf8) else { return .unknown }
        return parse(text).map { .on($0) } ?? .unknown
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
