import SwiftUI

struct OxygenSaturationDetailView: View {
    let client: DashboardAPIClient

    @State private var timeframe: ScoreTimeframe = .week
    @State private var selectedDate = Date()
    @State private var loadState: OxygenSaturationLoadState = .loading
    @State private var calendarSelection: ScoreCalendarSelection?

    private let timeframes: [ScoreTimeframe] = [.week, .month, .year]

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    timeframePicker
                    ScoreRangeNavigator(
                        timeframe: timeframe,
                        metricName: "SpO2",
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
        .navigationTitle("SpO2")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: loadKey) {
            await load()
        }
        .refreshable {
            await load()
        }
        .sheet(item: $calendarSelection) { selection in
            ScoreCalendarPicker(metricName: "SpO2", selection: selection) { nextDate in
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
        .accessibilityLabel("SpO2 timeframe")
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
                Text("Could not load SpO2")
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

    private func loadedContent(_ detail: OxygenSaturationDetail) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            SpO2SummaryPanel(detail: detail, timeframe: timeframe)
            SpO2ExplanationPanel()
            SpO2ChartPanel(detail: detail, timeframe: timeframe)
            SpO2PatternPanel(detail: detail, timeframe: timeframe)
            SpO2ContextPanel(detail: detail, timeframe: timeframe)
        }
    }

    @MainActor
    private func load() async {
        loadState = .loading
        do {
            loadState = .loaded(try await client.loadOxygenSaturationDetail(date: selectedDate, timeframe: timeframe))
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

private enum OxygenSaturationLoadState {
    case loading
    case loaded(OxygenSaturationDetail)
    case failed(String)
}

private struct SpO2SummaryPanel: View {
    let detail: OxygenSaturationDetail
    let timeframe: ScoreTimeframe

    private var displayPoints: [SpO2DisplayPoint] {
        SpO2DisplayPoint.points(from: detail.chart.points, timeframe: timeframe)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(detail.summary.title ?? titleFallback)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(spo2RelationTitle(detail.summary.baselineRelation))
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(spo2RelationColor(detail.summary.baselineRelation).opacity(0.16), in: Capsule())
                    .foregroundStyle(spo2RelationColor(detail.summary.baselineRelation))
            }

            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(spo2ValueText(detail.summary.primaryValue) ?? "--")
                            .font(.system(size: 48, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.62)
                        Text("%")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    Text(timeframe == .year ? "monthly avg" : "period avg")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Average SpO2 \(spo2ValueText(detail.summary.primaryValue) ?? "no value") percent")

                VStack(spacing: 9) {
                    SpO2MetricRow(title: "Usual range", value: spo2BaselineRangeText(detail.summary), tint: .cyan)
                    SpO2TrendRow(trend: detail.summary.trend)
                    SpO2MetricRow(title: lowCountTitle, value: lowCountText, tint: .orange)
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
        case .week: return "Weekly SpO2"
        case .month: return "Monthly SpO2"
        case .year: return "Yearly SpO2"
        case .day: return "SpO2"
        }
    }

    private var lowCountTitle: String {
        timeframe == .year ? "Low months" : "Low days"
    }

    private var lowCountText: String? {
        let lowCount = displayPoints.filter { point in
            guard let value = point.value else { return false }
            return value < spo2LowThreshold
        }.count
        return "\(lowCount)"
    }
}

private struct SpO2ExplanationPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("What SpO2 Means", systemImage: "lungs.fill")
                .font(.headline)
            Text("SpO2 estimates the percentage of oxygen carried in your blood.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Most healthy readings sit in the mid-to-high 90s. Occasional wearable dips can happen, so repeated low readings matter more than one point.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 20)
    }
}

private struct SpO2ChartPanel: View {
    let detail: OxygenSaturationDetail
    let timeframe: ScoreTimeframe
    @State private var selectedID: String?

    private var displayPoints: [SpO2DisplayPoint] {
        SpO2DisplayPoint.points(from: detail.chart.points, timeframe: timeframe)
    }

    private var selectedPoint: SpO2DisplayPoint? {
        if let selectedID, let point = displayPoints.first(where: { $0.id == selectedID }) {
            return point
        }
        return displayPoints.last(where: { $0.value != nil })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(chartTitle, systemImage: "chart.xyaxis.line")
                .font(.headline)

            if displayPoints.contains(where: { $0.value != nil }) {
                SpO2BaselineChart(points: displayPoints, timeframe: timeframe, selectedID: $selectedID)
                    .frame(height: 236)

                if let selectedPoint {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selectedPoint.readoutLabel(for: timeframe))
                                .font(.subheadline.weight(.bold))
                            Text(spo2ReadoutTitle(for: selectedPoint))
                                .font(.caption.weight(.bold))
                                .foregroundStyle(spo2ReadoutColor(for: selectedPoint))
                        }
                        Spacer()
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(spo2ValueText(selectedPoint.value) ?? "--")
                                .font(.title3.weight(.bold))
                                .monospacedDigit()
                            Text("%")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 2)
                }
            } else {
                Text("No SpO2 data was detected for this timeframe.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 20)
    }

    private var chartTitle: String {
        switch timeframe {
        case .week: return "Daily SpO2"
        case .month: return "Daily SpO2"
        case .year: return "Monthly SpO2"
        case .day: return "SpO2"
        }
    }
}

private struct SpO2BaselineChart: View {
    let points: [SpO2DisplayPoint]
    let timeframe: ScoreTimeframe
    @Binding var selectedID: String?

