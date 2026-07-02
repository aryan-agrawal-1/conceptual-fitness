import SwiftUI

struct StepsDetailView: View {
    let client: DashboardAPIClient

    @State private var timeframe: ScoreTimeframe = .day
    @State private var selectedDate = Date()
    @State private var loadState: StepsDetailLoadState = .loading
    @State private var calendarSelection: ScoreCalendarSelection?

    private let dailyGoal = 10_000.0

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    timeframePicker
                    ScoreRangeNavigator(
                        timeframe: timeframe,
                        metricName: "Steps",
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
        .navigationTitle("Steps")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: loadKey) {
            await load()
        }
        .refreshable {
            await load()
        }
        .sheet(item: $calendarSelection) { selection in
            ScoreCalendarPicker(metricName: "Steps", selection: selection) { nextDate in
                selectedDate = nextDate
                calendarSelection = nil
            }
        }
    }

    private var timeframePicker: some View {
        Picker("Timeframe", selection: $timeframe) {
            ForEach(ScoreTimeframe.allCases) { item in
                Text(item.title).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Steps timeframe")
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
                Text("Could not load Steps")
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

    private func loadedContent(_ detail: StepsDetail) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            StepsSummaryPanel(detail: detail, timeframe: timeframe, dailyGoal: dailyGoal)
            StepsChartPanel(detail: detail, timeframe: timeframe, dailyGoal: dailyGoal)
            StepsPatternPanel(detail: detail, timeframe: timeframe, dailyGoal: dailyGoal)
            if timeframe != .day {
                StepsConsistencyPanel(detail: detail, timeframe: timeframe, dailyGoal: dailyGoal)
            }
            StepsExplanationPanel()
        }
    }

    @MainActor
    private func load() async {
        loadState = .loading
        do {
            loadState = .loaded(try await client.loadStepsDetail(date: selectedDate, timeframe: timeframe))
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

private enum StepsDetailLoadState {
    case loading
    case loaded(StepsDetail)
    case failed(String)
}

private struct StepsSummaryPanel: View {
    let detail: StepsDetail
    let timeframe: ScoreTimeframe
    let dailyGoal: Double

    private var dailyPoints: [StepsDailyPoint] {
        StepsDailyPoint.points(from: detail.chart.points, timeframe: timeframe)
    }

    private var rawDailyValues: [Double] {
        stepsValues(from: detail.chart.points)
    }

    private var periodTotal: Double {
        rawDailyValues.reduce(0, +)
    }

    private var selectedTotal: Double? {
        timeframe == .day ? detail.summary.primaryValue : periodTotal
    }

    private var averageDaily: Double? {
        detail.summary.primaryValue
    }

    private var goalTarget: Double {
        dailyGoal * Double(max(timeframe == .day ? 1 : rawDailyValues.count, 1))
    }

    private var goalProgress: Double {
        guard goalTarget > 0 else { return 0 }
        return min(max((selectedTotal ?? 0) / goalTarget, 0), 1.25)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(statusTitle)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(statusColor.opacity(0.16), in: Capsule())
                    .foregroundStyle(statusColor)
            }

            HStack(alignment: .center, spacing: 18) {
                StepsProgressRing(
                    value: selectedTotal,
                    target: goalTarget,
                    label: timeframe == .day ? "steps" : "total"
                )
                .frame(width: 118, height: 118)

                VStack(spacing: 9) {
                    StepsSummaryRow(title: primaryRowTitle, value: primaryRowValue, tint: .blue)
                    StepsSummaryRow(title: "Goal", value: "\(stepsText(goalTarget))", tint: .green)
                    StepsSummaryRow(title: "Remaining", value: remainingText, tint: remainingTint)
                    StepsTrendRow(trend: detail.summary.trend)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 20)
    }

    private var title: String {
        switch timeframe {
        case .day: return detail.summary.title ?? "Daily Steps"
        case .week: return "Weekly Steps"
        case .month: return "Monthly Steps"
        case .year: return "Yearly Steps"
        }
    }

    private var statusTitle: String {
        if goalProgress >= 1 {
            return "Goal met"
        }
        if detail.summary.dataQuality == "missing" {
            return "No data"
        }
        return "\(Int((goalProgress * 100).rounded()))% goal"
    }

    private var statusColor: Color {
        if goalProgress >= 1 { return .green }
        if detail.summary.dataQuality == "missing" { return .secondary }
        return .blue
    }

    private var primaryRowTitle: String {
        timeframe == .day ? "Today" : "Daily average"
    }

    private var primaryRowValue: String {
        if timeframe == .day {
            return stepsText(selectedTotal)
        }
        return stepsText(averageDaily)
    }

    private var remainingText: String {
        let remaining = goalTarget - (selectedTotal ?? 0)
        if remaining <= 0 {
            return "\(stepsText(abs(remaining))) over"
        }
        return stepsText(remaining)
    }

    private var remainingTint: Color {
        goalProgress >= 1 ? .green : .secondary
    }
}

private struct StepsProgressRing: View {
    let value: Double?
    let target: Double
    let label: String

    private var ratio: Double {
        guard target > 0 else { return 0 }
        return min(max((value ?? 0) / target, 0), 1)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.55), lineWidth: 12)
            Circle()
                .trim(from: 0, to: ratio)
                .stroke(Color.blue.gradient, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let value, target > 0, value > target {
                Circle()
                    .trim(from: 0, to: min((value - target) / target, 0.34))
                    .stroke(Color.green.opacity(0.78), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }

            VStack(spacing: 1) {
                Text(compactStepsText(value))
                    .font(.system(size: 29, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                Text(label)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("\(stepsText(value)) \(label)")
    }
}

private struct StepsChartPanel: View {
    let detail: StepsDetail
    let timeframe: ScoreTimeframe
    let dailyGoal: Double
    @State private var selectedID: String?

    private var dailyPoints: [StepsDailyPoint] {
        StepsDailyPoint.points(from: detail.chart.points, timeframe: timeframe)
    }

    private var hourlyPoints: [StepsHourlyPoint] {
        StepsHourlyPoint.points(from: detail.intraday.points)
    }

    private var selectedDailyPoint: StepsDailyPoint? {
        if let selectedID, let point = dailyPoints.first(where: { $0.id == selectedID }) {
            return point
        }
        return dailyPoints.last(where: { $0.value != nil })
    }

    private var selectedHourlyPoint: StepsHourlyPoint? {
        if let selectedID, let point = hourlyPoints.first(where: { $0.id == selectedID }) {
            return point
        }
        return hourlyPoints.max { ($0.value ?? 0) < ($1.value ?? 0) }
    }

    var body: some View {
        StepsSection(title: chartTitle, systemImage: "chart.bar.fill") {
            if timeframe == .day {
                if hourlyPoints.contains(where: { ($0.value ?? 0) > 0 }) {
                    StepsHourlyBarChart(points: hourlyPoints, selectedID: $selectedID)
                        .frame(height: 236)
                    if let selectedHourlyPoint {
                        StepsSelectedReadout(
                            title: selectedHourlyPoint.readoutLabel,
                            subtitle: "Hourly steps",
                            value: stepsText(selectedHourlyPoint.value)
                        )
                    }
                } else {
                    missingChartText
                }
            } else if dailyPoints.contains(where: { $0.value != nil }) {
                StepsDailyBarChart(
                    points: dailyPoints,
                    timeframe: timeframe,
                    dailyGoal: dailyGoal,
                    selectedID: $selectedID
                )
                .frame(height: timeframe == .year ? 224 : 236)
                if let selectedDailyPoint {
                    StepsSelectedReadout(
                        title: selectedDailyPoint.readoutLabel(for: timeframe),
                        subtitle: selectedDailyPoint.value ?? 0 >= dailyGoal ? "Goal met" : "Below goal",
                        value: stepsText(selectedDailyPoint.value)
                    )
                }
            } else {
                missingChartText
            }
        }
    }

    private var chartTitle: String {
        switch timeframe {
        case .day: return "Hourly Steps"
        case .week: return "Daily Steps"
        case .month: return "Daily Steps"
        case .year: return "Monthly Average"
        }
    }

    private var missingChartText: some View {
        Text("No step data was detected for this timeframe.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
    }
}

private struct StepsHourlyBarChart: View {
    let points: [StepsHourlyPoint]
    @Binding var selectedID: String?

    private var selectedPoint: StepsHourlyPoint? {
        if let selectedID, let point = points.first(where: { $0.id == selectedID }) {
            return point
        }
        return points.max { ($0.value ?? 0) < ($1.value ?? 0) }
    }

    private var maxValue: Double {
        max(points.compactMap(\.value).max() ?? 0, 100)
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
            let count = max(points.count, 1)
            let step = plot.width / CGFloat(count)
            let barWidth = max(4, min(14, step * 0.62))

            ZStack(alignment: .topLeading) {
                ForEach(tickValues, id: \.self) { tick in
                    let y = plot.minY + plot.height - CGFloat(tick / maxValue) * plot.height
                    Text(compactStepsText(tick))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: yAxisWidth - 6, alignment: .trailing)
                        .position(x: (yAxisWidth - 6) / 2, y: y)
                    if tick > 0 {
                        Rectangle()
                            .fill(Color.primary.opacity(0.08))
                            .frame(width: plot.width, height: 1)
                            .position(x: plot.midX, y: y)
                    }
                }

                ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                    let value = point.value ?? 0
                    let height = max(3, CGFloat(value / maxValue) * plot.height)
                    let x = plot.minX + CGFloat(index) * step + step / 2
                    let y = plot.maxY - height / 2
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.blue.opacity(0.76).gradient)
                        .frame(width: barWidth, height: height)
                        .position(x: x, y: y)
                        .accessibilityLabel("\(point.readoutLabel), \(stepsText(point.value))")
                }

                ForEach(hourTickIndexes, id: \.self) { index in
                    Text(points[index].axisLabel)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 36)
                        .position(
                            x: plot.minX + CGFloat(index) * step + step / 2,
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

    private var hourTickIndexes: [Int] {
        [0, 6, 12, 18, 23].filter { $0 < points.count }
    }

    private var tickValues: [Double] {
        [maxValue, maxValue / 2, 0]
    }

    private func nearestPointID(to x: CGFloat, width: CGFloat) -> String? {
        guard !points.isEmpty else { return nil }
        let step = width / CGFloat(points.count)
        let index = Int((x / step).rounded(.down))
        return points[min(max(index, 0), points.count - 1)].id
    }
}

private struct StepsDailyBarChart: View {
    let points: [StepsDailyPoint]
    let timeframe: ScoreTimeframe
    let dailyGoal: Double
    @Binding var selectedID: String?

    private var selectedPoint: StepsDailyPoint? {
        if let selectedID, let point = points.first(where: { $0.id == selectedID }) {
            return point
        }
        return points.last(where: { $0.value != nil })
    }

    private var rawMaxValue: Double {
        max(points.compactMap(\.value).max() ?? 0, dailyGoal, 100)
    }

    private var maxValue: Double {
        let base = rawMaxValue
        if abs(base - dailyGoal) < max(900, base * 0.12) {
            return base * 1.18
        }
        return base
    }

    private var tickValues: [Double] {
        let includesGoal = abs(maxValue - dailyGoal) >= max(900, maxValue * 0.12)
        return includesGoal ? [maxValue, dailyGoal, 0] : [maxValue, 0]
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
            let count = max(points.count, 1)
            let step = plot.width / CGFloat(count)
            let barWidth = max(5, min(timeframe == .year ? 18 : 16, step * 0.62))

            ZStack(alignment: .topLeading) {
                ForEach(tickValues, id: \.self) { tick in
                    let y = plot.maxY - CGFloat(tick / maxValue) * plot.height
                    Text(compactStepsText(tick))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: yAxisWidth - 6, alignment: .trailing)
                        .position(x: (yAxisWidth - 6) / 2, y: y)
                    if tick > 0 {
                        Rectangle()
                            .fill(Color.primary.opacity(0.08))
                            .frame(width: plot.width, height: 1)
                            .position(x: plot.midX, y: y)
                    }
                }

                ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                    let value = point.value ?? 0
                    let height = max(value > 0 ? 3 : 0, CGFloat(value / maxValue) * plot.height)
                    let x = plot.minX + CGFloat(index) * step + step / 2
                    let y = plot.maxY - height / 2
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.blue.opacity(0.76).gradient)
                        .frame(width: barWidth, height: height)
                        .position(x: x, y: y)
                        .accessibilityLabel("\(point.readoutLabel(for: timeframe)), \(stepsText(point.value))")
                }

                ForEach(xTickIndexes, id: \.self) { index in
                    Text(points[index].axisLabel(for: timeframe))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: timeframe == .year ? 30 : 36)
                        .position(
                            x: plot.minX + CGFloat(index) * step + step / 2,
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

    private var xTickIndexes: [Int] {
        guard !points.isEmpty else { return [] }
        switch timeframe {
        case .week:
            return Array(points.indices)
        case .month:
            return evenlySpacedIndexes(count: points.count, maxCount: 5)
        case .year:
            return Array(points.indices)
        case .day:
            return Array(points.indices)
        }
    }

    private func nearestPointID(to x: CGFloat, width: CGFloat) -> String? {
        guard !points.isEmpty else { return nil }
        let step = width / CGFloat(points.count)
        let index = Int((x / step).rounded(.down))
        return points[min(max(index, 0), points.count - 1)].id
    }
}

private struct StepsPatternPanel: View {
    let detail: StepsDetail
    let timeframe: ScoreTimeframe
    let dailyGoal: Double

    private var dailyPoints: [StepsDailyPoint] {
        StepsDailyPoint.points(from: detail.chart.points, timeframe: timeframe)
    }

    private var hourlyPoints: [StepsHourlyPoint] {
        StepsHourlyPoint.points(from: detail.intraday.points)
    }

    var body: some View {
        StepsSection(title: title, systemImage: "square.grid.3x3.fill") {
            switch timeframe {
            case .day:
                if hourlyPoints.contains(where: { ($0.value ?? 0) > 0 }) {
                    VStack(spacing: 10) {
                        ForEach(daySegments) { segment in
                            StepsDistributionRow(item: segment)
                        }
                    }
                } else {
                    emptyText
                }
            case .week:
                HStack(spacing: 9) {
                    ForEach(dailyPoints) { point in
                        StepsPatternDot(point: point, timeframe: timeframe, dailyGoal: dailyGoal)
                            .frame(maxWidth: .infinity)
                    }
                }
                StepsGoalLegend()
            case .month:
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 7), spacing: 10) {
                    ForEach(dailyPoints) { point in
                        StepsPatternDot(point: point, timeframe: timeframe, dailyGoal: dailyGoal)
                    }
                }
                StepsGoalLegend()
            case .year:
                HStack(spacing: 8) {
                    ForEach(dailyPoints) { point in
                        StepsPatternDot(point: point, timeframe: timeframe, dailyGoal: dailyGoal)
                            .frame(maxWidth: .infinity)
                    }
                }
                StepsGoalLegend()
            }
        }
    }

    private var title: String {
        switch timeframe {
        case .day: return "Movement Timeline"
        case .week: return "Week Pattern"
        case .month: return "Month Pattern"
        case .year: return "Seasonality"
        }
    }

    private var daySegments: [StepsDistributionItem] {
        let segments: [(String, String, ClosedRange<Int>)] = [
            ("Morning", "sunrise.fill", 0...11),
            ("Afternoon", "sun.max.fill", 12...16),
            ("Evening", "sunset.fill", 17...23)
        ]
        let total = max(hourlyPoints.reduce(0) { $0 + ($1.value ?? 0) }, 1)
        return segments.map { title, icon, hours in
            let value = hourlyPoints
                .filter { hours.contains($0.hour) }
                .reduce(0) { $0 + ($1.value ?? 0) }
            return StepsDistributionItem(
                title: title,
                systemImage: icon,
                value: value,
                ratio: value / total
            )
        }
    }

    private var emptyText: some View {
        Text("No hourly step data was detected for this day.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }
}

private struct StepsDistributionItem: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
    let value: Double
    let ratio: Double
}

private struct StepsDistributionRow: View {
    let item: StepsDistributionItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.systemImage)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.blue)
                .frame(width: 28, height: 28)
                .background(Color.blue.opacity(0.13), in: Circle())

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(stepsText(item.value))
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.08))
                        Capsule()
                            .fill(Color.blue.gradient)
                            .frame(width: proxy.size.width * min(max(item.ratio, 0), 1))
                    }
                }
                .frame(height: 6)
            }
        }
    }
}

