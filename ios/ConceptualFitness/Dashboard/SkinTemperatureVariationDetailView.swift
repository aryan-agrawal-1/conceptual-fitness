import SwiftUI

struct SkinTemperatureVariationDetailView: View {
    let client: DashboardAPIClient

    @State private var timeframe: ScoreTimeframe = .week
    @State private var selectedDate = Date()
    @State private var loadState: SkinTemperatureVariationLoadState = .loading
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
                        metricName: "Skin Temp Variation",
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
        .navigationTitle("Skin Temp Variation")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: loadKey) {
            await load()
        }
        .refreshable {
            await load()
        }
        .sheet(item: $calendarSelection) { selection in
            ScoreCalendarPicker(metricName: "Skin Temp Variation", selection: selection) { nextDate in
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
        .accessibilityLabel("Skin temperature variation timeframe")
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
                Text("Could not load Skin Temp Variation")
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

    private func loadedContent(_ detail: SkinTemperatureVariationDetail) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            SkinTempSummaryPanel(detail: detail, timeframe: timeframe)
            SkinTempExplanationPanel()
            SkinTempChartPanel(detail: detail, timeframe: timeframe)
            SkinTempPatternPanel(detail: detail, timeframe: timeframe)
            SkinTempContextPanel(detail: detail, timeframe: timeframe)
        }
    }

    @MainActor
    private func load() async {
        loadState = .loading
        do {
            loadState = .loaded(try await client.loadSkinTemperatureVariationDetail(date: selectedDate, timeframe: timeframe))
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

private enum SkinTemperatureVariationLoadState {
    case loading
    case loaded(SkinTemperatureVariationDetail)
    case failed(String)
}

private struct SkinTempSummaryPanel: View {
    let detail: SkinTemperatureVariationDetail
    let timeframe: ScoreTimeframe

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(detail.summary.title ?? titleFallback)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(skinTempRelationTitle(detail.summary.baselineRelation))
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(skinTempRelationColor(detail.summary.baselineRelation).opacity(0.16), in: Capsule())
                    .foregroundStyle(skinTempRelationColor(detail.summary.baselineRelation))
            }

            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(skinTempValueText(detail.summary.primaryValue) ?? "--")
                            .font(.system(size: 48, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.62)
                        Text("C")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    Text(timeframe == .year ? "monthly avg" : "period avg")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Average skin temperature variation \(skinTempValueText(detail.summary.primaryValue) ?? "no value") Celsius")

                VStack(spacing: 9) {
                    SkinTempMetricRow(title: "Baseline", value: skinTempBaselineRangeText(detail.summary), tint: .teal)
                    SkinTempTrendRow(trend: detail.summary.trend)
                    SkinTempMetricRow(title: "Recorded", value: recordedText, tint: .secondary)
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
        case .week: return "Weekly Temperature Variation"
        case .month: return "Monthly Temperature Variation"
        case .year: return "Yearly Temperature Variation"
        case .day: return "Temperature Variation"
        }
    }

    private var recordedText: String? {
        guard let valid = detail.summary.validDays, let period = detail.summary.periodDays else { return nil }
        return "\(valid) / \(period) nights"
    }
}

private struct SkinTempExplanationPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("What Skin Temp Variation Means", systemImage: "thermometer")
                .font(.headline)
            Text("Skin temperature variation shows how your overnight skin temperature differed from your usual pattern.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Sustained elevation can appear with illness, poor recovery, alcohol, late meals, travel, hormonal changes, or a warm sleep environment.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 20)
    }
}

private struct SkinTempChartPanel: View {
    let detail: SkinTemperatureVariationDetail
    let timeframe: ScoreTimeframe
    @State private var selectedID: String?

    private var displayPoints: [SkinTempDisplayPoint] {
        SkinTempDisplayPoint.points(from: detail.chart.points, timeframe: timeframe)
    }

