//
//  HealthTab.swift
//  BatteryScope
//

import Foundation
import SwiftUI

// MARK: - Health

struct HealthTab: View {
    @EnvironmentObject var monitor: Monitor

    /// What to say underneath the measured figure.
    private var agreementText: String {
        guard let measured = monitor.measuredHealth else { return "" }
        let reported = monitor.snapshot.macOSHealthPercent ?? monitor.snapshot.trueHealthPercent

        if monitor.measuredHealthClamped, let raw = monitor.measuredHealthRaw {
            return String(format: "Held at the %.0f point limit. The raw count came out at %.1f%%, which is further from the reported figure than a battery can actually move. Usually that means drifted calibration rather than real wear; a few full charge cycles normally closes it.",
                          Monitor.agreementLimit, raw)
        }
        guard let reported else {
            return "Measured independently of anything the battery reports."
        }
        let gap = measured - reported
        if abs(gap) <= 2 {
            return "Within two points of the reported figure, which is what you want to see."
        }
        return String(format: "%.1f points %@ than reported, inside the %.0f point limit.",
                      abs(gap), gap > 0 ? "higher" : "lower", Monitor.agreementLimit)
    }

    var body: some View {
        let snap = monitor.snapshot

        Card("Health") {
            if let reported = snap.trueHealthPercent ?? snap.macOSHealthPercent {
                Row("Capacity ratio", Format.percent(reported), emphasis: true,
                    hint: "full charge vs. design")
            } else {
                Row("Capacity ratio", "\u{2014}", emphasis: true)
            }
            if let macOS = snap.macOSHealthPercent, snap.macOSHealthFromSettings {
                Row("System Settings says", String(format: "%.0f%%", macOS),
                    hint: "read from macOS, not recalculated")
            }

            if let measured = monitor.measuredHealth {
                Row("Measured health", Format.percent(measured),
                    hint: "measured by this app")
                Text(agreementText)
                    .font(.caption)
                    .foregroundStyle(monitor.measuredHealthClamped ? .orange : .secondary)
            } else {
                Row("Measured health", "\u{2014}")
                Text(monitor.measurementStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Row("Capacity lost", Format.percent(snap.wearPercent))

            if monitor.measurementSamples > 0 {
                HStack {
                    Text("\(monitor.measurementSamples) reading\(monitor.measurementSamples == 1 ? "" : "s") collected")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Start over") { monitor.resetHealthMeasurement() }
                        .controlSize(.small)
                }
            }
        }

        Card("Capacity") {
            Row("Design", Format.mAh(snap.designCapacity))
            Row("Full charge (raw)", Format.mAh(snap.rawMaxCapacity))
            Row("Nominal", Format.mAh(snap.nominalChargeCapacity))
            Row("Currently holding", Format.mAh(snap.rawCurrentCapacity))
        }

        Card("Cycles") {
            Row("Used", snap.cycleCount.map(String.init) ?? "—", emphasis: true)
            Row("Rated for", snap.designCycleCount.map(String.init) ?? "—")
            if let used = snap.cycleWearPercent {
                Row("Through", String(format: "%.1f%% of rated life", used))
                ProgressView(value: min(1, used / 100))
                    .progressViewStyle(.linear)
            }
            if let c = snap.cycleCount, let d = snap.designCycleCount, d > c {
                Row("Remaining", "\(d - c) cycles")
            }
        }

        Toggle("Show the battery's own charge figure instead of macOS's", isOn: $monitor.useHardwarePercent)
            .font(.callout)
    }
}