private struct StepsPatternDot: View {
    let point: StepsDailyPoint
    let timeframe: ScoreTimeframe
    let dailyGoal: Double

    var body: some View {
        VStack(spacing: 7) {
            Circle()
                .fill(patternColor)
                .frame(width: timeframe == .month ? 11 : 13, height: timeframe == .month ? 11 : 13)
            Text(point.axisLabel(for: timeframe))
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .accessibilityLabel("\(point.readoutLabel(for: timeframe)), \(stepsText(point.value))")
    }

    private var patternColor: Color {
        guard let value = point.value else { return stepsMissingColor }
        if value >= dailyGoal { return .green }
        return .red
    }
}

private struct StepsGoalLegend: View {
    private let items: [(String, Color)] = [
        ("Goal met", .green),
        ("Goal not met", .red),
        ("Missing", stepsMissingColor)
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

private struct StepsConsistencyPanel: View {
    let detail: StepsDetail
    let timeframe: ScoreTimeframe
    let dailyGoal: Double

    private var dailyPoints: [StepsDailyPoint] {
        StepsDailyPoint.points(from: detail.chart.points, timeframe: timeframe)
    }

    private var rawDailyValues: [Double] {
        stepsValues(from: detail.chart.points)
    }

    private var periodTotal: Double {
        rawDailyValues.reduce(0, +)
    }

    var body: some View {
        StepsSection(title: "Goal & Consistency", systemImage: "checkmark.seal.fill") {
            VStack(spacing: 10) {
                StepsContextRow(title: totalTitle, value: stepsText(periodTotal))
                StepsContextRow(title: "Daily average", value: stepsText(detail.summary.primaryValue))
                StepsContextRow(title: "Goal days", value: "\(goalDays) / \(rawDailyValues.count)")
                StepsContextRow(title: "Best \(bestUnit)", value: bestValueText)
                StepsContextRow(title: "Previous period", value: previousText)
                if let validDays = detail.summary.validDays, let periodDays = detail.summary.periodDays {
                    StepsContextRow(title: "Recorded", value: "\(validDays) / \(periodDays) days")
                }
            }
        }
    }

    private var totalTitle: String {
        timeframe == .day ? "Total steps" : "Period total"
    }

    private var goalDays: Int {
        rawDailyValues.filter { $0 >= dailyGoal }.count
    }

    private var bestUnit: String {
        timeframe == .year ? "month" : "day"
    }

    private var bestValueText: String {
        guard let best = dailyPoints.max(by: { ($0.value ?? 0) < ($1.value ?? 0) }), let value = best.value else {
            return "--"
        }
        return "\(stepsText(value)) \(best.shortReadout(for: timeframe))"
    }

    private var previousText: String {
        guard let change = detail.summary.absoluteChange else {
            return "No prior data"
        }
        let prefix = change > 0 ? "+" : ""
        return "\(prefix)\(stepsText(change)) avg/day"
    }
}

private struct StepsExplanationPanel: View {
    var body: some View {
        Text("Steps show general daily movement. Use the pattern with workouts, distance, and recovery signals to judge whether activity was steady, light, or unusually concentrated.")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .lineSpacing(3)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(cornerRadius: 16)
    }
}

private struct StepsSelectedReadout: View {
    let title: String
    let subtitle: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                Text(subtitle)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(value)
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.top, 2)
    }
}

private struct StepsSummaryRow: View {
    let title: String
    let value: String
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
            Text(value)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
    }
}

