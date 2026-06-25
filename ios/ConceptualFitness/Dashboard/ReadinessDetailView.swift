import SwiftUI

struct ReadinessDetailView: View {
    let client: DashboardAPIClient

    @State private var timeframe: ScoreTimeframe = .week
    @State private var selectedDate = Date()
    @State private var loadState: ReadinessDetailLoadState = .loading
    @State private var calendarSelection: ScoreCalendarSelection?

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    timeframePicker
                    ScoreRangeNavigator(
                        timeframe: timeframe,
                        metricName: "Readiness",
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
        .navigationTitle("Readiness")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: loadKey) {
            await load()
        }
        .refreshable {
            await load()
        }
        .sheet(item: $calendarSelection) { selection in
            ScoreCalendarPicker(metricName: "Readiness", selection: selection) { nextDate in
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
        .accessibilityLabel("Readiness timeframe")
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
                Text("Could not load Readiness")
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

    private func loadedContent(_ detail: ReadinessDetail) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ReadinessSummaryPanel(detail: detail)
            ReadinessChartPanel(detail: detail, timeframe: timeframe)
            ReadinessDriverPanel(components: detail.components, timeframe: timeframe)
            ReadinessContextPanel(context: detail.context)
            if !detail.reasons.isEmpty {
                ReadinessReasonsPanel(reasons: detail.reasons)
            }
            ReadinessGuidancePanel(message: detail.guidance.message)
            if shouldShowDataQuality(detail.dataQuality) {
                ReadinessDataQualityPanel(dataQuality: detail.dataQuality)
            }
        }
    }

    private func shouldShowDataQuality(_ dataQuality: ReadinessDataQuality) -> Bool {
        guard let completeness = dataQuality.completeness else { return true }
        return completeness < 0.8
    }

    @MainActor
    private func load() async {
        loadState = .loading
        do {
            loadState = .loaded(try await client.loadReadinessDetail(date: selectedDate, timeframe: timeframe))
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

private enum ReadinessDetailLoadState {
    case loading
    case loaded(ReadinessDetail)
    case failed(String)
}

private struct ReadinessSummaryPanel: View {
    let detail: ReadinessDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(detail.summary.title ?? "Readiness")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text(primaryValue)
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }

                Spacer()

                if let band = detail.summary.readinessBand {
                    Text(band.displayTitle)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(readinessColor(band).opacity(0.16), in: Capsule())
                        .foregroundStyle(readinessColor(band))
                }
            }

            HStack(spacing: 12) {
                SummaryChip(title: "Trend", value: detail.summary.trend?.displayTitle ?? "--", tint: trendColor(detail.summary.trend))
                SummaryChip(title: "Low days", value: detail.summary.lowDays.map(String.init) ?? "--", tint: .red)
                SummaryChip(title: "High days", value: detail.summary.highDays.map(String.init) ?? "--", tint: .green)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 20)
    }

    private var primaryValue: String {
        guard let value = detail.summary.primaryValue else { return "--" }
        if detail.timeframe == "day" {
            return value.clean
        }
        return "\(value.clean) avg"
    }
}

private struct SummaryChip: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(.white.opacity(0.42), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct ReadinessChartPanel: View {
    let detail: ReadinessDetail
    let timeframe: ScoreTimeframe

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(chartTitle)
                .font(.headline)

            if detail.chart.kind == "component_scores" {
                ComponentScoreChart(items: detail.components.items)
                    .frame(minHeight: 214)
            } else if detail.chart.kind == "monthly_average_scores" {
                MonthlyReadinessBars(points: detail.chart.points)
                    .frame(height: 210)
            } else {
                ReadinessLineChart(points: detail.chart.points, timeframe: timeframe)
                    .frame(height: timeframe == .month ? 250 : 220)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 20)
    }

    private var chartTitle: String {
        switch detail.chart.kind {
        case "component_scores": return "Today's drivers"
        case "monthly_average_scores": return "Monthly readiness"
        default: return timeframe == .month ? "Daily readiness" : "Weekly pattern"
        }
    }
}