    private var valueBounds: ClosedRange<Double> {
        let values = points.flatMap { point -> [Double] in
            [point.value, point.baselineLowerBound, point.baselineUpperBound, spo2NormalThreshold, spo2LowThreshold, spo2VeryLowThreshold].compactMap { $0 }
        }
        guard let minValue = values.min(), let maxValue = values.max() else { return 88...100 }
        let lower = min(88, floor(minValue) - 1)
        let upper = max(100, ceil(maxValue) + 1)
        return lower...upper
    }

    private var tickValues: [Double] {
        let bounds = valueBounds
        return [bounds.upperBound, spo2NormalThreshold, spo2LowThreshold, bounds.lowerBound]
            .filter { bounds.contains($0) }
    }

    private var selectedPoint: SpO2DisplayPoint? {
        if let selectedID, let point = points.first(where: { $0.id == selectedID }) {
            return point
        }
        return points.last(where: { $0.value != nil })
    }

    var body: some View {
        GeometryReader { proxy in
            let yAxisWidth: CGFloat = 38
            let xAxisHeight: CGFloat = 28
            let plot = CGRect(
                x: yAxisWidth,
                y: 8,
                width: max(proxy.size.width - yAxisWidth, 1),
                height: max(proxy.size.height - xAxisHeight - 10, 120)
            )
            let bounds = valueBounds

            ZStack(alignment: .topLeading) {
                lowRegion(in: plot, bounds: bounds)

                ForEach(tickValues, id: \.self) { tick in
                    let y = spo2YPosition(value: tick, bounds: bounds, height: plot.height) + plot.minY
                    Text("\(spo2ValueText(tick) ?? "--")")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: yAxisWidth - 6, alignment: .trailing)
                        .position(x: (yAxisWidth - 6) / 2, y: y)
                    Rectangle()
                        .fill(thresholdLineColor(tick).opacity(thresholdLineOpacity(tick)))
                        .frame(width: plot.width, height: thresholdLineHeight(tick))
                        .position(x: plot.midX, y: y)
                }

                SpO2BaselineBandShape(points: points, bounds: bounds)
                    .fill(Color.cyan.opacity(0.14))
                    .frame(width: plot.width, height: plot.height)
                    .offset(x: plot.minX, y: plot.minY)

                SpO2LineShape(points: points, bounds: bounds, valueKind: .baseline, connectsGaps: true)
                    .stroke(Color.cyan.opacity(0.42), style: StrokeStyle(lineWidth: 1.4, dash: [5, 5]))
                    .frame(width: plot.width, height: plot.height)
                    .offset(x: plot.minX, y: plot.minY)

                SpO2LineShape(points: points, bounds: bounds, valueKind: .oxygenSaturation, connectsGaps: false)
                    .stroke(Color.cyan.gradient, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .frame(width: plot.width, height: plot.height)
                    .offset(x: plot.minX, y: plot.minY)

                if let selectedPoint, let selectedIndex = points.firstIndex(where: { $0.id == selectedPoint.id }) {
                    let x = spo2XPosition(index: selectedIndex, count: points.count, width: plot.width) + plot.minX
                    Rectangle()
                        .fill(Color.primary.opacity(0.13))
                        .frame(width: 1, height: plot.height)
                        .position(x: x, y: plot.midY)
                    if let value = selectedPoint.value {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 13, height: 13)
                            .overlay(
                                Circle().stroke(spo2ReadoutColor(for: selectedPoint), lineWidth: 3)
                            )
                            .position(x: x, y: spo2YPosition(value: value, bounds: bounds, height: plot.height) + plot.minY)
                    }
                }

                if timeframe == .week {
                    ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                        if let value = point.value {
                            Circle()
                                .fill(spo2ReadoutColor(for: point))
                                .frame(width: point.id == selectedPoint?.id ? 9 : 6, height: point.id == selectedPoint?.id ? 9 : 6)
                                .position(
                                    x: spo2XPosition(index: index, count: points.count, width: plot.width) + plot.minX,
                                    y: spo2YPosition(value: value, bounds: bounds, height: plot.height) + plot.minY
                                )
                                .accessibilityLabel("\(point.readoutLabel(for: timeframe)), SpO2 \(spo2ValueText(value) ?? "--") percent")
                        }
                    }
                }

                ForEach(xTickItems) { item in
                    Text(item.label)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: item.width)
                        .position(
                            x: spo2XPosition(index: item.index, count: points.count, width: plot.width) + plot.minX,
                            y: plot.maxY + 18
                        )
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        selectedID = nearestPointID(to: value.location.x - plot.minX, width: plot.width)
                    }
            )
        }
    }

    private var xTickItems: [SpO2XTick] {
        guard !points.isEmpty else { return [] }
        switch timeframe {
        case .week:
            return points.enumerated().map { index, point in
                SpO2XTick(index: index, label: point.axisLabel(for: timeframe), width: 34)
            }
        case .month:
            return spo2EvenlySpacedIndexes(count: points.count, maxCount: 5).map { index in
                SpO2XTick(index: index, label: points[index].axisLabel(for: timeframe), width: 34)
            }
        case .year:
            return points.enumerated().map { index, point in
                SpO2XTick(index: index, label: point.axisLabel(for: timeframe), width: 30)
            }
        case .day:
            return points.enumerated().map { index, point in
                SpO2XTick(index: index, label: point.axisLabel(for: timeframe), width: 34)
            }
        }
    }

    @ViewBuilder
    private func lowRegion(in plot: CGRect, bounds: ClosedRange<Double>) -> some View {
        if bounds.lowerBound < spo2LowThreshold {
            let y = spo2YPosition(value: spo2LowThreshold, bounds: bounds, height: plot.height) + plot.minY
            Rectangle()
                .fill(Color.orange.opacity(0.08))
                .frame(width: plot.width, height: max(plot.maxY - y, 0))
                .position(x: plot.midX, y: y + max(plot.maxY - y, 0) / 2)
        }
    }

    private func nearestPointID(to x: CGFloat, width: CGFloat) -> String? {
        guard !points.isEmpty else { return nil }
        guard points.count > 1 else { return points[0].id }
        let step = width / CGFloat(points.count - 1)
        let index = Int((x / step).rounded())
        return points[min(max(index, 0), points.count - 1)].id
    }

    private func thresholdLineColor(_ value: Double) -> Color {
        value <= spo2LowThreshold ? .orange : .primary
    }

    private func thresholdLineOpacity(_ value: Double) -> Double {
        value == spo2LowThreshold ? 0.22 : 0.08
    }

    private func thresholdLineHeight(_ value: Double) -> CGFloat {
        value == spo2LowThreshold ? 1.4 : 1
    }
}

