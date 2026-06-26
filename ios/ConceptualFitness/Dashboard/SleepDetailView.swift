import SwiftUI

struct SleepDetailView: View {
    let client: DashboardAPIClient

    @State private var timeframe: ScoreTimeframe = .week
    @State private var selectedDate = Date()
    @State private var loadState: SleepDetailLoadState = .loading
    @State private var calendarSelection: ScoreCalendarSelection?

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    timeframePicker
                    ScoreRangeNavigator(
                        timeframe: timeframe,
                        metricName: "Sleep",
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
        .navigationTitle("Sleep")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: loadKey) {
            await load()
        }
        .refreshable {
            await load()
        }
        .sheet(item: $calendarSelection) { selection in
            ScoreCalendarPicker(metricName: "Sleep", selection: selection) { nextDate in
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
        .accessibilityLabel("Sleep timeframe")
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
                Text("Could not load Sleep")
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

    private func loadedContent(_ detail: SleepDetail) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            SleepSummaryPanel(detail: detail)
            SleepChartPanel(detail: detail, timeframe: timeframe)
            SleepDriverPanel(components: detail.components, timeframe: timeframe)
            SleepContextPanel(context: detail.context, timeframe: timeframe)
            if !detail.reasons.isEmpty {
                SleepReasonsPanel(reasons: detail.reasons)
            }
        }
    }

    @MainActor
    private func load() async {
        loadState = .loading
        do {
            loadState = .loaded(try await client.loadSleepDetail(date: selectedDate, timeframe: timeframe))
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

private enum SleepDetailLoadState {
    case loading
    case loaded(SleepDetail)
    case failed(String)
}

private struct SleepSummaryPanel: View {
    let detail: SleepDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(detail.summary.title ?? "Sleep")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                if let pill {
                    Text(pill.title)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(pill.color.opacity(0.16), in: Capsule())
                        .foregroundStyle(pill.color)
                }
            }

            HStack(spacing: 18) {
                SleepScoreCircle(
                    value: detail.summary.primaryValue,
                    band: detail.summary.sleepBand,
                    label: detail.timeframe == "day" ? nil : "avg"
                )
                .frame(width: 112, height: 112)

                if detail.timeframe == "day" {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(dayTimeRange)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                        Text(minutesText(detail.summary.sleepMinutes))
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.62)
                        Text("Target \(minutesText(detail.summary.targetSleepMinutes))")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: 9) {
                        SleepHeroStatRow(title: "Average sleep time", value: minutesText(detail.summary.averageSleepMinutes))
                        SleepHeroStatRow(title: "Target met nights", value: targetMetText)
                        SleepHeroStatRow(title: "Sleep debt", value: debtText(detail.summary.sleepDebtMinutes))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 20)
    }

    private var dayTimeRange: String {
        guard let bedtime = detail.summary.bedtime, let wake = detail.summary.wakeTime else {
            return "--"
        }
        return "\(bedtime) - \(wake)"
    }

    private var targetMetText: String {
        guard let met = detail.summary.targetMetNights else { return "--" }
        if let slept = detail.summary.sleptNights {
            return "\(met) / \(slept)"
        }
        return "\(met)"
    }

    private var pill: (title: String, color: Color)? {
        if let band = detail.summary.sleepBand {
            return (sleepBandTitle(band), sleepColor(band))
        }
        if let quality = detail.summary.dataQuality {
            return ("\(quality.displayTitle) quality", quality == "strong" ? .green : .orange)
        }
        if let status = detail.summary.status {
            return (status.displayTitle, .secondary)
        }
        return nil
    }
}

private struct SleepHeroStatRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.76)
                .layoutPriority(1)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.76)
        }
    }
}

private struct SleepScoreCircle: View {
    let value: Double?
    let band: String?
    let label: String?

