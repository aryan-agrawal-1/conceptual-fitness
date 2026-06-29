import SwiftUI

struct HeartRateDetailView: View {
    let client: DashboardAPIClient

    @State private var timeframe: ScoreTimeframe = .day
    @State private var selectedDate = Date()
    @State private var loadState: HeartRateDetailLoadState = .loading
    @State private var calendarSelection: ScoreCalendarSelection?

    private let timeframes = ScoreTimeframe.allCases

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    timeframePicker
                    ScoreRangeNavigator(
                        timeframe: timeframe,
                        metricName: "Heart Rate",
                        selectedDate: $selectedDate,
                        calendarSelection: $calendarSelection
                    )
                    content
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        }
        .navigationTitle("Heart Rate")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: loadKey) {
            await load()
        }
        .refreshable {
            await load()
        }
        .sheet(item: $calendarSelection) { selection in
            ScoreCalendarPicker(metricName: "Heart Rate", selection: selection) { nextDate in
                selectedDate = nextDate
                calendarSelection = nil
            }
        }
    }

    private var timeframePicker: some View {
        Picker("Timeframe", selection: $timeframe) {
            ForEach(timeframes) { item in
                Text(item.title).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Heart rate timeframe")
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
                Text("Could not load Heart Rate")
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
            loadedContent(detail)
        }
    }

    private func loadedContent(_ detail: HeartRateDetail) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HeartRateSummaryPanel(detail: detail, timeframe: timeframe)
            HeartRateChartPanel(detail: detail, timeframe: timeframe)
            HeartRateZonesPanel(zones: detail.zones)
            HeartRateDriversPanel(detail: detail, timeframe: timeframe)
        }
    }

    @MainActor
    private func load() async {
        loadState = .loading
        do {
            loadState = .loaded(try await client.loadHeartRateDetail(date: selectedDate, timeframe: timeframe))
        } catch is CancellationError {
            return
        } catch {
            loadState = .failed("The backend was unavailable at \(client.baseURL.absoluteString).")
        }
    }

    private var loadKey: String {
        "\(timeframe.rawValue)-\(ScoreDateFormatters.apiDate.string(from: selectedDate))"
    }
}

private enum HeartRateDetailLoadState {
    case loading
    case loaded(HeartRateDetail)
    case failed(String)
}

private struct HeartRateSummaryPanel: View {
    let detail: HeartRateDetail
    let timeframe: ScoreTimeframe

    private var latestPoint: HeartRateChartPoint? {
        detail.series.last(where: { $0.value != nil || $0.minValue != nil || $0.maxValue != nil })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(detail.summary.title ?? titleFallback)
                .font(.headline)
                .foregroundStyle(.secondary)

            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(detail.summary.primaryValue?.clean ?? "--")
                            .font(.system(size: 48, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.62)
                        Text("bpm")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    Text(timeframe == .day ? "daily avg" : timeframe == .year ? "year avg" : "period avg")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 9) {
                    HeartRateMetricRow(title: "Range", value: rangeText, tint: .pink)
                    HeartRateTrendRow(trend: detail.summary.trend)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 20)
    }

    private var titleFallback: String {
        switch timeframe {
        case .day: return "Daily Heart Rate"
        case .week: return "Weekly Heart Rate"
        case .month: return "Monthly Heart Rate"
        case .year: return "Yearly Heart Rate"
        }
    }

    private var rangeText: String? {
        guard let point = latestPoint, let min = point.minValue, let max = point.maxValue else { return nil }
        return "\(min.clean)-\(max.clean) bpm"
    }

}

private struct HeartRateChartPanel: View {
    let detail: HeartRateDetail
    let timeframe: ScoreTimeframe
    @State private var selectedDailyID: String?