private struct SpO2PatternPanel: View {
    let detail: OxygenSaturationDetail
    let timeframe: ScoreTimeframe

    private var displayPoints: [SpO2DisplayPoint] {
        SpO2DisplayPoint.points(from: detail.chart.points, timeframe: timeframe)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(patternTitle, systemImage: "square.grid.3x3")
                .font(.headline)

            if displayPoints.isEmpty {
                Text("No SpO2 data was detected for this timeframe.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                patternDots
                SpO2Legend()
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 20)
    }

    private var patternTitle: String {
        switch timeframe {
        case .week: return "Week Pattern"
        case .month: return "Month Pattern"
        case .year: return "Year Pattern"
        case .day: return "Pattern"
        }
    }

    @ViewBuilder
    private var patternDots: some View {
        switch timeframe {
        case .week:
            HStack(spacing: 9) {
                ForEach(displayPoints) { point in
                    SpO2PatternDot(point: point, timeframe: timeframe)
                        .frame(maxWidth: .infinity)
                }
            }
        case .month:
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 7), spacing: 10) {
                ForEach(displayPoints) { point in
                    SpO2PatternDot(point: point, timeframe: timeframe)
                }
            }
        case .year:
            HStack(spacing: 8) {
                ForEach(displayPoints) { point in
                    SpO2PatternDot(point: point, timeframe: timeframe)
                        .frame(maxWidth: .infinity)
                }
            }
        case .day:
            EmptyView()
        }
    }
}