    private var selectedPoint: SkinTempDisplayPoint? {
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
                SkinTempBaselineChart(points: displayPoints, timeframe: timeframe, selectedID: $selectedID)
                    .frame(height: 236)

                if let selectedPoint {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selectedPoint.readoutLabel(for: timeframe))
                                .font(.subheadline.weight(.bold))
                            Text(skinTempRelationTitle(selectedPoint.resolvedComparison))
                                .font(.caption.weight(.bold))
                                .foregroundStyle(skinTempRelationColor(selectedPoint.resolvedComparison))
                        }
                        Spacer()
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(skinTempValueText(selectedPoint.value) ?? "--")
                                .font(.title3.weight(.bold))
                                .monospacedDigit()
                            Text("C")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 2)
                }
            } else {
                Text("No skin temperature variation data was detected for this timeframe.")
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
        case .week: return "Nightly variation"
        case .month: return "Daily variation"
        case .year: return "Monthly variation"
        case .day: return "Temperature variation"
        }
    }
}

private struct SkinTempBaselineChart: View {
    let points: [SkinTempDisplayPoint]
    let timeframe: ScoreTimeframe
    @Binding var selectedID: String?

    private var valueBounds: ClosedRange<Double> {
        let values = points.flatMap { point -> [Double] in
            [point.value, point.normalLowerBound, point.normalUpperBound, point.baselineLineValue, 0].compactMap { $0 }
        }
        guard let minValue = values.min(), let maxValue = values.max() else { return -0.5...0.5 }
        let span = max(maxValue - minValue, 1.0)
        let padding = span * 0.18
        return (minValue - padding)...(maxValue + padding)
    }

    private var tickValues: [Double] {
        let bounds = valueBounds
        return [bounds.upperBound, (bounds.lowerBound + bounds.upperBound) / 2, bounds.lowerBound]
    }

    private var selectedPoint: SkinTempDisplayPoint? {
        if let selectedID, let point = points.first(where: { $0.id == selectedID }) {
            return point
        }
        return points.last(where: { $0.value != nil })
    }

