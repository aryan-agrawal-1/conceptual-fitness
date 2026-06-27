import SwiftUI

struct HRVDetailView: View {
    let client: DashboardAPIClient

    @State private var timeframe: ScoreTimeframe = .week
    @State private var selectedDate = Date()
    @State private var loadState: HRVDetailLoadState = .loading
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
                        metricName: "HRV",
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
        }
        .navigationTitle("HRV")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: loadKey) {
            await load()
        }
        .refreshable {
            await load()
        }
        .sheet(item: $calendarSelection) { selection in
            ScoreCalendarPicker(metricName: "HRV", selection: selection) { nextDate in
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
        .accessibilityLabel("HRV timeframe")
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
                Text("Could not load HRV")
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

    private func loadedContent(_ detail: HRVDetail) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HRVSummaryPanel(detail: detail, timeframe: timeframe)
            HRVExplanationPanel()
            HRVChartPanel(detail: detail, timeframe: timeframe)
            HRVPatternPanel(detail: detail, timeframe: timeframe)
        }
    }

    @MainActor
    private func load() async {
        loadState = .loading
        do {
            loadState = .loaded(try await client.loadHRVDetail(date: selectedDate, timeframe: timeframe))
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

private enum HRVDetailLoadState {
    case loading
    case loaded(HRVDetail)
    case failed(String)
}

private struct HRVSummaryPanel: View {
    let detail: HRVDetail
    let timeframe: ScoreTimeframe

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(detail.summary.title ?? timeframe.title)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(relationTitle(detail.summary.baselineRelation))
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(relationColor(detail.summary.baselineRelation).opacity(0.16), in: Capsule())
                    .foregroundStyle(relationColor(detail.summary.baselineRelation))
            }

            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(hrvWholeText(detail.summary.primaryValue) ?? "--")
                            .font(.system(size: 48, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.62)
                        Text("ms")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    Text(timeframe == .year ? "monthly avg" : "period avg")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Average HRV \(hrvWholeText(detail.summary.primaryValue) ?? "no value") milliseconds")

                VStack(spacing: 9) {
                    HRVMetricRow(title: "Baseline", value: baselineRangeText(detail.summary), tint: .blue)
                    HRVTrendRow(trend: detail.summary.trend)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 20)
    }
}

private struct HRVExplanationPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("What HRV Means", systemImage: "waveform.path.ecg")
                .font(.headline)
            Text("Heart rate variability is the tiny variation between heartbeats. It reflects how your autonomic nervous system balances stress and recovery.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Higher HRV is often associated with better recovery and fitness.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 20)
    }
}

private struct HRVChartPanel: View {
    let detail: HRVDetail
    let timeframe: ScoreTimeframe
    @State private var selectedID: String?

    private var displayPoints: [HRVDisplayPoint] {
        HRVDisplayPoint.points(from: detail.chart.points, timeframe: timeframe)
    }

    private var selectedPoint: HRVDisplayPoint? {
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
                HRVBaselineChart(points: displayPoints, timeframe: timeframe, selectedID: $selectedID)
                    .frame(height: 236)

                if let selectedPoint {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selectedPoint.readoutLabel(for: timeframe))
                                .font(.subheadline.weight(.bold))
                            Text(relationTitle(selectedPoint.comparison))
                                .font(.caption.weight(.bold))
                                .foregroundStyle(relationColor(selectedPoint.comparison))
                        }
                        Spacer()
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(selectedPoint.value?.clean ?? "--")
                                .font(.title3.weight(.bold))
                                .monospacedDigit()
                            Text("ms")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 2)
                }
            } else {
                Text("No HRV data was detected for this timeframe.")
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
        case .week: return "Nightly HRV"
        case .month: return "Daily HRV"
        case .year: return "Monthly HRV"
        case .day: return "HRV"
        }
    }
}

private struct HRVBaselineChart: View {
    let points: [HRVDisplayPoint]
    let timeframe: ScoreTimeframe
    @Binding var selectedID: String?

    private var valueBounds: ClosedRange<Double> {
        let values = points.flatMap { point -> [Double] in
            [point.value, point.baselineLowerBound, point.baselineUpperBound].compactMap { $0 }
        }
        guard let minValue = values.min(), let maxValue = values.max() else { return 0...1 }
        let span = max(maxValue - minValue, 8)
        let padding = span * 0.18
        return (minValue - padding)...(maxValue + padding)
    }

    private var tickValues: [Double] {
        let bounds = valueBounds
        return [bounds.upperBound, (bounds.lowerBound + bounds.upperBound) / 2, bounds.lowerBound]
    }