private struct SpO2ContextPanel: View {
    let detail: OxygenSaturationDetail
    let timeframe: ScoreTimeframe

    private var displayPoints: [SpO2DisplayPoint] {
        SpO2DisplayPoint.points(from: detail.chart.points, timeframe: timeframe)
    }

    var body: some View {
        SpO2Section(title: "Breathing Context", systemImage: "lungs.fill") {
            VStack(spacing: 10) {
                SpO2ContextRow(title: "Interpretation", value: interpretationText)
                SpO2ContextRow(title: lowCountTitle, value: countText(lowCount))
                SpO2ContextRow(title: belowUsualTitle, value: countText(belowUsualCount))
                if timeframe != .year {
                    SpO2ContextRow(title: "Longest low streak", value: countText(longestLowStreak))
                }
                SpO2ContextRow(title: missingTitle, value: countText(missingCount))
                SpO2ContextRow(title: "Confidence", value: detail.summary.confidencePhase?.displayTitle ?? detail.summary.dataQuality?.displayTitle)
            }
        }
    }

    private var interpretationText: String? {
        if displayPoints.isEmpty || missingCount > displayPoints.count / 2 {
            return "Limited data"
        }
        if timeframe != .year, longestLowStreak >= 2 {
            return "Repeated low readings"
        }
        if lowCount > 0 {
            return timeframe == .year ? "Some low months" : "Some low days"
        }
        switch detail.summary.baselineRelation {
        case "below": return "Below usual, not low"
        case "above": return "Above usual"
        case "normal": return "Within usual range"
        default: return "No baseline yet"
        }
    }

    private var lowCountTitle: String {
        timeframe == .year ? "Low months" : "Low days"
    }

    private var belowUsualTitle: String {
        timeframe == .year ? "Below usual months" : "Below usual days"
    }

    private var missingTitle: String {
        timeframe == .year ? "Missing months" : "Missing days"
    }

    private var lowCount: Int {
        displayPoints.filter { point in
            guard let value = point.value else { return false }
            return value < spo2LowThreshold
        }.count
    }

    private var belowUsualCount: Int {
        displayPoints.filter { $0.value != nil && $0.comparison == "below" }.count
    }

    private var missingCount: Int {
        displayPoints.filter { $0.value == nil }.count
    }

    private var longestLowStreak: Int {
        var longest = 0
        var current = 0
        for point in displayPoints {
            if let value = point.value, value < spo2LowThreshold {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }

    private func countText(_ value: Int) -> String {
        "\(value)"
    }
}

private struct SpO2MetricRow: View {
    let title: String
    let value: String?
    let tint: Color

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .layoutPriority(1)
            Spacer()
            Text(value ?? "--")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
    }
}

private struct SpO2TrendRow: View {
    let trend: String?

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
                Image(systemName: trendIcon)
                    .font(.caption.weight(.bold))
                Text(trendTitle)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .foregroundStyle(spo2TrendColor(trend))
        }
    }

    private var trendTitle: String {
        switch trend {
        case "up": return "Up"
        case "down": return "Down"
        case "flat": return "Steady"
        default: return "No prior data"
        }
    }

    private var trendIcon: String {
        switch trend {
        case "up": return "chart.line.uptrend.xyaxis"
        case "down": return "chart.line.downtrend.xyaxis"
        case "flat": return "minus"
        default: return "questionmark"
        }
    }
}

private struct SpO2PatternDot: View {
    let point: SpO2DisplayPoint
    let timeframe: ScoreTimeframe

    var body: some View {
        VStack(spacing: 7) {
            Circle()
                .fill(patternColor(for: point))
                .frame(width: 13, height: 13)
            Text(point.axisLabel(for: timeframe))
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .accessibilityLabel("\(point.readoutLabel(for: timeframe)), \(point.value == nil ? "Missing" : spo2ReadoutTitle(for: point))")
    }

    private func patternColor(for point: SpO2DisplayPoint) -> Color {
        point.value == nil ? spo2MissingColor : spo2ReadoutColor(for: point)
    }
}

private struct SpO2Legend: View {
    private let items: [(String, Color)] = [
        ("In range", .cyan),
        ("Below usual", .blue),
        ("Low", .orange),
        ("Missing", spo2MissingColor)
    ]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(items, id: \.0) { item in
                HStack(spacing: 5) {
                    Circle()
                        .fill(item.1)
                        .frame(width: 8, height: 8)
                    Text(item.0)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SpO2Section<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 18)
    }
}

private struct SpO2ContextRow: View {
    let title: String
    let value: String?

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .layoutPriority(1)
            Spacer()
            Text(value ?? "--")
                .font(.subheadline.weight(.bold))
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
    }
}

