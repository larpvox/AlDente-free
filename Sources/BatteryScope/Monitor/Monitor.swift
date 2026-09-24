//
//  Monitor.swift
//  BatteryScope
//
//  Poll loop, rolling history and the charge-limit state machine.
//

import Combine
import Foundation
import SwiftUI

/// A single point in the rolling power history.
struct PowerPoint: Identifiable {
    let id = UUID()
    let time: Date
    let systemWatts: Double
    let adapterWatts: Double
    let batteryWatts: Double
}

@MainActor
final class Monitor: ObservableObject {

    @Published private(set) var snapshot = BatterySnapshot()
    private var macOSChargeLimit: Double?
    private var macOSLimitUnknownStreak = 0
    @Published private(set) var processes: [ProcessEnergy] = []
    @Published private(set) var breakdown = EnergyBreakdown()

    /// The lowest system draw this Mac actually reaches, learned rather than
    /// assumed. Display brightness moves it by several watts, so it's a
    /// rolling figure rather than a constant.
    @Published private(set) var idleFloorWatts: Double?

    /// Runtime worked out from the rolling power history rather than taken
    /// from the gas gauge, which extrapolates from whatever the current draw
    /// happened to be at the instant you asked.
    @Published private(set) var estimatedMinutesLeft: Int?
    @Published private(set) var estimatedMinutesToFull: Int?
    @Published private(set) var estimateWatts: Double?
    @Published private(set) var estimateIsOurs = false
    private var idleWindow: [Double] = []
    @Published private(set) var history: [PowerPoint] = []
    @Published var panelTab: PanelTab = .control
    @Published private(set) var lastHelperMessage: String?

    /// Called once at the end of every refresh. The status item hangs off
    /// this instead of the object-wide change publisher, which was firing
    /// a dozen times per tick as each property landed.
    var menuBarDidChange: (() -> Void)?

    /// BatteryScope's own measured health figure, and how it's coming along.
    @Published private(set) var measuredHealth: Double?
    @Published private(set) var measurementSamples = 0
    @Published private(set) var measurementProgress: Double?

    /// True while the panel is open. Almost everything expensive is gated on
    /// this: there's no point sampling at five second resolution to draw a
    /// graph nobody can see.
    @Published var panelVisible = false {
        didSet { if panelVisible != oldValue { restartTimer() } }
    }

    /// Whether the measured figure had to be held at the agreement limit.
    @Published private(set) var measuredHealthClamped = false
    @Published private(set) var measuredHealthRaw: Double?

    private let estimator = HealthEstimator()

    // Settings
    @Published var chargeLimitEnabled: Bool {
        didSet { defaults.set(chargeLimitEnabled, forKey: "chargeLimitEnabled"); enforce() }
    }
    @Published var chargeLimit: Double {
        didSet { defaults.set(chargeLimit, forKey: "chargeLimit"); enforce() }
    }
    @Published var useHardwarePercent: Bool {
        didSet {
            defaults.set(useHardwarePercent, forKey: "useHardwarePercent")
            menuBarDidChange?()
        }
    }
    @Published var heatProtectionEnabled: Bool {
        didSet { defaults.set(heatProtectionEnabled, forKey: "heatProtectionEnabled"); enforce() }
    }
    @Published var heatProtectionCelsius: Double {
        didSet { defaults.set(heatProtectionCelsius, forKey: "heatProtectionCelsius") }
    }
    @Published var autoDischargeEnabled: Bool {
        didSet { defaults.set(autoDischargeEnabled, forKey: "autoDischargeEnabled"); enforce() }
    }

    /// Sailing Mode. On by default, and deliberately useful even with no
    /// charge limit set: left alone, a plugged-in Mac trickles a percent back
    /// in every time it slips a percent, which is a slow drip of partial
    /// cycles. A band means it charges once and then leaves the cell alone
    /// until it has drifted a few points down.
    @Published var sailingEnabled: Bool {
        didSet { defaults.set(sailingEnabled, forKey: "sailingEnabled"); enforce() }
    }

    /// How far below the ceiling the battery is allowed to drift.
    @Published var sailingRange: Double {
        didSet { defaults.set(sailingRange, forKey: "sailingRange"); enforce() }
    }

    @Published var dischargeMethod: DischargeMethod {
        didSet { defaults.set(dischargeMethod.rawValue, forKey: "dischargeMethod"); enforce() }
    }

    /// Discharging stops when the Mac sleeps, so optionally hold it awake.
    @Published var keepAwakeWhileDischarging: Bool {
        didSet { defaults.set(keepAwakeWhileDischarging, forKey: "keepAwakeWhileDischarging") }
    }

    @Published private(set) var calibrationPhase: CalibrationPhase = .idle
    @Published private(set) var calibrationMessage: String?
    @Published private(set) var lastCalibration: Date?