    private var dailyPoints: [HeartRateDisplayPoint] {
        HeartRateDisplayPoint.points(from: detail.series, timeframe: timeframe)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Label(chartTitle, systemImage: "chart.xyaxis.line")
                    .font(.headline)
                Spacer()
                if timeframe == .day, !detail.intraday.available {
                    Text("Daily summary")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }

            if timeframe == .day, detail.intraday.available {
                HeartRateIntradayChart(points: detail.intraday.points)
                    .frame(height: 236)
            } else if dailyPoints.contains(where: { $0.value != nil || $0.minValue != nil || $0.maxValue != nil }) {
                HeartRateRangeChart(points: dailyPoints, timeframe: timeframe, selectedID: $selectedDailyID)
                    .frame(height: 236)
                if timeframe == .day {
                    Text("Minute-level heart rate is retained for \(detail.intraday.retentionDays ?? 14) days. Older days use durable daily averages and ranges.")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No heart-rate data was detected for this timeframe.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 20)
    }

    private var chartTitle: String {
        if timeframe == .day {
            return detail.intraday.available ? "Intraday Heart Rate" : "Daily Heart Rate"
        }
        switch timeframe {
        case .week: return "Average Heart Rate"
        case .month: return "Average Heart Rate"
        case .year: return "Monthly Average Heart Rate"
        case .day: return "Heart Rate"
        }
    }
}

private struct HeartRateIntradayChart: View {
    let points: [HeartRateIntradayPoint]
    @State private var selectedProgress: Double?

    private var plotPoints: [HeartRateIntradayPlotPoint] {
        let values = points.compactMap { point -> (HeartRateIntradayPoint, Date, Double)? in
            guard let value = point.value, let date = DashboardFormatters.parseBackendDateTime(point.observedAt) else { return nil }
            return (point, date, value)
        }
        guard let first = values.first?.1, let last = values.last?.1 else { return [] }
        let duration = max(1, last.timeIntervalSince(first))
        return values.enumerated().map { index, item in
            HeartRateIntradayPlotPoint(
                id: "\(item.0.id)-\(index)",
                value: item.2,
                progress: duration > 1 ? item.1.timeIntervalSince(first) / duration : Double(index) / Double(max(1, values.count - 1)),
                timeLabel: DashboardFormatters.workoutTime.string(from: item.1)
            )
        }
    }

