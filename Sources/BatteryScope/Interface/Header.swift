//
//  Header.swift
//  BatteryScope
//

import Foundation
import SwiftUI

// MARK: - Header

struct Header: View {
    @EnvironmentObject var monitor: Monitor

    var body: some View {
        let snap = monitor.snapshot
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: monitor.stateSymbol)
                .font(.system(size: 26))
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(percentText)
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    if let other = otherPercent {
                        Text(other)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text("v\(Updater.shared.currentVersion)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help("BatteryScope version")
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var percentText: String {
        guard let p = monitor.effectivePercent else { return "--" }
        // Only show a decimal when the source actually has one. A battery
        // management system reporting whole numbers shouldn't look precise.
        return p == p.rounded()
            ? String(format: "%.0f%%", p)
            : String(format: "%.1f%%", p)
    }

    /// Whichever figure isn't currently on display, shown small beside it.
    private var otherPercent: String? {
        let snap = monitor.snapshot
        if monitor.useHardwarePercent {
            guard let shown = snap.displayedPercent else { return nil }
            return String(format: "macOS says %.0f%%", shown)
        }
        guard let hardware = snap.hardwarePercent,
              let shown = snap.displayedPercent,
              abs(hardware - shown) >= 0.5 else { return nil }
        return String(format: "battery reports %.0f%%", hardware)
    }

    private var subtitle: String {
        let snap = monitor.snapshot
        var parts = [snap.stateLabel]
        if snap.isCharging, let m = monitor.estimatedMinutesToFull {
            let target = monitor.chargeTarget
            parts.append("\(Format.duration(m)) to " + (target >= 100 ? "full" : String(format: "%.0f%%", target)))
        } else if !snap.isPluggedIn, let m = monitor.estimatedMinutesLeft {
            parts.append("\(Format.duration(m)) left")
        }
        if let note = monitor.lastHelperMessage { parts.append(note) }
        return parts.joined(separator: " · ")
    }

    private var tint: Color {
        let snap = monitor.snapshot
        if snap.isCharging { return .green }
        if snap.isPluggedIn { return .blue }
        if let p = monitor.effectivePercent, p < 20 { return .red }
        return .primary
    }
}