    /// True while the battery is being held at the top of the sailing band.
    @Published private(set) var sailingHolding = false

    /// Empty on the fanless machines, which is how the Fans tab decides
    /// whether to exist at all.
    @Published private(set) var fans: [FanInfo] = []
    var hasFans: Bool { fanCount > 0 }
    @Published private(set) var fanMessage: String?
    /// Read once at launch so the tab can exist without polling the fans.
    @Published private(set) var fanCount = 0
    /// Where each fan's slider is sitting before it's committed.
    @Published var pendingFanTargets: [Int: Double] = [:]

    /// Which fans BatteryScope is holding. The checkbox follows this rather
    /// than the SMC's own mode bit, because that bit doesn't mean the same
    /// thing on every Mac — some report forced mode while the fans sit at a
    /// zero target under system control. What the hardware claims is shown
    /// separately, so a disagreement is visible instead of confusing.
    @Published private(set) var heldFans: Set<Int> = []
    @Published var topUpArmed = false {
        didSet { enforce() }
    }
    /// Everything the menu bar can display. Any combination is allowed; they
    /// render in the order listed here.
    enum MenuBarField: String, CaseIterable, Identifiable {
        // Declared alphabetically by label, which is the order they appear
        // both in the checklist and in the menu bar itself.
        case batteryWatts, percent, chargerWatts, systemWatts
        case temperature, timeRemaining
        var id: String { rawValue }
        var label: String {
            switch self {
            case .percent: return "Charge percentage"
            case .systemWatts: return "System draw"
            case .batteryWatts: return "Battery watts"
            case .chargerWatts: return "Charger output"
            case .temperature: return "Temperature"
            case .timeRemaining: return "Time remaining"
            }
        }
    }

    @Published var menuBarFields: Set<MenuBarField> {
        didSet {
            defaults.set(menuBarFields.map(\.rawValue), forKey: "menuBarFields")
            restartTimer()          // an empty bar can idle; a live one can't
            menuBarDidChange?()
        }
    }

    /// How often everything refreshes, in seconds.
    @Published var refreshSeconds: Double {
        didSet {
            defaults.set(refreshSeconds, forKey: "refreshSeconds")
            restartTimer()
        }
    }

    /// Poll far more slowly with the panel closed. On by default; this is most
    /// of what keeps the app cheap to run.
    /// How often the readings that barely move are refreshed: health,
    /// capacity, cycle count, charge-control flags. Ignored while you're
    /// looking at the tab that shows them, which refreshes with everything
    /// else.
    @Published var slowSeconds: Double {
        didSet { defaults.set(slowSeconds, forKey: "slowSeconds") }
    }

    @Published var idleSlowdown: Bool {
        didSet {
            defaults.set(idleSlowdown, forKey: "idleSlowdown")
            restartTimer()
        }
    }

    /// The interval actually in force right now.
    ///
    /// The menu bar is the whole app when the panel is shut, so the rate you
    /// set is the rate it runs at either way. Backing off behind your back
    /// made the readout stale and made the slider look broken. What the
    /// slowdown does now is skip the secondary work, not throttle the power
    /// reading, which is one registry call and a handful of cached SMC reads.
    ///
    /// The exception is a menu bar with nothing on it: then there is nothing
    /// to keep current and it can idle properly.
    var effectiveInterval: Double {
        let base = max(1, refreshSeconds)
        if panelVisible { return base }
        if menuBarFields.isEmpty { return max(60, base * 12) }
        return base
    }

    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var lastAppsSample = Date.distantPast
    private var lastPowerMetricsSample = Date.distantPast
    private var lastProfilerSample = Date.distantPast
    private var lastSlowSample = Date.distantPast
    /// powermetrics only runs occasionally, so its answer has to survive the
    /// refreshes in between. Without this the CPU and GPU rows appeared for a
    /// single tick and vanished again.
    private var cachedCompute: (cpu: Double?, gpu: Double?, at: Date)?
    private var lastFanSample = Date.distantPast
    private var lastFloorUpdate = Date.distantPast
    private var profilerHealth: Double?
    /// Keep roughly ten minutes of history whatever the refresh rate.
    private var historyLimit: Int { max(60, Int(600 / max(1, refreshSeconds))) }

    var helperInstalled: Bool { ChargeControlClient.isInstalled }

    /// Charge control works alongside the macOS limit: macOS stops at its
    /// limit, BatteryScope can stop lower and sail below it.
    var chargeControlAvailable: Bool { helperInstalled }

    /// The limit macOS itself is enforcing, if any.
    var macOSLimit: Double? {
        snapshot.systemChargeLimitActive ? (snapshot.systemChargeLimitPercent ?? 80) : nil
    }

    /// Where charging stops: the lower of BatteryScope's limit and macOS's.
    var effectiveCeiling: Double {
        min(chargeLimitEnabled ? chargeLimit : 100, macOSLimit ?? 100)
    }

