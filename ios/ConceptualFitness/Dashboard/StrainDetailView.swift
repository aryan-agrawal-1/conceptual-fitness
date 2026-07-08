import SwiftUI

struct StrainDetailView: View {
    let client: DashboardAPIClient

    var body: some View {
        MetricDetailScreen(
            title: "Strain",
            metricName: "Strain",
            timeframeAccessibilityLabel: "Strain timeframe",
            timeframes: StrainTimeframe.allCases,
            initialTimeframe: .week,
            backendBaseURL: client.baseURL,
            load: { date, timeframe in
                try await client.loadStrainDetail(date: date, timeframe: timeframe)
            }
        ) { detail, timeframe in
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
    }
}

private struct StrainSummaryPanel: View {
    let detail: StrainDetail

    var body: some View {
        MetricHeroPanel(
            eyebrow: "Training load",
            headline: heroHeadline,
            value: primaryLoadText,
            unit: "load",
            caption: heroCaption,
            accent: HealthTheme.strain,
            stats: heroStats,
            ring: MetricHeroRing(
                value: ringValueText,
                unit: ringUnit,
                caption: ringCaption,
                progress: ringProgress,
                tint: HealthTheme.strain,
                accessibilityLabel: "Strain \(ringValueText ?? "no data")"
            ),
            accessibilityLabel: "Strain load \(primaryLoadText ?? "no data")"
        )
    }

    private var primaryLoadText: String? {
        primaryLoad.map(\.clean)
    }

    private var primaryLoad: Double? {
        switch detail.timeframe {
        case "week":
            return detail.summary.progressLoadPoints ?? detail.summary.loadPoints
        case "month", "year":
            return detail.summary.averageWeeklyLoad
        default:
            return detail.summary.primaryValue ?? detail.summary.loadPoints
        }
    }

    private var heroCaption: String {
        switch detail.timeframe {
        case "week": return "current load"
        case "month", "year": return "weekly average"
        default: return "today"
        }
    }

    private var heroHeadline: String {
        if let paceHeadline {
            return paceHeadline
        }
        if let pill = headerPill {
            return pill.title
        }
        return detail.summary.title ?? detail.timeframe.displayTitle
    }

    private var heroColor: Color {
        headerPill?.color ?? .orange
    }

    private var ringValueText: String? {
        if detail.timeframe == "week", detail.summary.targetLoadPoints != nil {
            return progressPercentText
        }
        return primaryLoadText
    }

    private var ringUnit: String {
        detail.timeframe == "week" && detail.summary.targetLoadPoints != nil ? "" : "load"
    }

    private var ringCaption: String {
        if detail.timeframe == "week", detail.summary.targetLoadPoints != nil {
            return "target"
        }
        if detail.timeframe == "month" || detail.timeframe == "year" {
            return "wk avg"
        }
        return heroCaption
    }

    private var ringProgress: Double {
        if let ratio = detail.summary.progressRatio {
            return min(max(ratio, 0), 1.25)
        }
        if let current = primaryLoad, let target = detail.summary.targetLoadPoints, target > 0 {
            return min(max(current / target, 0), 1.25)
        }
        return min(max((primaryLoad ?? 0) / 100, 0), 1)
    }

    private var paceHeadline: String? {
        guard detail.timeframe == "week" || detail.timeframe == "month" || detail.timeframe == "year",
              let progress = progressRatioForPace,
              let expected = expectedProgressForCurrentPeriod
        else { return nil }
        if progress >= 1 { return "Goal met" }
        if progress >= expected * 0.85 && progress <= expected * 1.25 { return "On track" }
        if progress > expected * 1.25 { return "Ahead of pace" }
        return "Behind pace"
    }

    private var progressRatioForPace: Double? {
        if let ratio = detail.summary.progressRatio {
            return ratio
        }
        guard let current = primaryLoad, let target = detail.summary.targetLoadPoints, target > 0 else {
            return nil
        }
        return current / target
    }

    private var expectedProgressForCurrentPeriod: Double? {
        guard let startDate = ScoreDateFormatters.apiDate.date(from: detail.start),
              let endDate = ScoreDateFormatters.apiDate.date(from: detail.end)
        else { return nil }

        let calendar = ScoreDateFormatters.calendar
        let start = calendar.startOfDay(for: startDate)
        let end = calendar.startOfDay(for: endDate)
        let today = calendar.startOfDay(for: Date())
        guard start <= today, today <= end else { return nil }

        let elapsedEnd = min(today, end)
        let elapsedDays = (calendar.dateComponents([.day], from: start, to: elapsedEnd).day ?? 0) + 1
        let totalDays = (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1
        guard totalDays > 0 else { return nil }
        return min(max(Double(elapsedDays) / Double(totalDays), 0), 1)
    }

    private var heroStats: [MetricHeroStat] {
        switch detail.timeframe {
        case "week":
            return [
                MetricHeroStat(title: "Target", value: detail.summary.targetLoadPoints?.clean ?? "--", tint: .green),
                MetricHeroStat(title: "Progress", value: progressPercentText, tint: HealthTheme.strain),
                MetricHeroStat(title: "Band", value: (detail.summary.loadBand ?? detail.trainingContext.latestLoadBand)?.displayTitle ?? "--", tint: heroColor)
            ]
        case "month", "year":
            return [
                MetricHeroStat(title: "Total", value: detail.summary.loadPoints?.clean ?? "--", tint: HealthTheme.strain),
                MetricHeroStat(title: "Weeks", value: detail.summary.weekCount.map(String.init) ?? "--", tint: .secondary),
                MetricHeroStat(title: "Band", value: (detail.summary.loadBand ?? detail.trainingContext.latestLoadBand)?.displayTitle ?? "--", tint: heroColor)
            ]
        default:
            return [
                MetricHeroStat(title: "Quality", value: detail.summary.dataQuality?.displayTitle ?? "--", tint: heroColor),
                MetricHeroStat(title: "Acute", value: detail.summary.acuteLoadPoints?.clean ?? "--", tint: HealthTheme.strain),
                MetricHeroStat(title: "Chronic", value: detail.summary.chronicLoadPoints?.clean ?? "--", tint: .secondary)
            ]
        }
    }

    private var progressPercentText: String {
        let ratio = detail.summary.progressRatio ?? {
            guard let current = primaryLoad, let target = detail.summary.targetLoadPoints, target > 0 else {
                return nil
            }
            return current / target
        }()
        guard let ratio else { return "--" }
        return "\(Int((ratio * 100).rounded()))%"
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
        SharedChartGeometry.xPosition(index: index, count: totalCount, width: width)
    }

    private func yPosition(for value: Double, maxValue: Double, plotHeight: CGFloat, topPadding: CGFloat) -> CGFloat {
        topPadding + plotHeight - (plotHeight * CGFloat(value / maxValue))
    }

    private func selectPoint(atX x: CGFloat, plotWidth: CGFloat, points: [WeeklyLinePoint]) {
        guard let index = SharedChartGeometry.nearestIndex(to: x, width: plotWidth, count: points.count) else {
            return
        }
        selectedID = points[index].id
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
        StrainDetailSection(title: "Where It Came From", systemImage: "chart.pie.fill") {
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
        StrainDetailSection(title: "Training Context", systemImage: "waveform.path.ecg") {
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
        StrainDetailSection(title: "Contributors", systemImage: "figure.run") {
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

private struct StrainDetailSection<Content: View>: View {
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

private typealias ContextRow = MetricSummaryRow

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
