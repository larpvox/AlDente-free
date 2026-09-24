#!/bin/bash
#
# BatteryScope — build, install, uninstall.
#
#   ./make.sh              Build build/BatteryScope.app
#   ./make.sh run          Build, then launch it
#   ./make.sh install      Build, install to /Applications, set up charge
#                          control and launch at login
#   ./make.sh uninstall    Remove everything, reset the charger to stock
#   ./make.sh zip          Rebuild BatteryScope.zip, the download, from source
#
# Needs the Xcode Command Line Tools. Nothing else.
# (`swift build` also works, via Package.swift, for a plain debug binary.)

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="BatteryScope"
BUNDLE_ID="com.local.batteryscope"
# The single source of truth for the version. The in-app updater compares the
# installed app's version against this file on GitHub, so bump it whenever a
# change should reach people who already have the app.
VERSION="$(tr -d '[:space:]' < VERSION 2>/dev/null || true)"
VERSION="${VERSION:-0}"
SOURCE_DIR="Sources/${APP_NAME}"
OUT="build"
APP="${OUT}/${APP_NAME}.app"
BIN="${APP}/Contents/MacOS/${APP_NAME}"

INSTALLED_APP="/Applications/${APP_NAME}.app"
HELPER="/usr/local/bin/batteryscope-helper"
SUDOERS="/etc/sudoers.d/batteryscope"
AGENT="${HOME}/Library/LaunchAgents/${BUNDLE_ID}.plist"

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }

require_tools() {
    if ! xcrun --find swiftc >/dev/null 2>&1; then
        echo "swiftc not found. Install the Command Line Tools:" >&2
        echo "  xcode-select --install" >&2
        exit 1
    fi
}

# swiftc needs to be told where macro plugins live; Xcode and SwiftPM pass this
# for you. Nothing in the sources uses a macro, but if that ever changes the build
# shouldn't break over a flag.
plugin_flags() {
    local sdk toolchain out=""
    sdk="$(xcrun --show-sdk-path 2>/dev/null || true)/usr/lib/swift/host/plugins"
    toolchain="$(dirname "$(xcrun --find swiftc)")/../lib/swift/host/plugins"
    [ -d "${sdk}" ] && out="${out} -plugin-path ${sdk}"
    [ -d "${toolchain}" ] && out="${out} -plugin-path ${toolchain}"
    printf '%s' "${out}"
}

# A short hash of every source file the root helper (`--ctl`) is built from.
# It's stamped into the binary, so the in-app updater can tell whether an
# update changes the helper at all. Most don't, and those install without
# a password. Battery/ is left out: the helper only uses it for diagnostic
# output, and power-reading fixes shouldn't cost a password.
helper_fingerprint() {
    find "${SOURCE_DIR}/CLI" "${SOURCE_DIR}/Control" "${SOURCE_DIR}/Fans" \
         "${SOURCE_DIR}/SMC" "${SOURCE_DIR}/Support" \
         "${SOURCE_DIR}/BatteryScopeMain.swift" -name '*.swift' -type f \
        | LC_ALL=C sort | xargs cat | shasum -a 256 | cut -c1-16
}

write_info_plist() {
    cat > "$1" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>BSHelperFingerprint</key><string>$2</string>
</dict>
</plist>
PLIST
}