    /// What the battery is charging towards right now.
    var chargeTarget: Double {
        topUpArmed ? (macOSLimit ?? 100) : effectiveCeiling
    }

    init() {
        chargeLimitEnabled = defaults.object(forKey: "chargeLimitEnabled") as? Bool ?? true
        let storedLimit = defaults.double(forKey: "chargeLimit")
        chargeLimit = storedLimit == 0 ? 80 : storedLimit
        useHardwarePercent = defaults.object(forKey: "useHardwarePercent") as? Bool ?? false
        heatProtectionEnabled = defaults.object(forKey: "heatProtectionEnabled") as? Bool ?? true
        let storedHeat = defaults.double(forKey: "heatProtectionCelsius")
        heatProtectionCelsius = storedHeat == 0 ? 40 : storedHeat
        autoDischargeEnabled = defaults.bool(forKey: "autoDischargeEnabled")
        if let saved = defaults.array(forKey: "menuBarFields") as? [String] {
            menuBarFields = Set(saved.compactMap(MenuBarField.init(rawValue:)))
        } else {
            // macOS already shows the percentage, so start with what it doesn't.
            menuBarFields = [.chargerWatts, .systemWatts, .timeRemaining]
        }
        let savedRefresh = defaults.double(forKey: "refreshSeconds")
        refreshSeconds = savedRefresh == 0 ? 2 : savedRefresh
        let savedSlow = defaults.double(forKey: "slowSeconds")
        slowSeconds = savedSlow == 0 ? 60 : savedSlow
        idleSlowdown = defaults.object(forKey: "idleSlowdown") as? Bool ?? true
        let savedFloor = defaults.double(forKey: "idleFloorWatts")
        if savedFloor > 0 { idleFloorWatts = savedFloor }
        sailingEnabled = defaults.object(forKey: "sailingEnabled") as? Bool ?? true
        let savedSailing = defaults.double(forKey: "sailingRange")
        sailingRange = savedSailing == 0 ? 5 : min(max(savedSailing, 2), 10)
        dischargeMethod = DischargeMethod(rawValue: defaults.string(forKey: "dischargeMethod") ?? "") ?? .automatic
        keepAwakeWhileDischarging = defaults.object(forKey: "keepAwakeWhileDischarging") as? Bool ?? true
        calibrationPhase = CalibrationPhase(rawValue: defaults.string(forKey: "calibrationPhase") ?? "") ?? .idle
        lastCalibration = defaults.object(forKey: "lastCalibration") as? Date
    }

    func start() {
        refresh()
        // Never inherit a previous session's fan state. Whatever was left
        // behind by a crash, a force quit or an earlier run, the app starts
        // with the system in charge of cooling.
        fanCount = FanController.count
        if fanCount > 0 {
            fans = FanController.read()
            if helperInstalled { restoreFans() }
        }
        restartTimer()
    }