private struct SpO2DisplayPoint: Identifiable {
    let id: String
    let date: String
    let value: Double?
    let baselineValue: Double?
    let baselineLowerBound: Double?
    let baselineUpperBound: Double?
    let comparison: String?
    let sampleCount: Int

    func axisLabel(for timeframe: ScoreTimeframe) -> String {
        switch timeframe {
        case .week:
            return ScoreDateFormatters.weekdayLabel(from: date)
        case .month:
            guard let parsedDate = ScoreDateFormatters.apiDate.date(from: date) else { return date }
            return String(ScoreDateFormatters.calendar.component(.day, from: parsedDate))
        case .year:
            return ScoreDateFormatters.monthLabel(from: date)
        case .day:
            return ScoreDateFormatters.weekdayLabel(from: date)
        }
    }

    func readoutLabel(for timeframe: ScoreTimeframe) -> String {
        if sampleCount > 1 || timeframe == .year {
            return ScoreDateFormatters.monthReadoutLabel(from: date)
        }
        return ScoreDateFormatters.weeklySelectedDateLabel(from: date)
    }

    static func points(from rawPoints: [BaselineMetricChartPoint], timeframe: ScoreTimeframe) -> [SpO2DisplayPoint] {
        let today = ScoreDateFormatters.apiDate.string(from: Date())
        let elapsedPoints = rawPoints.filter { point in
            guard let date = point.date else { return false }
            return date <= today
        }

        guard timeframe == .year else {
            return elapsedPoints.map {
                SpO2DisplayPoint(
                    id: $0.id,
                    date: $0.date ?? "",
                    value: $0.value,
                    baselineValue: $0.baselineValue,
                    baselineLowerBound: $0.baselineLowerBound,
                    baselineUpperBound: $0.baselineUpperBound,
                    comparison: $0.comparison,
                    sampleCount: 1
                )
            }
        }

        let grouped = Dictionary(grouping: elapsedPoints) { point in
            String((point.date ?? "").prefix(7))
        }
        return grouped.keys.sorted().map { key in
            let monthPoints = grouped[key] ?? []
            let values = monthPoints.compactMap(\.value)
            let baselineValues = monthPoints.compactMap(\.baselineValue)
            let lowerBounds = monthPoints.compactMap(\.baselineLowerBound)
            let upperBounds = monthPoints.compactMap(\.baselineUpperBound)
            let averageValue = average(values)
            let lower = average(lowerBounds)
            let upper = average(upperBounds)
            return SpO2DisplayPoint(
                id: key,
                date: "\(key)-01",
                value: averageValue,
                baselineValue: average(baselineValues),
                baselineLowerBound: lower,
                baselineUpperBound: upper,
                comparison: comparison(for: averageValue, lower: lower, upper: upper),
                sampleCount: values.count
            )
        }
    }

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func comparison(for value: Double?, lower: Double?, upper: Double?) -> String {
        guard let value, let lower, let upper else { return "unknown" }
        if value < lower { return "below" }
        if value > upper { return "above" }
        return "normal"
    }
}

private struct SpO2LineShape: Shape {
    let points: [SpO2DisplayPoint]
    let bounds: ClosedRange<Double>
    let valueKind: SpO2LineValueKind
    let connectsGaps: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var hasActiveSegment = false
        for (index, point) in points.enumerated() {
            guard let value = valueKind.value(from: point) else {
                if !connectsGaps {
                    hasActiveSegment = false
                }
                continue
            }
            let coordinate = CGPoint(
                x: spo2XPosition(index: index, count: points.count, width: rect.width),
                y: spo2YPosition(value: value, bounds: bounds, height: rect.height)
            )
            if hasActiveSegment {
                path.addLine(to: coordinate)
            } else {
                path.move(to: coordinate)
                hasActiveSegment = true
            }
        }
        return path
    }
}

private enum SpO2LineValueKind: Sendable {
    case oxygenSaturation
    case baseline

