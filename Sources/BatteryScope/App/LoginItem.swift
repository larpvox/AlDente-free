//
//  LoginItem.swift
//  BatteryScope
//
//  Launch at login, via the same LaunchAgent that `make.sh install` writes.
//

import Foundation

/// Launch at login is a per-user LaunchAgent plist. `make.sh install` and
/// `make.sh uninstall` manage the same file, so the menu toggle and the
/// installer can never disagree or launch the app twice.
enum LoginItem {

    static var label: String { Bundle.main.bundleIdentifier ?? "com.local.batteryscope" }

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// Writes or removes the agent. Nothing is loaded or unloaded now:
    /// launchd reads the folder at the next login. Loading it here would
    /// start a second copy (RunAtLoad), and unloading it would kill this one
    /// if login is how it was started.
    @discardableResult
    static func setEnabled(_ on: Bool) -> Bool {
        let fm = FileManager.default
        if !on {
            do {
                if isEnabled { try fm.removeItem(at: plistURL) }
                return true
            } catch {
                return false
            }
        }

        // Point at the copy that's actually running, so a build in
        // /Applications starts itself and nothing else.
        guard let executable = Bundle.main.executablePath else { return false }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": false,
        ]
        do {
            try fm.createDirectory(at: plistURL.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                          format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
