import SwiftUI

struct WorkoutDetailView: View {
    let workoutID: String
    let client: DashboardAPIClient

    @State private var loadState: WorkoutDetailLoadState = .loading

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                content
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("Workout")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: workoutID) {
            await load()
        }
        .refreshable {
            await load()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                Text("Could not load workout")
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Retry") {
                    Task { await load() }
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(cornerRadius: 18)
        case .loaded(let detail):
            VStack(alignment: .leading, spacing: 18) {
                WorkoutDetailHeader(detail: detail)
                WorkoutSummaryMetricsPanel(detail: detail)
                WorkoutHeartRatePanel(detail: detail)
                WorkoutZonesPanel(detail: detail)
            }
        }
    }

    @MainActor
    private func load() async {
        loadState = .loading
        do {
            loadState = .loaded(try await client.loadWorkoutDetail(id: workoutID))
        } catch is CancellationError {
            return
        } catch {
            loadState = .failed("The backend was unavailable at \(client.baseURL.absoluteString).")
        }
    }
}

private enum WorkoutDetailLoadState {
    case loading
    case loaded(WorkoutDetail)
    case failed(String)
}

private struct WorkoutDetailHeader: View {
    let detail: WorkoutDetail

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: detail.summaryIconName)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(detail.summaryTint.gradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(detail.summaryDisplayName)
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(detail.workoutDateLine)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(detail.durationRangeLine)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            Spacer(minLength: 8)

            if let intensity = detail.intensity, intensity != "unknown" {
                Text(intensity.displayTitle)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(detail.summaryTint.opacity(0.16), in: Capsule())
                    .foregroundStyle(detail.summaryTint)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 20)
    }
}

private struct WorkoutSummaryMetricsPanel: View {
    let detail: WorkoutDetail

    private var columns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Workout Summary")
                .font(.headline)

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(detail.summaryTiles) { tile in
                    WorkoutMetricTile(tile: tile)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 20)
    }
}

