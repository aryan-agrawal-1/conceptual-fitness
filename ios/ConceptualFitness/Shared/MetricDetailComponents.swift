import SwiftUI

struct DetailErrorPanel: View {
    let title: String
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Retry", action: retry)
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 18)
    }
}

struct DetailSection<Content: View>: View {
    let title: String
    let systemImage: String?
    var spacing: CGFloat = 14
    var cornerRadius: CGFloat = 20
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            if let systemImage {
                Label(title, systemImage: systemImage)
                    .font(.headline)
            } else {
                Text(title)
                    .font(.headline)
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: cornerRadius)
    }
}

struct MetricSummaryRow: View {
    let title: String
    let value: String?
    var tint: Color = .primary
    var placeholder: String = "--"
    var monospaced: Bool = false
    var multilineValue: Bool = false

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .layoutPriority(1)
            Spacer()
            Text(value ?? placeholder)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint)
                .multilineTextAlignment(.trailing)
                .lineLimit(multilineValue ? 2 : 1)
                .minimumScaleFactor(0.72)
                .modifier(MonospacedDigitsModifier(enabled: monospaced))
        }
    }
}

struct MetricTrendRow: View {
    let trend: String?
    var upColor: Color = HealthTheme.color(for: .positive)
    var downColor: Color = HealthTheme.color(for: .caution)
    var flatColor: Color = .secondary
    var unknownColor: Color = .secondary
    var flatTitle: String = "Steady"
    var unknownTitle: String = "No prior data"

    var body: some View {
        HStack {
            Text("Trend")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .layoutPriority(1)
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption.weight(.bold))
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .foregroundStyle(color)
        }
    }

    private var title: String {
        switch trend {
        case "up": return "Up"
        case "down": return "Down"
        case "flat": return flatTitle
        default: return unknownTitle
        }
    }

    private var icon: String {
        switch trend {
        case "up": return "chart.line.uptrend.xyaxis"
        case "down": return "chart.line.downtrend.xyaxis"
        case "flat": return "minus"
        default: return "questionmark"
        }
    }

    private var color: Color {
        switch trend {
        case "up": return upColor
        case "down": return downColor
        case "flat": return flatColor
        default: return unknownColor
        }
    }
}

struct StatusPill: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }
}

struct HeroMetricValue: View {
    let value: String?
    let unit: String?
    let caption: String
    let accessibilityLabel: String
    var valueSize: CGFloat = 48
    var placeholder: String = "--"

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value ?? placeholder)
                    .font(.system(size: valueSize, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                if let unit {
                    Text(unit)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
            Text(caption)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel(accessibilityLabel)
    }
}

struct SelectedChartReadout: View {
    let title: String
    let subtitle: String
    let value: String
    var valueTint: Color = .primary
    var monospaced: Bool = true

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                Text(subtitle)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(valueTint)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .modifier(MonospacedDigitsModifier(enabled: monospaced))
        }
        .padding(.top, 2)
    }
}

private struct MonospacedDigitsModifier: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.monospacedDigit()
        } else {
            content
        }
    }
}
