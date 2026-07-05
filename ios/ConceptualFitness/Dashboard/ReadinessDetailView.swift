import SwiftUI

struct ReadinessDetailView: View {
    let client: DashboardAPIClient

    var body: some View {
        MetricDetailScreen(
            title: "Readiness",
            metricName: "Readiness",
            timeframeAccessibilityLabel: "Readiness timeframe",
            timeframes: ScoreTimeframe.allCases,
            initialTimeframe: .week,
            backendBaseURL: client.baseURL,
            load: { date, timeframe in
                try await client.loadReadinessDetail(date: date, timeframe: timeframe)
            }
        ) { detail, timeframe in
            VStack(alignment: .leading, spacing: 18) {
                ReadinessSummaryPanel(detail: detail)
                ReadinessExplanationPanel()
                ReadinessChartPanel(detail: detail, timeframe: timeframe)
                if timeframe != .day {
                    ReadinessDriverPanel(components: detail.components)
                }
                ReadinessContextPanel(context: detail.context, timeframe: timeframe)
                if !detail.reasons.isEmpty {
                    ReadinessReasonsPanel(reasons: detail.reasons)
                }
            }
        }
    }
}

private struct ReadinessSummaryPanel: View {
    let detail: ReadinessDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(detail.summary.title ?? "Readiness")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                if let band = detail.summary.readinessBand {
                    StatusPill(title: band.displayTitle, color: readinessColor(band))
                }
            }

            HStack(spacing: 18) {
                ReadinessProgressCircle(
                    value: detail.summary.primaryValue,
                    band: detail.summary.readinessBand,
                    label: detail.timeframe == "day" ? nil : "avg"
                )
                .frame(width: 112, height: 112)

                if detail.timeframe == "day" {
                    VStack(spacing: 9) {
                        SummaryMetricRow(title: "Sleep debt (7d)", value: sleepDebtText(detail.context.sleepDebtValue), tint: .indigo)
                        SummaryMetricRow(title: "HRV", value: baselineText(detail.context.hrvBaselineRelation), tint: .teal)
                        SummaryMetricRow(title: "RHR", value: baselineText(detail.context.rhrBaselineRelation), tint: .teal)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    VStack(spacing: 9) {
                        SummaryMetricRow(title: "Trend", value: detail.summary.trend?.displayTitle, tint: trendColor(detail.summary.trend))
                        SummaryMetricRow(title: "High days", value: detail.summary.highDays.map(String.init), tint: .green)
                        SummaryMetricRow(title: "Low days", value: detail.summary.lowDays.map(String.init), tint: .red)
                    }
                    .frame(maxWidth: .infinity)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 20)
    }
}

private struct ReadinessProgressCircle: View {
    let value: Double?
    let band: String?
    let label: String?

    private var ratio: Double {
        min(max((value ?? 0) / 100, 0), 1)
    }