private struct WorkoutMetricTile: View {
    let tile: WorkoutMetricTileData

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: tile.systemImage)
                .font(.headline)
                .foregroundStyle(tile.tint)

            VStack(alignment: .leading, spacing: 3) {
                Text(tile.value)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Text(tile.title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        .background(.white.opacity(0.38), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct WorkoutHeartRatePanel: View {
    let detail: WorkoutDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Heart Rate")
                    .font(.headline)
                Spacer()
                Text(detail.heartRateSampleText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                WorkoutHeartRateStat(label: "Avg", value: detail.heartRate?.averageBPM)
                WorkoutHeartRateStat(label: "Min", value: detail.heartRate?.minBPM)
                WorkoutHeartRateStat(label: "Max", value: detail.heartRate?.maxBPM)
            }

            if detail.plottableHeartRateSamples.isEmpty {
                Text("No heart-rate samples were found for this workout.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 150, alignment: .center)
            } else {
                WorkoutHeartRateChart(detail: detail)
                    .frame(height: 210)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 20)
    }
}

private struct WorkoutHeartRateStat: View {
    let label: String
    let value: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value?.clean ?? "--")
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                if value != nil {
                    Text("bpm")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WorkoutHeartRateChart: View {
    let detail: WorkoutDetail
    @State private var selectedProgress: Double?

    private var samples: [WorkoutHeartRatePlotPoint] {
        detail.heartRatePlotPoints
    }

    private var selectedPoint: WorkoutHeartRatePlotPoint? {
        if let selectedProgress {
            return samples.min { left, right in
                abs(left.progress - selectedProgress) < abs(right.progress - selectedProgress)
            }
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            selectedReadout

            GeometryReader { proxy in
                let chartSamples = samples
                let topPadding: CGFloat = 14
                let bottomPadding: CGFloat = 28
                let labelGutter: CGFloat = 34
                let plotWidth = max(1, proxy.size.width - labelGutter)
                let plotHeight = max(1, proxy.size.height - topPadding - bottomPadding)
                let bounds = heartRateBounds(for: chartSamples)
                let bands = zoneBands(bounds: bounds)

                ZStack(alignment: .topLeading) {
                    ForEach(bands) { band in
                        zoneBand(
                            band,
                            bounds: bounds,
                            plotWidth: plotWidth,
                            labelGutter: labelGutter,
                            plotHeight: plotHeight,
                            topPadding: topPadding
                        )
                    }

                    ForEach(lineSegments(for: chartSamples, bands: bands)) { segment in
                        Path { path in
                            path.move(to: location(
                                for: segment.start,
                                bounds: bounds,
                                plotWidth: plotWidth,
                                plotHeight: plotHeight,
                                topPadding: topPadding
                            ))
                            path.addLine(to: location(
                                for: segment.end,
                                bounds: bounds,
                                plotWidth: plotWidth,
                                plotHeight: plotHeight,
                                topPadding: topPadding
                            ))
                        }
                        .stroke(zoneColor(segment.zone), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    }

                    if let selectedPoint {
                        let selectedLocation = location(
                            for: selectedPoint,
                            bounds: bounds,
                            plotWidth: plotWidth,
                            plotHeight: plotHeight,
                            topPadding: topPadding
                        )
                        Path { path in
                            path.move(to: CGPoint(x: selectedLocation.x, y: topPadding))
                            path.addLine(to: CGPoint(x: selectedLocation.x, y: topPadding + plotHeight))
                        }
                        .stroke(.primary.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                        Circle()
                            .fill(zoneColor(zone(for: selectedPoint.value, in: bands)))
                            .overlay {
                                Circle().stroke(.white, lineWidth: 2)
                            }
                            .frame(width: 12, height: 12)
                            .position(selectedLocation)
                    }

                    if let first = chartSamples.first {
                        Text(first.timeLabel)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .position(x: 0, y: topPadding + plotHeight + 18)
                    }
                    if let last = chartSamples.last {
                        Text(last.timeLabel)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .position(x: plotWidth, y: topPadding + plotHeight + 18)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            selectedProgress = min(1, max(0, value.location.x / plotWidth))
                        }
                )
            }
        }
    }

    @ViewBuilder
    private var selectedReadout: some View {
        if let selectedPoint {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(selectedPoint.value.clean)
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                    Text("bpm")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                Text(selectedPoint.timeLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Drag across the chart to inspect heart rate.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func zoneBand(
        _ band: WorkoutZoneBand,
        bounds: WorkoutHeartRateBounds,
        plotWidth: CGFloat,
        labelGutter: CGFloat,
        plotHeight: CGFloat,
        topPadding: CGFloat
    ) -> some View {
        let top = yPosition(for: band.upperBound, bounds: bounds, plotHeight: plotHeight, topPadding: topPadding)
        let bottom = yPosition(for: band.lowerBound, bounds: bounds, plotHeight: plotHeight, topPadding: topPadding)
        let height = max(1, bottom - top)
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(zoneColor(band.zone).opacity(0.1))
                .frame(width: plotWidth, height: height)
                .position(x: plotWidth / 2, y: top + height / 2)

            Path { path in
                path.move(to: CGPoint(x: 0, y: top))
                path.addLine(to: CGPoint(x: plotWidth, y: top))
            }
            .stroke(.white.opacity(0.42), lineWidth: 1)

            Text(band.shortLabel)
                .font(.caption2.weight(.bold))
                .foregroundStyle(zoneColor(band.zone))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .position(x: plotWidth + labelGutter / 2, y: top + height / 2)
        }
    }

    private func location(
        for point: WorkoutHeartRatePlotPoint,
        bounds: WorkoutHeartRateBounds,
        plotWidth: CGFloat,
        plotHeight: CGFloat,
        topPadding: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: plotWidth * CGFloat(point.progress),
            y: yPosition(for: point.value, bounds: bounds, plotHeight: plotHeight, topPadding: topPadding)
        )
    }

    private func yPosition(
        for value: Double,
        bounds: WorkoutHeartRateBounds,
        plotHeight: CGFloat,
        topPadding: CGFloat
    ) -> CGFloat {
        topPadding + plotHeight - plotHeight * CGFloat((value - bounds.min) / max(1, bounds.max - bounds.min))
    }

    private func heartRateBounds(for samples: [WorkoutHeartRatePlotPoint]) -> WorkoutHeartRateBounds {
        let values = samples.map(\.value)
        let minValue = values.min() ?? 0
        let maxValue = values.max() ?? 1
        let thresholdValues = detail.zoneThresholdValues
        let lower = min(minValue, thresholdValues.min() ?? minValue)
        let upper = max(maxValue, thresholdValues.max() ?? maxValue)
        if upper - lower < 10 {
            return WorkoutHeartRateBounds(min: max(0, lower - 5), max: upper + 5)
        }
        return WorkoutHeartRateBounds(min: max(0, lower - 8), max: upper + 8)
    }

    private func zoneBands(bounds: WorkoutHeartRateBounds) -> [WorkoutZoneBand] {
        if let thresholdBands = detail.thresholdZoneBands(bounds: bounds), !thresholdBands.isEmpty {
            return thresholdBands
        }
        let span = max(1, bounds.max - bounds.min)
        return ["zone_1", "zone_2", "zone_3", "zone_4"].enumerated().map { index, zone in
            let lower = bounds.min + span * Double(index) / 4
            let upper = bounds.min + span * Double(index + 1) / 4
            return WorkoutZoneBand(zone: zone, lowerBound: lower, upperBound: upper)
        }
    }

    private func lineSegments(
        for samples: [WorkoutHeartRatePlotPoint],
        bands: [WorkoutZoneBand]
    ) -> [WorkoutHeartRateSegment] {
        zip(samples, samples.dropFirst()).enumerated().map { index, pair in
            let midpoint = (pair.0.value + pair.1.value) / 2
            return WorkoutHeartRateSegment(
                id: "\(pair.0.id)-\(pair.1.id)-\(index)",
                start: pair.0,
                end: pair.1,
                zone: zone(for: midpoint, in: bands)
            )
        }
    }

    private func zone(for value: Double, in bands: [WorkoutZoneBand]) -> String {
        bands.first { value >= $0.lowerBound && value <= $0.upperBound }?.zone
            ?? bands.last?.zone
            ?? "zone_1"
    }
}

private struct WorkoutHeartRateBounds {
    let min: Double
    let max: Double
}

private struct WorkoutZoneBand: Identifiable {
    let zone: String
    let lowerBound: Double
    let upperBound: Double

    var id: String { zone }

    var shortLabel: String {
        switch zone {
        case "zone_1": return "Z1"
        case "zone_2": return "Z2"
        case "zone_3": return "Z3"
        case "zone_4": return "Z4"
        default: return zone.displayTitle
        }
    }
}

private struct WorkoutHeartRateSegment: Identifiable {
    let id: String
    let start: WorkoutHeartRatePlotPoint
    let end: WorkoutHeartRatePlotPoint
    let zone: String
}

private struct WorkoutZonesPanel: View {
    let detail: WorkoutDetail

    private var activeZones: [WorkoutHeartRateZone] {
        detail.heartRateZones.filter { $0.seconds > 0 }
    }

    private var totalSeconds: Int {
        detail.heartRateZones.reduce(0) { $0 + $1.seconds }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Heart Rate Zones")
                    .font(.headline)
                Spacer()
                Text(detail.zoneSourceText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            if activeZones.isEmpty {
                Text("No zone data was found for this workout.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90, alignment: .center)
            } else {
                WorkoutZoneStackedBar(zones: activeZones, totalSeconds: totalSeconds)
                    .frame(height: 16)

                VStack(spacing: 10) {
                    ForEach(detail.heartRateZones) { zone in
                        WorkoutZoneRow(zone: zone, totalSeconds: totalSeconds)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 20)
    }
}

private struct WorkoutZoneStackedBar: View {
    let zones: [WorkoutHeartRateZone]
    let totalSeconds: Int

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 3) {
                ForEach(zones) { zone in
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(zoneColor(zone.zone).gradient)
                        .frame(width: max(4, proxy.size.width * CGFloat(zone.seconds) / CGFloat(max(1, totalSeconds))))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct WorkoutZoneRow: View {
    let zone: WorkoutHeartRateZone
    let totalSeconds: Int

    private var ratio: Double {
        Double(zone.seconds) / Double(max(1, totalSeconds))
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(zoneColor(zone.zone))
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(zone.zoneDisplayTitle)
                    .font(.subheadline.weight(.bold))
                if let thresholdText = zone.thresholdText {
                    Text(thresholdText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(durationText(seconds: zone.seconds))
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                Text("\(Int((ratio * 100).rounded()))%")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}

private struct WorkoutMetricTileData: Identifiable {
    let id: String
    let title: String
    let value: String
    let systemImage: String
    let tint: Color
}

private struct WorkoutHeartRatePlotPoint: Identifiable {
    let id: String
    let value: Double
    let progress: Double
    let timeLabel: String
}

private extension WorkoutDetail {
    var summaryIconName: String {
        let type = workoutType?.lowercased() ?? ""
        if type.contains("run") { return "figure.run" }
        if type.contains("cycl") || type.contains("bike") { return "bicycle" }
        if type.contains("walk") { return "figure.walk" }
        if type.contains("swim") { return "figure.pool.swim" }
        if type.contains("strength") || type.contains("weight") { return "dumbbell.fill" }
        if type.contains("yoga") { return "figure.yoga" }
        if type.contains("hike") { return "figure.hiking" }
        return "figure.mixed.cardio"
    }

    var summaryTint: Color {
        intensityTint(intensity)
    }

    var summaryDisplayName: String {
        guard let workoutType else { return "Workout" }
        let normalized = workoutType
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "Workout" }
        return normalized
            .lowercased()
            .split(separator: " ")
            .map { word in
                word.prefix(1).uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }

    var workoutDateLine: String {
        if let startDate {
            return DashboardFormatters.shortDate.string(from: startDate)
        }
        return date ?? "Recent workout"
    }

    var durationRangeLine: String {
        let range = [startDate, endDate]
            .compactMap { $0.map(DashboardFormatters.workoutTime.string) }
            .joined(separator: "-")
        if range.isEmpty {
            return durationText(seconds: durationSeconds)
        }
        return "\(range)  \(durationText(seconds: durationSeconds))"
    }

    var startDate: Date? {
        DashboardFormatters.parseBackendDateTime(startTime)
    }

    var endDate: Date? {
        DashboardFormatters.parseBackendDateTime(endTime)
    }

    var summaryTiles: [WorkoutMetricTileData] {
        var tiles = [
            WorkoutMetricTileData(id: "duration", title: "Duration", value: durationText(seconds: durationSeconds), systemImage: "clock.fill", tint: .blue)
        ]

        if let distanceMeters {
            tiles.append(WorkoutMetricTileData(id: "distance", title: "Distance", value: distanceText(meters: distanceMeters), systemImage: "point.topleft.down.curvedto.point.bottomright.up", tint: .mint))
        }

        if let activeCalories {
            tiles.append(WorkoutMetricTileData(id: "calories", title: "Active Calories", value: "\(activeCalories.clean) kcal", systemImage: "flame.fill", tint: .orange))
        }

        if let strainLoadPoints {
            tiles.append(WorkoutMetricTileData(id: "strain", title: "Strain Load", value: strainLoadPoints.clean, systemImage: "bolt.heart.fill", tint: .red))
        } else if let average = heartRate?.averageBPM {
            tiles.append(WorkoutMetricTileData(id: "heart_rate", title: "Average HR", value: "\(average.clean) bpm", systemImage: "heart.fill", tint: .red))
        }

        return tiles
    }

    var plottableHeartRateSamples: [WorkoutHeartRateSample] {
        heartRateSamples.filter { $0.value != nil }
    }

    var heartRatePlotPoints: [WorkoutHeartRatePlotPoint] {
        let samples = plottableHeartRateSamples
        guard !samples.isEmpty else { return [] }
        let parsedDates = samples.map { DashboardFormatters.parseBackendDateTime($0.observedAt) }
        let start = startDate ?? parsedDates.compactMap(\.self).first
        let end = endDate ?? parsedDates.compactMap(\.self).last
        let duration = max(1, (end?.timeIntervalSince(start ?? end ?? Date()) ?? Double(samples.count - 1)))

        return samples.enumerated().compactMap { index, sample in
            guard let value = sample.value else { return nil }
            let sampleDate = parsedDates[index]
            let progress: Double
            if let sampleDate, let start {
                progress = min(1, max(0, sampleDate.timeIntervalSince(start) / duration))
            } else if samples.count > 1 {
                progress = Double(index) / Double(samples.count - 1)
            } else {
                progress = 0.5
            }
            return WorkoutHeartRatePlotPoint(
                id: "\(sample.observedAt ?? "sample")-\(index)",
                value: value,
                progress: progress,
                timeLabel: sampleDate.map(DashboardFormatters.workoutTime.string) ?? "\(index + 1)"
            )
        }
    }

    var zoneThresholdValues: [Double] {
        heartRateZones.flatMap { zone in
            (zone.thresholds ?? [:]).values.flatMap { threshold in
                [threshold.minBPM, threshold.maxBPM].compactMap(\.self)
            }
        }
    }

    func thresholdZoneBands(bounds: WorkoutHeartRateBounds) -> [WorkoutZoneBand]? {
        guard let thresholds = heartRateZones.compactMap(\.thresholds).first else { return nil }
        let orderedZones = ["zone_1", "zone_2", "zone_3", "zone_4"]
        let bands = orderedZones.compactMap { zone -> WorkoutZoneBand? in
            guard let threshold = thresholds[zone] else { return nil }
            let lower = threshold.minBPM ?? bounds.min
            let upper = threshold.maxBPM ?? bounds.max
            guard upper > lower else { return nil }
            return WorkoutZoneBand(
                zone: zone,
                lowerBound: max(bounds.min, lower),
                upperBound: min(bounds.max, upper)
            )
        }
        return bands.count == orderedZones.count ? bands : nil
    }

    var heartRateSampleText: String {
        let count = heartRate?.sampleCount ?? heartRateSamples.count
        return "\(count) \(count == 1 ? "sample" : "samples")"
    }

    var zoneSourceText: String {
        switch zoneSource {
        case "provider_workout_summary": return "Provider zones"
        case "time_in_heart_rate_zone": return "Time-in-zone data"
        case "heart_rate_reserve_inferred": return "Estimated zones"
        case "missing": return "No zone data"
        case .some(let value): return value.displayTitle
        case .none: return "Unknown"
        }
    }

}

private extension WorkoutHeartRateZone {
    var zoneDisplayTitle: String {
        switch zone {
        case "zone_1": return "Zone 1 Easy"
        case "zone_2": return "Zone 2 Aerobic"
        case "zone_3": return "Zone 3 Hard"
        case "zone_4": return "Zone 4 Peak"
        default: return zone.displayTitle
        }
    }

    var thresholdText: String? {
        guard let threshold = thresholds?[zone] else { return nil }
        switch (threshold.minBPM, threshold.maxBPM) {
        case (.some(let min), .some(let max)):
            return "\(min.clean)-\(max.clean) bpm"
        case (.some(let min), .none):
            return "\(min.clean)+ bpm"
        case (.none, .some(let max)):
            return "Up to \(max.clean) bpm"
        default:
            return nil
        }
    }
}

private func durationText(seconds: Int?) -> String {
    guard let seconds else { return "--" }
    let minutes = max(0, Int((Double(seconds) / 60).rounded()))
    if minutes >= 60 {
        return "\(minutes / 60)h \(minutes % 60)m"
    }
    return "\(minutes)m"
}

private func distanceText(meters: Double) -> String {
    if meters >= 1000 {
        return String(format: "%.1f km", meters / 1000)
    }
    return "\(meters.clean) m"
}

private func zoneColor(_ zone: String) -> Color {
    switch zone {
    case "zone_1": return .teal
    case "zone_2": return .green
    case "zone_3": return .orange
    case "zone_4": return .red
    default: return .secondary
    }
}

private func intensityTint(_ intensity: String?) -> Color {
    switch intensity?.lowercased() {
    case "light": return .teal
    case "moderate": return .green
    case "vigorous": return .orange
    case "peak": return .red
    default: return .indigo
    }
}

#Preview("Workout detail") {
    NavigationStack {
        WorkoutDetailPreview(detail: .sample)
    }
}

private struct WorkoutDetailPreview: View {
    let detail: WorkoutDetail

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    WorkoutDetailHeader(detail: detail)
                    WorkoutSummaryMetricsPanel(detail: detail)
                    WorkoutHeartRatePanel(detail: detail)
                    WorkoutZonesPanel(detail: detail)
                }
                .padding(20)
            }
        }
    }
}

private extension WorkoutDetail {
    static let sample = WorkoutDetail(
        id: "sample-workout",
        workoutType: "run",
        startTime: "2026-06-19T08:00:00Z",
        endTime: "2026-06-19T08:40:00Z",
        date: "2026-06-19",
        durationSeconds: 2400,
        distanceMeters: 5000,
        activeCalories: 420,
        heartRate: HeartRateSummary(averageBPM: 144, minBPM: 96, maxBPM: 178, sampleCount: 9),
        heartRateZones: [
            WorkoutHeartRateZone(zone: "zone_1", seconds: 300, minutes: 5, source: "provider_workout_summary", sourceZones: ["LIGHT"], thresholds: nil, maxHeartRate: nil, maxHeartRateSource: nil, restingHeartRate: nil),
            WorkoutHeartRateZone(zone: "zone_2", seconds: 1200, minutes: 20, source: "provider_workout_summary", sourceZones: ["MODERATE"], thresholds: nil, maxHeartRate: nil, maxHeartRateSource: nil, restingHeartRate: nil),
            WorkoutHeartRateZone(zone: "zone_3", seconds: 600, minutes: 10, source: "provider_workout_summary", sourceZones: ["VIGOROUS"], thresholds: nil, maxHeartRate: nil, maxHeartRateSource: nil, restingHeartRate: nil),
            WorkoutHeartRateZone(zone: "zone_4", seconds: 300, minutes: 5, source: "provider_workout_summary", sourceZones: ["PEAK"], thresholds: nil, maxHeartRate: nil, maxHeartRateSource: nil, restingHeartRate: nil)
        ],
        zoneSource: "provider_workout_summary",
        intensity: "moderate",
        strainLoadPoints: 32.4,
        heartRateSamples: [
            WorkoutHeartRateSample(observedAt: "2026-06-19T08:00:00Z", value: 96, unit: "bpm", sourcePlatform: "Google Health", sourceDevice: "Pixel Watch"),
            WorkoutHeartRateSample(observedAt: "2026-06-19T08:05:00Z", value: 122, unit: "bpm", sourcePlatform: "Google Health", sourceDevice: "Pixel Watch"),
            WorkoutHeartRateSample(observedAt: "2026-06-19T08:10:00Z", value: 138, unit: "bpm", sourcePlatform: "Google Health", sourceDevice: "Pixel Watch"),
            WorkoutHeartRateSample(observedAt: "2026-06-19T08:15:00Z", value: 151, unit: "bpm", sourcePlatform: "Google Health", sourceDevice: "Pixel Watch"),
            WorkoutHeartRateSample(observedAt: "2026-06-19T08:20:00Z", value: 162, unit: "bpm", sourcePlatform: "Google Health", sourceDevice: "Pixel Watch"),
            WorkoutHeartRateSample(observedAt: "2026-06-19T08:25:00Z", value: 178, unit: "bpm", sourcePlatform: "Google Health", sourceDevice: "Pixel Watch"),
            WorkoutHeartRateSample(observedAt: "2026-06-19T08:30:00Z", value: 161, unit: "bpm", sourcePlatform: "Google Health", sourceDevice: "Pixel Watch"),
            WorkoutHeartRateSample(observedAt: "2026-06-19T08:35:00Z", value: 148, unit: "bpm", sourcePlatform: "Google Health", sourceDevice: "Pixel Watch"),
            WorkoutHeartRateSample(observedAt: "2026-06-19T08:40:00Z", value: 132, unit: "bpm", sourcePlatform: "Google Health", sourceDevice: "Pixel Watch")
        ]
    )
}