build() {
    require_tools
    say "Compiling ${SOURCE_DIR}"

    local sources=()
    while IFS= read -r f; do sources+=("${f}"); done \
        < <(find "${SOURCE_DIR}" -name '*.swift' | sort)
    mkdir -p "${OUT}"
    rm -rf "${APP}"

    local plugins
    plugins="$(plugin_flags)"

    # The Info.plist is also embedded in the executable itself, so the bare
    # root helper copy (which has no bundle around it) can still report its
    # version and helper fingerprint.
    local plist="${OUT}/Info.plist"
    write_info_plist "${plist}" "$(helper_fingerprint)"
    local embed=(-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "${plist}")

    local slices=()
    for arch in arm64 x86_64; do
        # shellcheck disable=SC2086
        if xcrun swiftc -O -swift-version 5 -parse-as-library ${plugins} \
            -target "${arch}-apple-macos13.0" "${embed[@]}" \
            -o "${OUT}/${APP_NAME}-${arch}" \
            "${sources[@]}" 2>/dev/null; then
            slices+=("${OUT}/${APP_NAME}-${arch}")
            echo "    built ${arch}"
        fi
    done

    if [ ${#slices[@]} -eq 0 ]; then
        echo "    native slice failed, recompiling with diagnostics:" >&2
        # shellcheck disable=SC2086
        xcrun swiftc -O -swift-version 5 -parse-as-library ${plugins} "${embed[@]}" \
            -o "${OUT}/${APP_NAME}-native" "${sources[@]}"
        slices+=("${OUT}/${APP_NAME}-native")
    fi

    say "Assembling ${APP}"
    mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

    if [ ${#slices[@]} -gt 1 ]; then
        lipo -create -output "${BIN}" "${slices[@]}"
        echo "    universal binary"
    else
        cp "${slices[0]}" "${BIN}"
    fi
    chmod 755 "${BIN}"
    rm -f "${OUT}/${APP_NAME}-arm64" "${OUT}/${APP_NAME}-x86_64" "${OUT}/${APP_NAME}-native"

    mv "${plist}" "${APP}/Contents/Info.plist"

    codesign --force --sign - "${APP}" >/dev/null 2>&1 \
        || echo "    (ad hoc signing skipped — it still runs locally)"

    say "Built ${PWD}/${APP}"
}

install_all() {
    build

    say "Installing to ${INSTALLED_APP}"
    if [ -d "${INSTALLED_APP}" ]; then
        osascript -e "quit app \"${APP_NAME}\"" >/dev/null 2>&1 || true
        sleep 1
        rm -rf "${INSTALLED_APP}" 2>/dev/null || sudo rm -rf "${INSTALLED_APP}"
    fi
    # Installed as you, not root, so the in-app updater can replace it
    # without asking for a password.
    if ! cp -R "${APP}" "${INSTALLED_APP}" 2>/dev/null; then
        sudo cp -R "${APP}" "${INSTALLED_APP}"
        sudo chown -R "$(id -un)" "${INSTALLED_APP}"
    fi

    # Only one copy should exist once it's installed. Leaving a stale build
    # behind is how you end up launching last week's version by accident.
    rm -rf "${OUT:?}"

    echo
    echo "Charge limiting, discharge and heat protection need a root-owned copy"
    echo "of the same binary at ${HELPER}, plus a sudoers rule that lets"
    echo "$(id -un) run it without a password prompt."
    echo "Everything else in the app works without this."
    read -r -p "Set that up? [y/N] " reply

    if [[ "${reply}" =~ ^[Yy]$ ]]; then
        sudo mkdir -p /usr/local/bin
        sudo install -m 755 -o root -g wheel "${INSTALLED_APP}/Contents/MacOS/${APP_NAME}" "${HELPER}"

        local tmp
        tmp="$(mktemp)"
        printf '%s ALL=(root) NOPASSWD: %s\n' "$(id -un)" "${HELPER}" > "${tmp}"
        if sudo visudo -c -f "${tmp}" >/dev/null; then
            sudo install -m 440 -o root -g wheel "${tmp}" "${SUDOERS}"
            say "Charge control installed"
            sudo -n "${HELPER}" --ctl status || true
        else
            echo "sudoers rule failed validation, nothing was changed." >&2
        fi
        rm -f "${tmp}"
    else
        say "Skipped charge control"
    fi

    echo
    read -r -p "Launch at login? [y/N] " reply
    if [[ "${reply}" =~ ^[Yy]$ ]]; then
        mkdir -p "$(dirname "${AGENT}")"
        cat > "${AGENT}" <<AGENTPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${BUNDLE_ID}</string>
    <key>ProgramArguments</key>
    <array><string>${INSTALLED_APP}/Contents/MacOS/${APP_NAME}</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><false/>
</dict>
</plist>
AGENTPLIST
        launchctl unload "${AGENT}" >/dev/null 2>&1 || true
        launchctl load "${AGENT}"
        say "Launch agent loaded"
    fi

    echo
    open "${INSTALLED_APP}"
    say "Done. Look in the menu bar."
    say "Installed at ${INSTALLED_APP}; the build folder has been cleared."
}

uninstall_all() {
    say "Removing BatteryScope"
    osascript -e "quit app \"${APP_NAME}\"" >/dev/null 2>&1 || true

    if [ -x "${HELPER}" ]; then
        sudo "${HELPER}" --ctl reset >/dev/null 2>&1 || true
        sudo rm -f "${HELPER}"
    fi
    sudo rm -f "${SUDOERS}"

    if [ -f "${AGENT}" ]; then
        launchctl unload "${AGENT}" >/dev/null 2>&1 || true
        rm -f "${AGENT}"
    fi

    sudo rm -rf "${INSTALLED_APP}"
    defaults delete "${BUNDLE_ID}" >/dev/null 2>&1 || true
    say "Gone. Charging behaviour reset to stock."
}

# The download is the source, not a binary: an unsigned app downloaded from the
# web is quarantined by Gatekeeper, one built on the Mac it runs on is not.
make_zip() {
    say "Packaging ${APP_NAME}.zip"
    local stage
    stage="$(mktemp -d)"
    mkdir -p "${stage}/${APP_NAME}"
    cp -R Sources docs make.sh Package.swift README.md VERSION .gitignore "${stage}/${APP_NAME}/"
    find "${stage}" -name '.DS_Store' -delete
    # Fixed timestamps and a sorted file list, so the same sources always
    # give a byte-identical zip and CI only commits it when something changed.
    find "${stage}" -exec touch -t 198001010000 {} +
    rm -f "${APP_NAME}.zip"
    local dest="${PWD}/${APP_NAME}.zip"
    (cd "${stage}" && find "${APP_NAME}" | LC_ALL=C sort | zip -q -X -D "${dest}" -@)
    rm -rf "${stage}"
    say "Wrote ${PWD}/${APP_NAME}.zip"
}

case "${1:-build}" in
    build)      build ;;
    run)        build; open "${APP}" ;;
    install)    install_all ;;
    uninstall)  uninstall_all ;;
    zip)        make_zip ;;
    *)
        echo "usage: ./make.sh [build|run|install|uninstall|zip]" >&2
        exit 2
        ;;
esac
