import SwiftUI

struct VO2MaxDetailView: View {
    let client: DashboardAPIClient

    @State private var timeframe: ScoreTimeframe = .year
    @State private var selectedDate = Date()
    @State private var loadState: VO2MaxDetailLoadState
    @State private var calendarSelection: ScoreCalendarSelection?

    private let timeframes: [ScoreTimeframe] = [.week, .month, .year]
    private let loadsLiveData: Bool
    private let usesPreviewData: Bool

    init(client: DashboardAPIClient, previewDetail: VO2MaxMetricDetail? = nil) {
        self.client = client
        self.loadsLiveData = previewDetail == nil
        self.usesPreviewData = previewDetail != nil
        _selectedDate = State(initialValue: previewDetail == nil ? Date() : VO2PreviewData.anchorDate)
        _loadState = State(initialValue: previewDetail.map(VO2MaxDetailLoadState.loaded) ?? .loading)
    }

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    timeframePicker
                    ScoreRangeNavigator(
                        timeframe: timeframe,
                        metricName: "VO2 Max",
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
        .navigationTitle("VO2 Max")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: loadKey) {
            if usesPreviewData {
                loadState = .loaded(VO2PreviewData.detail(for: timeframe))
                return
            }
            guard loadsLiveData else { return }
            await load()
        }
        .refreshable {
            if usesPreviewData {
                loadState = .loaded(VO2PreviewData.detail(for: timeframe))
                return
            }
            guard loadsLiveData else { return }
            await load()
        }
        .sheet(item: $calendarSelection) { selection in
            ScoreCalendarPicker(metricName: "VO2 Max", selection: selection) { nextDate in
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
        .accessibilityLabel("VO2 Max timeframe")
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
                Text("Could not load VO2 Max")
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

    private func loadedContent(_ detail: VO2MaxMetricDetail) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VO2SummaryPanel(detail: detail, timeframe: timeframe)
            VO2ChartPanel(detail: detail, timeframe: timeframe)
            VO2EstimateContextPanel(detail: detail, timeframe: timeframe)
            VO2HowToPanel(hasEstimate: detail.current?.value != nil || detail.summary.latestValue != nil)
            VO2ExplanationPanel()
        }
    }

