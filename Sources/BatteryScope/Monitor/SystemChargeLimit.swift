//
//  SystemChargeLimit.swift
//  BatteryScope
//
//  Reads, and where the SMC no longer allows it sets, the Charge Limit from
//  System Settings › Battery (macOS 26.4+).
//

import Foundation
import ObjectiveC

/// The subset of PowerUI's PowerUISmartChargeClient we call. The class is
/// private and loaded at runtime, so the object is cast to this protocol.
@objc private protocol PowerUIClient {
    @objc(initWithClientName:) func initWithClientName(_ name: String) -> AnyObject
    @objc(isMCLSupported) func isMCLSupported() -> Bool
    @objc(isMCLCurrentlyEnabled:) func isMCLCurrentlyEnabled(_ error: NSErrorPointer) -> UInt64
    @objc(getMCLLimitWithError:) func getMCLLimit(_ error: NSErrorPointer) -> UInt8
    @objc(enableMCL:) func enableMCL(_ error: NSErrorPointer) -> Bool
    @objc(disableMCL:) func disableMCL(_ error: NSErrorPointer) -> Bool
    // Declared wide; the value is small and positive, so it arrives intact
    // whether the real parameter is a byte or a word.
    @objc(setMCLLimit:error:) func setMCLLimit(_ limit: Int, error: NSErrorPointer) -> Bool
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

    /// The lowest limit PowerUI accepts. It crashes on anything lower rather
    /// than refusing it, so nothing below this is ever passed in.
    static let minimumLimit = 80

    private static var writable: Bool?

    /// Whether this Mac lets an ordinary process change the limit. On macOS 27
    /// firmware this is the only way left to stop charging on mains power: the
    /// SMC charge keys are blanked out, even for root.
    static var canWrite: Bool {
        if let writable { return writable }
        var ok = false
        if powerUI() != nil,
           let cls = NSClassFromString("PowerUISmartChargeClient") as? NSObject.Type {
            ok = ["enableMCL:", "disableMCL:"].allSatisfy {
                cls.instancesRespond(to: NSSelectorFromString($0))
            }
            // Only call setMCLLimit:error: if its limit is a plain integer.
            if ok, let method = class_getInstanceMethod(cls, NSSelectorFromString("setMCLLimit:error:")) {
                var type = [CChar](repeating: 0, count: 8)
                method_getArgumentType(method, 2, &type, type.count)
                ok = "cCsSiIlLqQ".utf8.contains(UInt8(bitPattern: type[0]))
            } else {
                ok = false
            }
        }
        writable = ok
        return ok
    }

    /// Turn the limit on at `percent` (80 to 99). Firmware enforces it, on
    /// mains power: at the current level it holds there, below it drains
    /// down to it.
    @discardableResult
    static func set(_ percent: Int) -> Bool {
        guard canWrite, let client = powerUI(), percent >= minimumLimit, percent < 100 else { return false }
        var error: NSError?
        guard client.enableMCL(&error), error == nil else { return false }
        var limitError: NSError?
        return client.setMCLLimit(percent, error: &limitError) && limitError == nil
    }

    @discardableResult
    static func disable() -> Bool {
        guard canWrite, let client = powerUI() else { return false }
        var error: NSError?
        return client.disableMCL(&error) && error == nil
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