    private func restartTimer() {
        timer?.invalidate()
        let interval = effectiveInterval
        let newTimer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // Tolerance lets macOS fire this alongside other work already waking
        // the CPU rather than waking it on its own account. It is the cheapest
        // thing a repeating timer can do for battery life.
        // Enough slack for macOS to coalesce wakeups, not enough to be
        // visible in the menu bar.
        newTimer.tolerance = min(interval * 0.15, 2)
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    func binding(for field: MenuBarField) -> Binding<Bool> {
        Binding(
            get: { self.menuBarFields.contains(field) },
            set: { on in
                if on { self.menuBarFields.insert(field) } else { self.menuBarFields.remove(field) }
            }
        )
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// The charge figure the rest of the app should trust.
    var effectivePercent: Double? {
        if useHardwarePercent, let hw = snapshot.hardwarePercent { return hw }
        return snapshot.displayedPercent ?? snapshot.hardwarePercent
    }

    /// Waking from sleep invalidates the SMC handle and leaves the battery
    /// driver reporting zeros for a moment. Drop everything cached and reread.
    func handleWake() {
        SMC.shared.reset()
        forgetDiscoveredKeys()
        lastAppsSample = .distantPast
        lastPowerMetricsSample = .distantPast
        lastProfilerSample = .distantPast
        // Belt and braces: a timer that came through sleep in a bad state
        // is replaced rather than trusted.
        restartTimer()
        refresh(force: true)
        // The driver settles a second or two after wake.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.refresh(force: true)
        }
    }

    /// Drop every "this key isn't there" and "this key is the one" memory,
    /// so the next read probes the hardware afresh.
    private func forgetDiscoveredKeys() {
        SMC.shared.forgetMissing()
        BatteryReader.forgetResolvedKeys()
        ChargeControl.forgetKeySet()
        FanController.forget()
    }

    /// `force` is the Refresh button: bypass every throttle and re-read the
    /// lot, including the readings that normally wait for their own tab.
    func refresh(force: Bool = false) {
        let now = Date()

        // Refresh used to skip the key caches, so a reading that had dropped
        // out stayed blank however many times you pressed it.
        if force { forgetDiscoveredKeys() }

        // The slow half only runs when it's due, or when you're looking at a
        // tab that shows it. Everything else carries forward.
        let viewingHealth = panelVisible && panelTab == .health
        let viewingSlowTab = viewingHealth || (panelVisible && panelTab == .control)
        // With the panel shut and the slowdown on, the secondary readings go
        // four times slower still. Nothing is looking at them.
        let slowGap = slowSeconds * ((idleSlowdown && !panelVisible) ? 4 : 1)
        let slowDue = force || viewingSlowTab || now.timeIntervalSince(lastSlowSample) >= slowGap
        if slowDue { lastSlowSample = now }

        // Health is recomputed once at launch and then only while you're
        // looking at it.
        let healthDue = force || viewingHealth || snapshot.designCapacity == nil
        let carry = (slowDue && healthDue) ? nil : snapshot

        let snap = BatteryReader.snapshot(slow: slowDue, health: healthDue, carryOver: carry)
        if snap.isPluggedIn != snapshot.isPluggedIn {
            SMC.shared.forgetMissing()
            BatteryReader.forgetResolvedKeys()
        }
        snapshot = snap

        // macOS 26.4's Charge Limit slider doesn't show up in the IORegistry.
        // A read that can't tell keeps the last answer, so the Control tab
        // doesn't flicker; five in a row and it's treated as off.
        if slowDue {
            switch SystemChargeLimit.read() {
            case .on(let limit):
                macOSChargeLimit = limit
                macOSLimitUnknownStreak = 0
            case .off:
                macOSChargeLimit = nil
                macOSLimitUnknownStreak = 0
            case .unknown:
                macOSLimitUnknownStreak += 1
                if macOSLimitUnknownStreak >= 5 { macOSChargeLimit = nil }
            }
        }
        if let limit = macOSChargeLimit {
            snapshot.systemChargeLimitActive = true
            snapshot.systemChargeLimitPercent = limit
        }

        // System Settings rounds and smooths its Maximum Capacity figure, so
        // recomputing it from the capacity registers lands a point or two
        // away. Where system_profiler will tell us the real one, use it.
        if let h = profilerHealth {
            snapshot.macOSHealthPercent = h
            snapshot.macOSHealthFromSettings = true
        }

        if snapshot.cpuWatts == nil, let cached = cachedCompute,
           now.timeIntervalSince(cached.at) < 600 {
            snapshot.cpuWatts = cached.cpu
            snapshot.gpuWatts = snapshot.gpuWatts ?? cached.gpu
        }

        // Count the charge that actually moved. macOS's own percentage is the
        // yardstick, since that's the number the estimate is calibrating.
        estimator.feed(
            soc: snap.displayedPercent ?? snap.hardwarePercent,
            amperage: snap.amperage,
            charging: snap.isCharging,
            maxGap: effectiveInterval * 3,
            designCapacity: snap.designCapacity
        )
        applyMeasuredHealth(snap)
        measurementSamples = estimator.samples.count
        measurementProgress = estimator.progressPoints

        let sys = snap.systemWatts ?? abs(snap.batteryWatts ?? 0)
        history.append(PowerPoint(
            time: snap.timestamp,
            systemWatts: sys,
            adapterWatts: snap.adapterWatts ?? 0,
            batteryWatts: snap.batteryWatts ?? 0
        ))
        if history.count > historyLimit { history.removeFirst(history.count - historyLimit) }

        recomputeRuntime(snap)

        // Fans only get polled while you're watching them, or while we're
        // holding one and need to notice if it slips.
        if fanCount > 0,
           force || (panelVisible && panelTab == .fans) || !heldFans.isEmpty,
           force || now.timeIntervalSince(lastFanSample) >= 2 {
            lastFanSample = now
            fans = FanController.read()
        }

        // Learn the floor from the quietest readings in the recent window.
        // The fifth percentile rather than the outright minimum, so one odd
        // sample can't set it permanently low.
        if let measured = snap.systemWatts, measured > 0 {
            idleWindow.append(measured)
            if idleWindow.count > 240 { idleWindow.removeFirst(idleWindow.count - 240) }
            if idleWindow.count >= 20, now.timeIntervalSince(lastFloorUpdate) >= 60 {
                lastFloorUpdate = now
                let sorted = idleWindow.sorted()
                let floor = sorted[max(0, sorted.count / 20)]
                idleFloorWatts = floor
                defaults.set(floor, forKey: "idleFloorWatts")
            }
        }

        // top(1) costs about a second of CPU. Only run it while the tab that
        // displays its output is actually on screen.
        if force || (panelVisible && panelTab == .apps),
           force || now.timeIntervalSince(lastAppsSample) >= slowSeconds {
            lastAppsSample = now
            let totalWatts = sys
            let compute: Double? = snap.cpuWatts.map { $0 + (snap.gpuWatts ?? 0) }
            let floor = idleFloorWatts
            Task.detached(priority: .utility) {
                let result = AppEnergySampler.sample(
                    limit: 12,
                    totalWatts: totalWatts,
                    computeWatts: compute,
                    idleFloorWatts: floor
                )
                await MainActor.run {
                    self.breakdown = result
                    self.processes = result.processes
                }
            }
        }

        // Apple recalculates this rarely, so once on launch and then twice an
        // hour while the Health tab is in use is plenty.
        if force || profilerHealth == nil || viewingHealth,
           force || now.timeIntervalSince(lastProfilerSample) >= 1800 {
            lastProfilerSample = now
            Task.detached(priority: .utility) {
                guard let health = SystemProfilerBattery.maximumCapacityPercent() else { return }
                await MainActor.run {
                    self.profilerHealth = health
                    self.snapshot.macOSHealthPercent = health
                    self.snapshot.macOSHealthFromSettings = true
                }
            }
        }

        // powermetrics runs as root for the best part of a second. Same rule.
        if snap.cpuWatts == nil, force || (panelVisible && panelTab == .power),
           PowerMetrics.isAvailable,
           force || now.timeIntervalSince(lastPowerMetricsSample) >= 60 {
            lastPowerMetricsSample = now
            Task.detached(priority: .utility) {
                guard let pm = PowerMetrics.sample() else { return }
                await MainActor.run {
                    self.cachedCompute = (pm.cpuWatts, pm.gpuWatts, Date())
                    if let c = pm.cpuWatts { self.snapshot.cpuWatts = c }
                    if let g = pm.gpuWatts { self.snapshot.gpuWatts = g }
                }
            }
        }

        enforce()
        menuBarDidChange?()
    }

    // MARK: Runtime

    /// Energy left in the cell, in watt-hours.
    private func remainingEnergy(_ snap: BatterySnapshot, volts: Double) -> Double? {
        if let mAh = snap.rawCurrentCapacity, mAh > 0 {
            return mAh * volts / 1000
        }
        guard let percent = effectivePercent else { return nil }
        if let full = snap.rawMaxCapacity ?? snap.designCapacity, full > 0 {
            return full * (percent / 100) * volts / 1000
        }
        return nil
    }

    private func headroomEnergy(_ snap: BatterySnapshot, volts: Double, to target: Double) -> Double? {
        guard let full = snap.rawMaxCapacity ?? snap.designCapacity, full > 0 else { return nil }
        guard let percent = effectivePercent else {
            guard let now = snap.rawCurrentCapacity, now > 0 else { return nil }
            return max(0, full * target / 100 - now) * volts / 1000
        }
        return full * max(0, target - percent) / 100 * volts / 1000
    }

    /// Smoothed battery power for the runtime estimate, and when it was last
    /// fed. Reset whenever the battery switches between charging, discharging
    /// and neither, so one state's rate never leaks into another's estimate.
    private var runtimeWatts: Double?
    private var runtimeWattsAt: Date?
    private var runtimeMode = 0

    /// How quickly the estimate follows a change in load, in seconds. The old
    /// one-minute median with a three-sample minimum lagged the battery's own
    /// gauge badly; this settles within a couple of refreshes and still
    /// takes the edge off a single spike.
    static let runtimeTimeConstant: TimeInterval = 15

    private func smoothedRuntimeWatts(_ sample: Double?, mode: Int, at time: Date) -> Double? {
        if mode != runtimeMode {
            runtimeMode = mode
            runtimeWatts = nil
            runtimeWattsAt = nil
        }
        guard let sample, sample > 0.2 else { return runtimeWatts }
        if let previous = runtimeWatts, let last = runtimeWattsAt {
            let dt = max(0, time.timeIntervalSince(last))
            let alpha = 1 - exp(-dt / Self.runtimeTimeConstant)
            runtimeWatts = previous + alpha * (sample - previous)
        } else {
            runtimeWatts = sample
        }
        runtimeWattsAt = time
        return runtimeWatts
    }

    private func recomputeRuntime(_ snap: BatterySnapshot) {
        estimatedMinutesLeft = nil
        estimatedMinutesToFull = nil
        estimateWatts = nil
        estimateIsOurs = false

        let volts = snap.voltage ?? 11.5
        let mode = !snap.isPluggedIn ? 1 : (snap.isCharging ? 2 : 0)
        let signed = snap.batteryWatts
        let sample: Double? = mode == 1 ? signed.map { -$0 } : (mode == 2 ? signed : nil)
        let typical = smoothedRuntimeWatts(sample, mode: mode, at: snap.timestamp)

        if mode == 1 {
            if let typical, typical > 0.1, let energy = remainingEnergy(snap, volts: volts) {
                estimatedMinutesLeft = Int((energy / typical) * 60)
                estimateWatts = typical
                estimateIsOurs = true
                return
            }
            estimatedMinutesLeft = snap.minutesToEmpty
            return
        }

        if mode == 2 {
            // Charging towards the limit, not to 100%, when one is set. A
            // trickle that would take more than a day isn't a real estimate.
            let target = chargeTarget
            let percent = effectivePercent ?? 0
            guard !sailingHolding, percent < target - 0.5 else { return }
            if let typical, typical > 0.1, let headroom = headroomEnergy(snap, volts: volts, to: target) {
                // Above roughly 80% the charger tapers and the rate keeps
                // falling, so a flat extrapolation from the current rate runs
                // short. Below that the current rate is the honest answer.
                let taper = target > 90 && percent > 80 ? 1.3 : 1.0
                let minutes = Int((headroom / typical) * 60 * taper)
                guard minutes <= 24 * 60 else { return }
                estimatedMinutesToFull = minutes
                estimateWatts = typical
                estimateIsOurs = true
                return
            }
            if target >= 100 { estimatedMinutesToFull = snap.minutesToFull }
        }
    }

    // MARK: Charge control

    /// Decide what the charger should be doing and tell the helper, with a little
    /// hysteresis so we're not flapping the SMC every five seconds.
    private func enforce() {
        // macOS's own limit, when set, stops charging by itself. BatteryScope
        // works underneath it: it can stop lower, and sail below whichever
        // limit is lower. It never needs to lift macOS's.
        guard helperInstalled else { return }
        guard let percent = effectivePercent else { return }

        // A calibration run overrides every other rule until it finishes.
        if calibrationPhase == .discharging || calibrationPhase == .charging {
            runCalibration(percent: percent)
            return
        }

        if topUpArmed {
            if percent >= min(99.5, (macOSLimit ?? 100) - 0.5) {
                topUpArmed = false
            } else {
                apply(inhibit: false, discharge: false,
                      note: String(format: "Topping up to %.0f%%", macOSLimit ?? 100))
                return
            }
        }

        if heatProtectionEnabled, let t = snapshot.temperatureC, t >= heatProtectionCelsius {
            apply(inhibit: true, discharge: false,
                  note: String(format: "Charging paused: battery at %.1f\u{00B0}C", t))
            return
        }

        // The ceiling is the lower of our limit and macOS's, or a full charge.
        // Sailing Mode works against any of them.
        let ceiling = effectiveCeiling
        let appLimited = chargeLimitEnabled && chargeLimit < (macOSLimit ?? 100)
        // macOS stops a point or so short of its limit and then reports
        // not charging, which counts as having got there.
        let atCeiling = percent >= ceiling
            || (!appLimited && macOSLimit != nil && snapshot.isPluggedIn
                && !snapshot.isCharging && percent >= ceiling - 2)

        guard sailingEnabled else {
            sailingHolding = false
            // With only macOS limiting, there is nothing for us to do.
            guard appLimited else {
                apply(inhibit: false, discharge: false)
                return
            }
            if atCeiling {
                apply(inhibit: true, discharge: autoDischargeEnabled && percent > ceiling + 1)
            } else if percent <= ceiling - 3 {
                apply(inhibit: false, discharge: false)
            }
            return
        }

        // Sailing: charge to the ceiling, then hold the gate shut and let the
        // cell drift down through the band before charging again. One larger
        // charge instead of a continuous drip of small ones.
        let floorLevel = max(20, ceiling - sailingRange)

        if sailingHolding {
            if percent <= floorLevel {
                sailingHolding = false
                apply(inhibit: false, discharge: false,
                      note: String(format: "Sailing: charging back to %.0f%%", ceiling))
            } else {
                let wantsDischarge = autoDischargeEnabled && appLimited && percent > ceiling + 1
                apply(inhibit: true, discharge: wantsDischarge,
                      note: String(format: "Sailing between %.0f and %.0f%%", floorLevel, ceiling))
            }
        } else if atCeiling {
            sailingHolding = true
            apply(inhibit: true, discharge: false,
                  note: String(format: "Sailing: holding, will drift to %.0f%%", floorLevel))
        } else {
            apply(inhibit: false, discharge: false)
        }
    }

    // MARK: Calibration

    /// A calibration run: take the cell down to 15%, then charge it straight
    /// through to full without interruption. Weeks spent inside a narrow band
    /// leave the fuel gauge guessing; one clean sweep end to end gives it two
    /// real reference points again.
    func startCalibration() {
        // macOS's limit would stop the charge half short of 100%.
        guard helperInstalled, macOSLimit == nil else { return }
        setPhase(.discharging)
        calibrationMessage = "Starting"
        setKeepAwake(true, force: true)
        enforce()
    }

    func cancelCalibration() {
        setPhase(.aborted)
        calibrationMessage = "Cancelled"
        setKeepAwake(false)
        apply(inhibit: false, discharge: false)
    }

    private func setPhase(_ phase: CalibrationPhase) {
        calibrationPhase = phase
        defaults.set(phase.rawValue, forKey: "calibrationPhase")
    }

    private func runCalibration(percent: Double) {
        switch calibrationPhase {
        case .discharging:
            if percent <= 15 {
                setPhase(.charging)
                calibrationMessage = "Now charging straight through to 100%"
                apply(inhibit: false, discharge: false)
                return
            }
            calibrationMessage = String(format: "Discharging to 15%% \u{2014} at %.0f%%", percent)
            apply(inhibit: true, discharge: wantsAdapterCutoff)

        case .charging:
            if percent >= 99.5 || snapshot.fullyCharged {
                setPhase(.finished)
                lastCalibration = Date()
                defaults.set(lastCalibration, forKey: "lastCalibration")
                calibrationMessage = "Finished"
                setKeepAwake(false)
                apply(inhibit: false, discharge: false)
                return
            }
            if !snapshot.isPluggedIn {
                setPhase(.aborted)
                calibrationMessage = "Unplugged before the charge finished. Start again when you can leave it on mains."
                setKeepAwake(false)
                return
            }
            calibrationMessage = String(format: "Charging to 100%% \u{2014} at %.0f%%", percent)
            apply(inhibit: false, discharge: false)

        default:
            break
        }
    }

    /// Whether the selected discharge method should cut the adapter.
    private var wantsAdapterCutoff: Bool {
        switch dischargeMethod {
        case .passive: return false
        case .adapterCutoff: return true
        case .automatic: return ChargeControl.supportsAdapterCutoff
        }
    }

    // MARK: Keeping the Mac awake

    private var caffeinate: Process?

    /// Discharging and calibrating both stop dead when the Mac sleeps, so hold
    /// it awake for the duration and let go afterwards.
    private func setKeepAwake(_ on: Bool, force: Bool = false) {
        if on {
            guard caffeinate == nil, force || keepAwakeWhileDischarging else { return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
            process.arguments = ["-d", "-i"]
            try? process.run()
            caffeinate = process
        } else {
            caffeinate?.terminate()
            caffeinate = nil
        }
    }

    private var lastInhibit: Bool?
    private var lastDischarge: Bool?

    private func apply(inhibit: Bool, discharge: Bool, note: String? = nil) {
        if lastInhibit != inhibit {
            _ = ChargeControlClient.setChargingInhibited(inhibit)
            lastInhibit = inhibit
        }
        let cutAdapter = discharge && wantsAdapterCutoff
        if lastDischarge != cutAdapter {
            _ = ChargeControlClient.setAdapterDisabled(cutAdapter)
            lastDischarge = cutAdapter
            // A calibration run manages this itself; don't undo it here.
            if calibrationPhase != .discharging, calibrationPhase != .charging {
                setKeepAwake(cutAdapter)
            }
        }
        lastHelperMessage = note
    }

    /// How far the measured figure is allowed to sit from the reported one.
    /// Coulomb counting drifts; a battery does not lose a tenth of its capacity
    /// between one reading and the next. Beyond this the estimate is more
    /// likely wrong than the battery is, so hold it at the edge and say so.
    static let agreementLimit: Double = 4

    private func applyMeasuredHealth(_ snap: BatterySnapshot) {
        guard let raw = estimator.health(design: snap.designCapacity) else {
            measuredHealth = nil
            measuredHealthRaw = nil
            measuredHealthClamped = false
            return
        }
        measuredHealthRaw = raw

        guard let reference = snap.macOSHealthPercent ?? snap.trueHealthPercent else {
            measuredHealth = raw
            measuredHealthClamped = false
            return
        }

        let low = reference - Self.agreementLimit
        let high = reference + Self.agreementLimit
        let held = min(max(raw, low), high)
        measuredHealth = held
        measuredHealthClamped = abs(held - raw) > 0.05
    }

    func resetHealthMeasurement() {
        estimator.reset()
        measuredHealth = nil
        measuredHealthRaw = nil
        measuredHealthClamped = false
        measurementSamples = 0
        measurementProgress = nil
    }

    /// What to tell the user while there isn't enough data yet.
    var measurementStatus: String {
        if snapshot.designCapacity == nil {
            return "Needs a design capacity figure, which this Mac doesn't publish."
        }
        if snapshot.amperage == nil {
            return "Needs a current reading, which this Mac isn't reporting."
        }
        let required = HealthEstimator.requiredSpan
        if let progress = measurementProgress, progress > 0.5 {
            return String(format: "Measuring: %.0f of %.0f percentage points into this run.", progress, required)
        }
        return String(format: "Measuring. A reading needs %.0f points of continuous charge or discharge, uninterrupted by sleep.", required)
    }

    // MARK: Fans

    func setFanAuto(_ index: Int) {
        guard helperInstalled else { return }
        fanMessage = "Handing fan \(index + 1) back to the system\u{2026}"
        heldFans.remove(index)
        pendingFanTargets[index] = nil
        Task.detached(priority: .userInitiated) {
            let ok = FanControlClient.setAuto(index)
            await MainActor.run {
                // FanController keeps unsynchronised caches, so it is only
                // ever touched from the main thread.
                let stillManual = FanController.read()
                    .first { $0.index == index }?.manual ?? false
                self.fanMessage = (ok && !stillManual)
                    ? nil
                    : "Released fan \(index + 1), but the SMC still reports forced mode. On some Macs that bit stays set while the system is genuinely back in control \u{2014} watch the target and speed rather than the flag."
                self.refresh()
            }
        }
    }

    func setFanTarget(_ index: Int, rpm: Double) {
        guard helperInstalled else { return }
        // Taking a fan off the thermal manager can take a few seconds on M3
        // and later, so this runs off the main thread and reports back.
        fanMessage = "Taking fan \(index + 1) over\u{2026} this can take a few seconds."
        Task.detached(priority: .userInitiated) {
            let ok = FanControlClient.setTarget(index, rpm: rpm)
            await MainActor.run {
                if ok {
                    self.heldFans.insert(index)
                    self.fanMessage = nil
                } else {
                    self.heldFans.remove(index)
                    self.fanMessage = "This Mac refused manual control of fan \(index + 1). Its thermal manager is holding the fans."
                }
                self.refresh()
            }
        }
    }

    func restoreFans() {
        guard helperInstalled, hasFans else { return }
        heldFans.removeAll()
        pendingFanTargets.removeAll()
        Task.detached(priority: .userInitiated) {
            _ = FanControlClient.restoreAll()
            await MainActor.run {
                self.fanMessage = nil
                self.refresh()
            }
        }
    }

    func resetChargeControl() {
        guard helperInstalled else { return }
        _ = ChargeControlClient.reset()
        if hasFans { _ = FanControlClient.restoreAll() }
        lastInhibit = false
        lastDischarge = false
        sailingHolding = false
        if calibrationPhase == .discharging || calibrationPhase == .charging {
            cancelCalibration()
        }
        setKeepAwake(false)
    }

    // MARK: Menu bar

    var menuBarText: String {
        let parts = MenuBarField.allCases
            .filter { menuBarFields.contains($0) }
            .compactMap { menuBarValue(for: $0) }
        return parts.isEmpty ? "\u{26A1}" : parts.joined(separator: "  ")
    }

    /// nil means "this field doesn't apply right now" and it's left out.
    /// A reading that applies but momentarily isn't available shows a dash
    /// instead, so fields don't silently vanish from the bar and come back.
    private func menuBarValue(for field: MenuBarField) -> String? {
        let dash = "\u{2013}"
        switch field {
        case .percent:
            return effectivePercent.map { String(format: "%.0f%%", $0) } ?? "\(dash)%"
        case .systemWatts:
            return snapshot.systemWatts.map { String(format: "%.1fW", $0) } ?? "\(dash)W"
        case .batteryWatts:
            // On battery this is the system draw with a minus sign. Showing
            // both is the same number twice.
            if !snapshot.isPluggedIn, menuBarFields.contains(.systemWatts) { return nil }
            return snapshot.batteryWatts.map { String(format: "%+.1fW", $0) } ?? "\(dash)W"
        case .chargerWatts:
            guard snapshot.isPluggedIn else { return nil }
            return snapshot.adapterWatts.map { String(format: "%.0fW in", $0) } ?? "\(dash)W in"
        case .temperature:
            return snapshot.temperatureC.map { String(format: "%.0f\u{00B0}", $0) } ?? "\(dash)\u{00B0}"
        case .timeRemaining:
            if snapshot.isCharging { return estimatedMinutesToFull.map(Format.duration) ?? dash }
            if !snapshot.isPluggedIn { return estimatedMinutesLeft.map(Format.duration) ?? dash }
            return nil
        }
    }

    /// Only used for the icon inside the panel. The menu bar itself stays
    /// text-only, since macOS already puts a battery glyph up there.
    var stateSymbol: String {
        if !snapshot.batteryInstalled { return "bolt.slash" }
        if snapshot.chargingInhibited == true && snapshot.isPluggedIn { return "pause.circle" }
        if snapshot.isCharging { return "battery.100.bolt" }
        if snapshot.isPluggedIn { return "powerplug" }
        guard let p = effectivePercent else { return "battery.50" }
        switch p {
        case ..<12: return "battery.0"
        case ..<40: return "battery.25"
        case ..<70: return "battery.50"
        case ..<90: return "battery.75"
        default: return "battery.100"
        }
    }
}