    func value(from point: SpO2DisplayPoint) -> Double? {
        switch self {
        case .oxygenSaturation: return point.value
        case .baseline: return point.baselineValue
        }
    }
}

private struct SpO2BaselineBandShape: Shape {
    let points: [SpO2DisplayPoint]
    let bounds: ClosedRange<Double>

    func path(in rect: CGRect) -> Path {
        let boundedPoints = points.enumerated().filter {
            $0.element.baselineLowerBound != nil && $0.element.baselineUpperBound != nil
        }
        guard boundedPoints.count >= 2 else { return Path() }

        var path = Path()
        for (position, item) in boundedPoints.enumerated() {
            let coordinate = CGPoint(
                x: spo2XPosition(index: item.offset, count: points.count, width: rect.width),
                y: spo2YPosition(value: item.element.baselineUpperBound ?? 0, bounds: bounds, height: rect.height)
            )
            if position == 0 {
                path.move(to: coordinate)
            } else {
                path.addLine(to: coordinate)
            }
        }
        for item in boundedPoints.reversed() {
            path.addLine(to: CGPoint(
                x: spo2XPosition(index: item.offset, count: points.count, width: rect.width),
                y: spo2YPosition(value: item.element.baselineLowerBound ?? 0, bounds: bounds, height: rect.height)
            ))
        }
        path.closeSubpath()
        return path
    }
}

private struct SpO2XTick: Identifiable {
    let index: Int
    let label: String
    let width: CGFloat

    var id: String { "\(index)-\(label)" }
}

private let spo2NormalThreshold = 96.0
private let spo2LowThreshold = 94.0
private let spo2VeryLowThreshold = 92.0
private let spo2MissingColor = Color.secondary.opacity(0.35)

private func spo2EvenlySpacedIndexes(count: Int, maxCount: Int) -> [Int] {
    guard count > 0 else { return [] }
    guard count > maxCount else { return Array(0..<count) }
    let step = Double(count - 1) / Double(maxCount - 1)
    return (0..<maxCount).map { Int((Double($0) * step).rounded()) }
}

private func spo2XPosition(index: Int, count: Int, width: CGFloat) -> CGFloat {
    guard count > 1 else { return width / 2 }
    return CGFloat(index) / CGFloat(count - 1) * width
}

private func spo2YPosition(value: Double, bounds: ClosedRange<Double>, height: CGFloat) -> CGFloat {
    let span = max(bounds.upperBound - bounds.lowerBound, 1)
    let ratio = (value - bounds.lowerBound) / span
    return height - (CGFloat(ratio) * height)
}

private func spo2ValueText(_ value: Double?) -> String? {
    guard let value else { return nil }
    if abs(value.rounded() - value) < 0.05 {
        return String(Int(value.rounded()))
    }
    return String(format: "%.1f", value)
}

private func spo2BaselineRangeText(_ summary: BaselineMetricSummary) -> String? {
    guard let lower = summary.baselineLowerBound, let upper = summary.baselineUpperBound else { return nil }
    return "\(spo2ValueText(lower) ?? "--")-\(spo2ValueText(upper) ?? "--")%"
}

private func spo2RelationTitle(_ relation: String?) -> String {
    switch relation {
    case "normal": return "In range"
    case "below": return "Below usual"
    case "above": return "Above usual"
    default: return "No baseline"
    }
}

private func spo2RelationColor(_ relation: String?) -> Color {
    switch relation {
    case "normal": return .cyan
    case "below": return .blue
    case "above": return .teal
    default: return .secondary
    }
}

private func spo2ReadoutTitle(for point: SpO2DisplayPoint) -> String {
    guard let value = point.value else { return "Missing" }
    if value < spo2VeryLowThreshold { return "Very low" }
    if value < spo2LowThreshold { return "Low" }
    if point.comparison == "below" { return "Below usual" }
    return spo2RelationTitle(point.comparison)
}

private func spo2ReadoutColor(for point: SpO2DisplayPoint) -> Color {
    guard let value = point.value else { return spo2MissingColor }
    if value < spo2VeryLowThreshold { return .red }
    if value < spo2LowThreshold { return .orange }
    if point.comparison == "below" { return .blue }
    return spo2RelationColor(point.comparison)
}

private func spo2TrendColor(_ trend: String?) -> Color {
    switch trend {
    case "up": return .teal
    case "down": return .orange
    case "flat": return .secondary
    default: return .secondary
    }
}

#Preview {
    NavigationStack {
        OxygenSaturationDetailView(client: DashboardAPIClient())
    }
}