    @MainActor
    private func load() async {
        loadState = .loading
        do {
            loadState = .loaded(try await client.loadVO2MaxDetail(date: selectedDate, timeframe: timeframe))
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

private enum VO2MaxDetailLoadState {
    case loading
    case loaded(VO2MaxMetricDetail)
    case failed(String)
}

private struct VO2SummaryPanel: View {
    let detail: VO2MaxMetricDetail
    let timeframe: ScoreTimeframe

    private var points: [VO2DisplayPoint] {
        VO2DisplayPoint.points(from: detail.chart.points, timeframe: timeframe)
    }

    private var estimatePoints: [VO2DisplayPoint] {
        points.filter { $0.value != nil }
    }

    private var latestValue: Double? {
        detail.current?.value ?? detail.summary.latestValue
    }

    private var latestDate: String? {
        detail.current?.date ?? estimatePoints.last?.date
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

            if latestValue == nil {
                VO2EmptyHero()
            } else {
                HStack(alignment: .center, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(vo2ValueText(latestValue) ?? "--")
                                .font(.system(size: 48, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.62)
                            Text("ml/kg/min")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .minimumScaleFactor(0.72)
                        }
                        Text(latestDate.map { "Latest estimate • \(ScoreDateFormatters.shortDateLabel(from: $0))" } ?? "Latest estimate")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Latest VO2 Max \(vo2ValueText(latestValue) ?? "no value") milliliters per kilogram per minute")

                    VStack(spacing: 9) {
                        VO2SummaryRow(title: "Change", value: changeText, tint: changeColor)
                        VO2SummaryRow(title: "Best", value: bestText, tint: .green)
                        VO2TrendRow(trend: trend)
                        VO2SummaryRow(title: "Recorded", value: recordedText, tint: .secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 20)
    }

    private var title: String {
        switch timeframe {
        case .week: return "Recent VO2 Max"
        case .month: return "Monthly VO2 Max"
        case .year: return "Yearly VO2 Max"
        case .day: return "VO2 Max"
        }
    }

    private var trend: String? {
        detail.summary.trend ?? detail.trend.direction
    }

    private var statusTitle: String {
        guard latestValue != nil else { return "No estimate" }
        switch trend {
        case "up": return "Improving"
        case "down": return "Declining"
        case "flat": return "Stable"
        default: return "Estimate"
        }
    }

    private var statusColor: Color {
        guard latestValue != nil else { return .secondary }
        switch trend {
        case "up": return .green
        case "down": return .orange
        case "flat": return .blue
        default: return .secondary
        }
    }

    private var bestText: String? {
        estimatePoints.compactMap(\.value).max().map { "\($0.clean)" }
    }

    private var recordedText: String? {
        let count = estimatePoints.count
        switch timeframe {
        case .week: return "\(count) this week"
        case .month: return "\(count) this month"
        case .year: return "\(count) months"
        case .day: return "\(count)"
        }
    }

    private var changeText: String? {
        if let latestChange {
            return vo2SignedText(latestChange)
        }
        guard let absoluteChange = detail.summary.absoluteChange else { return nil }
        return vo2SignedText(absoluteChange)
    }

    private var latestChange: Double? {
        let values = estimatePoints.compactMap(\.value)
        guard values.count >= 2, let latest = values.last else { return nil }
        return latest - values[values.count - 2]
    }

    private var changeColor: Color {
        guard let change = latestChange ?? detail.summary.absoluteChange else { return .secondary }
        if change > 0.05 { return .green }
        if change < -0.05 { return .orange }
        return .secondary
    }
}

private struct VO2EmptyHero: View {
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "figure.run")
                .font(.title2.weight(.bold))
                .foregroundStyle(.green)
                .frame(width: 44, height: 44)
                .background(Color.green.opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 8) {
                Text("No VO2 Max estimate yet")
                    .font(.title3.weight(.bold))
                Text("VO2 Max usually needs eligible outdoor cardio workouts with heart-rate and motion data before an estimate appears.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct VO2ChartPanel: View {
    let detail: VO2MaxMetricDetail
    let timeframe: ScoreTimeframe
    @State private var selectedID: String?

    private var displayPoints: [VO2DisplayPoint] {
        VO2DisplayPoint.points(from: detail.chart.points, timeframe: timeframe)
    }

    private var estimatePoints: [VO2DisplayPoint] {
        displayPoints.filter { $0.value != nil }
    }

    private var selectedPoint: VO2DisplayPoint? {
        if let selectedID, let point = displayPoints.first(where: { $0.id == selectedID }) {
            return point
        }
        return displayPoints.last(where: { $0.value != nil })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(chartTitle, systemImage: "chart.xyaxis.line")
                .font(.headline)

            if estimatePoints.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "figure.walk.motion")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text("No VO2 Max estimates in this range.")
                        .font(.subheadline.weight(.semibold))
                    Text("Record an eligible outdoor walk, run, or hike with heart-rate data to generate estimates.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
            } else {
                VO2EstimateChart(points: displayPoints, timeframe: timeframe, selectedID: $selectedID)
                    .frame(height: 236)

                if let selectedPoint {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selectedPoint.readoutLabel(for: timeframe))
                                .font(.subheadline.weight(.bold))
                            Text(selectedPoint.sampleCount > 1 ? "\(selectedPoint.sampleCount) estimates" : "Estimate")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(vo2ValueText(selectedPoint.value) ?? "--")
                                .font(.title3.weight(.bold))
                                .monospacedDigit()
                            Text("ml/kg/min")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 20)
    }

    private var chartTitle: String {
        switch timeframe {
        case .week: return "This Week's Estimates"
        case .month: return "Monthly Estimates"
        case .year: return "12-Month Trend"
        case .day: return "VO2 Max"
        }
    }
}

private struct VO2EstimateContextPanel: View {
    let detail: VO2MaxMetricDetail
    let timeframe: ScoreTimeframe

    private var points: [VO2DisplayPoint] {
        VO2DisplayPoint.points(from: detail.chart.points, timeframe: timeframe)
    }

    private var estimatePoints: [VO2DisplayPoint] {
        points.filter { $0.value != nil }
    }

    var body: some View {
        VO2Section(title: "Estimate Context", systemImage: "waveform.path.ecg.rectangle") {
            VStack(alignment: .leading, spacing: 12) {
                Text(contextText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 10) {
                    VO2ContextRow(title: "Latest", value: latestText)
                    VO2ContextRow(title: "Best in range", value: bestText)
                    VO2ContextRow(title: "Estimates", value: estimateCountText)
                    VO2ContextRow(title: "Coverage", value: coverageText)
                    VO2ContextRow(title: "Confidence", value: detail.summary.dataQuality?.displayTitle)
                }
            }
        }
    }

    private var contextText: String {
        if estimatePoints.isEmpty {
            return "VO2 Max is estimated from specific workouts, so missing days are normal. The useful signal is whether estimates appear over time and move directionally."
        }
        switch timeframe {
        case .week:
            return "A week view is mainly useful for checking whether a recent eligible workout produced an estimate."
        case .month:
            return "Month-to-month movement is more useful than day-to-day noise because VO2 Max usually changes slowly."
        case .year:
            return "The yearly view is the clearest way to judge whether aerobic fitness is improving, stable, or drifting down."
        case .day:
            return "VO2 Max is not usually a daily measurement."
        }
    }

    private var latestText: String? {
        guard let value = detail.current?.value ?? detail.summary.latestValue else { return nil }
        if let date = detail.current?.date ?? estimatePoints.last?.date {
            return "\(value.clean) on \(ScoreDateFormatters.shortDateLabel(from: date))"
        }
        return value.clean
    }

    private var bestText: String? {
        estimatePoints.compactMap(\.value).max().map(\.clean)
    }

    private var estimateCountText: String {
        "\(estimatePoints.count)"
    }

    private var coverageText: String? {
        guard let valid = detail.coverage.validDays, let expected = detail.coverage.expectedDays else { return nil }
        return "\(valid) / \(expected) days"
    }
}

private struct VO2HowToPanel: View {
    let hasEstimate: Bool

    var body: some View {
        VO2Section(title: hasEstimate ? "Keep Estimates Current" : "How To Get An Estimate", systemImage: "figure.run") {
            VStack(spacing: 10) {
                VO2GuidanceRow(icon: "figure.walk", title: "Use eligible outdoor cardio", text: "Outdoor walks, runs, or hikes are the workouts most likely to produce estimates.")
                VO2GuidanceRow(icon: "heart.fill", title: "Wear heart-rate tracking", text: "The estimate needs heart-rate and motion data from the workout.")
                VO2GuidanceRow(icon: "calendar", title: "Look for trend, not noise", text: "VO2 Max changes slowly, so several estimates over weeks or months matter more than one reading.")
            }
        }
    }
}

private struct VO2ExplanationPanel: View {
    var body: some View {
        VO2Section(title: "What VO2 Max Means", systemImage: "lungs.fill") {
            VStack(alignment: .leading, spacing: 10) {
                Text("VO2 Max estimates the maximum oxygen your body can use during hard exercise. Higher values generally reflect stronger cardiorespiratory fitness.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Wearable estimates are best used as a long-term direction, not as a lab-grade measurement or a daily readiness signal.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct VO2EstimateChart: View {
    let points: [VO2DisplayPoint]
    let timeframe: ScoreTimeframe
    @Binding var selectedID: String?

    private var valueBounds: ClosedRange<Double> {
        let values = points.compactMap(\.value)
        guard let minValue = values.min(), let maxValue = values.max() else { return 0...1 }
        let span = max(maxValue - minValue, 6)
        let padding = span * 0.2
        return (minValue - padding)...(maxValue + padding)
    }

    private var tickValues: [Double] {
        let bounds = valueBounds
        return [bounds.upperBound, (bounds.lowerBound + bounds.upperBound) / 2, bounds.lowerBound]
    }

    private var selectedPoint: VO2DisplayPoint? {
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
                    let y = vo2YPosition(value: tick, bounds: bounds, height: plot.height) + plot.minY
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

                VO2LineShape(points: points, bounds: bounds)
                    .stroke(Color.green.gradient, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .frame(width: plot.width, height: plot.height)
                    .offset(x: plot.minX, y: plot.minY)

                ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                    if let value = point.value {
                        Circle()
                            .fill(point.id == selectedPoint?.id ? Color.white : Color.green)
                            .frame(width: point.id == selectedPoint?.id ? 13 : 8, height: point.id == selectedPoint?.id ? 13 : 8)
                            .overlay(
                                Circle().stroke(Color.green, lineWidth: point.id == selectedPoint?.id ? 3 : 0)
                            )
                            .position(
                                x: vo2XPosition(index: index, count: points.count, width: plot.width) + plot.minX,
                                y: vo2YPosition(value: value, bounds: bounds, height: plot.height) + plot.minY
                            )
                            .accessibilityLabel("\(point.readoutLabel(for: timeframe)), VO2 Max \(value.clean)")
                    }
                }

                if let selectedPoint, let selectedIndex = points.firstIndex(where: { $0.id == selectedPoint.id }) {
                    let x = vo2XPosition(index: selectedIndex, count: points.count, width: plot.width) + plot.minX
                    Rectangle()
                        .fill(Color.primary.opacity(0.13))
                        .frame(width: 1, height: plot.height)
                        .position(x: x, y: plot.midY)
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
                            x: vo2XPosition(index: item.index, count: points.count, width: plot.width) + plot.minX,
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

    private var xTickItems: [VO2XTick] {
        guard !points.isEmpty else { return [] }
        switch timeframe {
        case .week:
            return points.enumerated().map { index, point in
                VO2XTick(index: index, label: point.axisLabel(for: timeframe), width: 34)
            }
        case .month:
            return vo2EvenlySpacedIndexes(count: points.count, maxCount: 5).map { index in
                VO2XTick(index: index, label: points[index].axisLabel(for: timeframe), width: 34)
            }
        case .year:
            return points.enumerated().map { index, point in
                VO2XTick(index: index, label: point.axisLabel(for: timeframe), width: 30)
            }
        case .day:
            return []
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

private struct VO2XTick: Identifiable {
    let index: Int
    let label: String
    let width: CGFloat

    var id: String { "\(index)-\(label)" }
}

private struct VO2LineShape: Shape {
    let points: [VO2DisplayPoint]
    let bounds: ClosedRange<Double>

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var hasActiveSegment = false
        for (index, point) in points.enumerated() {
            guard let value = point.value else {
                continue
            }
            let coordinate = CGPoint(
                x: vo2XPosition(index: index, count: points.count, width: rect.width),
                y: vo2YPosition(value: value, bounds: bounds, height: rect.height)
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

private struct VO2DisplayPoint: Identifiable {
    let id: String
    let date: String
    let value: Double?
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
        if timeframe == .year || sampleCount > 1 {
            return ScoreDateFormatters.monthReadoutLabel(from: date)
        }
        return ScoreDateFormatters.weeklySelectedDateLabel(from: date)
    }

    static func points(from rawPoints: [BaselineMetricChartPoint], timeframe: ScoreTimeframe) -> [VO2DisplayPoint] {
        let today = ScoreDateFormatters.apiDate.string(from: Date())
        let elapsedPoints = rawPoints.filter { point in
            guard let date = point.date else { return false }
            return date <= today
        }

        guard timeframe == .year else {
            return elapsedPoints.map {
                VO2DisplayPoint(
                    id: $0.id,
                    date: $0.date ?? "",
                    value: $0.value,
                    sampleCount: $0.value == nil ? 0 : 1
                )
            }
        }

        let grouped = Dictionary(grouping: elapsedPoints) { point in
            String((point.date ?? "").prefix(7))
        }
        return grouped.keys.sorted().map { key in
            let monthPoints = grouped[key] ?? []
            let values = monthPoints.compactMap(\.value)
            return VO2DisplayPoint(
                id: key,
                date: "\(key)-01",
                value: average(values),
                sampleCount: values.count
            )
        }
    }

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}

private struct VO2Section<Content: View>: View {
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

private struct VO2SummaryRow: View {
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

private struct VO2TrendRow: View {
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
        case "flat": return .blue
        default: return .secondary
        }
    }
}

private struct VO2ContextRow: View {
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

private struct VO2GuidanceRow: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.green)
                .frame(width: 28, height: 28)
                .background(Color.green.opacity(0.13), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private func vo2EvenlySpacedIndexes(count: Int, maxCount: Int) -> [Int] {
    guard count > 0 else { return [] }
    guard count > maxCount else { return Array(0..<count) }
    let step = Double(count - 1) / Double(maxCount - 1)
    return (0..<maxCount).map { Int((Double($0) * step).rounded()) }
}

private func vo2XPosition(index: Int, count: Int, width: CGFloat) -> CGFloat {
    guard count > 1 else { return width / 2 }
    return CGFloat(index) / CGFloat(count - 1) * width
}

private func vo2YPosition(value: Double, bounds: ClosedRange<Double>, height: CGFloat) -> CGFloat {
    let span = max(bounds.upperBound - bounds.lowerBound, 1)
    let ratio = (value - bounds.lowerBound) / span
    return height - (CGFloat(ratio) * height)
}

private func vo2ValueText(_ value: Double?) -> String? {
    value.map { $0.clean }
}

private func vo2SignedText(_ value: Double) -> String {
    if abs(value) < 0.05 {
        return "0"
    }
    return value > 0 ? "+\(value.clean)" : value.clean
}

enum VO2PreviewData {
    static let anchorDate = ScoreDateFormatters.apiDate.date(from: "2026-06-22") ?? Date()

    static func detail(for timeframe: ScoreTimeframe) -> VO2MaxMetricDetail {
        switch timeframe {
        case .week:
            return makeDetail(
                timeframe: .week,
                rangeStart: "2026-06-22",
                rangeEnd: "2026-06-28",
                values: [
                    "2026-06-22": 48.2
                ],
                previousPeriodValue: 48.0,
                expectedDays: 7
            )
        case .month:
            return makeDetail(
                timeframe: .month,
                rangeStart: "2026-06-01",
                rangeEnd: "2026-06-30",
                values: [
                    "2026-06-05": 47.8,
                    "2026-06-14": 48.0,
                    "2026-06-22": 48.2
                ],
                previousPeriodValue: 47.6,
                expectedDays: 30
            )
        case .year:
            return makeDetail(
                timeframe: .year,
                rangeStart: "2026-01-01",
                rangeEnd: "2026-12-31",
                values: [
                    "2026-01-10": 46.4,
                    "2026-02-21": 47.1,
                    "2026-03-14": 47.6,
                    "2026-04-18": 47.9,
                    "2026-05-16": 48.0,
                    "2026-06-22": 48.2
                ],
                previousPeriodValue: 45.7,
                expectedDays: 365
            )
        case .day:
            return makeDetail(
                timeframe: .day,
                rangeStart: "2026-06-22",
                rangeEnd: "2026-06-22",
                values: ["2026-06-22": 48.2],
                previousPeriodValue: 48.0,
                expectedDays: 1
            )
        }
    }

    private static func makeDetail(
        timeframe: ScoreTimeframe,
        rangeStart: String,
        rangeEnd: String,
        values: [String: Double],
        previousPeriodValue: Double,
        expectedDays: Int
    ) -> VO2MaxMetricDetail {
        let points = dateStrings(from: rangeStart, to: rangeEnd).map { date in
            point(date: date, value: values[date])
        }
        let populated = points.filter { $0.value != nil }
        let latest = populated.last
        let previous = populated.dropLast().last
        let currentValue = latest?.value
        let currentAverage = average(populated.compactMap(\.value))
        let absoluteChange = currentValue.map { $0 - previousPeriodValue }

        return VO2MaxMetricDetail(
            metric: "vo2_max",
            unit: "ml_per_kg_min",
            timeframe: timeframe.rawValue,
            range: MetricDetailRange(start: rangeStart, end: rangeEnd),
            current: latest.flatMap { point in point.value.map { MetricPoint(value: $0, date: point.date) } },
            previous: previous.flatMap { point in point.value.map { MetricPoint(value: $0, date: point.date) } },
            trend: MetricTrend(direction: trend(for: absoluteChange), absoluteChange: absoluteChange.map { roundValue($0) }, percentChange: nil, windowAverage: currentAverage),
            baseline: nil,
            summary: BaselineMetricSummary(
                title: title(for: timeframe),
                primaryValue: currentAverage.map { roundValue($0) },
                latestValue: currentValue,
                previousPeriodValue: previousPeriodValue,
                baselineValue: nil,
                baselineLowerBound: nil,
                baselineUpperBound: nil,
                baselineRelation: "unknown",
                baselineDelta: nil,
                confidencePhase: nil,
                trend: trend(for: absoluteChange),
                absoluteChange: absoluteChange.map { roundValue($0) },
                validDays: populated.count,
                missingDays: max(expectedDays - populated.count, 0),
                periodDays: expectedDays,
                dataQuality: "strong"
            ),
            chart: BaselineMetricChart(kind: "daily_metric_baseline", points: points),
            distribution: BaselineMetricDistribution(
                withinCount: 0,
                belowCount: 0,
                aboveCount: 0,
                missingCount: max(expectedDays - populated.count, 0),
                unknownCount: populated.count,
                longestBelowStreak: 0
            ),
            coverage: MetricCoverage(
                expectedDays: expectedDays,
                validDays: populated.count,
                completeness: roundValue(Double(populated.count) / Double(max(expectedDays, 1)), places: 3),
                qualityCounts: ["strong": populated.count, "missing": max(expectedDays - populated.count, 0)]
            ),
            series: points,
            dataQuality: "strong",
            higherIsBetter: true
        )
    }

    private static func point(date: String, value: Double?) -> BaselineMetricChartPoint {
        BaselineMetricChartPoint(
            date: date,
            value: value,
            unit: "ml_per_kg_min",
            dataQuality: value == nil ? "missing" : "strong",
            baselineValue: nil,
            baselineLowerBound: nil,
            baselineUpperBound: nil,
            comparison: "unknown"
        )
    }

    private static func dateStrings(from start: String, to end: String) -> [String] {
        guard let startDate = ScoreDateFormatters.apiDate.date(from: start),
              let endDate = ScoreDateFormatters.apiDate.date(from: end)
        else {
            return []
        }
        var result: [String] = []
        var date = startDate
        while date <= endDate {
            result.append(ScoreDateFormatters.apiDate.string(from: date))
            date = ScoreDateFormatters.calendar.date(byAdding: .day, value: 1, to: date) ?? endDate.addingTimeInterval(86_400)
        }
        return result
    }

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func trend(for change: Double?) -> String {
        guard let change else { return "unknown" }
        if change > 0.05 { return "up" }
        if change < -0.05 { return "down" }
        return "flat"
    }

    private static func title(for timeframe: ScoreTimeframe) -> String {
        switch timeframe {
        case .week: return "Weekly VO2 Max"
        case .month: return "Monthly VO2 Max"
        case .year: return "Yearly VO2 Max"
        case .day: return "VO2 Max"
        }
    }

    private static func roundValue(_ value: Double, places: Int = 1) -> Double {
        let multiplier = pow(10, Double(places))
        return (value * multiplier).rounded() / multiplier
    }
}

#Preview("VO2 Max detail") {
    NavigationStack {
        VO2MaxDetailView(client: DashboardAPIClient(), previewDetail: VO2PreviewData.detail(for: .year))
    }
}
