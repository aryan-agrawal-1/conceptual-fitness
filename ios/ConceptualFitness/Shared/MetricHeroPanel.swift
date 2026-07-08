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
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(eyebrow)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(accent)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        Text(headline)
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.62)

                        Circle()
                            .fill(accent)
                            .frame(width: 8, height: 8)
                    }
                }

                Spacer(minLength: 8)

                if let ring {
                    ring
                        .frame(width: 88, height: 88)
                        .accessibilityLabel(accessibilityLabel ?? "\(headline), \(value ?? "no value") \(unit)")
                } else {
                    heroValue
                }
            }

            HStack(spacing: 0) {
                ForEach(Array(stats.enumerated()), id: \.offset) { index, stat in
                    if index > 0 {
                        Divider().opacity(0.28)
                    }
                    stat
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(.white.opacity(0.34), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    accent.opacity(0.22),
                    accent.opacity(0.08),
                    .white.opacity(0.36)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.48), lineWidth: 1)
        )
    }

    private var heroValue: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value ?? "--")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.58)
            if !unit.isEmpty {
                Text(unit)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            Text(caption)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.76)
        }
        .accessibilityLabel(accessibilityLabel ?? "\(headline), \(value ?? "no value") \(unit)")
    }
}

struct MetricHeroRing: View {
    let value: String?
    let unit: String
    let caption: String
    let progress: Double
    let tint: Color
    var overflowTint: Color? = HealthTheme.color(for: .risk)
    var accessibilityLabel: String?

    var body: some View {
        CircularProgressMetric(
            progress: progress,
            tint: tint,
            trackColor: .white.opacity(0.58),
            overflowTint: overflowTint,
            lineWidth: 10,
            overflowLineWidth: 5,
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

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(value)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.58)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
