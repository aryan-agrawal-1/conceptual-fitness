import SwiftUI

struct RespiratoryRateDetailView: View {
    let client: DashboardAPIClient

    var body: some View {
        MetricDetailScreen(
            title: "Respiratory Rate",
            metricName: "Respiratory Rate",
            timeframeAccessibilityLabel: "Respiratory rate timeframe",
            timeframes: [.week, .month, .year],
            initialTimeframe: .week,
            backendBaseURL: client.baseURL,
            load: { date, timeframe in
                try await client.loadRespiratoryRateDetail(date: date, timeframe: timeframe)
            }
        ) { detail, timeframe in
            VStack(alignment: .leading, spacing: 18) {
                RespiratorySummaryPanel(detail: detail, timeframe: timeframe)
                RespiratoryChartPanel(detail: detail, timeframe: timeframe)
                RespiratoryExplanationPanel()
                RespiratoryPatternPanel(detail: detail, timeframe: timeframe)
                RespiratoryContextPanel(detail: detail, timeframe: timeframe)
            }
        }
    }
}

private struct RespiratorySummaryPanel: View {
    let detail: RespiratoryRateDetail
    let timeframe: ScoreTimeframe

    private var displayPoints: [RespiratoryDisplayPoint] {
        RespiratoryDisplayPoint.points(from: detail.chart.points, timeframe: timeframe)
    }

    var body: some View {
        MetricHeroPanel(
            eyebrow: "Overnight breathing",
            headline: heroHeadline,
            value: respiratoryValueText(detail.summary.primaryValue),
            unit: "br/min",
            caption: timeframe == .year ? "monthly avg" : "period avg",
            accent: HealthTheme.respiratoryRate,
            stats: [
                MetricHeroStat(title: "Usual range", value: respiratoryBaselineRangeText(detail.summary) ?? "--", tint: HealthTheme.respiratoryRate),
                MetricHeroStat(title: "Trend", value: metricHeroTrendText(detail.summary.trend), tint: respiratoryTrendColor(detail.summary.trend)),
                MetricHeroStat(title: "Recorded", value: recordedText ?? "--", tint: .secondary)
            ],
            accessibilityLabel: "Average respiratory rate \(respiratoryValueText(detail.summary.primaryValue) ?? "no value") breaths per minute"
        )
    }

    private var heroHeadline: String {
        switch detail.summary.baselineRelation {
        case "above": return "Elevated"
        case "below": return "Below usual"
        case "normal": return "Breathing steady"
        default: return "Building baseline"
        }
    }

    private var recordedText: String? {
        if timeframe == .year {
            let validMonths = displayPoints.filter { $0.value != nil }.count
            return "\(validMonths) / \(displayPoints.count) months"
        }
        guard let valid = detail.summary.validDays, let period = detail.summary.periodDays else { return nil }
        return "\(valid) / \(period) nights"
    }
}

private struct RespiratoryExplanationPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("What Respiratory Rate Means", systemImage: "wind")
                .font(.headline)
            Text("Respiratory rate is the number of breaths you take per minute, usually measured during sleep.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("It is typically stable night to night, so sustained increases from your usual range can appear with stress, illness, alcohol, poor sleep, altitude, or heavy training.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 20)
    }
}

private struct RespiratoryChartPanel: View {
    let detail: RespiratoryRateDetail
    let timeframe: ScoreTimeframe
    @State private var selectedID: String?

    private var displayPoints: [RespiratoryDisplayPoint] {
        RespiratoryDisplayPoint.points(from: detail.chart.points, timeframe: timeframe)
    }

    private var selectedPoint: RespiratoryDisplayPoint? {
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
                RespiratoryBaselineChart(points: displayPoints, timeframe: timeframe, selectedID: $selectedID)
                    .frame(height: 236)

                if let selectedPoint {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selectedPoint.readoutLabel(for: timeframe))
                                .font(.subheadline.weight(.bold))
                            Text(respiratoryRelationTitle(selectedPoint.comparison))
                                .font(.caption.weight(.bold))
                                .foregroundStyle(respiratoryRelationColor(selectedPoint.comparison))
                        }
                        Spacer()
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(respiratoryValueText(selectedPoint.value) ?? "--")
                                .font(.title3.weight(.bold))
                                .monospacedDigit()
                            Text("br/min")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 2)
                }
            } else {
                Text("No respiratory rate data was detected for this timeframe.")
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
        case .week: return "Nightly respiratory rate"
        case .month: return "Daily respiratory rate"
        case .year: return "Monthly respiratory rate"
        case .day: return "Respiratory rate"
        }
    }
}