    private var ratio: Double {
        min(max((value ?? 0) / 100, 0), 1)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.55), lineWidth: 11)
            Circle()
                .trim(from: 0, to: ratio)
                .stroke(sleepColor(band).gradient, style: StrokeStyle(lineWidth: 11, lineCap: .round))
                .rotationEffect(.degrees(-90))

            VStack(spacing: 1) {
                Text(value?.clean ?? "--")
                    .font(.system(size: 31, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                if let label {
                    Text(label)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityLabel("Sleep score \(value?.clean ?? "no score")")
    }
}

private struct SleepChartPanel: View {
    let detail: SleepDetail
    let timeframe: ScoreTimeframe

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(chartTitle)
                .font(.headline)

            switch detail.chart.kind {
            case "stage_timeline":
                if detail.chart.points.isEmpty {
                    StageSummaryBar(items: detail.chart.stageSummary ?? [])
                        .frame(minHeight: 128)
                } else {
                    StageLaneTimelineChart(points: detail.chart.points)
                        .frame(height: 360)
                }
            case "weekly_sleep_pattern":
                WeeklySleepPatternChart(points: detail.chart.points)
                    .frame(height: 232)
            case "monthly_sleep_bars":
                SleepMonthlyBarChart(points: detail.chart.points)
                    .frame(height: 224)
            default:
                SleepDailyBarChart(points: detail.chart.points, timeframe: timeframe)
                    .frame(height: timeframe == .month ? 246 : 220)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 20)
    }

    private var chartTitle: String {
        switch detail.chart.kind {
        case "stage_timeline": return "Sleep stages"
        case "weekly_sleep_pattern": return "Sleep pattern"
        case "monthly_sleep_bars": return "Monthly sleep"
        default: return "Daily sleep"
        }
    }
}

private struct StageLaneTimelineChart: View {
    let points: [SleepChartPoint]

    private let lanes = ["AWAKE", "REM", "LIGHT", "DEEP"]

    private var visibleLanes: [String] {
        let present = Set(points.compactMap { normalizedStage($0.stage) })
        return lanes.filter { present.contains($0) }
    }

    private var totalMinutes: Double {
        max(1, points.compactMap(\.offsetEndMinutes).max() ?? points.reduce(0) { $0 + ($1.durationMinutes ?? 0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(visibleLanes, id: \.self) { lane in
                StageLaneRow(
                    lane: lane,
                    points: points.filter { normalizedStage($0.stage) == lane },
                    totalMinutes: totalMinutes
                )
            }

            timelineAxis
        }
    }

    @ViewBuilder
    private var timelineAxis: some View {
        if let first = points.first, let last = points.last {
            HStack {
                Text(first.startClock ?? "--")
                Spacer()
                Text(midpointClock)
                Spacer()
                Text(last.endClock ?? "--")
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
        }
    }

    private var midpointClock: String {
        guard let first = points.first, let start = first.startMinute else { return "--" }
        let middle = start + Int((totalMinutes / 2).rounded())
        return clockText(forAbsoluteMinute: middle)
    }
}

private struct StageLaneRow: View {
    let lane: String
    let points: [SleepChartPoint]
    let totalMinutes: Double

    private var totalLaneMinutes: Double {
        points.reduce(0) { $0 + ($1.durationMinutes ?? 0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(stageTitle(lane)) · \(stageDurationText(totalLaneMinutes))")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(.primary.opacity(0.08))
                        .frame(height: 22)

                    ForEach(points) { point in
                        let offset = xOffset(for: point, width: proxy.size.width)
                        let width = segmentWidth(for: point, width: proxy.size.width)
                        Rectangle()
                            .fill(stageColor(lane).gradient)
                            .frame(width: width, height: 22)
                            .offset(x: offset)
                            .accessibilityLabel("\(stageTitle(lane)), \(stageDurationText(point.durationMinutes))")
                    }
                }
            }
            .frame(height: 28)
        }
    }

    private func xOffset(for point: SleepChartPoint, width: CGFloat) -> CGFloat {
        guard let start = point.offsetStartMinutes else { return 0 }
        return width * CGFloat(start / totalMinutes)
    }

    private func segmentWidth(for point: SleepChartPoint, width: CGFloat) -> CGFloat {
        max(3, width * CGFloat((point.durationMinutes ?? 0) / totalMinutes))
    }
}

private struct StageSummaryBar: View {
    let items: [SleepStageSummary]
    @State private var selectedType: String?

    private var selectedItem: SleepStageSummary? {
        if let selectedType, let item = items.first(where: { $0.type == selectedType }) {
            return item
        }
        return items.max { $0.minutes < $1.minutes }
    }

    private var totalMinutes: Double {
        max(1, items.reduce(0) { $0 + $1.minutes })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let selectedItem {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(minutesText(selectedItem.minutes))
                        .font(.title3.weight(.bold))
                    Text(stageTitle(selectedItem.type))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Stage summary will appear when sleep stages are available.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                HStack(spacing: 3) {
                    ForEach(items) { item in
                        Button {
                            selectedType = item.type
                        } label: {
                            Rectangle()
                                .fill(stageColor(item.type).gradient)
                                .frame(width: max(6, proxy.size.width * CGFloat(item.minutes / totalMinutes)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 42)

            StageLegend(stages: items.map(\.type))
        }
    }
}

private struct StageLegend: View {
    let stages: [String]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(stages, id: \.self) { stage in
                HStack(spacing: 5) {
                    Circle()
                        .fill(stageColor(stage))
                        .frame(width: 7, height: 7)
                    Text(stageTitle(stage))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

private struct WeeklySleepPatternChart: View {
    let points: [SleepChartPoint]
    @State private var selectedID: String?

    private var validPoints: [SleepChartPoint] {
        points.filter { $0.sleepStartMinute != nil && $0.sleepEndMinute != nil }
    }

    private var hasEveningStarts: Bool {
        validPoints.contains { ($0.sleepStartMinute ?? 0) >= 12 * 60 }
    }

    private var axisStart: Int {
        validPoints.compactMap { normalizedSleepStart($0) }.min() ?? 20 * 60
    }

    private var axisEnd: Int {
        validPoints.compactMap { normalizedSleepEnd($0) }.max() ?? (10 * 60 + 1440)
    }

    private var axisSpan: Int {
        max(60, axisEnd - axisStart)
    }

    private var selectedPoint: SleepChartPoint? {
        if let selectedID, let point = points.first(where: { $0.id == selectedID }) {
            return point
        }
        return points.last { $0.durationMinutes != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            selectedReadout

            GeometryReader { _ in
                VStack(spacing: 5) {
                    ForEach(points) { point in
                        HStack(spacing: 10) {
                            Text(point.label(for: .week))
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                                .frame(width: 24, alignment: .leading)

                            GeometryReader { railProxy in
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(.white.opacity(0.45))
                                        .frame(height: 10)
                                    if let start = point.sleepStartMinute, let end = point.sleepEndMinute {
                                        Button {
                                            selectedID = point.id
                                        } label: {
                                            Capsule()
                                                .fill(sleepColor(point.sleepBand).gradient)
                                                .frame(
                                                    width: max(6, barWidth(start: start, end: end, width: railProxy.size.width)),
                                                    height: point.id == selectedPoint?.id ? 14 : 10
                                                )
                                        }
                                        .buttonStyle(.plain)
                                        .offset(x: barOffset(start: start, width: railProxy.size.width))
                                        .accessibilityLabel("\(point.label(for: .week)), \(minutesText(point.durationMinutes)) sleep")
                                    }
                                }
                                .clipShape(Capsule())
                            }
                            .frame(height: 16)
                        }
                    }

                    HStack {
                        Text(clockText(forAbsoluteMinute: axisStart))
                        Spacer()
                        Text(clockText(forAbsoluteMinute: axisStart + axisSpan / 2))
                        Spacer()
                        Text(clockText(forAbsoluteMinute: axisEnd))
                    }
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 34)
                }
            }
        }
    }

    @ViewBuilder
    private var selectedReadout: some View {
        if let selectedPoint, let duration = selectedPoint.durationMinutes {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(minutesText(duration))
                    .font(.title3.weight(.bold))
                Text("\(selectedPoint.label(for: .week)) \(selectedPoint.bedtime ?? "--") - \(selectedPoint.wakeTime ?? "--")")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        } else {
            Text("Sleep pattern will appear when nights are available.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func normalized(_ minute: Int) -> Int {
        hasEveningStarts && minute < 12 * 60 ? minute + 1440 : minute
    }

    private func barOffset(start: Int, width: CGFloat) -> CGFloat {
        let value = max(0, min(axisSpan, normalized(start) - axisStart))
        return width * CGFloat(value) / CGFloat(axisSpan)
    }

    private func barWidth(start: Int, end: Int, width: CGFloat) -> CGFloat {
        let normalizedStart = normalized(start)
        var normalizedEnd = normalized(end)
        if normalizedEnd <= normalizedStart {
            normalizedEnd += 1440
        }
        let duration = max(1, min(axisSpan, normalizedEnd - normalizedStart))
        return width * CGFloat(duration) / CGFloat(axisSpan)
    }

    private func normalizedSleepStart(_ point: SleepChartPoint) -> Int? {
        guard let start = point.sleepStartMinute else { return nil }
        return normalized(start)
    }

    private func normalizedSleepEnd(_ point: SleepChartPoint) -> Int? {
        guard let start = point.sleepStartMinute, let end = point.sleepEndMinute else { return nil }
        let normalizedStart = normalized(start)
        var normalizedEnd = normalized(end)
        if normalizedEnd <= normalizedStart {
            normalizedEnd += 1440
        }
        return normalizedEnd
    }
}

private struct SleepDailyBarChart: View {
    let points: [SleepChartPoint]
    let timeframe: ScoreTimeframe
    @State private var selectedID: String?

    private var selectedPoint: SleepChartPoint? {
        if let selectedID, let point = points.first(where: { $0.id == selectedID }) {
            return point
        }
        return points.last { $0.durationMinutes != nil }
    }

    private var maxMinutes: Double {
        max(540, points.compactMap(\.durationMinutes).max() ?? 0, points.compactMap(\.targetSleepMinutes).max() ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            selectedReadout

            GeometryReader { proxy in
                let chartHeight = proxy.size.height - 24
                ZStack(alignment: .bottomLeading) {
                    if let target = averageTarget {
                        let y = chartHeight - chartHeight * CGFloat(target / maxMinutes)
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                        }
                        .stroke(.secondary.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

                        Text("Target")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.white.opacity(0.72), in: Capsule())
                            .position(x: proxy.size.width - 24, y: max(10, y - 10))
                    }

                    if let selectedPoint, let selectedIndex = points.firstIndex(where: { $0.id == selectedPoint.id }) {
                        selectionLine(x: barCenterX(for: selectedIndex, width: proxy.size.width), topPadding: 0, plotHeight: chartHeight)
                    }

                    HStack(alignment: .bottom, spacing: points.count > 20 ? 4 : 7) {
                        ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                            VStack(spacing: 6) {
                                Button {
                                    selectedID = point.id
                                } label: {
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(sleepColor(point.sleepBand).gradient)
                                        .opacity(point.durationMinutes == nil ? 0.22 : 1)
                                        .frame(height: max(4, chartHeight * CGFloat((point.durationMinutes ?? 0) / maxMinutes)))
                                }
                                .buttonStyle(.plain)

                                Text(xTickLabel(for: point, index: index))
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(point.id == selectedPoint?.id ? .primary : .secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.58)
                                    .frame(height: 18)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                selectPoint(atX: value.location.x, width: proxy.size.width)
                            }
                    )
                }
            }
        }
    }

    private var averageTarget: Double? {
        let targets = points.compactMap(\.targetSleepMinutes)
        guard !targets.isEmpty else { return nil }
        return targets.reduce(0, +) / Double(targets.count)
    }

    private func xTickLabel(for point: SleepChartPoint, index: Int) -> String {
        if timeframe != .month {
            return point.label(for: timeframe)
        }
        if index == 0 || index == points.count - 1 || index % 5 == 0 {
            return point.label(for: timeframe)
        }
        return ""
    }

    @ViewBuilder
    private var selectedReadout: some View {
        if let selectedPoint, let duration = selectedPoint.durationMinutes {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(minutesText(duration))
                    .font(.title3.weight(.bold))
                Text(selectedPoint.readoutLabel(for: timeframe))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else {
            Text("Tap a day to inspect its sleep.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func selectPoint(atX x: CGFloat, width: CGFloat) {
        guard !points.isEmpty else { return }
        let clampedX = min(max(x, 0), max(width, 1))
        let index = Int((clampedX / max(width, 1) * CGFloat(points.count)).rounded(.down))
        selectedID = points[min(max(index, 0), points.count - 1)].id
    }

    private func barCenterX(for index: Int, width: CGFloat) -> CGFloat {
        guard !points.isEmpty else { return width / 2 }
        return (CGFloat(index) + 0.5) / CGFloat(points.count) * width
    }
}

private struct SleepMonthlyBarChart: View {
    let points: [SleepChartPoint]
    @State private var selectedID: String?

    private var selectedPoint: SleepChartPoint? {
        if let selectedID, let point = points.first(where: { $0.id == selectedID }) {
            return point
        }
        return points.last { $0.averageSleepMinutes != nil }
    }

    private var maxMinutes: Double {
        max(540, points.compactMap(\.averageSleepMinutes).max() ?? 0, points.compactMap(\.targetSleepMinutes).max() ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            selectedReadout

            GeometryReader { proxy in
                let chartHeight = proxy.size.height - 24
                ZStack(alignment: .bottomLeading) {
                    if let target = averageTarget {
                        let y = chartHeight - chartHeight * CGFloat(target / maxMinutes)
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                        }
                        .stroke(.secondary.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

                        Text("Target")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.white.opacity(0.72), in: Capsule())
                            .position(x: proxy.size.width - 24, y: max(10, y - 10))
                    }

                    if let selectedPoint, let selectedIndex = points.firstIndex(where: { $0.id == selectedPoint.id }) {
                        selectionLine(x: barCenterX(for: selectedIndex, width: proxy.size.width), topPadding: 0, plotHeight: chartHeight)
                    }

                    HStack(alignment: .bottom, spacing: 6) {
                        ForEach(points) { point in
                            VStack(spacing: 7) {
                                Button {
                                    selectedID = point.id
                                } label: {
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(sleepColor(for: point.averageScore).gradient)
                                        .opacity(point.averageSleepMinutes == nil ? 0.22 : 1)
                                        .frame(height: max(4, chartHeight * CGFloat((point.averageSleepMinutes ?? 0) / maxMinutes)))
                                }
                                .buttonStyle(.plain)

                                Text(point.label(for: .year))
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(point.id == selectedPoint?.id ? .primary : .secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                                    .frame(height: 18)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                selectPoint(atX: value.location.x, width: proxy.size.width)
                            }
                    )
                }
            }
        }
    }

    private var averageTarget: Double? {
        let targets = points.compactMap(\.targetSleepMinutes)
        guard !targets.isEmpty else { return nil }
        return targets.reduce(0, +) / Double(targets.count)
    }

    @ViewBuilder
    private var selectedReadout: some View {
        if let selectedPoint, let minutes = selectedPoint.averageSleepMinutes {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(minutesText(minutes))
                    .font(.title3.weight(.bold))
                Text(selectedPoint.readoutLabel(for: .year))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Tap a month to inspect its average.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func selectPoint(atX x: CGFloat, width: CGFloat) {
        guard !points.isEmpty else { return }
        let clampedX = min(max(x, 0), max(width, 1))
        let index = Int((clampedX / max(width, 1) * CGFloat(points.count)).rounded(.down))
        selectedID = points[min(max(index, 0), points.count - 1)].id
    }

    private func barCenterX(for index: Int, width: CGFloat) -> CGFloat {
        guard !points.isEmpty else { return width / 2 }
        return (CGFloat(index) + 0.5) / CGFloat(points.count) * width
    }
}

private func selectionLine(x: CGFloat, topPadding: CGFloat, plotHeight: CGFloat) -> some View {
    Path { path in
        path.move(to: CGPoint(x: x, y: topPadding))
        path.addLine(to: CGPoint(x: x, y: topPadding + plotHeight))
    }
    .stroke(.primary.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
}

private struct SleepDriverPanel: View {
    let components: SleepComponents
    let timeframe: ScoreTimeframe

    private var displayedItems: [SleepComponentItem] {
        timeframe == .day ? components.items : components.averageItems
    }

    var body: some View {
        SleepSection(title: timeframe == .day ? "Drivers" : "Average Drivers", systemImage: "slider.horizontal.3") {
            if displayedItems.isEmpty {
                Text("Sleep drivers will appear when enough score data is available.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                SleepComponentScoreChart(items: displayedItems)
            }
        }
    }
}

private struct SleepComponentScoreChart: View {
    let items: [SleepComponentItem]

    var body: some View {
        VStack(spacing: 12) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Label(item.label, systemImage: iconName(for: item.key))
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(componentColor(item.key))
                        Spacer()
                        Text(item.score.clean)
                            .font(.subheadline.weight(.bold))
                    }

                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(.white.opacity(0.5))
                            Capsule()
                                .fill(componentColor(item.key).gradient)
                                .frame(width: proxy.size.width * CGFloat(min(max(item.score / 100, 0), 1)))
                        }
                    }
                    .frame(height: 9)

                    if let message = item.message {
                        Text(message)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

private struct SleepContextPanel: View {
    let context: SleepContext
    let timeframe: ScoreTimeframe

    var body: some View {
        SleepSection(title: "Sleep Context", systemImage: "moon.zzz.fill") {
            VStack(spacing: 10) {
                SleepContextRow(title: "Sleep target", value: minutesText(context.adjustedSleepNeedMinutes))
                SleepContextRow(title: sleepDebtTitle, value: debtText(context.sleepDebtMinutes))
                if timeframe != .day {
                    SleepContextRow(title: "Target met", value: targetMetText)
                }
                if let adjusted = context.strainAdjustedNights, adjusted > 0 {
                    SleepContextRow(title: "Strain-adjusted nights", value: "\(adjusted)")
                }
                SleepContextRow(title: "HRV", value: baselineText(context.hrvBaselineRelation))
                SleepContextRow(title: "Resting HR", value: baselineText(context.rhrBaselineRelation))
                SleepContextRow(title: "Confidence", value: context.confidencePhase?.displayTitle)
            }
        }
    }

    private var sleepDebtTitle: String {
        switch timeframe {
        case .day, .week:
            return "Sleep debt (week)"
        case .month:
            return "Sleep debt (month)"
        case .year:
            return "Sleep debt (year)"
        }
    }

    private var targetMetText: String {
        guard let met = context.targetMetNights else { return "--" }
        if let slept = context.sleptNights {
            return "\(met) / \(slept)"
        }
        return "\(met)"
    }
}

private struct SleepReasonsPanel: View {
    let reasons: [ScoreReason]

    var body: some View {
        SleepSection(title: "Reasons", systemImage: "exclamationmark.circle.fill") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(reasons.enumerated()), id: \.offset) { _, reason in
                    HStack(alignment: .top, spacing: 10) {
                        Circle()
                            .fill(reason.direction == "negative" ? Color.orange : Color.green)
                            .frame(width: 8, height: 8)
                            .padding(.top, 6)
                        Text(reason.message ?? reason.code?.displayTitle ?? "Sleep changed.")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

private struct SleepSection<Content: View>: View {
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

private struct SleepContextRow: View {
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
        }
    }
}

private extension SleepChartPoint {
    func label(for timeframe: ScoreTimeframe) -> String {
        if timeframe == .year, let monthStartDate {
            return ScoreDateFormatters.monthLabel(from: monthStartDate)
        }
        if let date {
            return timeframe == .month
                ? ScoreDateFormatters.shortDateLabel(from: date)
                : ScoreDateFormatters.weekdayLabel(from: date)
        }
        return stage?.displayTitle ?? "--"
    }

    func readoutLabel(for timeframe: ScoreTimeframe) -> String {
        if timeframe == .year, let monthStartDate {
            return ScoreDateFormatters.monthReadoutLabel(from: monthStartDate)
        }
        if let date {
            return ScoreDateFormatters.weeklySelectedDateLabel(from: date)
        }
        return label(for: timeframe)
    }
}

private func minutesText(_ minutes: Double?) -> String {
    guard let minutes else { return "--" }
    let rounded = Int(minutes)
    return "\(rounded / 60)h \(String(format: "%02d", rounded % 60))m"
}

private func stageDurationText(_ minutes: Double?) -> String {
    guard let minutes else { return "--" }
    let rounded = Int(minutes)
    if rounded < 60 {
        return "\(rounded)m"
    }
    return minutesText(minutes)
}

private func debtText(_ minutes: Double?) -> String {
    guard let minutes else { return "--" }
    if minutes <= 0 {
        return "0h"
    }
    return minutesText(minutes)
}

private func baselineText(_ relation: String?) -> String? {
    guard let relation else { return nil }
    switch relation {
    case "above_baseline": return "Above baseline"
    case "below_baseline": return "Below baseline"
    case "at_baseline": return "At baseline"
    default: return relation.displayTitle
    }
}

private func normalizedStage(_ stage: String?) -> String? {
    guard let value = stage?.uppercased() else { return nil }
    if value.contains("AWAKE") || value.contains("WAKE") {
        return "AWAKE"
    }
    if value.contains("REM") {
        return "REM"
    }
    if value.contains("DEEP") || value.contains("SLOW") {
        return "DEEP"
    }
    if value.contains("LIGHT") {
        return "LIGHT"
    }
    return value
}

private func stageTitle(_ stage: String?) -> String {
    switch normalizedStage(stage) {
    case "AWAKE": return "Awake"
    case "REM": return "REM"
    case "LIGHT": return "Light"
    case "DEEP": return "Deep"
    default: return stage?.displayTitle ?? "--"
    }
}

private func clockText(forAbsoluteMinute value: Int) -> String {
    let minute = ((value % 1440) + 1440) % 1440
    return String(format: "%02d:%02d", minute / 60, minute % 60)
}

private func sleepBandTitle(_ band: String) -> String {
    switch band {
    case "good": return "Good"
    case "fair": return "Fair"
    case "low": return "Low"
    default: return band.displayTitle
    }
}

private func sleepColor(_ band: String?) -> Color {
    switch band {
    case "good": return .indigo
    case "fair": return .teal
    case "low": return .orange
    default: return .secondary
    }
}

private func sleepColor(for score: Double?) -> Color {
    guard let score else { return .secondary }
    if score >= 80 { return .indigo }
    if score >= 60 { return .teal }
    return .orange
}

private func stageColor(_ stage: String?) -> Color {
    switch normalizedStage(stage) {
    case "AWAKE": return .pink
    case "REM": return .cyan
    case "DEEP": return .purple
    case "LIGHT": return .blue
    default: return .secondary
    }
}

private func componentColor(_ key: String) -> Color {
    switch key {
    case "duration": return .indigo
    case "regularity": return .teal
    case "continuity": return .blue
    case "timing": return .mint
    case "physiology": return .green
    case "stages": return .purple
    default: return .secondary
    }
}

private func iconName(for key: String) -> String {
    switch key {
    case "duration": return "clock.fill"
    case "regularity": return "calendar.badge.clock"
    case "continuity": return "waveform.path"
    case "timing": return "moon.stars.fill"
    case "physiology": return "waveform.path.ecg"
    case "stages": return "bed.double.fill"
    default: return "circle.fill"
    }
}

#Preview {
    SleepDetailView(client: DashboardAPIClient())
}
