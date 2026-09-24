//
//  ControlTab.swift
//  BatteryScope
//

import Foundation
import SwiftUI

// MARK: - Control

struct ControlTab: View {
    @EnvironmentObject var monitor: Monitor

    private var ceiling: Double { monitor.effectiveCeiling }

    private var sailingFloor: Double {
        max(20, ceiling - monitor.sailingRange)
    }

    private var sailingStateText: String {
        guard monitor.sailingEnabled else { return "Off" }
        if monitor.sailingHolding {
            return String(format: "Holding, drifting to %.0f%%", sailingFloor)
        }
        return String(format: "Charging to %.0f%%", ceiling)
    }

    private var sailingStateHint: String? {
        guard monitor.sailingEnabled, monitor.sailingHolding else { return nil }
        guard monitor.snapshot.isPluggedIn else { return "on battery" }
        let current = monitor.snapshot.batteryWatts.map { abs($0) } ?? 0
        if current < 0.5 {
            return "battery idle, the Mac is running on the adapter"
        }
        return "the adapter can't quite cover the load, so the cell is helping"
    }

    private var calibrationRunning: Bool {
        monitor.calibrationPhase == .discharging || monitor.calibrationPhase == .charging
    }

    private var lastCalibrationText: String {
        guard let date = monitor.lastCalibration else {
            return "Never run. Worth doing every few weeks if you rarely take the battery through its full range."
        }
        let days = Int(Date().timeIntervalSince(date) / 86400)
        if days == 0 { return "Last run today." }
        if days == 1 { return "Last run yesterday." }
        if days > 30 {
            return "Last run \(days) days ago. A run every few weeks keeps the fuel gauge honest."
        }
        return "Last run \(days) days ago."
    }

    var body: some View {
        if !monitor.helperInstalled {
            Card("Charge control not installed") {
                Text("Needs the helper: run ./make.sh install.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }

        Card("Charge limit and sailing") {
            Toggle("Sailing Mode", isOn: $monitor.sailingEnabled)
                .disabled(!monitor.chargeControlAvailable)
            HStack {
                Text("Drift band")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 78, alignment: .leading)
                Slider(value: $monitor.sailingRange, in: 2...10, step: 1)
                Text(String(format: "%.0f pts", monitor.sailingRange))
                    .font(.callout.monospacedDigit())
                    .frame(width: 48, alignment: .trailing)
            }
            .disabled(!monitor.sailingEnabled || !monitor.chargeControlAvailable)
            Text(String(format: "Charges to %.0f%%, then lets the battery drift to %.0f%% before charging again.", ceiling, sailingFloor))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("While holding, the charger runs the Mac and the battery drifts down slowly on its own.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            if let mac = monitor.macOSLimit {
                Text(String(format: "macOS Charge Limit is %.0f%%. BatteryScope can stop lower; to go higher, change it in System Settings › Battery.", mac))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Limit charging below full", isOn: $monitor.chargeLimitEnabled)
                .disabled(!monitor.chargeControlAvailable)
            HStack {
                Slider(value: $monitor.chargeLimit, in: 20...100, step: 1)
                Text(String(format: "%.0f%%", monitor.chargeLimit))
                    .font(.callout.monospacedDigit())
                    .frame(width: 44, alignment: .trailing)
            }
            .disabled(!monitor.chargeLimitEnabled || !monitor.chargeControlAvailable)

            Button(String(format: monitor.topUpArmed ? "Topping up to %.0f%%\u{2026}" : "Top up to %.0f%% once",
                          monitor.macOSLimit ?? 100)) {
                monitor.topUpArmed.toggle()
            }
            .disabled(!monitor.chargeControlAvailable)
        }

        Card("Discharge") {
            Picker("", selection: $monitor.dischargeMethod) {
                ForEach(DischargeMethod.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.radioGroup)
            .disabled(!monitor.chargeControlAvailable)
            Text(monitor.dischargeMethod.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Keep the Mac awake while discharging", isOn: $monitor.keepAwakeWhileDischarging)
                .font(.callout)
                .disabled(!monitor.chargeControlAvailable)
            Toggle("Discharge down to the limit automatically", isOn: $monitor.autoDischargeEnabled)
                .font(.callout)
                .disabled(!monitor.chargeLimitEnabled || !monitor.chargeControlAvailable)
        }

        Card("Heat protection") {
            Toggle("Pause charging when hot", isOn: $monitor.heatProtectionEnabled)
                .disabled(!monitor.chargeControlAvailable)
            HStack {
                Slider(value: $monitor.heatProtectionCelsius, in: 30...45, step: 1)
                Text(String(format: "%.0f\u{00B0}C", monitor.heatProtectionCelsius))
                    .font(.callout.monospacedDigit())
                    .frame(width: 44, alignment: .trailing)
            }
            .disabled(!monitor.heatProtectionEnabled || !monitor.chargeControlAvailable)
        }

        Card("Reported state") {
            Row("Charging inhibited", Format.yesNo(monitor.snapshot.chargingInhibited))
            Row("Adapter disabled", Format.yesNo(monitor.snapshot.adapterDisabled))
            Row("Sailing", sailingStateText, hint: sailingStateHint)
            Row("macOS charge limit", monitor.snapshot.systemChargeLimitActive
                ? (monitor.snapshot.systemChargeLimitPercent.map { String(format: "On, %.0f%%", $0) } ?? "On")
                : "Off")
            Button("Reset to stock behaviour") { monitor.resetChargeControl() }
                .disabled(!monitor.chargeControlAvailable)
        }

        Card("Menu bar") {
            ForEach(Monitor.MenuBarField.allCases) { field in
                Toggle(field.label, isOn: monitor.binding(for: field))
                    .font(.callout)
            }
        }

        Card("Refresh rate") {
            HStack {
                Text("Power")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 78, alignment: .leading)
                Slider(value: $monitor.refreshSeconds, in: 1...30, step: 1)
                Text(String(format: "%.0fs", monitor.refreshSeconds))
                    .font(.callout.monospacedDigit())
                    .frame(width: 34, alignment: .trailing)
            }
            HStack {
                Text("Everything else")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 78, alignment: .leading)
                Slider(value: $monitor.slowSeconds, in: 15...300, step: 15)
                Text(String(format: "%.0fs", monitor.slowSeconds))
                    .font(.callout.monospacedDigit())
                    .frame(width: 34, alignment: .trailing)
            }
            Toggle("With the panel closed, only do what the menu bar needs", isOn: $monitor.idleSlowdown)
                .font(.callout)
            Text("Power: watts, volts, amps and temperature, including the menu bar. Everything else: health, capacity, cycles and the app list, which change slowly.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Card("Calibration") {
            if calibrationRunning {
                Text(monitor.calibrationMessage ?? "Running")
                    .font(.callout)
                ProgressView()
                    .progressViewStyle(.linear)
                Button("Stop calibration") { monitor.cancelCalibration() }
            } else {
                Text("Drains to 15%, then charges to 100% to recalibrate the gauge. Takes most of a day.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let message = monitor.calibrationMessage {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(monitor.calibrationPhase == .aborted ? .orange : .secondary)
                }
                Text(lastCalibrationText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if monitor.macOSLimit != nil {
                    Text("Turn off Charge Limit in System Settings › Battery first, or calibration can't reach 100%.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Button("Start calibration") { monitor.startCalibration() }
                    .disabled(!monitor.chargeControlAvailable || monitor.macOSLimit != nil)
            }
        }
    }
}
