//
//  PowerTab.swift
//  BatteryScope
//

import Foundation
import SwiftUI

// MARK: - Power

struct PowerTab: View {
    @EnvironmentObject var monitor: Monitor

    /// Only shown while plugged in. Unplugged, the battery figure and the
    /// system draw are the same number by definition, and printing it twice
    /// just invites you to add them together.
    func batteryLabel(_ snap: BatterySnapshot) -> String {
        guard let w = snap.batteryWatts else { return "Battery" }
        if w > 0.05 { return "Charging at" }
        if w < -0.05 { return "Cell supplementing" }
        return "Battery"
    }

    func batteryHint(_ snap: BatterySnapshot) -> String? {
        guard let w = snap.batteryWatts else { return nil }
        if w > 0.05 { return "into the cell, on top of what the machine is using" }
        if w < -0.05 { return "the charger can't cover the load, so the cell is helping" }
        return "idle, the charger is carrying everything"
    }

    var body: some View {
        let snap = monitor.snapshot

        Card("Right now") {
            Row("System draw", Format.watts(snap.systemWatts), emphasis: true,
                hint: snap.systemWatts == nil
                    ? "this Mac exposes no system power rail while plugged in"
                    : nil)
            if snap.isPluggedIn {
                Row("Charger delivering", Format.watts(snap.adapterWatts),
                    hint: snap.adapterWattsIsRated ? "rated figure, not a measurement" : nil)
                Row(batteryLabel(snap), Format.signedWatts(snap.batteryWatts),
                    hint: batteryHint(snap))
            }
            if let cpu = snap.cpuWatts { Row("CPU package", Format.watts(cpu)) }
            if let gpu = snap.gpuWatts { Row("GPU", Format.watts(gpu)) }
        }

        Card("Runtime") {
            if snap.isPluggedIn {
                Row("To full", monitor.estimatedMinutesToFull.map(Format.duration) ?? "\u{2014}",
                    emphasis: true,
                    hint: monitor.estimateIsOurs ? "from the current charge rate, lightly smoothed" : "from the battery's own gauge")
            } else {
                Row("Left", monitor.estimatedMinutesLeft.map(Format.duration) ?? "\u{2014}",
                    emphasis: true,
                    hint: monitor.estimateIsOurs ? "at your recent rate of use" : "from the battery's own gauge")
            }
            if let watts = monitor.estimateWatts {
                Row("Based on", String(format: "%.1f W", watts),
                    hint: "~15 s average")
            }
            if let now = snap.batteryWatts, abs(now) > 0.05 {
                Row("Right now", String(format: "%.1f W", abs(now)),
                    hint: "this instant, unsmoothed")
            }
            if let gauge = snap.isPluggedIn ? snap.minutesToFull : snap.minutesToEmpty {
                Row("Gauge says", Format.duration(gauge),
                    hint: "battery's own estimate")
            }
        }

        Sparkline(points: monitor.history)

        Card("Electrical") {
            Row("Voltage", Format.volts(snap.voltage))
            Row("Current", Format.amps(snap.amperage))
            Row("Battery temp", Format.celsius(snap.temperatureC))
            if let t = snap.chargerTempC { Row("Charger temp", Format.celsius(t)) }
        }

        if let adapter = snap.adapter {
            Card("Charger") {
                if let name = adapter.name ?? adapter.description { Row("Model", name) }
                Row("Rated", adapter.ratedWatts.map { "\($0) W" } ?? "—")
                Row("Negotiated", Format.watts(adapter.negotiatedWatts))
                if let v = adapter.negotiatedVoltage, let a = adapter.negotiatedCurrent {
                    Row("Contract", String(format: "%.1f V @ %.2f A", v, a))
                }
                if let m = adapter.manufacturer { Row("Made by", m) }
                if let s = adapter.serial { Row("Serial", s) }
            }
        } else {
            Card("Charger") {
                Text("Nothing connected.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