private struct ComponentScoreChart: View {
    let items: [ReadinessComponentItem]

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
                                .fill(readinessColor(for: item.score).gradient)
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

private struct ReadinessLineChart: View {
    let points: [ReadinessChartPoint]
    let timeframe: ScoreTimeframe
    @State private var selectedID: String?

    private var plottablePoints: [ReadinessChartPoint] {
        points.filter { $0.score != nil }
    }

    private var selectedPoint: ReadinessChartPoint? {
        if let selectedID, let point = plottablePoints.first(where: { $0.id == selectedID }) {
            return point
        }
        return plottablePoints.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            selectedReadout

            GeometryReader { proxy in
                let plotPoints = plottablePoints
                let topPadding: CGFloat = 18
                let bottomPadding: CGFloat = 36
                let plotHeight = max(1, proxy.size.height - topPadding - bottomPadding)
                let plotWidth = max(1, proxy.size.width)

                ZStack(alignment: .topLeading) {
                    thresholdLine(value: 80, title: "High", proxy: proxy, topPadding: topPadding, plotHeight: plotHeight)
                    thresholdLine(value: 60, title: "Low", proxy: proxy, topPadding: topPadding, plotHeight: plotHeight)

                    Path { path in
                        for (index, point) in plotPoints.enumerated() {
                            let location = location(
                                for: point,
                                index: index,
                                count: plotPoints.count,
                                width: plotWidth,
                                height: plotHeight,
                                topPadding: topPadding
                            )
                            if index == 0 {
                                path.move(to: location)
                            } else {
                                path.addLine(to: location)
                            }
                        }
                    }
                    .stroke(Color.blue.gradient, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

                    ForEach(Array(plotPoints.enumerated()), id: \.element.id) { index, point in
                        let location = location(
                            for: point,
                            index: index,
                            count: plotPoints.count,
                            width: plotWidth,
                            height: plotHeight,
                            topPadding: topPadding
                        )
                        Button {
                            selectedID = point.id
                        } label: {
                            Circle()
                                .fill(point.id == selectedPoint?.id ? readinessColor(point.readinessBand ?? "") : Color.white)
                                .overlay {
                                    Circle()
                                        .stroke(readinessColor(point.readinessBand ?? ""), lineWidth: point.id == selectedPoint?.id ? 3 : 2)
                                }
                                .frame(width: point.id == selectedPoint?.id ? 16 : 12, height: point.id == selectedPoint?.id ? 16 : 12)
                        }
                        .buttonStyle(.plain)
                        .position(location)
                        .accessibilityLabel("\(point.label(for: timeframe)), readiness \(point.score?.clean ?? "--")")
                    }

                    ForEach(Array(labelPoints(plotPoints).enumerated()), id: \.element.id) { index, point in
                        Text(point.label(for: timeframe))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .position(
                                x: xPosition(for: index, count: labelPoints(plotPoints).count, width: plotWidth),
                                y: topPadding + plotHeight + 20
                            )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var selectedReadout: some View {
        if let selectedPoint, let score = selectedPoint.score {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(score.clean)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                Text(selectedPoint.readoutLabel(for: timeframe))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        } else {
            Text("No readiness scores in this range yet.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func thresholdLine(value: Double, title: String, proxy: GeometryProxy, topPadding: CGFloat, plotHeight: CGFloat) -> some View {
        let y = yPosition(for: value, height: plotHeight, topPadding: topPadding)
        return ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: proxy.size.width, y: y))
            }
            .stroke(.secondary.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.white.opacity(0.72), in: Capsule())
                .position(x: proxy.size.width - 24, y: max(10, y - 10))
        }
    }

    private func labelPoints(_ points: [ReadinessChartPoint]) -> [ReadinessChartPoint] {
        guard timeframe == .month, points.count > 10 else { return points }
        return points.enumerated().compactMap { index, point in
            index % 5 == 0 || index == points.count - 1 ? point : nil
        }
    }

    private func location(
        for point: ReadinessChartPoint,
        index: Int,
        count: Int,
        width: CGFloat,
        height: CGFloat,
        topPadding: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: xPosition(for: index, count: count, width: width),
            y: yPosition(for: point.score ?? 0, height: height, topPadding: topPadding)
        )
    }

    private func xPosition(for index: Int, count: Int, width: CGFloat) -> CGFloat {
        guard count > 1 else { return width / 2 }
        return CGFloat(index) / CGFloat(count - 1) * width
    }

    private func yPosition(for value: Double, height: CGFloat, topPadding: CGFloat) -> CGFloat {
        topPadding + height - (height * CGFloat(min(max(value / 100, 0), 1)))
    }
}

private struct MonthlyReadinessBars: View {
    let points: [ReadinessChartPoint]
    @State private var selectedID: String?

    private var selectedPoint: ReadinessChartPoint? {
        if let selectedID, let point = points.first(where: { $0.id == selectedID }) {
            return point
        }
        return points.last { $0.averageScore != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            selectedReadout

            GeometryReader { proxy in
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(points) { point in
                        VStack(spacing: 7) {
                            Button {
                                selectedID = point.id
                            } label: {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(readinessColor(for: point.averageScore).gradient)
                                    .opacity(point.averageScore == nil ? 0.22 : 1)
                                    .overlay {
                                        if point.id == selectedPoint?.id {
                                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                                .stroke(.primary.opacity(0.35), lineWidth: 2)
                                        }
                                    }
                                    .frame(height: max(4, proxy.size.height * 0.68 * CGFloat((point.averageScore ?? 0) / 100)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(point.label(for: .year)), average readiness \(point.averageScore?.clean ?? "no data")")

                            Text(point.label(for: .year))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(point.id == selectedPoint?.id ? .primary : .secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var selectedReadout: some View {
        if let selectedPoint, let score = selectedPoint.averageScore {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(score.clean) avg")
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
}

private struct ReadinessDriverPanel: View {
    let components: ReadinessComponents
    let timeframe: ScoreTimeframe

    private var displayedItems: [ReadinessComponentItem] {
        timeframe == .day ? components.items : components.averageItems
    }

    var body: some View {
        ReadinessSection(title: timeframe == .day ? "What Moved It" : "Average Drivers", systemImage: "slider.horizontal.3") {
            if displayedItems.isEmpty {
                Text("Readiness drivers will appear when recovery data is available.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 12) {
                    ForEach(displayedItems) { item in
                        HStack(spacing: 12) {
                            Image(systemName: iconName(for: item.key))
                                .font(.headline)
                                .foregroundStyle(componentColor(item.key))
                                .frame(width: 30, height: 30)
                                .background(componentColor(item.key).opacity(0.13), in: Circle())

                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.label)
                                    .font(.subheadline.weight(.bold))
                                if let message = item.message, timeframe == .day {
                                    Text(message)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }

                            Spacer()

                            Text(item.score.clean)
                                .font(.title3.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(readinessColor(for: item.score))
                        }
                    }
                }
            }
        }
    }
}

private struct ReadinessContextPanel: View {
    let context: ReadinessContext

    var body: some View {
        ReadinessSection(title: "Recovery Context", systemImage: "waveform.path.ecg") {
            VStack(spacing: 10) {
                ReadinessContextRow(title: "Sleep debt", value: sleepDebtText)
                ReadinessContextRow(title: "HRV baseline score", value: context.hrvScore?.clean)
                ReadinessContextRow(title: "Resting HR score", value: context.rhrScore?.clean)
                ReadinessContextRow(title: "Recent load ratio", value: context.loadRatio.map { "\($0.clean)x" })
                ReadinessContextRow(title: "Yesterday load", value: context.yesterdayLoad?.clean)
                ReadinessContextRow(title: "Confidence", value: context.confidencePhase?.displayTitle)
            }
        }
    }

    private var sleepDebtText: String? {
        guard let minutes = context.sleepDebtMinutes7d else { return nil }
        return "\(round(minutes / 60 * 10) / 10)h"
    }
}

private struct ReadinessReasonsPanel: View {
    let reasons: [ScoreReason]

    var body: some View {
        ReadinessSection(title: "Reasons", systemImage: "exclamationmark.circle.fill") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(reasons.enumerated()), id: \.offset) { _, reason in
                    HStack(alignment: .top, spacing: 10) {
                        Circle()
                            .fill(reason.direction == "negative" ? Color.orange : Color.green)
                            .frame(width: 8, height: 8)
                            .padding(.top, 6)
                        Text(reason.message ?? reason.code?.displayTitle ?? "Readiness changed.")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

private struct ReadinessGuidancePanel: View {
    let message: String?

    var body: some View {
        Text(message ?? "Use readiness with recent strain and how you feel before choosing the day.")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .lineSpacing(3)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(cornerRadius: 16)
    }
}

private struct ReadinessDataQualityPanel: View {
    let dataQuality: ReadinessDataQuality

    var body: some View {
        ReadinessSection(title: "Data Quality", systemImage: "checkmark.seal.fill") {
            VStack(spacing: 10) {
                ReadinessContextRow(title: "Scored days", value: scoredDaysText)
                ReadinessContextRow(title: "Completeness", value: completenessText)
            }
        }
    }

    private var scoredDaysText: String? {
        guard let scored = dataQuality.scoredDays, let expected = dataQuality.expectedDays else { return nil }
        return "\(scored) / \(expected)"
    }

    private var completenessText: String? {
        guard let completeness = dataQuality.completeness else { return nil }
        return "\(Int((completeness * 100).rounded()))%"
    }
}

private struct ReadinessSection<Content: View>: View {
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

private struct ReadinessContextRow: View {
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

private extension ReadinessChartPoint {
    func label(for timeframe: ScoreTimeframe) -> String {
        if timeframe == .year, let monthStartDate {
            return ScoreDateFormatters.monthLabel(from: monthStartDate)
        }
        if let date {
            return timeframe == .month
                ? ScoreDateFormatters.shortDateLabel(from: date)
                : ScoreDateFormatters.weekdayLabel(from: date)
        }
        return label ?? "--"
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

private func readinessColor(_ band: String) -> Color {
    switch band {
    case "high": return .green
    case "medium": return .blue
    case "low": return .red
    default: return .secondary
    }
}

private func readinessColor(for score: Double?) -> Color {
    guard let score else { return .secondary }
    if score >= 80 { return .green }
    if score >= 60 { return .blue }
    return .red
}

private func trendColor(_ trend: String?) -> Color {
    switch trend {
    case "improving": return .green
    case "declining": return .orange
    case "steady": return .blue
    default: return .secondary
    }
}

private func componentColor(_ key: String) -> Color {
    switch key {
    case "sleep_adequacy_debt": return .indigo
    case "autonomic_recovery": return .teal
    case "recent_load_fit": return .orange
    case "illness_anomaly_context": return .red
    case "confidence": return .blue
    default: return .secondary
    }
}

private func iconName(for key: String) -> String {
    switch key {
    case "sleep_adequacy_debt": return "bed.double.fill"
    case "autonomic_recovery": return "heart.fill"
    case "recent_load_fit": return "figure.run"
    case "illness_anomaly_context": return "cross.case.fill"
    case "confidence": return "checkmark.seal.fill"
    default: return "circle.fill"
    }
}

#Preview {
    NavigationStack {
        ReadinessDetailView(client: DashboardAPIClient())
    }
}
