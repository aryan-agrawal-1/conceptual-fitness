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
            if data.dateContext == .yesterday {
                Text("Yesterday's scores")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.primary.opacity(0.68))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.38), in: Capsule())
            }

            HStack(alignment: .top, spacing: 12) {
                ScoreRingView(item: .strain(from: data.snapshot))
                ScoreRingView(item: .readiness(from: data.snapshot))
                ScoreRingView(item: .sleep(from: data.snapshot))
            }

            if let insight = data.insight?.nonEmptyDashboardText {
                Text(insight)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary.opacity(0.78))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
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
    let detailText: String
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
            detailText: current.flatMap { current in target.map { "\(current.clean)/\($0.clean)" } } ?? "Target pending",
            progress: min(max(ratio ?? 0, 0), 1.35),
            color: .orange,
            routeMetric: "strain"
        )
    }

    static func readiness(from snapshot: DashboardSnapshot) -> ScoreRingItem {
        let value = snapshot.scores.readiness?.value
        return ScoreRingItem(
            title: "Readiness",
            valueText: value.map { "\(Int($0.rounded()))" } ?? "--",
            detailText: snapshot.scores.readiness?.status?.displayTitle ?? "Sync pending",
            progress: (value ?? 0) / 100,
            color: .green,
            routeMetric: "readiness"
        )
    }

    static func sleep(from snapshot: DashboardSnapshot) -> ScoreRingItem {
        let value = snapshot.scores.sleep?.value
        return ScoreRingItem(
            title: "Sleep",
            valueText: value.map { "\(Int($0.rounded()))" } ?? "--",
            detailText: snapshot.scores.sleep?.status?.displayTitle ?? "No data yet",
            progress: (value ?? 0) / 100,
            color: .indigo,
            routeMetric: "sleep"
        )
    }
}

struct ScoreRingView: View {
    let item: ScoreRingItem

    var body: some View {
        NavigationLink(value: AppRoute.metric(item.routeMetric)) {
            VStack(spacing: 9) {
                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.34), lineWidth: 9)
                    Circle()
                        .trim(from: 0, to: min(item.progress, 1))
                        .stroke(item.color.gradient, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    if item.progress > 1 {
                        Circle()
                            .trim(from: 0, to: min(item.progress - 1, 0.35))
                            .stroke(.red.opacity(0.8), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }

                    VStack(spacing: 0) {
                        Text(item.valueText)
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .minimumScaleFactor(0.65)
                        Text(item.title)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 88, height: 88)

                Text(item.detailText)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: 96)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.title), \(item.valueText), \(item.detailText)")
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
        HStack(spacing: 14) {
            Image(systemName: workout.iconName)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(workout.tint.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text(workout.workoutType?.displayTitle ?? "Workout")
                    .font(.headline)
                Text(workout.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 5) {
                Text(workout.durationText)
                    .font(.subheadline.bold())
                Text(workout.activeCalories.map { "\(Int($0.rounded())) kcal" } ?? "--")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .glassSurface(cornerRadius: 20, interactive: true)
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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: item.systemImage)
                    .font(.headline)
                    .foregroundStyle(item.tint)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary.opacity(0.55))
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.valueText)
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(item.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .padding(14)
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .glassSurface(cornerRadius: 20, interactive: true)
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

    static func items(from data: DashboardData) -> [MetricCardItem] {
        let metrics = data.snapshot.metrics
        var items: [MetricCardItem] = [
            item("heart_rate_variability", "HRV", value(for: "heart_rate_variability", in: data, fallback: metrics?.heartRateVariability), "ms", "waveform.path.ecg", .purple, quality(for: "heart_rate_variability", in: data, fallback: metrics?.dataQuality)),
            item("resting_heart_rate", "Resting HR", value(for: "resting_heart_rate", in: data, fallback: metrics?.restingHeartRate), "bpm", "heart.fill", .red, quality(for: "resting_heart_rate", in: data, fallback: metrics?.dataQuality)),
            item("oxygen_saturation", "SpO2", value(for: "oxygen_saturation", in: data, fallback: metrics?.oxygenSaturation), "%", "lungs.fill", .cyan, quality(for: "oxygen_saturation", in: data, fallback: metrics?.dataQuality)),
            item("respiratory_rate", "Respiratory", value(for: "respiratory_rate", in: data, fallback: metrics?.respiratoryRate), "br/min", "wind", .teal, quality(for: "respiratory_rate", in: data, fallback: metrics?.dataQuality))
        ]

        let vo2 = data.vo2Max?.current?.value ?? value(for: "vo2_max", in: data, fallback: nil)
        if let vo2 {
            items.append(item("vo2_max", "VO2 Max", vo2, "ml/kg/min", "figure.run", .green, data.vo2Max?.dataQuality ?? quality(for: "vo2_max", in: data, fallback: nil)))
        }

        items += [
            item("sleep", "Sleep", value(for: "sleep", in: data, fallback: metrics?.sleepMinutes.map(Double.init)), "min", "bed.double.fill", .indigo, quality(for: "sleep", in: data, fallback: metrics?.dataQuality)),
            item("steps", "Steps", value(for: "steps", in: data, fallback: metrics?.steps.map(Double.init)), "", "shoeprints.fill", .blue, quality(for: "steps", in: data, fallback: metrics?.dataQuality)),
            item("active_calories", "Active Calories", value(for: "active_calories", in: data, fallback: metrics?.activeCalories), "kcal", "flame.fill", .orange, quality(for: "active_calories", in: data, fallback: metrics?.dataQuality)),
            item("distance", "Distance", distanceKilometers(from: data, fallbackMeters: metrics?.distanceMeters), "km", "point.topleft.down.curvedto.point.bottomright.up", .mint, quality(for: "distance", in: data, fallback: metrics?.dataQuality))
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
        _ title: String,
        _ value: Double?,
        _ unit: String,
        _ icon: String,
        _ tint: Color,
        _ quality: String?
    ) -> MetricCardItem {
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
            title: title,
            valueText: valueText,
            status: value == nil ? "No data yet" : (quality?.displayTitle ?? "Synced"),
            systemImage: icon,
            tint: tint
        )
    }
}

private extension WorkoutSummary {
    var iconName: String {
        let type = workoutType?.lowercased() ?? ""
        if type.contains("run") { return "figure.run" }
        if type.contains("cycl") || type.contains("bike") { return "bicycle" }
        if type.contains("walk") { return "figure.walk" }
        if type.contains("swim") { return "figure.pool.swim" }
        return "figure.mixed.cardio"
    }

    var tint: Color {
        switch intensity?.lowercased() {
        case "high": return .orange
        case "moderate": return .blue
        case "low": return .green
        default: return .indigo
        }
    }

    var subtitle: String {
        let start = DashboardFormatters.parseBackendDateTime(startTime).map(DashboardFormatters.workoutTime.string) ?? date ?? "Recent"
        let distance = distanceMeters.map { String(format: "%.1f km", $0 / 1000) }
        let maxHR = heartRate?.maxBPM.map { "Max \(Int($0.rounded())) bpm" }
        return [start, distance, maxHR].compactMap(\.self).joined(separator: "  ")
    }

    var durationText: String {
        guard let durationSeconds else { return "--" }
        let minutes = max(1, Int((Double(durationSeconds) / 60).rounded()))
        if minutes >= 60 {
            return "\(minutes / 60)h \(minutes % 60)m"
        }
        return "\(minutes)m"
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
