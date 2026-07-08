import SwiftUI

struct WeatherStatusChip: View {
    let title: String
    let systemImage: String
    @Binding var isPresented: Bool

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.primary.opacity(0.76))
                .frame(width: 38, height: 38)
                .glassSurface(cornerRadius: 19, interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show current location")
        .alert("Your location", isPresented: $isPresented) {
            Button("Done", role: .cancel) {}
        } message: {
            Text(title)
        }
    }
}

struct DailyBriefCard: View {
    let data: DashboardData

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center) {
                Text(data.dateContext == .yesterday ? "Yesterday's scores" : "Daily Status")
                    .font(.headline)
                    .foregroundStyle(.primary.opacity(0.86))

                Spacer()

                Text(statusPillTitle)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(statusPillColor)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(statusPillColor.opacity(0.12), in: Capsule())
            }

            HStack(alignment: .top, spacing: 12) {
                ScoreRingView(item: .readiness(from: data.snapshot), size: 86)
                ScoreRingView(item: .sleep(from: data.snapshot), size: 86)
                ScoreRingView(item: .strain(from: data.snapshot), size: 86)
            }

            #if DEBUG
            if let aiDebugStatus = data.aiDebugStatus?.nonEmptyDashboardText {
                Text(aiDebugStatus)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.red.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)
            }
            #endif
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 26)
    }

    private var statusPillTitle: String {
        let readiness = data.snapshot.scores.readiness?.value
        let sleep = data.snapshot.scores.sleep?.value

        if readiness == nil && sleep == nil { return "Syncing" }
        if (readiness ?? 0) >= 85 && (sleep ?? 0) >= 85 { return "Excellent" }
        if (readiness ?? 0) >= 70 && (sleep ?? 0) >= 70 { return "Good" }
        if (readiness ?? 100) < 55 || (sleep ?? 100) < 55 { return "Low" }
        return "Steady"
    }

    private var statusPillColor: Color {
        switch statusPillTitle {
        case "Excellent", "Good":
            return HealthTheme.color(for: .positive)
        case "Low":
            return HealthTheme.color(for: .caution)
        case "Syncing":
            return HealthTheme.color(for: .missing)
        default:
            return HealthTheme.color(for: .stable)
        }
    }
}

struct DailyBriefSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(.white.opacity(0.34))
                        .frame(width: 86, height: 86)
                }
            }

            RoundedRectangle(cornerRadius: 8)
                .fill(.white.opacity(0.34))
                .frame(height: 42)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 26)
        .redacted(reason: .placeholder)
    }
}

struct ScoreRingItem {
    let title: String
    let valueText: String
    let progress: Double
    let color: Color
    let routeMetric: String

    static func strain(from snapshot: DashboardSnapshot) -> ScoreRingItem {
        let current = snapshot.strainTarget?.progressLoadPoints ?? snapshot.scores.strain?.value
        let target = snapshot.strainTarget?.targetLoadPoints
        let ratio = target.flatMap { target in
            target > 0 ? (current ?? 0) / target : nil
        } ?? snapshot.strainTarget?.progressRatio
        let percentage = (ratio ?? 0) * 100
        return ScoreRingItem(
            title: "Strain",
            valueText: percentage.isFinite ? "\(Int(percentage.rounded()))%" : "--",
            progress: min(max(ratio ?? 0, 0), 1.35),
            color: HealthTheme.color(for: .strain),
            routeMetric: "strain"
        )
    }

    static func readiness(from snapshot: DashboardSnapshot) -> ScoreRingItem {
        let value = snapshot.scores.readiness?.value
        return ScoreRingItem(
            title: "Readiness",
            valueText: value.map { "\(Int($0.rounded()))" } ?? "--",
            progress: (value ?? 0) / 100,
            color: HealthTheme.color(for: .readiness),
            routeMetric: "readiness"
        )
    }

    static func sleep(from snapshot: DashboardSnapshot) -> ScoreRingItem {
        let value = snapshot.scores.sleep?.value
        return ScoreRingItem(
            title: "Sleep",
            valueText: value.map { "\(Int($0.rounded()))" } ?? "--",
            progress: (value ?? 0) / 100,
            color: HealthTheme.color(for: .sleep),
            routeMetric: "sleep"
        )
    }
}

