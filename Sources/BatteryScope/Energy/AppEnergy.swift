//
//  AppEnergy.swift
//  BatteryScope
//
//  Per-process energy: top(1) parser, system_profiler and powermetrics bridges.
//

import Foundation

public struct ProcessEnergy: Identifiable, Equatable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let name: String
    /// Activity Monitor's "Energy Impact" score. Unitless, relative.
    public let energyImpact: Double
    public let cpuPercent: Double
    /// Estimated share of the machine's measured wattage. See note in README.
    public var estimatedWatts: Double?
}

/// The whole picture: what went to processes, what didn't, and what the
/// figures rest on.
public struct EnergyBreakdown {
    public var processes: [ProcessEnergy] = []
    /// Power the model is willing to attribute to processes at all.
    public var attributableWatts: Double = 0
    /// Attributable power belonging to processes below the cut.
    public var otherProcessesWatts: Double = 0
    /// Display, radios, storage and the idle floor of the chip. Nothing to do
    /// with any particular process.
    public var baselineWatts: Double = 0
    public var totalWatts: Double = 0
    public var basis: String = "No power reading yet."
    public var usingComputePower = false
    public var sampledProcessCount = 0
}

public enum AppEnergySampler {

    /// Attribute power to processes.
    ///
    /// The old version divided the machine's entire draw among the twelve
    /// processes on screen, which meant those twelve absorbed everything
    /// whether they accounted for it or not, and the numbers were guaranteed
    /// not to reconcile with anything.
    ///
    /// Two things changed. The budget is now the power that processes can
    /// plausibly be responsible for, rather than the whole machine: CPU and
    /// GPU package power where the SMC reports it, otherwise system draw minus
    /// the lowest idle draw actually observed on this Mac. Your display, Wi-Fi
    /// radio and SSD draw power no process asked for, and handing that to
    /// Chrome was never defensible. And the shares are computed across every
    /// process sampled, not just the ones displayed, so what's on screen is a
    /// real fraction of the total rather than a rescaled one.
    ///
    /// Where a compute-power figure exists, CPU time does the splitting, which
    /// is close to proportional to package power. Without one, Energy Impact
    /// does it — a weighted composite of CPU, wakeups, GPU and disk that's a
    /// ranking rather than a measurement.
    public static func sample(limit: Int = 12,
                              totalWatts: Double?,
                              computeWatts: Double?,
                              idleFloorWatts: Double?) -> EnergyBreakdown {
        var result = EnergyBreakdown()
        guard let raw = runTop() else { return result }

        var rows = parse(raw)
        // `top` is only running because we asked it to. Its cost is the price
        // of the measurement, not a fact about the machine.
        rows.removeAll { $0.name == "top" || $0.name.hasSuffix("/top") }
        result.sampledProcessCount = rows.count

        let total = totalWatts ?? 0
        result.totalWatts = total

        let budget: Double
        if let compute = computeWatts, compute > 0 {
            budget = total > 0 ? min(compute, total) : compute
            result.usingComputePower = true
            result.basis = "Measured CPU and GPU package power, split by each process's share of CPU time."
        } else if let floor = idleFloorWatts, total > 0, floor < total {
            budget = total - floor
            result.basis = String(format: "System draw less %.1f W, the lowest idle draw seen on this Mac recently, split by Energy Impact. That floor is your display, radios and storage, which belong to no process.", floor)
        } else if total > 0 {
            budget = 0
            result.basis = "Still learning this Mac's idle draw. Until there's a floor to subtract, nothing is attributed."
        } else {
            budget = 0
            result.basis = "No system power reading available on this Mac."
        }

        result.attributableWatts = budget
        result.baselineWatts = max(0, total - budget)

        let weights = rows.map { row in
            result.usingComputePower ? max(0, row.cpuPercent) : max(0, row.energyImpact)
        }
        let totalWeight = weights.reduce(0, +)
        if totalWeight > 0, budget > 0 {
            for i in rows.indices {
                rows[i].estimatedWatts = budget * (weights[i] / totalWeight)
            }
        }

        rows.sort { ($0.estimatedWatts ?? 0, $0.energyImpact) > ($1.estimatedWatts ?? 0, $1.energyImpact) }
        var selected = Array(rows.prefix(limit))

        // Always show our own cost, ranked or not. An app that monitors power
        // shouldn't hide its own.
        if !selected.contains(where: { $0.name.hasSuffix("BatteryScope") }),
           let own = rows.first(where: { $0.name.hasSuffix("BatteryScope") }) {
            selected.append(own)
        }

        let shown = selected.reduce(0) { $0 + ($1.estimatedWatts ?? 0) }
        result.otherProcessesWatts = max(0, budget - shown)
        result.processes = selected
        return result
    }

