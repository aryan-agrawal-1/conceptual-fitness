import SwiftUI

struct StrainDetailView: View {
    let client: DashboardAPIClient

    @State private var timeframe: StrainTimeframe = .week
    @State private var selectedDate = Date()
    @State private var loadState: StrainDetailLoadState = .loading
    @State private var calendarSelection: ScoreCalendarSelection?

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    timeframePicker
                    ScoreRangeNavigator(
                        timeframe: timeframe,
                        metricName: "Strain",
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
        .navigationTitle("Strain")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: loadKey) {
            await load()
        }
        .refreshable {
            await load()
        }
        .sheet(item: $calendarSelection) { selection in
            ScoreCalendarPicker(metricName: "Strain", selection: selection) { nextDate in
                selectedDate = nextDate
                calendarSelection = nil
            }
        }
    }

    private var timeframePicker: some View {
        Picker("Timeframe", selection: $timeframe) {
            ForEach(StrainTimeframe.allCases) { item in
                Text(item.title).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Strain timeframe")
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
                Text("Could not load Strain")
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

    private func loadedContent(_ detail: StrainDetail) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            StrainSummaryPanel(detail: detail)
            StrainChartPanel(detail: detail)
            StrainExplanationPanel()
            if detail.timeframe != "day" {
                StrainComponentPanel(components: detail.components)
            }
            StrainContributorsPanel(workouts: detail.contributors, timeframe: timeframe, client: client)
            StrainTrainingContextPanel(context: detail.trainingContext, timeframe: timeframe)
        }
    }

    @MainActor
    private func load() async {
        loadState = .loading
        do {
            loadState = .loaded(try await client.loadStrainDetail(date: selectedDate, timeframe: timeframe))
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

private enum StrainDetailLoadState {
    case loading
    case loaded(StrainDetail)
    case failed(String)
}

private struct StrainSummaryPanel: View {
    let detail: StrainDetail

    var body: some View {
        Group {
            if detail.timeframe == "week" {
                WeeklyStrainSummary(detail: detail)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(detail.summary.title ?? detail.timeframe.displayTitle)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            Text(primaryValue)
                                .font(.system(size: 38, weight: .bold, design: .rounded))
                                .lineLimit(1)
                                .minimumScaleFactor(0.68)
                        }

                        Spacer()

                        if let pill = headerPill {
                            Text(pill.title)
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(pill.color.opacity(0.16), in: Capsule())
                                .foregroundStyle(pill.color)
                        }
                    }

                    if let supportingText {
                        Text(supportingText)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 20)
    }

    private var primaryValue: String {
        switch detail.timeframe {
        case "week":
            let current = detail.summary.progressLoadPoints ?? detail.summary.loadPoints
            if let current, let target = detail.summary.targetLoadPoints {
                return "\(current.clean) / \(target.clean)"
            }
            return current.map { "\($0.clean) load" } ?? "--"
        case "month", "year":
            return detail.summary.averageWeeklyLoad.map { "\($0.clean) avg" } ?? "--"
        default:
            return detail.summary.primaryValue.map { "\($0.clean) load" } ?? "--"
        }
    }

    private var supportingText: String? {
        switch detail.timeframe {
        case "day":
            return nil
        case "month", "year":
            return detail.summary.loadPoints.map { "Total load \($0.clean)" }
        default:
            return nil
        }
    }

    private var headerPill: (title: String, color: Color)? {
        if detail.timeframe == "day" {
            if let quality = detail.summary.dataQuality {
                return ("\(quality.displayTitle) quality", quality == "strong" ? .green : .orange)
            }
            if let status = detail.summary.status {
                return (status.displayTitle, .secondary)
            }
            return nil
        }
        guard let band = detail.summary.loadBand ?? detail.trainingContext.latestLoadBand else { return nil }
        return (band.displayTitle, bandColor(band))
    }

}

private struct WeeklyStrainSummary: View {
    let detail: StrainDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(detail.summary.title ?? "Weekly load")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                if let band = detail.summary.loadBand ?? detail.trainingContext.latestLoadBand {
                    Text(band.displayTitle)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(bandColor(band).opacity(0.16), in: Capsule())
                        .foregroundStyle(bandColor(band))
                }
            }

            HStack(spacing: 18) {
                WeeklyProgressRing(ratio: ratio)
                    .frame(width: 96, height: 96)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Strain")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(currentTargetText)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.58)
                    Text("current / target")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var current: Double? {
        detail.summary.progressLoadPoints ?? detail.summary.loadPoints
    }

    private var ratio: Double {
        if let ratio = detail.summary.progressRatio {
            return ratio
        }
        guard let current, let target = detail.summary.targetLoadPoints, target > 0 else {
            return 0
        }
        return current / target
    }

    private var currentTargetText: String {
        guard let current else { return "--" }
        if let target = detail.summary.targetLoadPoints {
            return "\(current.clean) / \(target.clean)"
        }
        return "\(current.clean)"
    }
}

private struct WeeklyProgressRing: View {
    let ratio: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.5), lineWidth: 11)
            Circle()
                .trim(from: 0, to: min(max(ratio, 0), 1))
                .stroke(.orange.gradient, style: StrokeStyle(lineWidth: 11, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if ratio > 1 {
                Circle()
                    .trim(from: 0, to: min(ratio - 1, 0.35))
                    .stroke(.red.opacity(0.85), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Text("\(Int((ratio * 100).rounded()))%")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .accessibilityLabel("\(Int((ratio * 100).rounded())) percent of weekly strain target")
    }
}

private struct StrainChartPanel: View {
    let detail: StrainDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(chartTitle)
                    .font(.headline)
                Spacer()
                if let target = detail.chart.targetLoadPoints {
                    Text("Target \(target.clean)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            if detail.chart.kind == "component_bar" {
                ComponentStackBar(items: detail.components.items)
            } else if detail.chart.kind == "daily_bars" {
                WeeklyStrainLineChart(
                    points: detail.chart.points,
                    targetLoadPoints: detail.chart.targetLoadPoints
                )
                .frame(height: 270)
            } else {
                LoadBarChart(points: detail.chart.points, timeframe: detail.timeframe)
                    .frame(height: 190)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 20)
    }

    private var chartTitle: String {
        switch detail.chart.kind {
        case "component_bar": return "Load sources"
        case "daily_bars": return "Weekly progression"
        case "weekly_bars": return "Weekly load"
        default: return "Average weekly load"
        }
    }
}

private struct WeeklyStrainLineChart: View {
    let points: [StrainChartPoint]
    let targetLoadPoints: Double?
    @State private var selectedID: String?

    private var cumulativePoints: [WeeklyLinePoint] {
        var runningTotal = 0.0
        return occurredPoints.enumerated().map { index, point in
            let dailyLoad = point.loadPoints ?? 0
            runningTotal += dailyLoad
            return WeeklyLinePoint(
                id: point.id,
                index: index,
                label: point.label(for: "week"),
                dateLabel: point.weeklyDateLabel,
                dailyLoad: dailyLoad,
                cumulativeLoad: runningTotal
            )
        }
    }

    private var occurredPoints: [StrainChartPoint] {
        points.filter { point in
            guard let value = point.date,
                  let date = ScoreDateFormatters.apiDate.date(from: value)
            else {
                return true
            }
            return ScoreDateFormatters.calendar.startOfDay(for: date) <= ScoreDateFormatters.calendar.startOfDay(for: Date())
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            selectedReadout

            GeometryReader { proxy in
                let chartPoints = cumulativePoints
                let guides = guideValues(for: chartPoints)
                let maxValue = max((guides + chartPoints.map(\.cumulativeLoad)).max() ?? 1, 1)
                let topPadding: CGFloat = 18
                let bottomPadding: CGFloat = 34
                let labelGutter: CGFloat = 84
                let plotHeight = proxy.size.height - topPadding - bottomPadding
                let plotWidth = max(1, proxy.size.width - labelGutter)

                ZStack(alignment: .topLeading) {
                    ForEach(guides, id: \.self) { guide in
                        guideLine(
                            value: guide,
                            maxValue: maxValue,
                            plotHeight: plotHeight,
                            plotWidth: plotWidth,
                            labelGutter: labelGutter,
                            topPadding: topPadding
                        )
                    }

                    Path { path in
                        for (index, point) in chartPoints.enumerated() {
                            let location = location(
                                for: point,
                                totalCount: chartPoints.count,
                                plotWidth: plotWidth,
                                plotHeight: plotHeight,
                                maxValue: maxValue,
                                topPadding: topPadding
                            )
                            if index == 0 {
                                path.move(to: location)
                            } else {
                                path.addLine(to: location)
                            }
                        }
                    }
                    .stroke(.orange.gradient, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

                    if let selectedPoint {
                        let selectedX = xPosition(for: selectedPoint.index, totalCount: chartPoints.count, width: plotWidth)
                        selectionLine(x: selectedX, topPadding: topPadding, plotHeight: plotHeight)
                    }

                    ForEach(chartPoints) { point in
                        let location = location(
                            for: point,
                            totalCount: chartPoints.count,
                            plotWidth: plotWidth,
                            plotHeight: plotHeight,
                            maxValue: maxValue,
                            topPadding: topPadding
                        )
                        Button {
                            selectedID = point.id
                        } label: {
                            Circle()
                                .fill(point.id == selectedID ? Color.orange : Color.white)
                                .overlay {
                                    Circle()
                                        .stroke(Color.orange, lineWidth: point.id == selectedID ? 3 : 2)
                                }
                                .frame(width: point.id == selectedID ? 16 : 12, height: point.id == selectedID ? 16 : 12)
                        }
                        .buttonStyle(.plain)
                        .position(location)
                        .accessibilityLabel("\(point.label), \(point.dailyLoad.clean) load")
                    }

                    ForEach(chartPoints) { point in
                        Text(point.label)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .position(
                                x: xPosition(for: point.index, totalCount: chartPoints.count, width: plotWidth),
                                y: topPadding + plotHeight + 18
                            )
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            selectPoint(atX: value.location.x, plotWidth: plotWidth, points: chartPoints)
                        }
                )
            }
        }
    }

    @ViewBuilder
    private var selectedReadout: some View {
        if let selectedPoint {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(selectedPoint.dailyLoad.clean) load")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Text(selectedPoint.dateLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        } else {
            Text("Tap a point to see its load.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var selectedPoint: WeeklyLinePoint? {
        guard let selectedID else { return nil }
        return cumulativePoints.first { $0.id == selectedID }
    }

    private func guideValues(for points: [WeeklyLinePoint]) -> [Double] {
        let maxObserved = points.map(\.cumulativeLoad).max() ?? 0
        var values: [Double] = []
        if let targetLoadPoints, targetLoadPoints > 0 {
            values.append(targetLoadPoints)
            values.append(targetLoadPoints / 2)
            if maxObserved > targetLoadPoints {
                values.append(maxObserved)
            }
        } else if maxObserved > 0 {
            values.append(maxObserved)
            values.append(maxObserved / 2)
        }
        return Array(Set(values.map { round($0 * 10) / 10 }))
            .filter { $0 > 0 }
            .sorted(by: >)
    }

    private func guideLine(
        value: Double,
        maxValue: Double,
        plotHeight: CGFloat,
        plotWidth: CGFloat,
        labelGutter: CGFloat,
        topPadding: CGFloat
    ) -> some View {
        let y = yPosition(for: value, maxValue: maxValue, plotHeight: plotHeight, topPadding: topPadding)
        return ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: plotWidth, y: y))
            }
            .stroke(.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

            Text(guideLabel(for: value))
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.white.opacity(0.72), in: Capsule())
                .position(x: plotWidth + (labelGutter / 2), y: max(10, y - 10))
        }
    }

    private func guideLabel(for value: Double) -> String {
        return value.clean
    }

    private func location(
        for point: WeeklyLinePoint,
        totalCount: Int,
        plotWidth: CGFloat,
        plotHeight: CGFloat,
        maxValue: Double,
        topPadding: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: xPosition(for: point.index, totalCount: totalCount, width: plotWidth),
            y: yPosition(for: point.cumulativeLoad, maxValue: maxValue, plotHeight: plotHeight, topPadding: topPadding)
        )
    }

    private func xPosition(for index: Int, totalCount: Int, width: CGFloat) -> CGFloat {
        guard totalCount > 1 else { return width / 2 }
        return CGFloat(index) / CGFloat(totalCount - 1) * width
    }

    private func yPosition(for value: Double, maxValue: Double, plotHeight: CGFloat, topPadding: CGFloat) -> CGFloat {
        topPadding + plotHeight - (plotHeight * CGFloat(value / maxValue))
    }

    private func selectPoint(atX x: CGFloat, plotWidth: CGFloat, points: [WeeklyLinePoint]) {
        guard !points.isEmpty else { return }
        let clampedX = min(max(x, 0), plotWidth)
        let progress = plotWidth > 0 ? clampedX / plotWidth : 0
        let index = Int((progress * CGFloat(points.count - 1)).rounded())
        selectedID = points[min(max(index, 0), points.count - 1)].id
    }
}

private struct WeeklyLinePoint: Identifiable {
    let id: String
    let index: Int
    let label: String
    let dateLabel: String
    let dailyLoad: Double
    let cumulativeLoad: Double
}

private struct LoadBarChart: View {
    let points: [StrainChartPoint]
    let timeframe: String
    @State private var selectedID: String?

    private var selectedPoint: StrainChartPoint? {
        if let selectedID, let point = points.first(where: { $0.id == selectedID }) {
            return point
        }
        return points.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            selectedReadout

            GeometryReader { proxy in
                let maxValue = max(points.map(\.chartValue).max() ?? 1, 1)
                let chartHeight = max(1, proxy.size.height - 24)
                ZStack(alignment: .bottomLeading) {
                    if let selectedPoint, let selectedIndex = points.firstIndex(where: { $0.id == selectedPoint.id }) {
                        selectionLine(x: barCenterX(for: selectedIndex, width: proxy.size.width), topPadding: 0, plotHeight: chartHeight)
                    }

                    HStack(alignment: .bottom, spacing: barSpacing(for: proxy.size.width)) {
                        ForEach(points) { point in
                            VStack(spacing: 7) {
                                Button {
                                    selectedID = point.id
                                } label: {
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(barColor(for: point).gradient)
                                        .overlay {
                                            if point.id == selectedPoint?.id {
                                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                                    .stroke(.primary.opacity(0.35), lineWidth: 2)
                                            }
                                        }
                                        .frame(height: max(4, proxy.size.height * 0.68 * CGFloat(point.chartValue / maxValue)))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(point.label(for: timeframe)), \(point.readoutValue(for: timeframe).clean) load")

                                Text(point.label(for: timeframe))
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(point.id == selectedPoint?.id ? .primary : .secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.55)
                                    .frame(maxWidth: .infinity)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        selectedID = point.id
                                    }
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

    @ViewBuilder
    private var selectedReadout: some View {
        if let selectedPoint {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(selectedPoint.readoutValue(for: timeframe).clean) load")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Text(selectedPoint.readoutLabel(for: timeframe))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        } else {
            Text("Tap a bar to see its load.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func barSpacing(for width: CGFloat) -> CGFloat {
        timeframe == "year" && points.count > 8 ? 5 : 9
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

private struct ComponentStackBar: View {
    let items: [StrainComponentItem]
    @State private var selectedKey: String?

    private var selectedItem: StrainComponentItem? {
        if let selectedKey, let item = items.first(where: { $0.key == selectedKey }) {
            return item
        }
        return items.max { $0.loadPoints < $1.loadPoints }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            selectedReadout

            GeometryReader { proxy in
                HStack(spacing: 3) {
                    ForEach(items) { item in
                        Button {
                            selectedKey = item.key
                        } label: {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(componentColor(item.key).gradient)
                                .overlay {
                                    if item.key == selectedItem?.key {
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .stroke(.primary.opacity(0.35), lineWidth: 2)
                                    }
                                }
                                .frame(width: max(6, proxy.size.width * CGFloat(item.share ?? 0)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(item.label), \(item.loadPoints.clean) load")
                    }
                }
            }
            .frame(height: 32)

            HStack(spacing: 10) {
                ForEach(items) { item in
                    Button {
                        selectedKey = item.key
                    } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(componentColor(item.key))
                                .frame(width: 7, height: 7)
                            Text(item.label)
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.65)
                        }
                        .foregroundStyle(item.key == selectedItem?.key ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var selectedReadout: some View {
        if let selectedItem {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(selectedItem.loadPoints.clean) load")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Text(selectedItem.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        } else {
            Text("Tap a source to see its load.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

private struct StrainExplanationPanel: View {
    var body: some View {
        Text("Strain is your body's training load. It helps you understand whether you're building steadily, taking it easy, or pushing beyond your usual range.")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .lineSpacing(3)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(cornerRadius: 16)
    }
}

private struct StrainComponentPanel: View {
    let components: StrainComponents

    var body: some View {
        DetailSection(title: "Where It Came From", systemImage: "chart.pie.fill") {
            if components.items.isEmpty {
                Text("No strain load was detected for this timeframe.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 10) {
                    ForEach(components.items) { item in
                        HStack {
                            Label(item.label, systemImage: iconName(for: item.key))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(componentColor(item.key))
                            Spacer()
                            Text("\(item.loadPoints.clean) load")
                                .font(.subheadline.weight(.bold))
                        }
                    }
                }
            }
        }
    }
}

private struct StrainTrainingContextPanel: View {
    let context: StrainTrainingContext
    let timeframe: StrainTimeframe

    var body: some View {
        DetailSection(title: "Training Context", systemImage: "waveform.path.ecg") {
            VStack(spacing: 10) {
                ContextRow(title: "Total load", value: context.totalLoadPoints?.clean)
                ContextRow(title: "Average daily load", value: context.averageDailyLoad?.clean)
                ContextRow(title: "Weekly target", value: context.latestTargetLoadPoints?.clean)
            }
        }
    }
}

private struct StrainContributorsPanel: View {
    let workouts: [WorkoutSummary]
    let timeframe: StrainTimeframe
    let client: DashboardAPIClient
    @State private var selectedGroup: WorkoutContributorGroup?

    private var shouldAggregate: Bool {
        timeframe == .month || timeframe == .year
    }

    private var groups: [WorkoutContributorGroup] {
        let grouped = Dictionary(grouping: workouts) { workout in
            workout.summaryDisplayName
        }
        return grouped.map { label, items in
            let total = items.reduce(0.0) { partial, workout in
                partial + (workout.strainLoadPoints ?? 0)
            }
            let first = items[0]
            return WorkoutContributorGroup(
                id: label,
                label: label,
                count: items.count,
                strainLoadPoints: total,
                iconName: first.summaryIconName,
                tint: first.summaryTint,
                workouts: items.sorted {
                    ($0.startTime ?? "") > ($1.startTime ?? "")
                }
            )
        }
        .sorted {
            if $0.strainLoadPoints == $1.strainLoadPoints {
                return $0.label < $1.label
            }
            return $0.strainLoadPoints > $1.strainLoadPoints
        }
    }

    var body: some View {
        DetailSection(title: "Contributors", systemImage: "figure.run") {
            if workouts.isEmpty {
                Text("No workouts were found for this \(timeframe.rawValue). Daily activity can still contribute to Strain.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if shouldAggregate {
                VStack(spacing: 10) {
                    ForEach(groups) { group in
                        Button {
                            selectedGroup = group
                        } label: {
                            WorkoutContributorGroupRow(group: group)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                VStack(spacing: 10) {
                    ForEach(workouts) { workout in
                        NavigationLink(value: AppRoute.workout(workout.id)) {
                            WorkoutSummaryRow(workout: workout, presentation: .compact)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .sheet(item: $selectedGroup) { group in
            WorkoutContributorGroupSheet(group: group, client: client)
        }
    }
}

private struct WorkoutContributorGroup: Identifiable {
    let id: String
    let label: String
    let count: Int
    let strainLoadPoints: Double
    let iconName: String
    let tint: Color
    let workouts: [WorkoutSummary]
}

private struct WorkoutContributorGroupRow: View {
    let group: WorkoutContributorGroup

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: group.iconName)
                .font(.headline)
                .foregroundStyle(group.tint)
                .frame(width: 30, height: 30)
                .background(group.tint.opacity(0.13), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(group.label)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                Text("\(group.count) \(group.count == 1 ? "workout" : "workouts")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            VStack(alignment: .trailing, spacing: 0) {
                Text(group.strainLoadPoints.clean)
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text("strain")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct WorkoutContributorGroupSheet: View {
    let group: WorkoutContributorGroup
    let client: DashboardAPIClient
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(group.workouts) { workout in
                        NavigationLink(value: AppRoute.workout(workout.id)) {
                            WorkoutSummaryRow(workout: workout, presentation: .compact)
                                .padding(14)
                                .frame(maxWidth: .infinity)
                                .background(.white.opacity(0.46), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(18)
            }
            .background(Color(.systemGroupedBackground).opacity(0.35))
            .navigationTitle(group.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(group.strainLoadPoints.clean)
                            .font(.headline.weight(.bold))
                            .monospacedDigit()
                        Text("strain")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationDestination(for: AppRoute.self) { route in
                switch route {
                case .workout(let workoutID):
                    WorkoutDetailView(workoutID: workoutID, client: client)
                case .metric(let metric):
                    PlaceholderDetailView(
                        title: metric,
                        systemImage: "chart.line.uptrend.xyaxis",
                        message: "This dashboard detail screen is reserved for trends, baselines, and explanations."
                    )
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct DetailSection<Content: View>: View {
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

private struct ContextRow: View {
    let title: String
    let value: String?

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value ?? "--")
                .font(.subheadline.weight(.bold))
                .multilineTextAlignment(.trailing)
        }
    }
}

private func componentColor(_ key: String) -> Color {
    switch key {
    case "workouts": return .orange
    case "general_activity": return .teal
    case "cardio_load": return .orange
    case "daily_activity_load": return .teal
    case "muscular_load": return .purple
    case "source_zone_load": return .blue
    default: return .gray
    }
}

private func iconName(for key: String) -> String {
    switch key {
    case "workouts": return "figure.run"
    case "general_activity": return "figure.walk"
    case "cardio_load": return "heart.fill"
    case "daily_activity_load": return "shoeprints.fill"
    case "muscular_load": return "dumbbell.fill"
    case "source_zone_load": return "waveform.path.ecg"
    default: return "circle.fill"
    }
}

private func bandColor(_ band: String) -> Color {
    switch band {
    case "below": return .blue
    case "steady": return .green
    case "above": return .orange
    case "well_above": return .red
    default: return .secondary
    }
}

private func barColor(for point: StrainChartPoint) -> Color {
    if let band = point.loadBand {
        return bandColor(band)
    }
    return .orange
}

private extension StrainChartPoint {
    var chartValue: Double {
        averageWeeklyLoad ?? loadPoints ?? totalLoadPoints ?? 0
    }

    func readoutValue(for timeframe: String) -> Double {
        if timeframe == "year" {
            return totalLoadPoints ?? chartValue
        }
        return chartValue
    }

    func readoutLabel(for timeframe: String) -> String {
        if timeframe == "year", let monthStartDate {
            return ScoreDateFormatters.monthReadoutLabel(from: monthStartDate)
        }
        if let weekStartDate {
            return "Week of \(ScoreDateFormatters.shortDateLabel(from: weekStartDate))"
        }
        if let date {
            return ScoreDateFormatters.weeklySelectedDateLabel(from: date)
        }
        return label(for: timeframe)
    }

    func label(for timeframe: String) -> String {
        if timeframe == "year", let monthStartDate {
            return ScoreDateFormatters.monthLabel(from: monthStartDate)
        }
        if let weekStartDate {
            return ScoreDateFormatters.shortDateLabel(from: weekStartDate)
        }
        if let date {
            return ScoreDateFormatters.weekdayLabel(from: date)
        }
        return "--"
    }

    var weeklyDateLabel: String {
        guard let date else { return "" }
        return ScoreDateFormatters.weeklySelectedDateLabel(from: date)
    }
}

#Preview {
    NavigationStack {
        StrainDetailView(client: DashboardAPIClient())
    }
}