private struct RespiratoryBaselineChart: View {
    let points: [RespiratoryDisplayPoint]
    let timeframe: ScoreTimeframe
    @Binding var selectedID: String?

    private var valueBounds: ClosedRange<Double> {
        let values = points.flatMap { point -> [Double] in
            [point.value, point.baselineLowerBound, point.baselineUpperBound].compactMap { $0 }
        }
        guard let minValue = values.min(), let maxValue = values.max() else { return 8...24 }
        let span = max(maxValue - minValue, 4)
        let padding = span * 0.22
        return (minValue - padding)...(maxValue + padding)
    }

    private var tickValues: [Double] {
        let bounds = valueBounds
        return [bounds.upperBound, (bounds.lowerBound + bounds.upperBound) / 2, bounds.lowerBound]
    }

    private var selectedPoint: RespiratoryDisplayPoint? {
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
                ForEach(tickValues, id: \.self) { tick in
                    let y = respiratoryYPosition(value: tick, bounds: bounds, height: plot.height) + plot.minY
                    Text(respiratoryValueText(tick) ?? "--")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: yAxisWidth - 6, alignment: .trailing)
                        .position(x: (yAxisWidth - 6) / 2, y: y)
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: plot.width, height: 1)
                        .position(x: plot.midX, y: y)
                }

                RespiratoryBaselineBandShape(points: points, bounds: bounds)
                    .fill(Color.teal.opacity(0.14))
                    .frame(width: plot.width, height: plot.height)
                    .offset(x: plot.minX, y: plot.minY)

                RespiratoryLineShape(points: points, bounds: bounds, valueKind: .baseline, connectsGaps: true)
                    .stroke(Color.teal.opacity(0.42), style: StrokeStyle(lineWidth: 1.4, dash: [5, 5]))
                    .frame(width: plot.width, height: plot.height)
                    .offset(x: plot.minX, y: plot.minY)

                RespiratoryLineShape(points: points, bounds: bounds, valueKind: .respiratoryRate, connectsGaps: false)
                    .stroke(Color.teal.gradient, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .frame(width: plot.width, height: plot.height)
                    .offset(x: plot.minX, y: plot.minY)

                if let selectedPoint, let selectedIndex = points.firstIndex(where: { $0.id == selectedPoint.id }) {
                    let x = respiratoryXPosition(index: selectedIndex, count: points.count, width: plot.width) + plot.minX
                    Rectangle()
                        .fill(Color.primary.opacity(0.13))
                        .frame(width: 1, height: plot.height)
                        .position(x: x, y: plot.midY)
                    if let value = selectedPoint.value {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 13, height: 13)
                            .overlay(
                                Circle().stroke(respiratoryRelationColor(selectedPoint.comparison), lineWidth: 3)
                            )
                            .position(x: x, y: respiratoryYPosition(value: value, bounds: bounds, height: plot.height) + plot.minY)
                    }
                }

                if timeframe == .week {
                    ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                        if let value = point.value {
                            Circle()
                                .fill(respiratoryRelationColor(point.comparison))
                                .frame(width: point.id == selectedPoint?.id ? 9 : 6, height: point.id == selectedPoint?.id ? 9 : 6)
                                .position(
                                    x: respiratoryXPosition(index: index, count: points.count, width: plot.width) + plot.minX,
                                    y: respiratoryYPosition(value: value, bounds: bounds, height: plot.height) + plot.minY
                                )
                                .accessibilityLabel("\(point.readoutLabel(for: timeframe)), respiratory rate \(respiratoryValueText(value) ?? "--") breaths per minute")
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
                            x: respiratoryXPosition(index: item.index, count: points.count, width: plot.width) + plot.minX,
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

    private var xTickItems: [RespiratoryXTick] {
        guard !points.isEmpty else { return [] }
        switch timeframe {
        case .week:
            return points.enumerated().map { index, point in
                RespiratoryXTick(index: index, label: point.axisLabel(for: timeframe), width: 34)
            }
        case .month:
            return SharedChartGeometry.evenlySpacedIndexes(count: points.count, maxCount: 5).map { index in
                RespiratoryXTick(index: index, label: points[index].axisLabel(for: timeframe), width: 34)
            }
        case .year:
            return points.enumerated().map { index, point in
                RespiratoryXTick(index: index, label: point.axisLabel(for: timeframe), width: 30)
            }
        case .day:
            return points.enumerated().map { index, point in
                RespiratoryXTick(index: index, label: point.axisLabel(for: timeframe), width: 34)
            }
        }
    }

    private func nearestPointID(to x: CGFloat, width: CGFloat) -> String? {
        guard let index = SharedChartGeometry.nearestIndex(to: x, width: width, count: points.count) else {
            return nil
        }
        return points[index].id
    }
}

private struct RespiratoryXTick: Identifiable {
    let index: Int
    let label: String
    let width: CGFloat

    var id: String { "\(index)-\(label)" }
}

private struct RespiratoryPatternPanel: View {
    let detail: RespiratoryRateDetail
    let timeframe: ScoreTimeframe

    private var displayPoints: [RespiratoryDisplayPoint] {
        RespiratoryDisplayPoint.points(from: detail.chart.points, timeframe: timeframe)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(patternTitle, systemImage: "square.grid.3x3")
                .font(.headline)

            if displayPoints.isEmpty {
                Text("No respiratory rate data was detected for this timeframe.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                patternDots
                RespiratoryLegend()
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
                    RespiratoryPatternDot(point: point, timeframe: timeframe)
                        .frame(maxWidth: .infinity)
                }
            }
        case .month:
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 7), spacing: 10) {
                ForEach(displayPoints) { point in
                    RespiratoryPatternDot(point: point, timeframe: timeframe)
                }
            }
        case .year:
            HStack(spacing: 8) {
                ForEach(displayPoints) { point in
                    RespiratoryPatternDot(point: point, timeframe: timeframe)
                        .frame(maxWidth: .infinity)
                }
            }
        case .day:
            EmptyView()
        }
    }
}