struct ScoreRingView: View {
    let item: ScoreRingItem
    var size: CGFloat = 88

    var body: some View {
        NavigationLink(value: AppRoute.metric(item.routeMetric)) {
            VStack(spacing: 9) {
                CircularProgressMetric(
                    progress: item.progress,
                    tint: item.color,
                    trackColor: .white.opacity(0.34),
                    overflowTint: HealthTheme.color(for: .risk),
                    lineWidth: 9,
                    overflowLineWidth: 5,
                    accessibilityLabel: "\(item.title), \(item.valueText)"
                ) {
                    VStack(spacing: 0) {
                        Text(item.valueText)
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .minimumScaleFactor(0.65)
                        Text(item.title)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: size, height: size)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct RecentWorkoutsSection: View {
    let workouts: [WorkoutSummary]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your recent workouts")
                .font(.title3.bold())

            if workouts.isEmpty {
                EmptyDashboardCard(title: "No recent workouts", message: "Workouts from the last 30 days will appear here after sync.")
            } else {
                ForEach(workouts.prefix(3)) { workout in
                    NavigationLink(value: AppRoute.workout(workout.id)) {
                        WorkoutCard(workout: workout)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WorkoutCard: View {
    let workout: WorkoutSummary

    var body: some View {
        WorkoutSummaryRow(workout: workout, presentation: .card)
        .padding(14)
        .frame(maxWidth: .infinity)
        .glassSurface(cornerRadius: 20, interactive: true)
    }
}

enum WorkoutSummaryRowPresentation {
    case card
    case compact
}

struct WorkoutSummaryRow: View {
    let workout: WorkoutSummary
    var presentation: WorkoutSummaryRowPresentation = .compact

    private var workoutPresentation: WorkoutPresentation {
        workout.presentation
    }

    var body: some View {
        HStack(spacing: presentation == .card ? 14 : 12) {
            iconView

            VStack(alignment: .leading, spacing: presentation == .card ? 5 : 4) {
                Text(workoutPresentation.displayName)
                    .font(titleFont)
                    .lineLimit(1)
                Text(workout.summarySubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            Spacer(minLength: 10)

            metricView
        }
        .contentShape(Rectangle())
    }

    private var iconSize: CGFloat {
        presentation == .card ? 48 : 30
    }

    private var iconFont: Font {
        presentation == .card ? .system(size: 24, weight: .semibold) : .headline
    }

    @ViewBuilder
    private var iconView: some View {
        if presentation == .card {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: workoutPresentation.symbolName)
                    .font(iconFont)
                    .foregroundStyle(workoutPresentation.activityAccent)
                    .frame(width: iconSize, height: iconSize)
                    .background(workoutPresentation.activityAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                Circle()
                    .fill(workoutPresentation.strainAccent)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(.white.opacity(0.72), lineWidth: 1))
                    .offset(x: -5, y: -5)
            }
        } else {
            Image(systemName: workoutPresentation.symbolName)
                .font(iconFont)
                .foregroundStyle(workoutPresentation.activityAccent)
                .frame(width: iconSize, height: iconSize)
                .background(workoutPresentation.activityAccent.opacity(0.13), in: Circle())
        }
    }

    private var titleFont: Font {
        presentation == .card ? .headline : .subheadline.weight(.bold)
    }

    @ViewBuilder
    private var metricView: some View {
        if let strainLoadPoints = workout.strainLoadPoints {
            VStack(alignment: .trailing, spacing: 0) {
                Text(strainLoadPoints.clean)
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text("strain")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("\(strainLoadPoints.clean) strain")
        } else {
            VStack(alignment: .trailing, spacing: 0) {
                Text(workout.summaryDurationText)
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text("duration")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct HealthMetricsSection: View {
    let items: [MetricCardItem]

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Health Metrics")
                .font(.title3.bold())

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(items) { item in
                    NavigationLink(value: AppRoute.metric(item.metricKey)) {
                        MetricCard(item: item)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MetricCard: View {
    let item: MetricCardItem

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: item.systemImage)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(item.tint)

                Text(item.title)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.74)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary.opacity(0.55))
            }

            Text(item.valueText)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.64)

            MiniMetricChart(points: item.previewPoints, kind: item.chartKind, tint: item.tint)
                .padding(.vertical, 2)

            Spacer(minLength: 0)

            Text(item.status)
                .font(.caption.weight(.semibold))
                .foregroundStyle(item.statusColor)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(14)
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .glassSurface(cornerRadius: 20, interactive: true)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.title), \(item.valueText), \(item.status)")
    }
}

struct EmptyDashboardCard: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 20)
    }
}

struct MetricCardItem: Identifiable {
    let id = UUID()
    let metricKey: String
    let title: String
    let valueText: String
    let status: String
    let systemImage: String
    let tint: Color
    let statusColor: Color
    let chartKind: MiniMetricChartKind
    let previewPoints: [MiniMetricChartPoint]

    static func items(from data: DashboardData) -> [MetricCardItem] {
        let metrics = data.snapshot.metrics
        var items: [MetricCardItem] = [
            item("heart_rate_variability", value(for: "heart_rate_variability", in: data, fallback: metrics?.heartRateVariability), quality(for: "heart_rate_variability", in: data, fallback: metrics?.dataQuality), data: data),
            item("resting_heart_rate", value(for: "resting_heart_rate", in: data, fallback: metrics?.restingHeartRate), quality(for: "resting_heart_rate", in: data, fallback: metrics?.dataQuality), data: data),
            item("heart_rate", value(for: "heart_rate", in: data, fallback: nil), quality(for: "heart_rate", in: data, fallback: metrics?.dataQuality), data: data),
            item("skin_temperature_variation", value(for: "skin_temperature_variation", in: data, fallback: nil), quality(for: "skin_temperature_variation", in: data, fallback: metrics?.dataQuality), data: data),
            item("oxygen_saturation", value(for: "oxygen_saturation", in: data, fallback: metrics?.oxygenSaturation), quality(for: "oxygen_saturation", in: data, fallback: metrics?.dataQuality), data: data),
            item("respiratory_rate", value(for: "respiratory_rate", in: data, fallback: metrics?.respiratoryRate), quality(for: "respiratory_rate", in: data, fallback: metrics?.dataQuality), data: data),
            item("vo2_max", data.vo2Max?.current?.value ?? value(for: "vo2_max", in: data, fallback: nil), data.vo2Max?.dataQuality ?? quality(for: "vo2_max", in: data, fallback: nil), data: data)
        ]

        items += [
            item("sleep", value(for: "sleep", in: data, fallback: metrics?.sleepMinutes.map(Double.init)), quality(for: "sleep", in: data, fallback: metrics?.dataQuality), data: data),
            item("steps", value(for: "steps", in: data, fallback: metrics?.steps.map(Double.init)), quality(for: "steps", in: data, fallback: metrics?.dataQuality), data: data),
            item("total_calories", value(for: "total_calories", in: data, fallback: metrics?.totalCalories), quality(for: "total_calories", in: data, fallback: metrics?.dataQuality), data: data),
            item("distance", distanceKilometers(from: data, fallbackMeters: metrics?.distanceMeters), quality(for: "distance", in: data, fallback: metrics?.dataQuality), data: data)
        ]

        return items
    }

    private static func value(for key: String, in data: DashboardData, fallback: Double?) -> Double? {
        data.metricSummaries[key]?.current?.value ?? fallback
    }

    private static func quality(for key: String, in data: DashboardData, fallback: String?) -> String? {
        data.metricSummaries[key]?.dataQuality ?? fallback
    }

    private static func distanceKilometers(from data: DashboardData, fallbackMeters: Double?) -> Double? {
        let meters = value(for: "distance", in: data, fallback: fallbackMeters)
        return meters.map { $0 / 1000 }
    }

    private static func item(
        _ key: String,
        _ value: Double?,
        _ quality: String?,
        data: DashboardData
    ) -> MetricCardItem {
        let presentation = HealthMetricPresentation.presentation(for: key)
        let unit = presentation.unit
        let valueText: String
        if let value {
            if key == "steps" {
                valueText = "\(Int(value.rounded()))"
            } else if key == "distance" {
                valueText = String(format: "%.1f %@", value, unit)
            } else if unit.isEmpty {
                valueText = value.clean
            } else {
                valueText = "\(value.clean) \(unit)"
            }
        } else {
            valueText = "--"
        }

        return MetricCardItem(
            metricKey: key,
            title: presentation.title,
            valueText: valueText,
            status: statusText(key: key, value: value, quality: quality, summary: data.metricSummaries[key], presentation: presentation),
            systemImage: presentation.systemImage,
            tint: presentation.tint,
            statusColor: statusColor(value: value, summary: data.metricSummaries[key], presentation: presentation),
            chartKind: presentation.chartKind,
            previewPoints: data.metricSummaries[key]?.previewPoints ?? []
        )
    }

    private static func statusText(
        key: String,
        value: Double?,
        quality: String?,
        summary: MetricDashboardSummary?,
        presentation: HealthMetricPresentation
    ) -> String {
        guard value != nil else { return "No data yet" }
        if let comparison = summary?.baseline?.comparison {
            switch comparison {
            case "normal":
                return "Within baseline"
            case "below":
                return presentation.higherIsBetter == false ? "Below baseline" : "Lower than baseline"
            case "above":
                return presentation.higherIsBetter == false ? "Elevated vs baseline" : "Above baseline"
            default:
                break
            }
        }
        if let direction = summary?.trend?.direction, direction != "unknown" {
            return direction == "flat" ? "Stable trend" : "\(direction.displayTitle) trend"
        }
        return quality?.displayTitle ?? "Synced"
    }

    private static func statusColor(
        value: Double?,
        summary: MetricDashboardSummary?,
        presentation: HealthMetricPresentation
    ) -> Color {
        guard value != nil else { return HealthTheme.color(for: .missing) }
        if let comparison = summary?.baseline?.comparison {
            switch comparison {
            case "normal":
                return HealthTheme.color(for: .stable)
            case "below":
                return presentation.higherIsBetter == false ? HealthTheme.color(for: .positive) : HealthTheme.color(for: .caution)
            case "above":
                return presentation.higherIsBetter == false ? HealthTheme.color(for: .caution) : HealthTheme.color(for: .positive)
            default:
                break
            }
        }
        return HealthTheme.color(for: .stable)
    }
}

extension WorkoutSummary {
    var presentation: WorkoutPresentation {
        WorkoutPresentationFactory.make(type: workoutType, intensity: intensity, strainLoadPoints: strainLoadPoints)
    }

    var summaryIconName: String {
        presentation.symbolName
    }

    var summaryTint: Color {
        presentation.activityAccent
    }

    var summarySubtitle: String {
        let start = DashboardFormatters.parseBackendDateTime(startTime).map(DashboardFormatters.workoutTime.string) ?? date ?? "Recent"
        let distance = distanceMeters.map { String(format: "%.1f km", $0 / 1000) }
        return [start, distance, summaryDurationText].compactMap(\.self).joined(separator: "  ")
    }

    var summaryDurationText: String {
        guard let durationSeconds else { return "--" }
        let minutes = max(1, Int((Double(durationSeconds) / 60).rounded()))
        if minutes >= 60 {
            return "\(minutes / 60)h \(minutes % 60)m"
        }
        return "\(minutes)m"
    }

    var summaryDisplayName: String {
        presentation.displayName
    }
}

extension Double {
    var clean: String {
        if abs(self.rounded() - self) < 0.05 {
            return "\(Int(self.rounded()))"
        }
        return String(format: "%.1f", self)
    }
}

#Preview("Daily brief") {
    DailyBriefCard(data: .sample)
        .padding()
        .background(WeatherBackgroundView(weather: .fallback))
}

#Preview("Daily brief - no AI") {
    DailyBriefCard(data: .previewWithoutInsights())
        .padding()
        .background(WeatherBackgroundView(weather: .fallback))
}

#Preview("Metric grid") {
    ScrollView {
        HealthMetricsSection(items: MetricCardItem.items(from: .sample))
            .padding()
    }
    .background(AppBackground())
}

extension String {
    var nonEmptyDashboardText: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