private struct StepsTrendRow: View {
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
            .foregroundStyle(trendColor)
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

    private var trendColor: Color {
        switch trend {
        case "up": return .green
        case "down": return .orange
        case "flat": return .secondary
        default: return .secondary
        }
    }
}

private struct StepsContextRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .layoutPriority(1)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.bold))
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
    }
}

private struct StepsSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 20)
    }
}

private struct StepsHourlyPoint: Identifiable {
    let id: String
    let hour: Int
    let value: Double?
    let sourcePlatform: String?
    let sourceDevice: String?

    var axisLabel: String {
        String(format: "%02d", hour)
    }

    var readoutLabel: String {
        "\(String(format: "%02d:00", hour))-\(String(format: "%02d:00", (hour + 1) % 24))"
    }

    var segmentTitle: String {
        return "Hourly steps"
    }

    static func points(from rawPoints: [StepsIntradayPoint]) -> [StepsHourlyPoint] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: rawPoints) { point -> Int in
            guard let date = DashboardFormatters.parseBackendDateTime(point.bucketStart) else { return -1 }
            return calendar.component(.hour, from: date)
        }
        return (0..<24).map { hour in
            let items = grouped[hour] ?? []
            let total = items.reduce(0.0) { $0 + ($1.value ?? 0) }
            let source = items.compactMap(\.sourcePlatform).first
            let device = items.compactMap(\.sourceDevice).first
            return StepsHourlyPoint(
                id: "hour-\(hour)",
                hour: hour,
                value: items.isEmpty ? nil : total,
                sourcePlatform: source,
                sourceDevice: device
            )
        }
    }
}