    private var selectedPoint: HeartRateIntradayPlotPoint? {
        if let selectedProgress {
            return plotPoints.min { left, right in
                abs(left.progress - selectedProgress) < abs(right.progress - selectedProgress)
            }
        }
        return plotPoints.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            selectedReadout

            GeometryReader { proxy in
                let samples = plotPoints
                let topPadding: CGFloat = 12
                let bottomPadding: CGFloat = 28
                let labelGutter: CGFloat = 34
                let plotWidth = max(1, proxy.size.width - labelGutter)
                let plotHeight = max(1, proxy.size.height - topPadding - bottomPadding)
                let bounds = heartRateBounds(samples.map(\.value))
                let bands = zoneBands(bounds: bounds)

                ZStack(alignment: .topLeading) {
                    ForEach(bands) { band in
                        heartRateZoneBand(
                            band,
                            bounds: bounds,
                            plotWidth: plotWidth,
                            labelGutter: labelGutter,
                            plotHeight: plotHeight,
                            topPadding: topPadding
                        )
                    }

                    ForEach(lineSegments(for: samples, bands: bands)) { segment in
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
                        .stroke(heartRateZoneColor(segment.zone), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
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
                            .fill(heartRateZoneColor(zone(for: selectedPoint.value, in: bands)))
                            .overlay { Circle().stroke(.white, lineWidth: 2) }
                            .frame(width: 12, height: 12)
                            .position(selectedLocation)
                    }

                    if let first = samples.first {
                        Text(first.timeLabel)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .position(x: 0, y: topPadding + plotHeight + 18)
                    }
                    if let last = samples.last {
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
                Text("\(selectedPoint.value.clean) bpm")
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
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

    private func location(
        for point: HeartRateIntradayPlotPoint,
        bounds: ClosedRange<Double>,
        plotWidth: CGFloat,
        plotHeight: CGFloat,
        topPadding: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: plotWidth * CGFloat(point.progress),
            y: yPosition(for: point.value, bounds: bounds, plotHeight: plotHeight, topPadding: topPadding)
        )
    }

    private func lineSegments(
        for samples: [HeartRateIntradayPlotPoint],
        bands: [HeartRateZoneBand]
    ) -> [HeartRateLineSegment] {
        zip(samples, samples.dropFirst()).enumerated().map { index, pair in
            let midpoint = (pair.0.value + pair.1.value) / 2
            return HeartRateLineSegment(
                id: "\(pair.0.id)-\(pair.1.id)-\(index)",
                start: pair.0,
                end: pair.1,
                zone: zone(for: midpoint, in: bands)
            )
        }
    }

    private func zone(for value: Double, in bands: [HeartRateZoneBand]) -> String {
        bands.first { value >= $0.lowerBound && value <= $0.upperBound }?.id
            ?? bands.last?.id
            ?? "zone_1"
    }
}

private struct HeartRateRangeChart: View {
    let points: [HeartRateDisplayPoint]
    let timeframe: ScoreTimeframe
    @Binding var selectedID: String?

    private var selectedPoint: HeartRateDisplayPoint? {
        if let selectedID, let point = points.first(where: { $0.id == selectedID }) {
            return point
        }
        return points.last(where: { $0.value != nil || $0.minValue != nil || $0.maxValue != nil })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let selectedPoint {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedPoint.readoutLabel(for: timeframe))
                            .font(.subheadline.weight(.bold))
                        Text(selectedPoint.rangeText)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(selectedPoint.value?.clean ?? "--")
                            .font(.title3.weight(.bold))
                            .monospacedDigit()
                        Text("bpm")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            GeometryReader { proxy in
                let topPadding: CGFloat = 14
                let bottomPadding: CGFloat = 28
                let plotHeight = max(1, proxy.size.height - topPadding - bottomPadding)
                let plotWidth = max(1, proxy.size.width)
                let bounds = heartRateBounds(points.compactMap(\.value))
                let plottable = points.enumerated().compactMap { index, point -> HeartRateAveragePlotPoint? in
                    guard let value = point.value else { return nil }
                    return HeartRateAveragePlotPoint(index: index, point: point, value: value)
                }

                ZStack(alignment: .topLeading) {
                    Path { path in
                        for (offset, item) in plottable.enumerated() {
                            let location = CGPoint(
                                x: xPosition(index: item.index, count: points.count, width: plotWidth),
                                y: yPosition(for: item.value, bounds: bounds, plotHeight: plotHeight, topPadding: topPadding)
                            )
                            if offset == 0 {
                                path.move(to: location)
                            } else {
                                path.addLine(to: location)
                            }
                        }
                    }
                    .stroke(.pink, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

                    ForEach(plottable) { item in
                        let isSelected = selectedPoint?.id == item.point.id
                        Circle()
                            .fill(isSelected ? .pink : .primary.opacity(0.45))
                            .frame(width: isSelected ? 9 : 5, height: isSelected ? 9 : 5)
                            .position(
                                x: xPosition(index: item.index, count: points.count, width: plotWidth),
                                y: yPosition(for: item.value, bounds: bounds, plotHeight: plotHeight, topPadding: topPadding)
                            )
                    }

                    ForEach(axisTicks) { tick in
                        if tick.index < points.count {
                            Text(tick.label)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)
                                .frame(width: tick.width)
                                .position(
                                    x: xPosition(index: tick.index, count: points.count, width: plotWidth),
                                    y: topPadding + plotHeight + 18
                                )
                        }
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let index = nearestIndex(x: value.location.x, width: plotWidth, count: points.count)
                            selectedID = points.indices.contains(index) ? points[index].id : selectedID
                        }
                )
            }
        }
    }

    private var axisTicks: [HeartRateAxisTick] {
        guard !points.isEmpty else { return [] }
        switch timeframe {
        case .week:
            return points.enumerated().map { HeartRateAxisTick(index: $0.offset, label: $0.element.axisLabel(for: timeframe), width: 34) }
        case .month:
            let stride = max(1, points.count / 4)
            return points.indices.compactMap { index in
                index % stride == 0 || index == points.count - 1
                    ? HeartRateAxisTick(index: index, label: points[index].axisLabel(for: timeframe), width: 34)
                    : nil
            }
        case .year:
            return points.enumerated().map { HeartRateAxisTick(index: $0.offset, label: $0.element.axisLabel(for: timeframe), width: 28) }
        case .day:
            return [HeartRateAxisTick(index: 0, label: points[0].axisLabel(for: timeframe), width: 46)]
        }
    }
}

private struct HeartRateZonesPanel: View {
    let zones: HeartRateZonesSummary

    private var activeZones: [WorkoutHeartRateZone] {
        zones.items.filter { $0.seconds > 0 }
    }

    private var totalSeconds: Int {
        zones.items.reduce(0) { $0 + $1.seconds }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Heart Rate Zones")
                    .font(.headline)
                Spacer()
                Text(zoneSourceText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if activeZones.isEmpty {
                Text("Zone time will appear when workouts in this range include provider or inferred zone data.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90, alignment: .center)
            } else {
                HeartRateZoneStackedBar(zones: activeZones, totalSeconds: totalSeconds)
                    .frame(height: 16)

                VStack(spacing: 10) {
                    ForEach(zones.items) { zone in
                        HeartRateZoneRow(zone: zone, totalSeconds: totalSeconds)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 20)
    }

    private var zoneSourceText: String {
        switch zones.source {
        case "provider_workout_summary": return "Provider workouts"
        case "time_in_heart_rate_zone": return "Time-in-zone data"
        case "heart_rate_reserve_inferred": return "Estimated workouts"
        case "mixed_workouts": return "Mixed workout data"
        case "workouts": return "Workouts"
        case .some(let value): return value.displayTitle
        case .none: return "Workouts"
        }
    }
}

private struct HeartRateDriversPanel: View {
    let detail: HeartRateDetail
    let timeframe: ScoreTimeframe

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Drivers")
                .font(.headline)

            HeartRateSleepDriverCard(sleep: detail.drivers.sleep, timeframe: timeframe)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Workouts", systemImage: "figure.run")
                        .font(.subheadline.weight(.bold))
                    Spacer()
                    Text("\(detail.drivers.workouts.count)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }

                if detail.drivers.workouts.isEmpty {
                    Text("No workouts were recorded in this range.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(detail.drivers.workouts.prefix(5)) { workout in
                        NavigationLink(value: AppRoute.workout(workout.id)) {
                            WorkoutSummaryRow(workout: workout, presentation: .compact)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(14)
            .background(.white.opacity(0.34), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 20)
    }
}

private struct HeartRateSleepDriverCard: View {
    let sleep: HeartRateSleepDriver
    let timeframe: ScoreTimeframe

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label("Sleep", systemImage: "bed.double.fill")
                    .font(.subheadline.weight(.bold))
                Spacer()
                Text(scoreText)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                HeartRateDriverStat(title: timeframe == .day ? "Slept" : "Avg sleep", value: sleepDurationText)
                HeartRateDriverStat(title: "Debt", value: debtText)
            }
        }
        .padding(14)
        .background(.white.opacity(0.34), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var scoreText: String {
        let value = timeframe == .day ? sleep.latestScore : sleep.averageScore
        return value.map { "Score \($0.clean)" } ?? "No score"
    }

    private var sleepDurationText: String {
        let minutes = timeframe == .day ? sleep.sleepMinutes : sleep.averageSleepMinutes
        return minutes.map { compactDurationText(minutes: $0) } ?? "--"
    }

    private var debtText: String {
        guard let minutes = sleep.sleepDebtMinutes else { return "--" }
        return compactDurationText(minutes: minutes)
    }

}

private struct HeartRateDriverStat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value)
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HeartRateMetricRow: View {
    let title: String
    let value: String?
    let tint: Color

    var body: some View {
        HStack {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value ?? "--")
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .monospacedDigit()
        }
    }
}

private struct HeartRateTrendRow: View {
    let trend: String?

    var body: some View {
        HStack {
            Text("Trend")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: trendIcon)
                    .font(.caption.weight(.bold))
                Text(trendText)
                    .font(.caption.weight(.bold))
            }
            .foregroundStyle(trendColor)
        }
    }

    private var trendText: String {
        guard let trend, trend != "unknown" else { return "--" }
        return trend == "flat" ? "Steady" : trend.displayTitle
    }

    private var trendIcon: String {
        switch trend {
        case "up": return "chart.line.uptrend.xyaxis"
        case "down": return "chart.line.downtrend.xyaxis"
        case "flat": return "minus"
        default: return "questionmark"
        }
    }

    private var trendColor: Color {
        switch trend {
        case "up": return .orange
        case "down": return .blue
        case "flat": return .secondary
        default: return .secondary
        }
    }
}

private struct HeartRateZoneStackedBar: View {
    let zones: [WorkoutHeartRateZone]
    let totalSeconds: Int

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 3) {
                ForEach(zones) { zone in
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(heartRateZoneColor(zone.zone).gradient)
                        .frame(width: max(4, proxy.size.width * CGFloat(zone.seconds) / CGFloat(max(1, totalSeconds))))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct HeartRateZoneRow: View {
    let zone: WorkoutHeartRateZone
    let totalSeconds: Int

    private var ratio: Double {
        Double(zone.seconds) / Double(max(1, totalSeconds))
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(heartRateZoneColor(zone.zone))
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(zone.hrZoneDisplayTitle)
                    .font(.subheadline.weight(.bold))
                if let thresholdText = zone.hrThresholdText {
                    Text(thresholdText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(hrDurationText(seconds: zone.seconds))
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

private struct HeartRateIntradayPlotPoint: Identifiable {
    let id: String
    let value: Double
    let progress: Double
    let timeLabel: String
}

private struct HeartRateLineSegment: Identifiable {
    let id: String
    let start: HeartRateIntradayPlotPoint
    let end: HeartRateIntradayPlotPoint
    let zone: String
}

private struct HeartRateAveragePlotPoint: Identifiable {
    let index: Int
    let point: HeartRateDisplayPoint
    let value: Double

    var id: String { point.id }
}

private struct HeartRateAxisTick: Identifiable {
    let index: Int
    let label: String
    let width: CGFloat

    var id: Int { index }
}

private struct HeartRateZoneBand: Identifiable {
    let id: String
    let lowerBound: Double
    let upperBound: Double
}

private struct HeartRateDisplayPoint: Identifiable {
    let id: String
    let date: Date?
    let monthStartDate: Date?
    let value: Double?
    let minValue: Double?
    let maxValue: Double?
    let sampleCount: Int

    var rangeText: String {
        guard let minValue, let maxValue else { return "No range" }
        return "\(minValue.clean)-\(maxValue.clean) bpm"
    }

    func axisLabel(for timeframe: ScoreTimeframe) -> String {
        if timeframe == .year, let monthStartDate {
            return ScoreDateFormatters.month.string(from: monthStartDate)
        }
        guard let date else { return "--" }
        switch timeframe {
        case .day:
            return ScoreDateFormatters.weekdayDate.string(from: date)
        case .week:
            return ScoreDateFormatters.weekday.string(from: date)
        case .month:
            return ScoreDateFormatters.dayOfMonth.string(from: date)
        case .year:
            return ScoreDateFormatters.month.string(from: date)
        }
    }

    func readoutLabel(for timeframe: ScoreTimeframe) -> String {
        if timeframe == .year, let monthStartDate {
            return ScoreDateFormatters.monthYear.string(from: monthStartDate)
        }
        guard let date else { return "Heart rate" }
        return timeframe == .week
            ? ScoreDateFormatters.weekdayDate.string(from: date)
            : ScoreDateFormatters.compactDate.string(from: date)
    }

    static func points(from rawPoints: [HeartRateChartPoint], timeframe: ScoreTimeframe) -> [HeartRateDisplayPoint] {
        let daily = rawPoints.map { point in
            let date = ScoreDateFormatters.apiDate.date(from: point.date ?? "")
            return HeartRateDisplayPoint(
                id: point.date ?? point.id,
                date: date,
                monthStartDate: nil,
                value: point.value,
                minValue: point.minValue,
                maxValue: point.maxValue,
                sampleCount: point.sampleCount ?? 0
            )
        }
        guard timeframe == .year else { return daily }

        let calendar = ScoreDateFormatters.calendar
        let grouped = Dictionary(grouping: daily.compactMap { point -> HeartRateDisplayPoint? in
            guard let date = point.date else { return nil }
            let components = calendar.dateComponents([.year, .month], from: date)
            guard let month = calendar.date(from: components) else { return nil }
            return HeartRateDisplayPoint(
                id: point.id,
                date: point.date,
                monthStartDate: month,
                value: point.value,
                minValue: point.minValue,
                maxValue: point.maxValue,
                sampleCount: point.sampleCount
            )
        }) { point in
            point.monthStartDate ?? point.date ?? Date.distantPast
        }

        return grouped.keys.sorted().map { month in
            let points = grouped[month] ?? []
            let values = points.compactMap(\.value)
            let mins = points.compactMap(\.minValue)
            let maxes = points.compactMap(\.maxValue)
            return HeartRateDisplayPoint(
                id: ScoreDateFormatters.apiDate.string(from: month),
                date: nil,
                monthStartDate: month,
                value: values.isEmpty ? nil : values.reduce(0, +) / Double(values.count),
                minValue: mins.min(),
                maxValue: maxes.max(),
                sampleCount: points.reduce(0) { $0 + $1.sampleCount }
            )
        }
    }
}

private extension WorkoutHeartRateZone {
    var hrZoneDisplayTitle: String {
        switch zone {
        case "zone_1": return "Zone 1"
        case "zone_2": return "Zone 2"
        case "zone_3": return "Zone 3"
        case "zone_4": return "Zone 4"
        default: return zone.displayTitle
        }
    }

    var hrThresholdText: String? {
        guard let thresholds, let threshold = thresholds[zone] else { return nil }
        switch (threshold.minBPM, threshold.maxBPM) {
        case (.some(let min), .some(let max)):
            return "\(min.clean)-\(max.clean) bpm"
        case (.some(let min), .none):
            return "\(min.clean)+ bpm"
        case (.none, .some(let max)):
            return "<\(max.clean) bpm"
        default:
            return nil
        }
    }
}

private func heartRateBounds(_ values: [Double]) -> ClosedRange<Double> {
    guard let minValue = values.min(), let maxValue = values.max() else { return 40...180 }
    let lower = max(35, minValue - 8)
    let upper = max(maxValue + 8, lower + 20)
    return lower...upper
}

private func zoneBands(bounds: ClosedRange<Double>) -> [HeartRateZoneBand] {
    let span = max(1, bounds.upperBound - bounds.lowerBound)
    return ["zone_1", "zone_2", "zone_3", "zone_4"].enumerated().map { index, zone in
        HeartRateZoneBand(
            id: zone,
            lowerBound: bounds.lowerBound + span * Double(index) / 4,
            upperBound: bounds.lowerBound + span * Double(index + 1) / 4
        )
    }
}

@ViewBuilder
private func heartRateZoneBand(
    _ band: HeartRateZoneBand,
    bounds: ClosedRange<Double>,
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
            .fill(heartRateZoneColor(band.id).opacity(0.08))
            .frame(width: plotWidth, height: height)
            .position(x: plotWidth / 2, y: top + height / 2)

        Text(heartRateZoneShortLabel(band.id))
            .font(.caption2.weight(.bold))
            .foregroundStyle(heartRateZoneColor(band.id))
            .position(x: plotWidth + labelGutter / 2, y: top + height / 2)
    }
}

private func yPosition(
    for value: Double,
    bounds: ClosedRange<Double>,
    plotHeight: CGFloat,
    topPadding: CGFloat
) -> CGFloat {
    topPadding + plotHeight - plotHeight * CGFloat((value - bounds.lowerBound) / max(1, bounds.upperBound - bounds.lowerBound))
}

private func xPosition(index: Int, count: Int, width: CGFloat) -> CGFloat {
    guard count > 1 else { return width / 2 }
    return width * CGFloat(index) / CGFloat(count - 1)
}

private func nearestIndex(x: CGFloat, width: CGFloat, count: Int) -> Int {
    guard count > 1 else { return 0 }
    let progress = min(1, max(0, x / max(1, width)))
    return Int((progress * CGFloat(count - 1)).rounded())
}

private func hrDurationText(seconds: Int?) -> String {
    guard let seconds else { return "--" }
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    if hours > 0 {
        return "\(hours)h \(minutes)m"
    }
    return "\(minutes)m"
}

private func compactDurationText(minutes: Double) -> String {
    let rounded = max(0, Int(minutes.rounded()))
    let hours = rounded / 60
    let mins = rounded % 60
    if hours > 0 {
        return "\(hours)h \(mins)m"
    }
    return "\(mins)m"
}
