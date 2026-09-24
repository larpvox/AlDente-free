//
//  BatteryScopeMain.swift
//  BatteryScope
//
//  Entry point: picks app or CLI from argv.
//

import AppKit
import Foundation

@main
enum BatteryScopeMain {

    /// Explicitly main-actor isolated. Top-level code only gets that for free in
    /// a file called main.swift, and this file isn't one.
    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())

        if arguments.first == "--ctl" {
            CLI.run(Array(arguments.dropFirst()))
        }
        if arguments.first == "--help" || arguments.first == "-h" {
            CLI.usage()
        }

        let application = NSApplication.shared
        let appDelegate = AppDelegate()
        application.delegate = appDelegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
