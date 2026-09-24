//
//  ProcessRunner.swift
//  BatteryScope
//
//  Runs a child process with a deadline.
//

import Foundation

enum ProcessRunner {

    struct Result {
        var status: Int32
        var output: Data
        var timedOut: Bool
    }

    /// Run a tool and collect its output, killing it if it outlives `timeout`.
    ///
    /// Several of these calls happen on the main thread (the sudo helper) or
    /// hold a worker thread for their whole life (top, powermetrics). With no
    /// deadline, one wedged child froze the refresh loop for good: the menu
    /// bar stopped updating and Refresh did nothing, because Refresh runs on
    /// the same thread that was stuck waiting.
    static func run(_ path: String,
                    _ arguments: [String],
                    timeout: TimeInterval,
                    mergeStderr: Bool = false) -> Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = mergeStderr ? pipe : FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let lock = NSLock()
        var timedOut = false
        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            lock.lock(); timedOut = true; lock.unlock()
            process.terminate()
            // SIGTERM can be ignored; SIGKILL can't.
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

        // Read before waiting: a child that fills the pipe buffer blocks until
        // someone drains it, and would never exit.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        lock.lock(); let late = timedOut; lock.unlock()
        return Result(status: process.terminationStatus, output: data, timedOut: late)
    }
}