private struct StepsDailyPoint: Identifiable {
    let id: String
    let date: Date?
    let monthStartDate: Date?
    let value: Double?

    func axisLabel(for timeframe: ScoreTimeframe) -> String {
        if timeframe == .year, let monthStartDate {
            return ScoreDateFormatters.month.string(from: monthStartDate)
        }
        guard let date else { return "--" }
        switch timeframe {
        case .day:
            return ScoreDateFormatters.weekday.string(from: date)
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
        guard let date else { return "Steps" }
        return timeframe == .week
            ? ScoreDateFormatters.weekdayDate.string(from: date)
            : ScoreDateFormatters.compactDate.string(from: date)
    }

    func shortReadout(for timeframe: ScoreTimeframe) -> String {
        if timeframe == .year, let monthStartDate {
            return ScoreDateFormatters.month.string(from: monthStartDate)
        }
        guard let date else { return "" }
        return timeframe == .week
            ? ScoreDateFormatters.weekday.string(from: date)
            : ScoreDateFormatters.compactDate.string(from: date)
    }

    static func points(from rawPoints: [BaselineMetricChartPoint], timeframe: ScoreTimeframe) -> [StepsDailyPoint] {
        let today = ScoreDateFormatters.calendar.startOfDay(for: Date())
        let daily = rawPoints.compactMap { point -> StepsDailyPoint? in
            guard let date = ScoreDateFormatters.apiDate.date(from: point.date ?? "") else { return nil }
            guard ScoreDateFormatters.calendar.startOfDay(for: date) <= today else { return nil }
            return StepsDailyPoint(
                id: point.date ?? point.id,
                date: date,
                monthStartDate: nil,
                value: point.value
            )
        }
        guard timeframe == .year else { return daily }

        let calendar = ScoreDateFormatters.calendar
        let grouped = Dictionary(grouping: daily.compactMap { point -> StepsDailyPoint? in
            guard let date = point.date else { return nil }
            let components = calendar.dateComponents([.year, .month], from: date)
            guard let month = calendar.date(from: components) else { return nil }
            return StepsDailyPoint(
                id: point.id,
                date: point.date,
                monthStartDate: month,
                value: point.value
            )
        }) { point in
            point.monthStartDate ?? point.date ?? Date.distantPast
        }

        return grouped.keys.sorted().map { month in
            let values = (grouped[month] ?? []).compactMap(\.value)
            return StepsDailyPoint(
                id: ScoreDateFormatters.apiDate.string(from: month),
                date: nil,
                monthStartDate: month,
                value: average(values)
            )
        }
    }
}

private func stepsText(_ value: Double?) -> String {
    guard let value else { return "--" }
    return stepsFormatter.string(from: NSNumber(value: Int(value.rounded()))) ?? "\(Int(value.rounded()))"
}

private func compactStepsText(_ value: Double?) -> String {
    guard let value else { return "--" }
    let absolute = abs(value)
    if absolute >= 1_000_000 {
        return String(format: "%.1fM", value / 1_000_000)
    }
    if absolute >= 10_000 {
        return "\(Int((value / 1_000).rounded()))k"
    }
    if absolute >= 1_000 {
        return String(format: "%.1fk", value / 1_000)
    }
    return "\(Int(value.rounded()))"
}

private func stepsValues(from rawPoints: [BaselineMetricChartPoint]) -> [Double] {
    let today = ScoreDateFormatters.calendar.startOfDay(for: Date())
    return rawPoints.compactMap { point in
        guard let date = ScoreDateFormatters.apiDate.date(from: point.date ?? "") else { return nil }
        guard ScoreDateFormatters.calendar.startOfDay(for: date) <= today else { return nil }
        return point.value
    }
}

private let stepsFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 0
    return formatter
}()

private let stepsMissingColor = Color.secondary.opacity(0.35)

private func average(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    return values.reduce(0, +) / Double(values.count)
}

private func evenlySpacedIndexes(count: Int, maxCount: Int) -> [Int] {
    guard count > 0 else { return [] }
    guard count > maxCount else { return Array(0..<count) }
    let step = Double(count - 1) / Double(maxCount - 1)
    return (0..<maxCount).map { Int((Double($0) * step).rounded()) }
}

#Preview {
    NavigationStack {
        StepsDetailView(client: DashboardAPIClient())
    }
}
