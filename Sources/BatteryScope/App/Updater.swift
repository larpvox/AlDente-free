//
//  Updater.swift
//  BatteryScope
//
//  Checks GitHub for a newer version and installs it by rebuilding from source.
//

import AppKit
import Foundation

/// BatteryScope ships as source and is built on the Mac it runs on, so an
/// update is the same thing an install is: download the zip, run make.sh,
/// swap the new app in. The version lives in the repo's VERSION file, which
/// make.sh copies into Info.plist.
///
/// The launch check is silent whatever goes wrong, including the 404 GitHub
/// returns for a private repository. Only a check you asked for says so.
@MainActor
final class Updater {

    static let shared = Updater()

    static let owner = "larpvox"
    static let repo = "batteryscope"
    static let helperPath = "/usr/local/bin/batteryscope-helper"

    /// `HEAD` is whatever the default branch is called.
    private let versionURL = URL(string: "https://raw.githubusercontent.com/\(Updater.owner)/\(Updater.repo)/HEAD/VERSION")!
    private let zipURL = URL(string: "https://github.com/\(Updater.owner)/\(Updater.repo)/raw/HEAD/BatteryScope.zip")!

    /// True from the moment an update starts downloading until it finishes or
    /// fails. The menu bar shows "Updating…" meanwhile.
    private(set) var isBusy = false {
        didSet { onBusyChange?() }
    }
    var onBusyChange: (() -> Void)?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private let skippedKey = "updaterSkippedVersion"

    // MARK: Checking

    func checkOnLaunch() {
        Task { await check(userInitiated: false) }
    }

    func checkManually() {
        Task { await check(userInitiated: true) }
    }

