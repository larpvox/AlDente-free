//
//  ContentView.swift
//  BatteryScope
//
//  The SwiftUI panel and its tabs.
//

import Combine
import Foundation
import SwiftUI

/// Which tab the panel is showing. This lives outside the view, in Monitor,
/// because @State is a compiler macro in recent SDKs and a plain swiftc
/// invocation doesn't load macro plugins. @Published needs no plugin.
enum PanelTab: String, CaseIterable, Identifiable {
    case control = "Control"
    case power = "Power"
    case health = "Health"
    case apps = "Apps"
    /// Only offered on Macs that actually have fans.
    case fans = "Fans"
    var id: String { rawValue }
}

struct ContentView: View {
    @EnvironmentObject var monitor: Monitor

    var body: some View {
        VStack(spacing: 0) {
            Header()
            Divider()
            Picker("", selection: $monitor.panelTab) {
                ForEach(PanelTab.allCases.filter { $0 != .fans || monitor.hasFans }) {
                    Text($0.rawValue).tag($0)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch monitor.panelTab {
                    case .control: ControlTab()
                    case .power: PowerTab()
                    case .health: HealthTab()
                    case .apps: AppsTab()
                    case .fans: FansTab()
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }

            Divider()
            Footer()
        }
        .frame(width: 390, height: 600)
    }
}
