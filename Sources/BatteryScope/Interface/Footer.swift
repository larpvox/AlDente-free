//
//  Footer.swift
//  BatteryScope
//

import AppKit
import Foundation
import SwiftUI

// MARK: - Footer

struct Footer: View {
    @EnvironmentObject var monitor: Monitor

    var body: some View {
        HStack {
            Text("Updated \(Format.clock(monitor.snapshot.timestamp))")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Updates\u{2026}") { Updater.shared.checkManually() }
                .controlSize(.small)
                .help("Check for updates")
            Button("Refresh") { monitor.refresh(force: true) }
                .controlSize(.small)
            Button("Quit") {
                monitor.resetChargeControl()
                NSApp.terminate(nil)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
