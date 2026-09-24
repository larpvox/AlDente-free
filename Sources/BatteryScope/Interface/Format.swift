//
//  Format.swift
//  BatteryScope
//
//  Value formatting for display.
//

import Foundation

// MARK: - Formatting

enum Format {
    static func watts(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.2f W", v)
    }
    static func signedWatts(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%+.2f W", v)
    }
    static func volts(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.3f V", v)
    }
    static func amps(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%+.3f A", v)
    }
    static func celsius(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.1f °C  (%.0f °F)", v, v * 9 / 5 + 32)
    }
    static func percent(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.1f%%", v)
    }
    static func mAh(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.0f mAh", v)
    }
    static func yesNo(_ v: Bool?) -> String {
        guard let v else { return "—" }
        return v ? "Yes" : "No"
    }
    static func duration(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .medium
        return f
    }()

    static func clock(_ date: Date) -> String {
        clockFormatter.string(from: date)
    }
    static func processName(_ raw: String) -> String {
        raw.split(separator: "/").last.map(String.init) ?? raw
    }
}