    var body: some View {
        GeometryReader { proxy in
            let yAxisWidth: CGFloat = 42
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
                    let y = skinTempYPosition(value: tick, bounds: bounds, height: plot.height) + plot.minY
                    Text(skinTempValueText(tick) ?? "--")
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

                if bounds.contains(0) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.16))
                        .frame(width: plot.width, height: 1.2)
                        .position(x: plot.midX, y: skinTempYPosition(value: 0, bounds: bounds, height: plot.height) + plot.minY)
                }

                SkinTempBaselineBandShape(points: points, bounds: bounds)
                    .fill(Color.teal.opacity(0.15))
                    .frame(width: plot.width, height: plot.height)
                    .offset(x: plot.minX, y: plot.minY)

                SkinTempLineShape(points: points, bounds: bounds, valueKind: .baseline, connectsGaps: true)
                    .stroke(Color.teal.opacity(0.48), style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
                    .frame(width: plot.width, height: plot.height)
                    .offset(x: plot.minX, y: plot.minY)

                SkinTempLineShape(points: points, bounds: bounds, valueKind: .variation, connectsGaps: false)
                    .stroke(Color.orange.gradient, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .frame(width: plot.width, height: plot.height)
                    .offset(x: plot.minX, y: plot.minY)

                if let selectedPoint, let selectedIndex = points.firstIndex(where: { $0.id == selectedPoint.id }) {
                    let x = skinTempXPosition(index: selectedIndex, count: points.count, width: plot.width) + plot.minX
                    Rectangle()
                        .fill(Color.primary.opacity(0.13))
                        .frame(width: 1, height: plot.height)
                        .position(x: x, y: plot.midY)
                    if let value = selectedPoint.value {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 13, height: 13)
                            .overlay(
                                Circle().stroke(skinTempRelationColor(selectedPoint.resolvedComparison), lineWidth: 3)
                            )
                            .position(x: x, y: skinTempYPosition(value: value, bounds: bounds, height: plot.height) + plot.minY)
                    }
                }

                if timeframe == .week {
                    ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                        if let value = point.value {
                            Circle()
                                .fill(skinTempRelationColor(point.resolvedComparison))
                                .frame(width: point.id == selectedPoint?.id ? 9 : 6, height: point.id == selectedPoint?.id ? 9 : 6)
                                .position(
                                    x: skinTempXPosition(index: index, count: points.count, width: plot.width) + plot.minX,
                                    y: skinTempYPosition(value: value, bounds: bounds, height: plot.height) + plot.minY
                                )
                                .accessibilityLabel("\(point.readoutLabel(for: timeframe)), skin temperature variation \(skinTempValueText(value) ?? "--") Celsius")
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
                            x: skinTempXPosition(index: item.index, count: points.count, width: plot.width) + plot.minX,
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

    private var xTickItems: [SkinTempXTick] {
        guard !points.isEmpty else { return [] }
        switch timeframe {
        case .week:
            return points.enumerated().map { index, point in
                SkinTempXTick(index: index, label: point.axisLabel(for: timeframe), width: 34)
            }
        case .month:
            return skinTempEvenlySpacedIndexes(count: points.count, maxCount: 5).map { index in
                SkinTempXTick(index: index, label: points[index].axisLabel(for: timeframe), width: 34)
            }
        case .year:
            return points.enumerated().map { index, point in
                SkinTempXTick(index: index, label: point.axisLabel(for: timeframe), width: 30)
            }
        case .day:
            return points.enumerated().map { index, point in
                SkinTempXTick(index: index, label: point.axisLabel(for: timeframe), width: 34)
            }
        }
    }

    private func nearestPointID(to x: CGFloat, width: CGFloat) -> String? {
        guard !points.isEmpty else { return nil }
        guard points.count > 1 else { return points[0].id }
        let step = width / CGFloat(points.count - 1)
        let index = Int((x / step).rounded())
        return points[min(max(index, 0), points.count - 1)].id
    }
}

private struct SkinTempPatternPanel: View {
    let detail: SkinTemperatureVariationDetail
    let timeframe: ScoreTimeframe

    private var displayPoints: [SkinTempDisplayPoint] {
        SkinTempDisplayPoint.points(from: detail.chart.points, timeframe: timeframe)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(patternTitle, systemImage: "square.grid.3x3")
                .font(.headline)

            if displayPoints.isEmpty {
                Text("No skin temperature variation data was detected for this timeframe.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                patternDots
                SkinTempLegend()
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
                    SkinTempPatternDot(point: point, timeframe: timeframe)
                        .frame(maxWidth: .infinity)
                }
            }
        case .month:
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 7), spacing: 10) {
                ForEach(displayPoints) { point in
                    SkinTempPatternDot(point: point, timeframe: timeframe)
                }
            }
        case .year:
            HStack(spacing: 8) {
                ForEach(displayPoints) { point in
                    SkinTempPatternDot(point: point, timeframe: timeframe)
                        .frame(maxWidth: .infinity)
                }
            }
        case .day:
            EmptyView()
        }
    }
}

private struct SkinTempContextPanel: View {
    let detail: SkinTemperatureVariationDetail
    let timeframe: ScoreTimeframe

    private var displayPoints: [SkinTempDisplayPoint] {
        SkinTempDisplayPoint.points(from: detail.chart.points, timeframe: timeframe)
    }

    var body: some View {
        SkinTempSection(title: "Temperature Context", systemImage: "thermometer.medium") {
            VStack(spacing: 10) {
                SkinTempContextRow(title: "Interpretation", value: interpretationText)
                if timeframe == .year {
                    SkinTempContextRow(title: "Elevated months", value: countText(elevatedCount))
                    SkinTempContextRow(title: "Most elevated month", value: mostElevatedText)
                    SkinTempContextRow(title: "In range months", value: countText(normalCount))
                    SkinTempContextRow(title: "Lower months", value: countText(lowerCount))
                    SkinTempContextRow(title: "Missing months", value: countText(missingCount))
                } else {
                    SkinTempContextRow(title: "Elevated nights", value: countText(elevatedCount))
                    SkinTempContextRow(title: "Longest elevated streak", value: countText(longestElevatedStreak))
                    SkinTempContextRow(title: "In range nights", value: countText(normalCount))
                    SkinTempContextRow(title: "Lower nights", value: countText(lowerCount))
                    SkinTempContextRow(title: "Missing nights", value: countText(missingCount))
                }
                SkinTempContextRow(title: "Confidence", value: detail.summary.confidencePhase?.displayTitle ?? detail.summary.dataQuality?.displayTitle)
            }
        }
    }

