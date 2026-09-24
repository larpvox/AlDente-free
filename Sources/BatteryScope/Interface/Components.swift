//
//  Components.swift
//  BatteryScope
//
//  Shared view pieces: Card, Row, Sparkline.
//

import Foundation
import SwiftUI

// MARK: - Pieces

struct Card<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .kerning(0.6)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct Row: View {
    let label: String
    let value: String
    var emphasis = false
    var hint: String?

    init(_ label: String, _ value: String, emphasis: Bool = false, hint: String? = nil) {
        self.label = label
        self.value = value
        self.emphasis = emphasis
        self.hint = hint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(value)
                    .font(emphasis ? .callout.weight(.semibold).monospacedDigit() : .callout.monospacedDigit())
            }
            if let hint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct Sparkline: View {
    let points: [PowerPoint]

    private var maxValue: Double {
        max(points.map(\.systemWatts).max() ?? 1, 1)
    }

    private var spanLabel: String {
        guard let first = points.first, let last = points.last, points.count > 1 else {
            return "SYSTEM DRAW"
        }
        let seconds = Int(last.time.timeIntervalSince(first.time))
        if seconds < 90 { return "LAST \(seconds)s" }
        return "LAST \(seconds / 60) MIN"
    }

    private func label(_ watts: Double) -> String {
        watts >= 10 ? String(format: "%.0f", watts) : String(format: "%.1f", watts)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(spanLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 6) {
                // Scale markers, so the line means something.
                VStack(alignment: .trailing, spacing: 0) {
                    Text(label(maxValue))
                    Spacer(minLength: 0)
                    Text(label(maxValue / 2))
                    Spacer(minLength: 0)
                    Text("0")
                }
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 26, height: 60)

                GeometryReader { geo in
                    ZStack {
                        ForEach([0.0, 0.5, 1.0], id: \.self) { fraction in
                            Path { path in
                                let y = geo.size.height * (1 - fraction)
                                path.move(to: CGPoint(x: 0, y: y))
                                path.addLine(to: CGPoint(x: geo.size.width, y: y))
                            }
                            .stroke(Color.primary.opacity(0.15),
                                    style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                        }

                        Path { path in
                            let values = points.map(\.systemWatts)
                            guard values.count > 1 else { return }
                            for (i, v) in values.enumerated() {
                                let x = geo.size.width * CGFloat(i) / CGFloat(values.count - 1)
                                let y = geo.size.height * (1 - CGFloat(v / maxValue))
                                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                                else { path.addLine(to: CGPoint(x: x, y: y)) }
                            }
                        }
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                    }
                }
                .frame(height: 60)

                Text("W")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}