private struct RespiratoryContextPanel: View {
    let detail: RespiratoryRateDetail
    let timeframe: ScoreTimeframe

    private var displayPoints: [RespiratoryDisplayPoint] {
        RespiratoryDisplayPoint.points(from: detail.chart.points, timeframe: timeframe)
    }

    var body: some View {
        RespiratorySection(title: "Breathing Context", systemImage: "wind") {
            VStack(spacing: 10) {
                RespiratoryContextRow(title: "Interpretation", value: interpretationText)
                RespiratoryContextRow(title: elevatedTitle, value: countText(elevatedCount))
                RespiratoryContextRow(title: inRangeTitle, value: countText(inRangeCount))
                RespiratoryContextRow(title: lowerTitle, value: countText(lowerCount))
                if timeframe != .year {
                    RespiratoryContextRow(title: "Longest elevated streak", value: countText(longestElevatedStreak))
                }
                RespiratoryContextRow(title: missingTitle, value: countText(missingCount))
                RespiratoryContextRow(title: "Confidence", value: detail.summary.confidencePhase?.displayTitle ?? detail.summary.dataQuality?.displayTitle)
            }
        }
    }

    private var interpretationText: String? {
        if displayPoints.isEmpty || missingCount > displayPoints.count / 2 {
            return "Limited data"
        }
        if timeframe != .year, longestElevatedStreak >= 2 {
            return "Repeated elevated nights"
        }
        if elevatedCount > 0 {
            return timeframe == .year ? "Some elevated months" : "Some elevated nights"
        }
        switch detail.summary.baselineRelation {
        case "above": return "Elevated vs baseline"
        case "below": return "Lower than usual"
        case "normal": return "Within usual range"
        default: return "No baseline yet"
        }
    }

    private var elevatedTitle: String {
        timeframe == .year ? "Elevated months" : "Elevated nights"
    }

    private var inRangeTitle: String {
        timeframe == .year ? "In range months" : "In range nights"
    }

    private var lowerTitle: String {
        timeframe == .year ? "Lower months" : "Lower nights"
    }

    private var missingTitle: String {
        timeframe == .year ? "Missing months" : "Missing nights"
    }

    private var elevatedCount: Int {
        displayPoints.filter { $0.value != nil && $0.comparison == "above" }.count
    }

    private var inRangeCount: Int {
        displayPoints.filter { $0.value != nil && $0.comparison == "normal" }.count
    }

    private var lowerCount: Int {
        displayPoints.filter { $0.value != nil && $0.comparison == "below" }.count
    }

    private var missingCount: Int {
        displayPoints.filter { $0.value == nil }.count
    }