    private var interpretationText: String? {
        if missingCount > displayPoints.count / 2 {
            return "Limited data"
        }
        if timeframe != .year, longestElevatedStreak >= 2 {
            return "Persistent elevation"
        }
        switch detail.summary.baselineRelation {
        case "above": return timeframe == .year ? "Warmer than usual" : "Elevated vs usual"
        case "below": return "Lower than usual"
        case "normal": return "Within usual range"
        default:
            if elevatedCount > 0 { return "Some elevated nights" }
            return nil
        }
    }

    private var elevatedCount: Int {
        displayPoints.filter { $0.value != nil && $0.resolvedComparison == "above" }.count
    }

    private var normalCount: Int {
        displayPoints.filter { $0.value != nil && $0.resolvedComparison == "normal" }.count
    }

    private var lowerCount: Int {
        displayPoints.filter { $0.value != nil && $0.resolvedComparison == "below" }.count
    }

    private var missingCount: Int {
        displayPoints.filter { $0.value == nil }.count
    }

    private var longestElevatedStreak: Int {
        var longest = 0
        var current = 0
        for point in displayPoints {
            if point.value != nil && point.resolvedComparison == "above" {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }

    private var mostElevatedText: String? {
        guard let point = displayPoints.compactMap({ point -> SkinTempDisplayPoint? in
            point.value == nil ? nil : point
        }).max(by: { ($0.value ?? 0) < ($1.value ?? 0) }) else {
            return nil
        }
        return "\(point.axisLabel(for: .year)) \(skinTempValueText(point.value) ?? "--") C"
    }

    private func countText(_ value: Int) -> String {
        "\(value)"
    }
}

private struct SkinTempMetricRow: View {
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

private struct SkinTempTrendRow: View {
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
            .foregroundStyle(skinTempTrendColor(trend))
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

private struct SkinTempPatternDot: View {
    let point: SkinTempDisplayPoint
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
        .accessibilityLabel("\(point.readoutLabel(for: timeframe)), \(point.value == nil ? "Missing" : skinTempRelationTitle(point.resolvedComparison))")
    }

    private func patternColor(for point: SkinTempDisplayPoint) -> Color {
        point.value == nil ? skinTempMissingColor : skinTempRelationColor(point.resolvedComparison)
    }
}

private struct SkinTempLegend: View {
    private let items: [(String, Color)] = [
        ("Lower", .cyan),
        ("In range", .teal),
        ("Elevated", .orange),
        ("Missing", skinTempMissingColor)
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

private struct SkinTempSection<Content: View>: View {
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

private struct SkinTempContextRow: View {
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

private struct SkinTempDisplayPoint: Identifiable {
    let id: String
    let date: String
    let value: Double?
    let baselineValue: Double?
    let baselineLowerBound: Double?
    let baselineUpperBound: Double?
    let comparison: String?
    let sampleCount: Int

    var baselineLineValue: Double? {
        baselineValue ?? 0
    }

    var normalLowerBound: Double? {
        baselineLowerBound ?? -0.3
    }

    var normalUpperBound: Double? {
        baselineUpperBound ?? 0.3
    }

    var resolvedComparison: String {
        if comparison == "normal" || comparison == "above" || comparison == "below" {
            return comparison ?? "unknown"
        }
        guard let value, let lower = normalLowerBound, let upper = normalUpperBound else {
            return "unknown"
        }
        if value < lower { return "below" }
        if value > upper { return "above" }
        return "normal"
    }

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

    static func points(from rawPoints: [BaselineMetricChartPoint], timeframe: ScoreTimeframe) -> [SkinTempDisplayPoint] {
        let today = ScoreDateFormatters.apiDate.string(from: Date())
        let elapsedPoints = rawPoints.filter { point in
            guard let date = point.date else { return false }
            return date <= today
        }

        guard timeframe == .year else {
            return elapsedPoints.map {
                SkinTempDisplayPoint(
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
            return SkinTempDisplayPoint(
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

private struct SkinTempLineShape: Shape {
    let points: [SkinTempDisplayPoint]
    let bounds: ClosedRange<Double>
    let valueKind: SkinTempLineValueKind
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
                x: skinTempXPosition(index: index, count: points.count, width: rect.width),
                y: skinTempYPosition(value: value, bounds: bounds, height: rect.height)
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

private enum SkinTempLineValueKind: Sendable {
    case variation
    case baseline

    func value(from point: SkinTempDisplayPoint) -> Double? {
        switch self {
        case .variation: return point.value
        case .baseline: return point.baselineLineValue
        }
    }
}

private struct SkinTempBaselineBandShape: Shape {
    let points: [SkinTempDisplayPoint]
    let bounds: ClosedRange<Double>

    func path(in rect: CGRect) -> Path {
        let boundedPoints = points.enumerated().filter {
            $0.element.normalLowerBound != nil && $0.element.normalUpperBound != nil
        }
        guard boundedPoints.count >= 2 else { return Path() }

        var path = Path()
        for (position, item) in boundedPoints.enumerated() {
            let coordinate = CGPoint(
                x: skinTempXPosition(index: item.offset, count: points.count, width: rect.width),
                y: skinTempYPosition(value: item.element.normalUpperBound ?? 0, bounds: bounds, height: rect.height)
            )
            if position == 0 {
                path.move(to: coordinate)
            } else {
                path.addLine(to: coordinate)
            }
        }
        for item in boundedPoints.reversed() {
            path.addLine(to: CGPoint(
                x: skinTempXPosition(index: item.offset, count: points.count, width: rect.width),
                y: skinTempYPosition(value: item.element.normalLowerBound ?? 0, bounds: bounds, height: rect.height)
            ))
        }
        path.closeSubpath()
        return path
    }
}

private struct SkinTempXTick: Identifiable {
    let index: Int
    let label: String
    let width: CGFloat

    var id: String { "\(index)-\(label)" }
}

private func skinTempEvenlySpacedIndexes(count: Int, maxCount: Int) -> [Int] {
    guard count > 0 else { return [] }
    guard count > maxCount else { return Array(0..<count) }
    let step = Double(count - 1) / Double(maxCount - 1)
    return (0..<maxCount).map { Int((Double($0) * step).rounded()) }
}

private func skinTempXPosition(index: Int, count: Int, width: CGFloat) -> CGFloat {
    guard count > 1 else { return width / 2 }
    return CGFloat(index) / CGFloat(count - 1) * width
}

private func skinTempYPosition(value: Double, bounds: ClosedRange<Double>, height: CGFloat) -> CGFloat {
    let span = max(bounds.upperBound - bounds.lowerBound, 0.1)
    let ratio = (value - bounds.lowerBound) / span
    return height - (CGFloat(ratio) * height)
}

private func skinTempValueText(_ value: Double?) -> String? {
    guard let value else { return nil }
    if abs(value) < 0.05 {
        return "0.0"
    }
    return "\(value > 0 ? "+" : "")\(String(format: "%.1f", value))"
}

private func skinTempRelationTitle(_ relation: String?) -> String {
    switch relation {
    case "normal": return "In range"
    case "below": return "Lower"
    case "above": return "Elevated"
    default: return "No baseline"
    }
}

private func skinTempRelationColor(_ relation: String?) -> Color {
    switch relation {
    case "normal": return .teal
    case "below": return .cyan
    case "above": return .orange
    default: return .secondary
    }
}

private let skinTempMissingColor = Color.secondary.opacity(0.35)

private func skinTempBaselineRangeText(_ summary: BaselineMetricSummary) -> String? {
    let lower = summary.baselineLowerBound ?? -0.3
    let upper = summary.baselineUpperBound ?? 0.3
    return "\(skinTempValueText(lower) ?? "--") to \(skinTempValueText(upper) ?? "--") C"
}

private func skinTempTrendColor(_ trend: String?) -> Color {
    switch trend {
    case "up": return .orange
    case "down": return .cyan
    case "flat": return .secondary
    default: return .secondary
    }
}

#Preview {
    NavigationStack {
        SkinTemperatureVariationDetailView(client: DashboardAPIClient())
    }
}
