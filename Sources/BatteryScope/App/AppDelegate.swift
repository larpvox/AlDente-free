//
//  AppDelegate.swift
//  BatteryScope
//
//  Menu bar: status item, popover, tooltip.
//

import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let monitor = Monitor()

    /// Held for the life of the app. Without it macOS App Naps a windowless
    /// accessory app, and its refresh timer gets deferred by minutes at a
    /// time: the menu bar freezes on a stale reading until something wakes it.
    private var activity: NSObjectProtocol?

    /// The widest the status item has needed to be for the current set of
    /// fields. Growing is allowed, shrinking only when the fields change, so
    /// the item doesn't twitch every refresh. On a notched MacBook a status
    /// item that keeps changing width is one macOS keeps hiding behind the
    /// notch.
    private var statusWidth: CGFloat = 0
    private var statusFields: Set<Monitor.MenuBarField> = []
    private var statusPlugged: Bool?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Keeps the menu bar readout current"
        )

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // A stable name gives macOS something to remember the position by.
        // And visibility is a remembered preference: if it was ever switched
        // off (a Cmd-drag, or the menu bar settings on newer macOS), the item
        // stays gone on every relaunch. This app has no other window, so it
        // always asks to be shown.
        item.autosaveName = "BatteryScopeStatusItem"
        item.isVisible = true
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        _ = item.button?.cell?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item

        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = false
        pop.contentSize = NSSize(width: 390, height: 600)
        pop.delegate = self
        popover = pop

        // One update per refresh, driven by the monitor, rather than one per
        // published property via objectWillChange.
        monitor.menuBarDidChange = { [weak self] in self?.updateStatusItem() }
        monitor.start()
        updateStatusItem()

        Updater.shared.onBusyChange = { [weak self] in
            self?.lastTitle = ""
            self?.updateStatusItem()
        }
        // Give launch a moment to settle, then look for a newer version.
        // Silent unless there is one.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            Updater.shared.checkOnLaunch()
        }

        // The SMC handle doesn't survive sleep, so rebuild it on wake.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.monitor.handleWake() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.monitor.handleWake() }
        }

    }

    func applicationWillTerminate(_ notification: Notification) {
        // Never leave a machine with charging inhibited because the app went away.
        monitor.resetChargeControl()
        monitor.stop()
    }

    private var lastTitle = ""

    private func updateStatusItem() {
        guard let item = statusItem, let button = item.button else { return }
        // Text only. macOS already shows a battery glyph up there and a second
        // one is just clutter.
        let title = Updater.shared.isBusy ? "Updating\u{2026}" : monitor.menuBarText
        if title != lastTitle {   // no needless redraws
            lastTitle = title
            button.title = title
            button.image = nil

            // Plugging in or out changes which fields apply, so it starts
            // the width over too.
            if monitor.menuBarFields != statusFields || monitor.snapshot.isPluggedIn != statusPlugged {
                statusFields = monitor.menuBarFields
                statusPlugged = monitor.snapshot.isPluggedIn
                statusWidth = 0
            }
            // What variableLength would have used, padding included.
            let needed = ceil(button.intrinsicContentSize.width)
            if needed > statusWidth || statusWidth == 0 {
                statusWidth = needed
                item.length = statusWidth
            }
        }

        // The tooltip changes even when the title doesn't.
        let snap = monitor.snapshot
        var lines: [String] = [snap.stateLabel]
        if let h = snap.trueHealthPercent { lines.append(String(format: "Health %.1f%%", h)) }
        if let c = snap.cycleCount { lines.append("\(c) cycles") }
        button.toolTip = lines.joined(separator: " · ")
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button, let pop = popover else { return }
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            showContextMenu(from: button)
            return
        }
        if pop.isShown {
            pop.performClose(sender)
        } else {
            // The view tree exists only while it's on screen. A hosting
            // controller kept alive behind a closed popover still diffs and
            // lays out on every published change, for nobody.
            pop.contentViewController = NSHostingController(
                rootView: ContentView().environmentObject(monitor)
            )
            monitor.panelVisible = true
            monitor.refresh(force: true)
            pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            pop.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        monitor.panelVisible = false
        popover?.contentViewController = nil
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Refresh now", action: #selector(refreshNow), keyEquivalent: "r")
            .target = self
        menu.addItem(withTitle: "Reset charge control", action: #selector(resetControl), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        let login = menu.addItem(withTitle: "Launch at login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        let updates = menu.addItem(withTitle: Updater.shared.isBusy ? "Updating\u{2026}" : "Check for Updates\u{2026}",
                                   action: Updater.shared.isBusy ? nil : #selector(checkForUpdates),
                                   keyEquivalent: "")
        updates.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit BatteryScope", action: #selector(quit), keyEquivalent: "q")
            .target = self
        // Attach the menu to the status item and click it, so macOS opens it
        // exactly where it opens every other menu bar menu. Popping it up by
        // hand at a computed point made it open scrolled, with the first
        // items hidden behind an arrow. performClick returns once the menu
        // closes, and the menu is detached again so left-click still opens
        // the panel.
        statusItem?.menu = menu
        button.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func refreshNow() { monitor.refresh(force: true) }
    @objc private func resetControl() { monitor.resetChargeControl() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func checkForUpdates() { Updater.shared.checkManually() }

    @objc private func toggleLaunchAtLogin() {
        let wanted = !LoginItem.isEnabled
        guard LoginItem.setEnabled(wanted) else {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at login"
            alert.informativeText = "BatteryScope couldn't write \(LoginItem.plistURL.path)."
            alert.runModal()
            return
        }
    }
}
