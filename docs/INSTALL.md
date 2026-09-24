# Installing BatteryScope

## Step 1 — check you have the compiler

```bash
xcode-select -p
```

If it prints a path such as `/Library/Developer/CommandLineTools`, skip to
step 2.

If it says "unable to get active developer directory", run:

```bash
ls /Library/Developer/CommandLineTools/usr/bin/swiftc
```

If that prints the path back, the tools are installed but not selected:

```bash
sudo xcode-select --switch /Library/Developer/CommandLineTools
```

If it says "No such file or directory", install them:

```bash
xcode-select --install
```

A dialog appears. Click Install, accept the licence, and wait for the
progress window to finish. It is roughly 700 MB.

Confirm before continuing:

```bash
xcode-select -p
swiftc --version
```

The first prints a path, the second prints a version number.

## Step 2 — build and install

Download [BatteryScope.zip](https://github.com/larpvox/batteryscope/raw/HEAD/BatteryScope.zip)
into `~/Downloads`, then paste this whole block:

```bash
osascript -e 'quit app "BatteryScope"'
cd ~/Downloads
rm -rf BatteryScope
unzip -o BatteryScope.zip
cd BatteryScope
chmod +x make.sh
./make.sh install
```

Working from a clone of this repository instead, run `./make.sh install` from
the repository root.

## Diagnostics

Everything your Mac exposes — every battery property and power sensor.
This is what to send if a figure shows a dash:

```bash
/Applications/BatteryScope.app/Contents/MacOS/BatteryScope --ctl dump
```

Just the fan keys:

```bash
/Applications/BatteryScope.app/Contents/MacOS/BatteryScope --ctl dump | grep -E "^F"
```

Fan state:

```bash
/Applications/BatteryScope.app/Contents/MacOS/BatteryScope --ctl fans
```

One SMC key by name:

```bash
/Applications/BatteryScope.app/Contents/MacOS/BatteryScope --ctl get PDTR
```

Compare against what macOS itself reports:

```bash
system_profiler SPPowerDataType
```

## Removing it

```bash
cd ~/Downloads/BatteryScope
./make.sh uninstall
```

Removes the app, the root helper, the sudoers rule and the launch agent,
and resets the charger and fans to stock on the way out.

## Notes

- The app has no window and no Dock icon. It lives in the menu bar.
  Left-click for the panel, right-click for refresh, reset, launch at login and quit.
- Closing Terminal does not quit the app.
- The repository contains source code, not a ready-made app. Step 2 is what
  turns it into one. That is the trade for having no App Store, no developer
  account and no installer package.