    private var longestElevatedStreak: Int {
        var longest = 0
        var current = 0
        for point in displayPoints {
            if point.value != nil && point.comparison == "above" {
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

private typealias RespiratoryMetricRow = MetricSummaryRow

private struct RespiratoryTrendRow: View {
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
            .foregroundStyle(respiratoryTrendColor(trend))
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

private struct RespiratoryPatternDot: View {
    let point: RespiratoryDisplayPoint
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
        .accessibilityLabel("\(point.readoutLabel(for: timeframe)), \(point.value == nil ? "Missing" : respiratoryRelationTitle(point.comparison))")
    }

    private func patternColor(for point: RespiratoryDisplayPoint) -> Color {
        point.value == nil ? respiratoryMissingColor : respiratoryRelationColor(point.comparison)
    }
}

private struct RespiratoryLegend: View {
    private let items: [(String, Color)] = [
        ("Lower", .blue),
        ("In range", .teal),
        ("Elevated", .orange),
        ("Missing", respiratoryMissingColor)
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

private struct RespiratorySection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        DetailSection(title: title, systemImage: systemImage, spacing: 12, cornerRadius: 18) {
            content
        }
    }
}

private typealias RespiratoryContextRow = MetricSummaryRow

private struct RespiratoryDisplayPoint: Identifiable {
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

    static func points(from rawPoints: [BaselineMetricChartPoint], timeframe: ScoreTimeframe) -> [RespiratoryDisplayPoint] {
        let today = ScoreDateFormatters.apiDate.string(from: Date())
        let elapsedPoints = rawPoints.filter { point in
            guard let date = point.date else { return false }
            return date <= today
        }

        guard timeframe == .year else {
            return elapsedPoints.map {
                RespiratoryDisplayPoint(
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
            return RespiratoryDisplayPoint(
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

private struct RespiratoryLineShape: Shape {
    let points: [RespiratoryDisplayPoint]
    let bounds: ClosedRange<Double>
    let valueKind: RespiratoryLineValueKind
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
                x: respiratoryXPosition(index: index, count: points.count, width: rect.width),
                y: respiratoryYPosition(value: value, bounds: bounds, height: rect.height)
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

private enum RespiratoryLineValueKind: Sendable {
    case respiratoryRate
    case baseline

    func value(from point: RespiratoryDisplayPoint) -> Double? {
        switch self {
        case .respiratoryRate: return point.value
        case .baseline: return point.baselineValue
        }
    }
}

private struct RespiratoryBaselineBandShape: Shape {
    let points: [RespiratoryDisplayPoint]
    let bounds: ClosedRange<Double>

    func path(in rect: CGRect) -> Path {
        let boundedPoints = points.enumerated().filter {
            $0.element.baselineLowerBound != nil && $0.element.baselineUpperBound != nil
        }
        guard boundedPoints.count >= 2 else { return Path() }

        var path = Path()
        for (position, item) in boundedPoints.enumerated() {
            let coordinate = CGPoint(
                x: respiratoryXPosition(index: item.offset, count: points.count, width: rect.width),
                y: respiratoryYPosition(value: item.element.baselineUpperBound ?? 0, bounds: bounds, height: rect.height)
            )
            if position == 0 {
                path.move(to: coordinate)
            } else {
                path.addLine(to: coordinate)
            }
        }
        for item in boundedPoints.reversed() {
            path.addLine(to: CGPoint(
                x: respiratoryXPosition(index: item.offset, count: points.count, width: rect.width),
                y: respiratoryYPosition(value: item.element.baselineLowerBound ?? 0, bounds: bounds, height: rect.height)
            ))
        }
        path.closeSubpath()
        return path
    }
}

private func respiratoryXPosition(index: Int, count: Int, width: CGFloat) -> CGFloat {
    SharedChartGeometry.xPosition(index: index, count: count, width: width)
}

private func respiratoryYPosition(value: Double, bounds: ClosedRange<Double>, height: CGFloat) -> CGFloat {
    let span = max(bounds.upperBound - bounds.lowerBound, 1)
    let ratio = (value - bounds.lowerBound) / span
    return height - (CGFloat(ratio) * height)
}

private func respiratoryValueText(_ value: Double?) -> String? {
    guard let value else { return nil }
    return String(format: "%.1f", value)
}

private func respiratoryBaselineRangeText(_ summary: BaselineMetricSummary) -> String? {
    metricHeroWholeRangeText(lower: summary.baselineLowerBound, upper: summary.baselineUpperBound, unit: "br/min")
}

private func respiratoryRelationTitle(_ relation: String?) -> String {
    switch relation {
    case "normal": return "In range"
    case "below": return "Lower"
    case "above": return "Elevated"
    default: return "No baseline"
    }
}

private func respiratoryRelationColor(_ relation: String?) -> Color {
    switch relation {
    case "normal": return .teal
    case "below": return .blue
    case "above": return .orange
    default: return .secondary
    }
}

private func respiratoryTrendColor(_ trend: String?) -> Color {
    switch trend {
    case "up": return .orange
    case "down": return .blue
    case "flat": return .secondary
    default: return .secondary
    }
}

private let respiratoryMissingColor = Color.secondary.opacity(0.35)

#Preview {
    NavigationStack {
        RespiratoryRateDetailView(client: DashboardAPIClient())
    }
}