    private static func runTop() -> String? {
        // Two samples: the first is cumulative since boot and useless, the
        // second is live. Take a wide slice so the shares are computed against
        // everything running, not just the busiest handful.
        guard let result = ProcessRunner.run(
            "/usr/bin/top",
            ["-l", "2", "-n", "150", "-o", "power", "-stats", "pid,power,cpu,command"],
            timeout: 10
        ), !result.timedOut else { return nil }
        return String(data: result.output, encoding: .utf8)
    }

    static func parse(_ output: String) -> [ProcessEnergy] {
        // Keep only the final sample block.
        let blocks = output.components(separatedBy: "Processes:")
        guard let block = blocks.last else { return [] }

        var started = false
        var results: [ProcessEnergy] = []

        for line in block.split(separator: "\n", omittingEmptySubsequences: true) {
            let text = String(line)
            if !started {
                if text.hasPrefix("PID") { started = true }
                continue
            }
            let parts = text.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count >= 4,
                  let pid = Int32(parts[0]) else { continue }
            let power = Double(parts[1].replacingOccurrences(of: "+", with: "")) ?? 0
            let cpu = Double(parts[2].replacingOccurrences(of: "+", with: "")) ?? 0
            let name = parts[3].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            results.append(ProcessEnergy(pid: pid, name: name, energyImpact: power, cpuPercent: cpu, estimatedWatts: nil))
        }
        return results
    }
}

/// Some Macs publish no raw mAh capacities at all, which leaves the health
/// figures blank. system_profiler still knows, so ask it — sparingly, because
/// it takes about a second.
public enum SystemProfilerBattery {

    public static func maximumCapacityPercent() -> Double? {
        guard let result = ProcessRunner.run("/usr/sbin/system_profiler", ["SPPowerDataType"], timeout: 30),
              !result.timedOut,
              let text = String(data: result.output, encoding: .utf8) else { return nil }

        for line in text.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard l.hasPrefix("Maximum Capacity:") else { continue }
            let digits = l.drop { $0 != ":" }.dropFirst()
                .trimmingCharacters(in: .whitespaces)
                .prefix { $0.isNumber || $0 == "." }
            if let v = Double(digits), v > 0, v <= 200 { return v }
        }
        return nil
    }
}

/// Real per-subsystem wattage from `powermetrics`, which needs root.
/// Only used when the user has installed the sudoers rule described in the README.
public enum PowerMetrics {

    public struct Sample {
        public var cpuWatts: Double?
        public var gpuWatts: Double?
        public var aneWatts: Double?
        public var packageWatts: Double?
    }

    public static var isAvailable: Bool {
        ChargeControlClient.isInstalled
            && FileManager.default.isExecutableFile(atPath: "/usr/bin/powermetrics")
    }

    public static func sample(timeoutMs: Int = 800) -> Sample? {
        guard let result = ProcessRunner.run(
            "/usr/bin/sudo",
            ["-n", ChargeControlClient.helperPath, "--ctl", "powermetrics", String(timeoutMs)],
            timeout: 10
        ), !result.timedOut, result.status == 0,
              let text = String(data: result.output, encoding: .utf8) else { return nil }

        var sample = Sample()
        for line in text.split(separator: "\n") {
            let l = String(line)
            if let w = milliwatts(in: l) {
                if l.hasPrefix("CPU Power") { sample.cpuWatts = w }
                else if l.hasPrefix("GPU Power") { sample.gpuWatts = w }
                else if l.hasPrefix("ANE Power") { sample.aneWatts = w }
                else if l.hasPrefix("Combined Power") || l.hasPrefix("Package Power") { sample.packageWatts = w }
            }
        }
        return sample
    }

    private static func milliwatts(in line: String) -> Double? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let tail = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        let number = tail.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(number) else { return nil }
        if tail.contains("mW") { return value / 1000 }
        if tail.contains("W") { return value }
        return nil
    }
}
