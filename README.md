# BatteryScope

A menu bar battery monitor for macOS in the AlDente mould. Live wattage, cycle
count, both versions of battery health, per-app power, what the charger is
actually delivering, and optional charge limiting.

## Download

**[⬇ Download BatteryScope.zip](https://github.com/larpvox/batteryscope/raw/HEAD/BatteryScope.zip)**

Unzip it, open Terminal in the folder, and run:

```bash
cd ~/Downloads/BatteryScope
chmod +x make.sh
./make.sh install
```

That builds the app on your Mac and installs it to `/Applications`. You need
the Xcode Command Line Tools; [docs/INSTALL.md](docs/INSTALL.md) walks through
getting them, plus diagnostics and removal.

The rest of this repository is the same app as source, split into one file
per subsystem for development.

---

```
BatteryScope.zip        the download — the sources plus make.sh, built by `./make.sh zip`
Sources/BatteryScope/   the app, split by subsystem (see "Inside the source")
make.sh                 build / install / uninstall
Package.swift           for `swift build`, Xcode and editor tooling
docs/INSTALL.md         step-by-step install, diagnostics, removal
VERSION                 the version; the in-app updater compares against it
```

No dependencies and no Xcode project; `make.sh` drives `swiftc` directly.
Needs the Command Line Tools (`xcode-select --install`) and nothing else. macOS 13 or later, Intel or
Apple silicon.

---

## Use it

```bash
chmod +x make.sh
./make.sh run
```

That compiles a universal binary, wraps it in `build/BatteryScope.app`, signs it
ad hoc and launches it. Look in the menu bar. Left-click for the panel,
right-click for refresh, reset, launch at login and quit.

To put it somewhere permanent:

```bash
./make.sh install
```

Copies the app to `/Applications` and then asks two yes/no questions: whether to
set up charge control, and whether to launch at login. Say no to both and you
still get the full monitor.

To back all of it out, including the sudoers rule and the launch agent:

```bash
./make.sh uninstall
```

## Updates

BatteryScope checks GitHub for a newer version each time it launches. If there
is one it asks first, then downloads the new source, builds it on your Mac,
swaps the app in place and relaunches. No password is needed, because the app
is installed as you rather than root. The one exception is an update that
changes the root-owned charge control helper: the build stamps a fingerprint
of the helper's source into the binary, and only when that differs from the
installed helper's does the updater ask for your password to replace it. You can check by hand from
the right-click menu or the **Updates…** button in the panel.

The launch check is silent if GitHub can't be reached, which includes the
repository being private. A check you start yourself tells you what happened.

---

## One binary, two jobs

Launched with no arguments, `BatteryScope` is the menu bar app and runs as you.

Launched with `--ctl`, the same binary is a command line tool. Charge control
means writing to the SMC, which needs root, so `./make.sh install` places a
root-owned copy at `/usr/local/bin/batteryscope-helper` and adds a one-line
sudoers rule for your account only. The app shells out to it with `sudo -n`. If
the helper isn't there the call fails quietly and everything else carries on.

The CLI is useful on its own:

```bash
BatteryScope --ctl status
BatteryScope --ctl get PDTR            # what the charger is delivering
BatteryScope --ctl get B0AC            # battery current
BatteryScope --ctl fans                # fan speeds, targets and limits
sudo batteryscope-helper --ctl inhibit on
sudo batteryscope-helper --ctl fan 0 3000   # fan 0 to 3000 rpm
sudo batteryscope-helper --ctl fans auto    # every fan back to the system
sudo batteryscope-helper --ctl reset
```

---

## What it shows

**Power** — system draw from the SMC's `PSTR` rail, what the charger is actually
pushing from `PDTR` rather than the number printed on the brick, battery watts
signed so you can read charge rate against discharge rate, CPU and GPU package
power, voltage, current, battery and charger temperature, the adapter's model,
manufacturer, serial, rated wattage and the voltage/current contract it actually
negotiated, and a ten-minute sparkline.

**Health** — true health (raw full-charge capacity against design, uncapped) next
to the macOS health figure (nominal against design, clamped at 100%), with the
gap between them spelled out. Design, full-charge, nominal and current capacity
in mAh. Cycle count against rated design cycles with a progress bar and cycles
remaining. Battery model, manufacturer, manufacture date, serial. And a toggle
for hardware charge percentage, which reads state of charge straight from the
battery management system rather than the smoothed number macOS displays —
usually 2 to 7 points apart.

**Apps** — top processes by energy use with an estimated wattage each.

**Control** — charge limit from 20 to 100%, Sailing Mode (charge to the ceiling,
then let the battery drift down a few points before charging again, instead of
topping up every time it slips a percent), automatic discharge down to the
limit while plugged in, a one-shot top up to 100%, heat protection that pauses
charging above a temperature you pick, a calibration run (down to 15%, then
straight through to 100%), live readback of what the SMC says the charger is
doing, and a choice of what the menu bar itself displays: any combination of
charge percentage, system draw, battery watts, charger output, temperature and
time remaining.

**Fans** — shown only on Macs that have fans. Live speed, target and the
firmware's own minimum and maximum for each fan, plus manual control: drag a
fan's slider to set a target speed, or hand it back to the system. The target
is always clamped to the range the firmware reports, so a fan can't be driven
below what Apple considers safe. Every fan is handed back to the system on
quit, on uninstall and from Reset, and the app starts with the system in charge
whatever state the last run left behind. On M3 and later the thermal manager
owns the fans and has to be asked to let go, which takes a few seconds and is
refused outright on some machines — the tab says so when that happens. Fan
control needs the helper; reading speeds doesn't.

---

## How much to trust each number

**Exact.** Everything in Power and Health. It comes from
`IOService:/AppleSmartBattery` and the AppleSMC user client — the same sources
System Information and Activity Monitor read. The SMC power rails (`PSTR`,
`PDTR`, `PPBR`) are read-only and need no privileges on either architecture.

**Estimated, and labelled as such in the app.** Per-app wattage. macOS has no
public API that attributes real power to a process. Activity Monitor's Energy
Impact is a weighted composite of CPU time, wakeups, GPU and disk activity, not
watts, and `powermetrics` needs root. So the app takes measured system draw,
subtracts a small idle baseline, and splits the rest by each process's share of
that score. The ranking is accurate, the watt figure is a plausible magnitude.
If you installed the helper, real CPU and GPU package power arrive from
`powermetrics` and fill in the rows the SMC leaves empty on Apple silicon.

**Experimental, off by default.** Charge control and fan control. Apple documents none of it. The
app writes `CH0B` and `CH0C` (charge inhibit), `CH0I` (adapter cutoff), `CHWA`
(the firmware 80% cap on Apple silicon) and `CHTE`. These keys vary by model and
by macOS version — AlDente rewrites this layer with nearly every major release,
which tells you how stable it is. Fan control writes the per-fan mode and
target keys (`F0Md`/`F0md` or `FS!`, `F0Tg`, and `Ftst` on M3 and later). The
app resets both to stock on quit, on uninstall, and from the button in the
Control tab.

Two things worth knowing before you enable it. Holding a battery below 80% for
weeks without full cycles throws off the calibration, and the machine starts
shutting down at 40–50% or sitting at 100% for hours; four or five full cycles
fixes it, and one full cycle a fortnight avoids it. And macOS Tahoe 26.4 added a
native 80–100% charge limit in System Settings — if an 80% ceiling is all you
want, use Apple's, because it runs in firmware and survives sleep and logout.
The reason to run this app is the instrumentation.

---

## Inside the source

```
Sources/BatteryScope/
├── BatteryScopeMain.swift      entry point — picks app or CLI from argv
├── SMC/SMC.swift               AppleSMC user client — key info, read, write
├── Battery/BatteryReader.swift AppleSmartBattery IORegistry reader, snapshot model
├── Energy/AppEnergy.swift      top(1) parser, powermetrics bridge
├── Control/ChargeControl.swift the SMC charge keys and the sudo client wrapper
├── Health/HealthEstimator.swift measured health, discharge and calibration
├── Fans/FanController.swift    fan readings and control
├── Monitor/Monitor.swift       5s poll loop, rolling history, charge-limit state machine
├── Interface/                  SwiftUI panel — one file per tab, plus shared pieces
├── App/AppDelegate.swift       status item, popover, tooltip, right-click menu
├── App/LoginItem.swift         launch at login (the same LaunchAgent make.sh writes)
├── App/Updater.swift           update check against GitHub, rebuild and reinstall
├── CLI/CLI.swift               --ctl
└── Support/ProcessRunner.swift child processes with a timeout
```

`./make.sh` compiles every `.swift` file under `Sources/BatteryScope/` into a
universal binary. `swift build` works too, for a plain debug binary without the
app bundle.

`BatteryScope.zip`, the download, is rebuilt automatically: a GitHub Actions
workflow (`.github/workflows/zip.yml`) runs `./make.sh zip` on every push to
the default branch that changes the sources and commits the new zip. You can also run
`./make.sh zip` yourself; the output is reproducible, so an unchanged source
gives an identical zip.

Not done yet: Shortcuts actions, MagSafe LED colour, scheduling.
