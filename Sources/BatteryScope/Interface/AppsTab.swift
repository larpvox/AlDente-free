//
//  AppsTab.swift
//  BatteryScope
//

import Foundation
import SwiftUI

// MARK: - Apps

struct AppsTab: View {
    @EnvironmentObject var monitor: Monitor

    var body: some View {
        let breakdown = monitor.breakdown

        Card("Power by app") {
            if monitor.processes.isEmpty {
                Text("Sampling\u{2026}")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(monitor.processes) { proc in
                    HStack(spacing: 8) {
                        Text(Format.processName(proc.name))
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        if let w = proc.estimatedWatts {
                            Text(Format.smallWatts(w))
                                .font(.callout.monospacedDigit())
                        }
                        Text(String(format: "%.0f", breakdown.usingComputePower ? proc.cpuPercent : proc.energyImpact))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
            }
        }

        Card("Adding up") {
            Row("These \(monitor.processes.count)", Format.watts(shownWatts))
            Row("Other \(max(0, breakdown.sampledProcessCount - monitor.processes.count)) apps and processes",
                Format.watts(breakdown.otherProcessesWatts))
            Row("Idle floor", Format.watts(breakdown.baselineWatts),
                hint: "what this Mac draws with nothing running")
            Row("System total", Format.watts(breakdown.totalWatts), emphasis: true)
        }

        Text(breakdown.basis)
            .font(.caption)
            .foregroundStyle(.secondary)

        Text(breakdown.usingComputePower
             ? "The right-hand column is CPU usage, which splits the measured CPU and GPU power. The rest of the draw above the floor (screen, GPU, radios, storage) is split by Energy Impact."
             : "The right-hand column is Activity Monitor's Energy Impact score, a weighted composite of CPU time, wakeups, GPU and disk activity. It ranks well and converts to watts only roughly. Installing charge control lets the app read real CPU and GPU power through powermetrics, which is better.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var shownWatts: Double {
        monitor.processes.reduce(0) { $0 + ($1.estimatedWatts ?? 0) }
    }
}