    private var selectedPoint: HRVDisplayPoint? {
        if let selectedID, let point = points.first(where: { $0.id == selectedID }) {
            return point
        }
        return points.last(where: { $0.value != nil })
    }

    var body: some View {
        GeometryReader { proxy in
            let yAxisWidth: CGFloat = 34
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
                    let y = yPosition(value: tick, bounds: bounds, height: plot.height) + plot.minY
                    Text(tick.clean)
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

                HRVBaselineBandShape(points: points, bounds: bounds)
                    .fill(Color.teal.opacity(0.14))
                    .frame(width: plot.width, height: plot.height)
                    .offset(x: plot.minX, y: plot.minY)

                HRVLineShape(points: points, bounds: bounds, valueKind: .baseline, connectsGaps: true)
                    .stroke(Color.teal.opacity(0.42), style: StrokeStyle(lineWidth: 1.4, dash: [5, 5]))
                    .frame(width: plot.width, height: plot.height)
                    .offset(x: plot.minX, y: plot.minY)

                HRVLineShape(points: points, bounds: bounds, valueKind: .hrv, connectsGaps: false)
                    .stroke(Color.blue.gradient, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .frame(width: plot.width, height: plot.height)
                    .offset(x: plot.minX, y: plot.minY)

                if let selectedPoint, let selectedIndex = points.firstIndex(where: { $0.id == selectedPoint.id }) {
                    let x = xPosition(index: selectedIndex, count: points.count, width: plot.width) + plot.minX
                    Rectangle()
                        .fill(Color.primary.opacity(0.13))
                        .frame(width: 1, height: plot.height)
                        .position(x: x, y: plot.midY)
                    if let value = selectedPoint.value {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 13, height: 13)
                            .overlay(
                                Circle().stroke(Color.blue, lineWidth: 3)
                            )
                            .position(x: x, y: yPosition(value: value, bounds: bounds, height: plot.height) + plot.minY)
                    }
                }

                if timeframe == .week {
                    ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                        if let value = point.value {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: point.id == selectedPoint?.id ? 9 : 6, height: point.id == selectedPoint?.id ? 9 : 6)
                                .position(
                                    x: xPosition(index: index, count: points.count, width: plot.width) + plot.minX,
                                    y: yPosition(value: value, bounds: bounds, height: plot.height) + plot.minY
                                )
                                .accessibilityLabel("\(point.readoutLabel(for: timeframe)), HRV \(value.clean) milliseconds")
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
                            x: xPosition(index: item.index, count: points.count, width: plot.width) + plot.minX,
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

    private var xTickItems: [HRVXTick] {
        guard !points.isEmpty else { return [] }
        switch timeframe {
        case .week:
            return points.enumerated().map { index, point in
                HRVXTick(index: index, label: point.axisLabel(for: timeframe), width: 34)
            }
        case .month:
            return evenlySpacedIndexes(count: points.count, maxCount: 5).map { index in
                HRVXTick(index: index, label: points[index].axisLabel(for: timeframe), width: 34)
            }
        case .year:
            return points.enumerated().map { index, point in
                HRVXTick(index: index, label: point.axisLabel(for: timeframe), width: 30)
            }
        case .day:
            return points.enumerated().map { index, point in
                HRVXTick(index: index, label: point.axisLabel(for: timeframe), width: 34)
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

private struct HRVXTick: Identifiable {
    let index: Int
    let label: String
    let width: CGFloat

    var id: String { "\(index)-\(label)" }
}

private func evenlySpacedIndexes(count: Int, maxCount: Int) -> [Int] {
    guard count > 0 else { return [] }
    guard count > maxCount else { return Array(0..<count) }
    let step = Double(count - 1) / Double(maxCount - 1)
    return (0..<maxCount).map { Int((Double($0) * step).rounded()) }
}

private struct HRVPatternPanel: View {
    let detail: HRVDetail
    let timeframe: ScoreTimeframe

    private var displayPoints: [HRVDisplayPoint] {
        HRVDisplayPoint.points(from: detail.chart.points, timeframe: timeframe)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(patternTitle, systemImage: "square.grid.3x3")
                .font(.headline)

            if displayPoints.isEmpty {
                Text("No HRV data was detected for this timeframe.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                patternDots
                HRVLegend()
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
                    HRVPatternDot(point: point, timeframe: timeframe)
                        .frame(maxWidth: .infinity)
                }
            }
        case .month:
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 7), spacing: 10) {
                ForEach(displayPoints) { point in
                    HRVPatternDot(point: point, timeframe: timeframe)
                }
            }
        case .year:
            HStack(spacing: 8) {
                ForEach(displayPoints) { point in
                    HRVPatternDot(point: point, timeframe: timeframe)
                        .frame(maxWidth: .infinity)
                }
            }
        case .day:
            HStack(spacing: 9) {
                ForEach(displayPoints) { point in
                    HRVPatternDot(point: point, timeframe: timeframe)
                }
            }
        }
    }
}

private struct HRVMetricRow: View {
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

private struct HRVTrendRow: View {
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
            .foregroundStyle(trendColor(trend))
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

private struct HRVPatternDot: View {
    let point: HRVDisplayPoint
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
        .accessibilityLabel("\(point.readoutLabel(for: timeframe)), \(point.value == nil ? "Missing" : relationTitle(point.comparison))")
    }

    private func patternColor(for point: HRVDisplayPoint) -> Color {
        point.value == nil ? missingColor : relationColor(point.comparison)
    }
}

private struct HRVLegend: View {
    private let items: [(String, Color)] = [
        ("Within", .blue),
        ("Below", .orange),
        ("Above", .purple),
        ("Missing", missingColor)
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

private struct HRVDisplayPoint: Identifiable {
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

    static func points(from rawPoints: [HRVChartPoint], timeframe: ScoreTimeframe) -> [HRVDisplayPoint] {
        let today = ScoreDateFormatters.apiDate.string(from: Date())
        let elapsedPoints = rawPoints.filter { point in
            guard let date = point.date else { return false }
            return date <= today
        }

        guard timeframe == .year else {
            return elapsedPoints.map {
                HRVDisplayPoint(
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
            return HRVDisplayPoint(
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

private struct HRVLineShape: Shape {
    let points: [HRVDisplayPoint]
    let bounds: ClosedRange<Double>
    let valueKind: HRVLineValueKind
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
                x: xPosition(index: index, count: points.count, width: rect.width),
                y: yPosition(value: value, bounds: bounds, height: rect.height)
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

private enum HRVLineValueKind: Sendable {
    case hrv
    case baseline

    func value(from point: HRVDisplayPoint) -> Double? {
        switch self {
        case .hrv: return point.value
        case .baseline: return point.baselineValue
        }
    }
}

private struct HRVBaselineBandShape: Shape {
    let points: [HRVDisplayPoint]
    let bounds: ClosedRange<Double>

    func path(in rect: CGRect) -> Path {
        let boundedPoints = points.enumerated().filter {
            $0.element.baselineLowerBound != nil && $0.element.baselineUpperBound != nil
        }
        guard boundedPoints.count >= 2 else { return Path() }

        var path = Path()
        for (position, item) in boundedPoints.enumerated() {
            let coordinate = CGPoint(
                x: xPosition(index: item.offset, count: points.count, width: rect.width),
                y: yPosition(value: item.element.baselineUpperBound ?? 0, bounds: bounds, height: rect.height)
            )
            if position == 0 {
                path.move(to: coordinate)
            } else {
                path.addLine(to: coordinate)
            }
        }
        for item in boundedPoints.reversed() {
            path.addLine(to: CGPoint(
                x: xPosition(index: item.offset, count: points.count, width: rect.width),
                y: yPosition(value: item.element.baselineLowerBound ?? 0, bounds: bounds, height: rect.height)
            ))
        }
        path.closeSubpath()
        return path
    }
}

private func xPosition(index: Int, count: Int, width: CGFloat) -> CGFloat {
    guard count > 1 else { return width / 2 }
    return CGFloat(index) / CGFloat(count - 1) * width
}

private func yPosition(value: Double, bounds: ClosedRange<Double>, height: CGFloat) -> CGFloat {
    let span = max(bounds.upperBound - bounds.lowerBound, 1)
    let ratio = (value - bounds.lowerBound) / span
    return height - (CGFloat(ratio) * height)
}

private func relationTitle(_ relation: String?) -> String {
    switch relation {
    case "normal": return "Within baseline"
    case "below": return "Below baseline"
    case "above": return "Above baseline"
    default: return "No baseline"
    }
}

private func relationColor(_ relation: String?) -> Color {
    switch relation {
    case "normal": return .blue
    case "below": return .orange
    case "above": return .purple
    default: return .secondary
    }
}

private let missingColor = Color.secondary.opacity(0.35)

private func hrvWholeText(_ value: Double?) -> String? {
    value.map { String(Int($0.rounded())) }
}

private func baselineRangeText(_ summary: HRVSummary) -> String? {
    guard let lower = summary.baselineLowerBound, let upper = summary.baselineUpperBound else { return nil }
    return "\(lower.clean)-\(upper.clean) ms"
}

private func trendColor(_ trend: String?) -> Color {
    switch trend {
    case "up": return .blue
    case "down": return .orange
    case "flat": return .secondary
    default: return .secondary
    }
}
