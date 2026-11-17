import SwiftUI

struct MetricHeroPanel: View {
    let eyebrow: String
    let headline: String
    let value: String?
    let unit: String
    let caption: String
    let accent: Color
    let stats: [MetricHeroStat]
    var ring: MetricHeroRing? = nil
    var accessibilityLabel: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(eyebrow)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(HealthTheme.secondaryInk)
                        .lineLimit(1)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(value ?? "--")
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(HealthTheme.ink)
                        if !unit.isEmpty {
                            Text(unit)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(HealthTheme.secondaryInk)
                        }
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.58)
                    Text(headline)
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(accent.opacity(0.14), in: Capsule())
                        .lineLimit(1)
                    if !caption.isEmpty, caption != "--" {
                        Text(caption)
                            .font(.footnote)
                            .foregroundStyle(HealthTheme.secondaryInk)
                            .lineLimit(1)
                            .minimumScaleFactor(0.76)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityLabel ?? "\(headline), \(value ?? "no value") \(unit)")

                Spacer(minLength: 8)

                if let ring {
                    ring.frame(width: 104, height: 104)
                }
            }

            if !stats.isEmpty {
                Rectangle()
                    .fill(HealthTheme.hairline)
                    .frame(height: 1)
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Array(stats.enumerated()), id: \.offset) { _, stat in
                        stat
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface(cornerRadius: 24)
    }
}

struct MetricHeroRing: View {
    let value: String?
    let unit: String
    let caption: String
    let progress: Double
    let tint: Color
    var accessibilityLabel: String?

    var body: some View {
        CircularProgressMetric(
            progress: progress,
            tint: tint,
            lineWidth: 10,
            accessibilityLabel: accessibilityLabel ?? "\(value ?? "no value") \(unit)"
        ) {
            VStack(spacing: 1) {
                Text(value ?? "--")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Text(caption)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
            }
        }
    }
}

struct MetricHeroStat: View {
    let title: String
    let value: String
    let tint: Color

    private var parts: (number: String, unit: String) {
        let tokens = value.split(separator: " ")
        let trailing = tokens.reversed().prefix { token in !token.contains(where: \.isNumber) }.count
        guard trailing > 0, trailing < tokens.count else { return (value, "") }
        return (
            tokens.dropLast(trailing).joined(separator: " "),
            tokens.suffix(trailing).joined(separator: " ")
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(parts.number)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(HealthTheme.ink)
                    .monospacedDigit()
                    .layoutPriority(1)
                if !parts.unit.isEmpty {
                    Text(parts.unit)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(HealthTheme.secondaryInk)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(HealthTheme.secondaryInk)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

func metricHeroTrendText(_ trend: String?) -> String {
    switch trend {
    case "up": return "Up"
    case "down": return "Down"
    case "flat": return "Steady"
    default: return "--"
    }
}

func metricHeroSignedChangeText(_ change: Double?, unit: String) -> String {
    guard let change else { return "--" }
    let prefix = change > 0 ? "+" : ""
    return "\(prefix)\(change.clean) \(unit)"
}

func metricHeroWholeRangeText(lower: Double?, upper: Double?, unit: String) -> String? {
    guard let lower, let upper else { return nil }
    return "\(Int(lower.rounded()))-\(Int(upper.rounded())) \(unit)"
}
