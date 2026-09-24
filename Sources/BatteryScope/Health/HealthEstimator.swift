//
//  HealthEstimator.swift
//  BatteryScope
//
//  Measured health, discharge methods and calibration phases.
//

import Foundation

/// One completed measurement: how much charge actually moved, divided by how
/// much of the battery macOS said that represented.
struct CapacitySample: Codable {
    let capacity: Double    // implied full-charge capacity, mAh
    let span: Double        // percentage points it was measured across
    let date: Date
    let charging: Bool
}

/// Works out real capacity by counting coulombs rather than trusting a
/// reported number.
///
/// Integrate current over time and you know exactly how many milliamp-hours
/// left or entered the cell. Divide that by the fraction of the battery macOS
/// says it represented and you get the implied full-charge capacity. Compare
/// that against the design capacity and you have a health figure that was
/// measured rather than reported.
///
/// The catch is that it takes time. A measurement needs a decent swing in the
/// charge level, and anything integrated across a sleep is fiction, so runs
/// interrupted by sleep, by plugging in, or by a gap in sampling are thrown
/// away rather than patched over.
final class HealthEstimator {

    /// Smallest charge swing that counts. Below this, rounding in the reported
    /// percentage swamps the measurement.
    static let requiredSpan: Double = 10

    private static let storageKey = "capacitySamples"
    private static let maximumSamples = 24

    private(set) var samples: [CapacitySample] = []

    private var lastTime: Date?
    private var lastSoC: Double?
    private var runStartSoC: Double?
    private var runMilliampHours: Double = 0
    private var runCharging: Bool?

    init() { load() }

    /// How far into the current measurement we are, in percentage points.
    var progressPoints: Double? {
        guard let start = runStartSoC, let now = lastSoC else { return nil }
        return abs(now - start)
    }

    var medianCapacity: Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.map(\.capacity).sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    func health(design: Double?) -> Double? {
        guard let design, design > 0, let capacity = medianCapacity else { return nil }
        return capacity / design * 100
    }

    func reset() {
        samples = []
        resetRun()
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
    }

    private func resetRun() {
        runStartSoC = nil
        runMilliampHours = 0
        runCharging = nil
        lastTime = nil
        lastSoC = nil
    }

    /// Feed one reading. Returns true when a measurement completed.
    @discardableResult
    func feed(soc: Double?, amperage: Double?, charging: Bool,
              maxGap: TimeInterval, designCapacity: Double?) -> Bool {
        let now = Date()
        guard let soc else { return false }

        defer {
            lastTime = now
            lastSoC = soc
        }

        guard let previousTime = lastTime, let previousSoC = lastSoC else {
            runStartSoC = soc
            runMilliampHours = 0
            runCharging = charging
            return false
        }

        let elapsed = now.timeIntervalSince(previousTime)
        // A gap longer than a few sampling intervals means the machine slept.
        // Whatever happened to the battery in between is unknown.
        guard elapsed > 0, elapsed <= maxGap else {
            resetRun()
            return false
        }

        // Direction changes end a run: charging and discharging are separate
        // measurements and averaging across the turn would be meaningless.
        let reversed = (charging && soc < previousSoC) || (!charging && soc > previousSoC)
        if runCharging != charging || reversed {
            runStartSoC = soc
            runMilliampHours = 0
            runCharging = charging
            return false
        }

        if runStartSoC == nil {
            runStartSoC = previousSoC
            runMilliampHours = 0
            runCharging = charging
        }

        // Sitting at a plug with nothing moving contributes no charge but
        // doesn't invalidate the run either.
        if let amperage, abs(amperage) > 0.01 {
            runMilliampHours += abs(amperage) * (elapsed / 3600) * 1000
        }

        guard let start = runStartSoC else { return false }
        let span = abs(soc - start)
        guard span >= Self.requiredSpan, runMilliampHours > 0 else { return false }

        let implied = runMilliampHours / (span / 100)
        runStartSoC = soc
        runMilliampHours = 0

        // Discard anything wildly outside the plausible range rather than let
        // one bad run drag the median around.
        if let design = designCapacity, design > 0 {
            guard implied > design * 0.4, implied < design * 1.3 else { return false }
        }

        samples.append(CapacitySample(capacity: implied, span: span, date: now, charging: charging))
        if samples.count > Self.maximumSamples {
            samples.removeFirst(samples.count - Self.maximumSamples)
        }
        save()
        return true
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(samples) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([CapacitySample].self, from: data) else { return }
        samples = decoded
    }
}

/// How to get charge out of the battery while the machine is plugged in.
enum DischargeMethod: String, CaseIterable, Identifiable {
    /// Cut the adapter through the SMC. Fast, and the only method that works
    /// while the machine is idle, but it leans on an undocumented key.
    case adapterCutoff
    /// Just stop charging and let ordinary use drain the cell. Slow, does
    /// nothing while the Mac sits idle, but touches nothing risky.
    case passive
    /// Cut the adapter where the hardware supports it, otherwise wait.
    case automatic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .adapterCutoff: return "Cut the adapter"
        case .passive: return "Let it drain through use"
        case .automatic: return "Automatic"
        }
    }

    var detail: String {
        switch self {
        case .adapterCutoff:
            return "Disconnects the charger in firmware so the Mac runs off the cell. Works even when idle. Uses an undocumented SMC key, and macOS may blink the MagSafe LED because it thinks the charger has failed."
        case .passive:
            return "Stops charging and waits for normal use to bring the level down. Touches nothing beyond the charge gate, but a Mac sitting idle on mains barely discharges at all."
        case .automatic:
            return "Cuts the adapter where this Mac supports it, and falls back to waiting where it doesn't."
        }
    }
}

/// Where a calibration run has got to. Persisted, so quitting mid-run doesn't
/// silently leave the charger in a strange state.
enum CalibrationPhase: String {
    case idle
    case discharging
    case charging
    case finished
    case aborted
}