    var body: some View {
        CircularProgressMetric(
            progress: ratio,
            tint: readinessColor(band ?? ""),
            accessibilityLabel: "Readiness \(value?.clean ?? "no score")"
        ) {
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
    }
}

private typealias SummaryMetricRow = MetricSummaryRow

private struct ReadinessExplanationPanel: View {
    var body: some View {
        Text("Readiness is a 0-100 snapshot of how prepared your body looks for training today. Higher scores suggest you may tolerate more stress, while lower scores suggest giving recovery more priority.")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .lineSpacing(3)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(cornerRadius: 16)
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

                    if let selectedPoint,
                       let selectedIndex = plotPoints.firstIndex(where: { $0.id == selectedPoint.id }) {
                        let selectedX = xPosition(for: selectedIndex, count: plotPoints.count, width: plotWidth)
                        selectionLine(x: selectedX, topPadding: topPadding, plotHeight: plotHeight)
                    }

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
                                        .stroke(readinessColor(point.readinessBand ?? ""), lineWidth: nodeStrokeWidth(for: point))
                                }
                                .frame(width: nodeSize(for: point), height: nodeSize(for: point))
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
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            selectPoint(atX: value.location.x, width: plotWidth, points: plotPoints)
                        }
                )
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

    private func nodeSize(for point: ReadinessChartPoint) -> CGFloat {
        if timeframe == .month {
            return point.id == selectedPoint?.id ? 9 : 6
        }
        return point.id == selectedPoint?.id ? 12 : 8
    }

    private func nodeStrokeWidth(for point: ReadinessChartPoint) -> CGFloat {
        if timeframe == .month {
            return point.id == selectedPoint?.id ? 2 : 1.25
        }
        return point.id == selectedPoint?.id ? 2.5 : 1.75
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
        SharedChartGeometry.xPosition(index: index, count: count, width: width)
    }

    private func yPosition(for value: Double, height: CGFloat, topPadding: CGFloat) -> CGFloat {
        topPadding + height - (height * CGFloat(min(max(value / 100, 0), 1)))
    }

    private func selectPoint(atX x: CGFloat, width: CGFloat, points: [ReadinessChartPoint]) {
        guard !points.isEmpty else { return }
        let clampedX = min(max(x, 0), max(width, 1))
        let progress = clampedX / max(width, 1)
        let index = Int((progress * CGFloat(points.count - 1)).rounded())
        selectedID = points[min(max(index, 0), points.count - 1)].id
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
                let chartHeight = max(1, proxy.size.height - 24)
                ZStack(alignment: .bottomLeading) {
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

    private func selectPoint(atX x: CGFloat, width: CGFloat) {
        guard let index = SharedChartGeometry.nearestBucketIndex(to: x, width: width, count: points.count) else {
            return
        }
        selectedID = points[index].id
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

private struct ReadinessDriverPanel: View {
    let components: ReadinessComponents

    private var displayedItems: [ReadinessComponentItem] { components.averageItems }

    var body: some View {
        ReadinessSection(title: "Average Drivers", systemImage: "slider.horizontal.3") {
            if displayedItems.isEmpty {
                Text("Readiness drivers will appear when recovery data is available.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ComponentScoreChart(items: displayedItems)
            }
        }
    }
}

private struct ReadinessContextPanel: View {
    let context: ReadinessContext
    let timeframe: ScoreTimeframe

    var body: some View {
        ReadinessSection(title: "Recovery Context", systemImage: "waveform.path.ecg") {
            VStack(spacing: 10) {
                ReadinessContextRow(title: sleepDebtTitle, value: sleepDebtText(context.sleepDebtValue))
                ReadinessContextRow(title: "HRV", value: baselineText(context.hrvBaselineRelation))
                ReadinessContextRow(title: "Resting HR", value: baselineText(context.rhrBaselineRelation))
                ReadinessContextRow(title: "Recent load ratio", value: context.loadRatio.map { "\($0.clean)x" })
                if timeframe == .day {
                    ReadinessContextRow(title: "Yesterday load", value: context.yesterdayLoad?.clean)
                }
                ReadinessContextRow(title: "Confidence", value: context.confidencePhase?.displayTitle)
            }
        }
    }

    private var sleepDebtTitle: String {
        switch timeframe {
        case .day, .week:
            return "Sleep debt (7d)"
        case .month:
            return "Sleep debt (month)"
        case .year:
            return "Sleep debt (year)"
        }
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
                        Text(reasonMessage(reason))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func reasonMessage(_ reason: ScoreReason) -> String {
        let fallback = reason.code?.displayTitle ?? "Readiness changed."
        return (reason.message ?? fallback).normalizedReasonText
    }
}

private struct ReadinessSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        DetailSection(title: title, systemImage: systemImage, spacing: 12, cornerRadius: 18) {
            content
        }
    }
}

private typealias ReadinessContextRow = MetricSummaryRow

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

private func sleepDebtText(_ minutes: Double?) -> String? {
    guard let minutes else { return nil }
    return "\(round(minutes / 60 * 10) / 10)h"
}

private func baselineText(_ relation: String?) -> String? {
    switch relation {
    case "above_baseline": return "Above baseline"
    case "below_baseline": return "Below baseline"
    case "at_baseline": return "At baseline"
    default: return nil
    }
}

private extension String {
    var normalizedReasonText: String {
        replacingOccurrences(of: "_", with: " ")
    }
}

#Preview {
    NavigationStack {
        ReadinessDetailView(client: DashboardAPIClient())
    }
}
