//
//  FansTab.swift
//  BatteryScope
//

import Foundation
import SwiftUI

// MARK: - Fans

struct FansTab: View {
    @EnvironmentObject var monitor: Monitor

    var body: some View {
        if let message = monitor.fanMessage {
            Text(message)
                .font(.callout)
                .foregroundStyle(.orange)
        }

        ForEach(monitor.fans) { fan in
            Card("Fan \(fan.index + 1)") {
                Row("Now", fan.stopped ? "Stopped" : String(format: "%.0f rpm", fan.rpm),
                    emphasis: true,
                    hint: fan.stopped ? "normal when the machine is cool" : nil)
                Row("Target", String(format: "%.0f rpm", fan.target))
                Row("Range", String(format: "%.0f to %.0f rpm", fan.minimum, fan.maximum))
                Row("SMC reports", fan.manual ? "Forced" : "System")

                Toggle("Manual control", isOn: manualBinding(for: fan))
                    .font(.callout)
                    .disabled(!monitor.helperInstalled)

                if fan.maximum > fan.minimum {
                    Slider(
                        value: sliderBinding(for: fan),
                        in: fan.minimum...fan.maximum,
                        step: 50,
                        onEditingChanged: { editing in
                            if !editing {
                                commit(fan, sliderBinding(for: fan).wrappedValue)
                            }
                        }
                    )
                    .disabled(!held(fan) || !monitor.helperInstalled)
                    HStack {
                        Text(String(format: "%.0f rpm", sliderBinding(for: fan).wrappedValue))
                            .font(.callout.monospacedDigit())
                        Spacer()
                        Button("Quiet") { commit(fan, fan.minimum) }
                            .controlSize(.small)
                        Button("Full") { commit(fan, fan.maximum) }
                            .controlSize(.small)
                    }
                    .disabled(!held(fan) || !monitor.helperInstalled)
                }
            }
        }

        if !monitor.helperInstalled {
            Text("Needs the helper: run ./make.sh install.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Button("Hand every fan back to the system") { monitor.restoreFans() }
            .disabled(!monitor.helperInstalled)

        Text("Limited to the fan's safe range. Fans return to automatic on quit.")
            .font(.caption)
            .foregroundStyle(.secondary)

        Text("Slower fans mean more heat, which ages the battery.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func held(_ fan: FanInfo) -> Bool {
        monitor.heldFans.contains(fan.index)
    }

    /// Send a target and move the slider with it, so the two never disagree.
    private func commit(_ fan: FanInfo, _ rpm: Double) {
        monitor.pendingFanTargets[fan.index] = rpm
        monitor.setFanTarget(fan.index, rpm: rpm)
    }

    /// Switching this off hands the fan straight back to the system.
    private func manualBinding(for fan: FanInfo) -> Binding<Bool> {
        Binding(
            get: { held(fan) },
            set: { on in
                if on {
                    commit(fan, sliderBinding(for: fan).wrappedValue)
                } else {
                    monitor.setFanAuto(fan.index)
                }
            }
        )
    }

    private func sliderBinding(for fan: FanInfo) -> Binding<Double> {
        Binding(
            get: {
                if let pending = monitor.pendingFanTargets[fan.index] { return pending }
                let live = fan.target > 0 ? fan.target : fan.minimum
                return min(max(live, fan.minimum), max(fan.minimum, fan.maximum))
            },
            set: { monitor.pendingFanTargets[fan.index] = $0 }
        )
    }
}