    private func check(userInitiated: Bool) async {
        guard !isBusy else { return }

        guard let latest = await fetchLatestVersion() else {
            if userInitiated {
                inform("Couldn't check for updates",
                       "GitHub didn't answer. The repository may be private, or this Mac is offline.")
            }
            return
        }

        guard Self.compare(latest, currentVersion) > 0 else {
            if userInitiated {
                inform("BatteryScope is up to date", "Version \(currentVersion) is the latest.")
            }
            return
        }

        // A version you skipped isn't offered again at launch, but asking
        // for it by hand always works.
        if !userInitiated, UserDefaults.standard.string(forKey: skippedKey) == latest { return }

        let alert = NSAlert()
        alert.messageText = "BatteryScope \(latest) is available"
        alert.informativeText = """
            You have \(currentVersion). The update builds on this Mac and takes a minute or two.
            """
        alert.addButton(withTitle: "Update Now")
        alert.addButton(withTitle: "Later")
        if !userInitiated { alert.addButton(withTitle: "Skip This Version") }
        NSApp.activate(ignoringOtherApps: true)

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            await install(expecting: latest)
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(latest, forKey: skippedKey)
        default:
            break
        }
    }

    private func fetchLatestVersion() async -> String? {
        let request = URLRequest(url: versionURL,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 15)
        guard let result = try? await URLSession.shared.data(for: request),
              (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: result.0, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              Self.isVersion(text) else { return nil }
        return text
    }

    // MARK: Installing

    private struct UpdateError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func install(expecting latest: String) async {
        // Only ever replace an app bundle. Run as a bare `swift build`
        // binary, bundlePath is just the folder it sits in.
        guard Bundle.main.bundlePath.hasSuffix(".app") else {
            inform("Can't update this copy",
                   "This BatteryScope isn't running from an app bundle. Build and install it with ./make.sh install.")
            return
        }
        isBusy = true
        let fm = FileManager.default
        let work = fm.temporaryDirectory
            .appendingPathComponent("BatteryScope-update-\(UUID().uuidString)")
        defer {
            try? fm.removeItem(at: work)
            isBusy = false
        }

        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)

            // Download.
            let download = try await URLSession.shared.download(from: zipURL)
            guard (download.1 as? HTTPURLResponse)?.statusCode == 200 else {
                throw UpdateError(message: "The download failed. Try again later.")
            }
            let zip = work.appendingPathComponent("BatteryScope.zip")
            try fm.moveItem(at: download.0, to: zip)

            // Unpack and build, off the main thread: the build takes a while.
            let source = work.appendingPathComponent("BatteryScope")
            let built = source.appendingPathComponent("build/BatteryScope.app")
            let buildLog: String? = try await Task.detached(priority: .userInitiated) { () throws -> String? in
                guard let unzip = ProcessRunner.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path],
                                                    timeout: 60),
                      unzip.status == 0 else {
                    throw UpdateError(message: "The downloaded zip couldn't be unpacked.")
                }
                guard let build = ProcessRunner.run(
                    "/bin/bash", [source.appendingPathComponent("make.sh").path, "build"],
                    timeout: 900, mergeStderr: true
                ) else {
                    throw UpdateError(message: "Couldn't start the build.")
                }
                if build.timedOut { throw UpdateError(message: "The build took too long and was stopped.") }
                if build.status != 0 { return String(data: build.output, encoding: .utf8) ?? "" }
                return nil
            }.value

            if let log = buildLog {
                let tail = log.split(separator: "\n").suffix(12).joined(separator: "\n")
                throw UpdateError(message: "The new version didn't build.\n\n\(tail)")
            }

            // The zip is rebuilt by CI a few seconds after a push, so for a
            // moment the version file can be ahead of the download. Installing
            // the old build would just offer the same update again.
            let builtVersion = Bundle(url: built)?
                .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            guard Self.compare(builtVersion, currentVersion) > 0 else {
                throw UpdateError(message: "GitHub hasn't finished publishing \(latest) yet. Try again in a few minutes.")
            }

            try await replaceApp(with: built, scratch: work)
        } catch {
            inform("Update failed", error.localizedDescription)
            return
        }

        relaunch()
    }

    /// Swap the running app for the new build. The root helper is only
    /// replaced when the helper code itself changed, and only that (or an
    /// app still owned by root from an older install) needs a password.
    /// Everything else, which is most updates, installs silently.
    private func replaceApp(with built: URL, scratch: URL) async throws {
        let fm = FileManager.default
        let destination = Bundle.main.bundlePath
        let helperInstalled = fm.fileExists(atPath: Self.helperPath)

        let newFingerprint = Bundle(url: built)?
            .object(forInfoDictionaryKey: "BSHelperFingerprint") as? String
        let helperNeedsUpdate: Bool
        if helperInstalled {
            // The helper is world-executable and answers this without root.
            // A helper too old to know the command gets replaced.
            let helper = Self.helperPath
            let installed: String? = await Task.detached(priority: .userInitiated) { () -> String? in
                guard let r = ProcessRunner.run(helper, ["--ctl", "fingerprint"], timeout: 5),
                      !r.timedOut, r.status == 0 else { return nil }
                return String(data: r.output, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }.value
            helperNeedsUpdate = newFingerprint == nil || installed != newFingerprint
        } else {
            helperNeedsUpdate = false
        }

        let needsAdmin = helperNeedsUpdate || !Self.canReplace(destination)

        var lines = [
            "set -e",
            "rm -rf \(Self.shellQuote(destination))",
            "cp -R \(Self.shellQuote(built.path)) \(Self.shellQuote(destination))",
        ]
        if needsAdmin {
            // Hand the app to the user while we have root anyway, so the next
            // update doesn't need a password for it.
            lines.append("chown -R \(Self.shellQuote(NSUserName())) \(Self.shellQuote(destination))")
        }
        if helperNeedsUpdate {
            lines.append("install -m 755 -o root -g wheel "
                         + Self.shellQuote(destination + "/Contents/MacOS/BatteryScope") + " "
                         + Self.shellQuote(Self.helperPath))
        }
        let script = scratch.appendingPathComponent("install.sh")
        try (lines.joined(separator: "\n") + "\n").write(to: script, atomically: true, encoding: .utf8)

        let result: ProcessRunner.Result? = await Task.detached(priority: .userInitiated) { () -> ProcessRunner.Result? in
            if needsAdmin {
                let command = "/bin/sh " + Updater.shellQuote(script.path)
                let apple = "do shell script \"\(Updater.appleScriptEscape(command))\" with administrator privileges"
                return ProcessRunner.run("/usr/bin/osascript", ["-e", apple], timeout: 300, mergeStderr: true)
            }
            return ProcessRunner.run("/bin/sh", [script.path], timeout: 120, mergeStderr: true)
        }.value

        guard let result, !result.timedOut, result.status == 0 else {
            let output = result.flatMap { String(data: $0.output, encoding: .utf8) } ?? ""
            if output.contains("-128") || output.localizedCaseInsensitiveContains("cancel") {
                throw UpdateError(message: "Cancelled. The installed app hasn't changed.")
            }
            throw UpdateError(message: "The new app couldn't be copied into place.\n\n\(output)")
        }
    }

    /// Whether this user can delete the bundle and put a new one in its place
    /// without root: the folder it sits in, and every folder inside it, have
    /// to be writable.
    nonisolated static func canReplace(_ bundlePath: String) -> Bool {
        let fm = FileManager.default
        let parent = (bundlePath as NSString).deletingLastPathComponent
        guard fm.isWritableFile(atPath: parent), fm.isWritableFile(atPath: bundlePath) else { return false }
        guard let walker = fm.enumerator(atPath: bundlePath) else { return false }
        for case let relative as String in walker {
            let path = (bundlePath as NSString).appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
               !fm.isWritableFile(atPath: path) {
                return false
            }
        }
        return true
    }

    /// Start the new copy once this one has gone, then go.
    private func relaunch() {
        let destination = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 2; /usr/bin/open \(Self.shellQuote(destination))"]
        try? process.run()
        NSApp.terminate(nil)
    }

    // MARK: Helpers

    private func inform(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    nonisolated static func isVersion(_ s: String) -> Bool {
        !s.isEmpty && s.count < 32 && s.allSatisfy { $0.isNumber || $0 == "." }
    }

    /// Numeric, component by component: 1.10 is newer than 1.9.
    nonisolated static func compare(_ a: String, _ b: String) -> Int {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }

    nonisolated static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
