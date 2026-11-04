//
//  AppEnergy.swift
//  BatteryScope
//
//  Per-process energy: top(1) parser, system_profiler and powermetrics bridges.
//

import Darwin
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

    /// Attribute power to processes. The budget is system draw less the
    /// least this Mac has drawn with nothing running, since the rest is there
    /// because of what's running. Shares are taken across every process
    /// sampled, not just the ones shown, so the rows are real fractions.
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

        let total = totalWatts ?? 0
        result.totalWatts = total

        // Everything above what the machine draws with nothing going on is
        // down to what's running: the work itself, and the screen, GPU,
        // radios and storage that work keeps busy. Measured CPU and GPU power
        // is split by CPU time; the rest by Energy Impact, which weighs GPU,
        // wakeups and disk as well as CPU.
        let compute = (computeWatts ?? 0) > 0 ? computeWatts : nil
        var budget = 0.0
        var computePart = 0.0
        if total > 0, let floor = idleFloorWatts, floor < total {
            budget = total - floor
            computePart = min(compute ?? 0, budget)
            let split = compute != nil
                ? "measured CPU and GPU power by each app's CPU time, the rest by Energy Impact"
                : "by Energy Impact"
            result.basis = String(format: "System draw less %.1f W, the least this Mac has drawn with nothing running. Everything above that is down to what's running, shared out ", floor)
                + split + "."
        } else if let compute {
            budget = total > 0 ? min(compute, total) : compute
            computePart = budget
            result.basis = "Still learning this Mac's idle draw, so only measured CPU and GPU power is shared out for now, by CPU time."
        } else if total > 0 {
            result.basis = "Still learning this Mac's idle draw. Until there's a floor to subtract, nothing is attributed."
        } else {
            result.basis = "No system power reading available on this Mac."
        }
        result.usingComputePower = computePart > 0

        result.attributableWatts = budget
        result.baselineWatts = max(0, total - budget)

        func share(_ watts: Double, by weight: (ProcessEnergy) -> Double) {
            let weights = rows.map { max(0, weight($0)) }
            let sum = weights.reduce(0, +)
            guard watts > 0, sum > 0 else { return }
            for i in rows.indices where weights[i] > 0 {
                rows[i].estimatedWatts = (rows[i].estimatedWatts ?? 0) + watts * weights[i] / sum
            }
        }
        share(computePart, by: \.cpuPercent)
        share(budget - computePart, by: \.energyImpact)

        rows = groupByApp(rows)
        result.sampledProcessCount = rows.count

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

    /// Chrome, Safari and every Electron app run as a crowd of helper
    /// processes, each of which on its own looks cheap. Activity Monitor adds
    /// them up under the app that owns them, and so does this.
    static func groupByApp(_ rows: [ProcessEnergy]) -> [ProcessEnergy] {
        var groups: [String: ProcessEnergy] = [:]
        var order: [String] = []
        for row in rows {
            let app = appBundle(pid: row.pid)
            let key = app?.path ?? "pid:\(row.pid)"
            if let g = groups[key] {
                groups[key] = ProcessEnergy(
                    pid: g.pid,
                    name: g.name,
                    energyImpact: g.energyImpact + row.energyImpact,
                    cpuPercent: g.cpuPercent + row.cpuPercent,
                    estimatedWatts: g.estimatedWatts.map { $0 + (row.estimatedWatts ?? 0) } ?? row.estimatedWatts
                )
            } else {
                var first = row
                if let app { first = ProcessEnergy(pid: row.pid, name: app.name, energyImpact: row.energyImpact,
                                                   cpuPercent: row.cpuPercent, estimatedWatts: row.estimatedWatts) }
                groups[key] = first
                order.append(key)
            }
        }
        return order.compactMap { groups[$0] }
    }

    /// The outermost .app a process runs from. Helpers live inside their
    /// app's own bundle, so the first ".app/" in the path is the app itself.
    private static func appBundle(pid: Int32) -> (path: String, name: String)? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        guard let range = path.range(of: ".app/") else { return nil }
        let bundle = String(path[..<range.lowerBound])
        let name = (bundle as NSString).lastPathComponent
        guard !name.isEmpty else { return nil }
        return (bundle + ".app", name)
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
