import SwiftUI

typealias DistanceDetail = StepsDetail

struct DistanceDetailView: View {
    let client: DashboardAPIClient

    var body: some View {
        MetricDetailScreen(
            title: "Distance",
            metricName: "Distance",
            timeframeAccessibilityLabel: "Distance timeframe",
            timeframes: ScoreTimeframe.allCases,
            initialTimeframe: .day,
            backendBaseURL: client.baseURL,
            load: { date, timeframe in
                try await client.loadDistanceDetail(date: date, timeframe: timeframe)
            }
        ) { detail, timeframe in
            VStack(alignment: .leading, spacing: 18) {
                DistanceSummaryPanel(detail: detail, timeframe: timeframe)
                DistanceChartPanel(detail: detail, timeframe: timeframe)
                DistancePatternPanel(detail: detail, timeframe: timeframe)
                if timeframe != .day {
                    DistanceConsistencyPanel(detail: detail, timeframe: timeframe)
                }
            }
        }
    }
}

private struct DistanceSummaryPanel: View {
    let detail: DistanceDetail
    let timeframe: ScoreTimeframe

    private var dailyValues: [Double] {
        distanceValues(from: detail.chart.points)
    }

    private var displayPoints: [DistancePeriodPoint] {
        DistancePeriodPoint.points(from: detail.chart.points, timeframe: timeframe)
    }

    private var hourlyPoints: [DistanceHourlyPoint] {
        DistanceHourlyPoint.points(from: detail.intraday.points)
    }

    private var periodTotal: Double {
        dailyValues.reduce(0, +)
    }

    private var dayTotal: Double? {
        detail.summary.latestValue ?? dailyValues.first
    }

    private var primaryValue: Double? {
        timeframe == .day ? dayTotal : detail.summary.primaryValue
    }

    var body: some View {
        MetricHeroPanel(
            eyebrow: "Distance",
            headline: statusTitle,
            value: distanceText(primaryValue),
            unit: "",
            caption: primaryLabel,
            accent: HealthTheme.distance,
            stats: [
                MetricHeroStat(title: totalRowTitle, value: distanceText(timeframe == .day ? dayTotal : periodTotal), tint: HealthTheme.distance),
                MetricHeroStat(title: bestRowTitle, value: bestValueText, tint: .green),
                MetricHeroStat(title: "Trend", value: metricHeroTrendText(detail.summary.trend), tint: statusColor)
            ],
            accessibilityLabel: "\(distanceText(primaryValue)) \(primaryLabel)"
        )
    }

    private var primaryLabel: String {
        timeframe == .day ? "total distance" : "daily average"
    }

    private var totalRowTitle: String {
        timeframe == .day ? "Today" : "Period total"
    }

    private var bestRowTitle: String {
        if timeframe == .day {
            return "Active hours"
        }
        return timeframe == .year ? "Best month" : "Best day"
    }

    private var bestValueText: String {
        if timeframe == .day {
            let activeHours = hourlyPoints.filter { ($0.value ?? 0) > 0 }.count
            return detail.intraday.available ? "\(activeHours) / 24" : "--"
        }
        guard let best = displayPoints.max(by: { ($0.value ?? 0) < ($1.value ?? 0) }), let value = best.value else {
            return "--"
        }
        return "\(distanceText(value)) \(best.shortReadout(for: timeframe))"
    }

    private var statusTitle: String {
        if detail.summary.dataQuality == "missing" || dailyValues.isEmpty {
            return "No data"
        }
        switch detail.summary.trend {
        case "up": return "Distance up"
        case "down": return "Distance down"
        case "flat": return "Steady"
        default: return "Recorded"
        }
    }

    private var statusColor: Color {
        if detail.summary.dataQuality == "missing" || dailyValues.isEmpty { return .secondary }
        switch detail.summary.trend {
        case "up": return .green
        case "down": return .orange
        default: return .mint
        }
    }
}

private struct DistanceChartPanel: View {
    let detail: DistanceDetail
    let timeframe: ScoreTimeframe
    @State private var selectedID: String?

    private var periodPoints: [DistancePeriodPoint] {
        DistancePeriodPoint.points(from: detail.chart.points, timeframe: timeframe)
    }

    private var hourlyPoints: [DistanceHourlyPoint] {
        DistanceHourlyPoint.points(from: detail.intraday.points)
    }

    private var selectedPeriodPoint: DistancePeriodPoint? {
        if let selectedID, let point = periodPoints.first(where: { $0.id == selectedID }) {
            return point
        }
        return periodPoints.last(where: { $0.value != nil })
    }

    private var selectedHourlyPoint: DistanceHourlyPoint? {
        if let selectedID, let point = hourlyPoints.first(where: { $0.id == selectedID }) {
            return point
        }
        return hourlyPoints.last(where: { ($0.value ?? 0) > 0 })
    }

    var body: some View {
        DistanceSection(title: chartTitle, systemImage: "chart.bar.fill") {
            if timeframe == .day {
                if detail.intraday.available, hourlyPoints.contains(where: { ($0.value ?? 0) > 0 }) {
                    DistanceBarChart(
                        points: hourlyPoints.map(\.barPoint),
                        timeframe: timeframe,
                        selectedID: $selectedID
                    )
                    .frame(height: 236)
                    if let selectedHourlyPoint {
                        DistanceSelectedReadout(
                            title: selectedHourlyPoint.readoutLabel,
                            subtitle: "Hourly distance",
                            value: distanceText(selectedHourlyPoint.value)
                        )
                    }
                } else {
                    missingChartText
                }
            } else if periodPoints.contains(where: { $0.value != nil }) {
                DistanceBarChart(
                    points: periodPoints.map { $0.barPoint(for: timeframe) },
                    timeframe: timeframe,
                    selectedID: $selectedID
                )
                .frame(height: timeframe == .year ? 224 : 236)
                if let selectedPeriodPoint {
                    DistanceSelectedReadout(
                        title: selectedPeriodPoint.readoutLabel(for: timeframe),
                        subtitle: selectedSubtitle(for: selectedPeriodPoint),
                        value: distanceText(selectedPeriodPoint.value)
                    )
                }
            } else {
                missingChartText
            }
        }
    }

    private var chartTitle: String {
        switch timeframe {
        case .day: return "Hourly Distance"
        case .week: return "Daily Distance"
        case .month: return "Daily Distance"
        case .year: return "Monthly Distance"
        }
    }

    private var missingChartText: some View {
        Text("No distance data was detected for this timeframe.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
    }

    private func selectedSubtitle(for point: DistancePeriodPoint) -> String {
        let values = periodPoints.compactMap(\.value)
        guard let value = point.value, let average = distanceAverage(values), average > 0 else {
            return "No distance recorded"
        }
        if value == values.max() {
            return timeframe == .year ? "Longest month" : "Longest day"
        }
        if value >= average * 1.15 {
            return "Above average"
        }
        if value <= average * 0.75 {
            return "Below average"
        }
        return "Near average"
    }
}

private struct DistanceBarChart: View {
    let points: [DistanceBarPoint]
    let timeframe: ScoreTimeframe
    @Binding var selectedID: String?

    private var selectedPoint: DistanceBarPoint? {
        if let selectedID, let point = points.first(where: { $0.id == selectedID }) {
            return point
        }
        return points.last(where: { $0.value != nil })
    }

    private var maxValue: Double {
        max(points.compactMap(\.value).max() ?? 0, 100)
    }

    var body: some View {
        GeometryReader { proxy in
            let yAxisWidth: CGFloat = 46
            let xAxisHeight: CGFloat = 28
            let plot = CGRect(
                x: yAxisWidth,
                y: 8,
                width: max(proxy.size.width - yAxisWidth, 1),
                height: max(proxy.size.height - xAxisHeight - 10, 120)
            )
            let count = max(points.count, 1)
            let step = plot.width / CGFloat(count)
            let barWidth = max(4, min(timeframe == .year ? 18 : 16, step * 0.62))

            ZStack(alignment: .topLeading) {
                ForEach(tickValues, id: \.self) { tick in
                    let y = plot.maxY - CGFloat(tick / maxValue) * plot.height
                    Text(compactDistanceText(tick))
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
                        .fill(barColor(for: point, value: value).gradient)
                        .frame(width: barWidth, height: height)
                        .position(x: x, y: y)
                        .accessibilityLabel("\(point.readoutLabel), \(distanceText(point.value))")
                }

                if let selectedPoint, let selectedIndex = points.firstIndex(where: { $0.id == selectedPoint.id }) {
                    let x = plot.minX + CGFloat(selectedIndex) * step + step / 2
                    Rectangle()
                        .fill(Color.primary.opacity(0.13))
                        .frame(width: 1, height: plot.height)
                        .position(x: x, y: plot.midY)
                }

                ForEach(xTickIndexes, id: \.self) { index in
                    Text(points[index].axisLabel)
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

    private var tickValues: [Double] {
        [maxValue, maxValue / 2, 0]
    }

    private var xTickIndexes: [Int] {
        guard !points.isEmpty else { return [] }
        switch timeframe {
        case .day:
            return [0, 6, 12, 18, 23].filter { $0 < points.count }
        case .week:
            return Array(points.indices)
        case .month:
            return SharedChartGeometry.evenlySpacedIndexes(count: points.count, maxCount: 5)
        case .year:
            return Array(points.indices)
        }
    }

    private func barColor(for point: DistanceBarPoint, value: Double) -> Color {
        guard value > 0 else { return distanceMissingColor }
        if point.id == selectedPoint?.id {
            return .green
        }
        return .mint
    }

    private func nearestPointID(to x: CGFloat, width: CGFloat) -> String? {
        guard let index = SharedChartGeometry.nearestBucketIndex(to: x, width: width, count: points.count) else {
            return nil
        }
        return points[index].id
    }
}

private struct DistancePatternPanel: View {
    let detail: DistanceDetail
    let timeframe: ScoreTimeframe

    private var periodPoints: [DistancePeriodPoint] {
        DistancePeriodPoint.points(from: detail.chart.points, timeframe: timeframe)
    }

    private var hourlyPoints: [DistanceHourlyPoint] {
        DistanceHourlyPoint.points(from: detail.intraday.points)
    }

    var body: some View {
        DistanceSection(title: title, systemImage: "square.grid.3x3.fill") {
            switch timeframe {
            case .day:
                if detail.intraday.available, hourlyPoints.contains(where: { ($0.value ?? 0) > 0 }) {
                    VStack(spacing: 10) {
                        ForEach(daySegments) { segment in
                            DistanceDistributionRow(item: segment)
                        }
                    }
                } else {
                    emptyText
                }
            case .week:
                HStack(spacing: 9) {
                    ForEach(periodPoints) { point in
                        DistancePatternDot(point: point, timeframe: timeframe, averageValue: averageValue)
                            .frame(maxWidth: .infinity)
                    }
                }
                DistancePatternLegend()
            case .month:
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 7), spacing: 10) {
                    ForEach(periodPoints) { point in
                        DistancePatternDot(point: point, timeframe: timeframe, averageValue: averageValue)
                    }
                }
                DistancePatternLegend()
            case .year:
                HStack(spacing: 8) {
                    ForEach(periodPoints) { point in
                        DistancePatternDot(point: point, timeframe: timeframe, averageValue: averageValue)
                            .frame(maxWidth: .infinity)
                    }
                }
                DistancePatternLegend()
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

    private var averageValue: Double? {
        distanceAverage(periodPoints.compactMap(\.value))
    }

    private var daySegments: [DistanceDistributionItem] {
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
            return DistanceDistributionItem(
                title: title,
                systemImage: icon,
                value: value,
                ratio: value / total
            )
        }
    }

    private var emptyText: some View {
        Text("No hourly distance data was detected for this day.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }
}

private struct DistanceConsistencyPanel: View {
    let detail: DistanceDetail
    let timeframe: ScoreTimeframe

    private var periodPoints: [DistancePeriodPoint] {
        DistancePeriodPoint.points(from: detail.chart.points, timeframe: timeframe)
    }

    private var dailyValues: [Double] {
        distanceValues(from: detail.chart.points)
    }

    private var periodTotal: Double {
        dailyValues.reduce(0, +)
    }

    var body: some View {
        DistanceSection(title: "Distance & Consistency", systemImage: "checkmark.seal.fill") {
            VStack(spacing: 10) {
                DistanceContextRow(title: totalTitle, value: distanceText(periodTotal))
                DistanceContextRow(title: averageTitle, value: distanceText(averageValue))
                DistanceContextRow(title: "Active days", value: "\(activeDays) / \(dailyValues.count)")
                DistanceContextRow(title: "Best \(bestUnit)", value: bestValueText)
                DistanceContextRow(title: previousTitle, value: previousText)
                if let validDays = detail.summary.validDays, let periodDays = detail.summary.periodDays {
                    DistanceContextRow(title: "Recorded", value: "\(validDays) / \(periodDays) days")
                }
            }
        }
    }

    private var totalTitle: String {
        timeframe == .year ? "Year total" : "Total distance"
    }

    private var averageTitle: String {
        timeframe == .year ? "Daily average" : "Daily average"
    }

    private var averageValue: Double? {
        detail.summary.primaryValue
    }

    private var activeDays: Int {
        dailyValues.filter { $0 > 0 }.count
    }

    private var bestUnit: String {
        timeframe == .year ? "month" : "day"
    }

    private var bestValueText: String {
        guard let best = periodPoints.max(by: { ($0.value ?? 0) < ($1.value ?? 0) }), let value = best.value else {
            return "--"
        }
        return "\(distanceText(value)) \(best.shortReadout(for: timeframe))"
    }

    private var previousTitle: String {
        switch timeframe {
        case .day: return "Previous day"
        case .week: return "Previous week"
        case .month: return "Previous month"
        case .year: return "Previous year"
        }
    }

    private var previousText: String {
        guard let change = detail.summary.absoluteChange else {
            return "No prior data"
        }
        let prefix = change > 0 ? "+" : ""
        return "\(prefix)\(distanceText(change)) avg/day"
    }
}

private typealias DistanceSelectedReadout = SelectedChartReadout
private typealias DistanceSummaryRow = MetricSummaryRow
private typealias DistanceTrendRow = MetricTrendRow
private typealias DistanceContextRow = MetricSummaryRow
private typealias DistanceSection<Content: View> = DetailSection<Content>

private struct DistanceDistributionItem: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
    let value: Double
    let ratio: Double
}

private struct DistanceDistributionRow: View {
    let item: DistanceDistributionItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.systemImage)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.mint)
                .frame(width: 28, height: 28)
                .background(Color.mint.opacity(0.13), in: Circle())

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(distanceText(item.value))
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.08))
                        Capsule()
                            .fill(Color.mint.gradient)
                            .frame(width: proxy.size.width * min(max(item.ratio, 0), 1))
                    }
                }
                .frame(height: 6)
            }
        }
    }
}

private struct DistancePatternDot: View {
    let point: DistancePeriodPoint
    let timeframe: ScoreTimeframe
    let averageValue: Double?

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
        .accessibilityLabel("\(point.readoutLabel(for: timeframe)), \(distanceText(point.value))")
    }

    private var patternColor: Color {
        guard let value = point.value, value > 0 else { return distanceMissingColor }
        guard let averageValue, averageValue > 0 else { return .mint }
        if value >= averageValue * 1.15 { return .green }
        if value <= averageValue * 0.75 { return Color.mint.opacity(0.42) }
        return .mint
    }
}

private struct DistancePatternLegend: View {
    private let items: [(String, Color)] = [
        ("Long", .green),
        ("Typical", .mint),
        ("Light", Color.mint.opacity(0.42)),
        ("Missing", distanceMissingColor)
    ]

    var body: some View {
        HStack(spacing: 10) {
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

private struct DistanceHourlyPoint: Identifiable {
    let id: String
    let hour: Int
    let value: Double?

    var axisLabel: String {
        String(format: "%02d", hour)
    }

    var readoutLabel: String {
        "\(String(format: "%02d:00", hour))-\(String(format: "%02d:00", (hour + 1) % 24))"
    }

    var barPoint: DistanceBarPoint {
        DistanceBarPoint(id: id, axisLabel: axisLabel, readoutLabel: readoutLabel, value: value)
    }

    static func points(from rawPoints: [StepsIntradayPoint]) -> [DistanceHourlyPoint] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: rawPoints) { point -> Int in
            guard let date = DashboardFormatters.parseBackendDateTime(point.bucketStart) else { return -1 }
            return calendar.component(.hour, from: date)
        }
        return (0..<24).map { hour in
            let items = grouped[hour] ?? []
            let total = items.reduce(0.0) { $0 + ($1.value ?? 0) }
            return DistanceHourlyPoint(
                id: "hour-\(hour)",
                hour: hour,
                value: items.isEmpty ? nil : total
            )
        }
    }
}

private struct DistancePeriodPoint: Identifiable {
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
        guard let date else { return "Distance" }
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

    func barPoint(for timeframe: ScoreTimeframe) -> DistanceBarPoint {
        DistanceBarPoint(
            id: id,
            axisLabel: axisLabel(for: timeframe),
            readoutLabel: readoutLabel(for: timeframe),
            value: value
        )
    }

    static func points(from rawPoints: [BaselineMetricChartPoint], timeframe: ScoreTimeframe) -> [DistancePeriodPoint] {
        let today = ScoreDateFormatters.calendar.startOfDay(for: Date())
        let daily = rawPoints.compactMap { point -> DistancePeriodPoint? in
            guard let date = ScoreDateFormatters.apiDate.date(from: point.date ?? "") else { return nil }
            guard ScoreDateFormatters.calendar.startOfDay(for: date) <= today else { return nil }
            return DistancePeriodPoint(
                id: point.date ?? point.id,
                date: date,
                monthStartDate: nil,
                value: point.value
            )
        }
        guard timeframe == .year else { return daily }

        let calendar = ScoreDateFormatters.calendar
        let grouped = Dictionary(grouping: daily.compactMap { point -> DistancePeriodPoint? in
            guard let date = point.date else { return nil }
            let components = calendar.dateComponents([.year, .month], from: date)
            guard let month = calendar.date(from: components) else { return nil }
            return DistancePeriodPoint(
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
            return DistancePeriodPoint(
                id: ScoreDateFormatters.apiDate.string(from: month),
                date: nil,
                monthStartDate: month,
                value: values.isEmpty ? nil : values.reduce(0, +)
            )
        }
    }
}

private struct DistanceBarPoint: Identifiable {
    let id: String
    let axisLabel: String
    let readoutLabel: String
    let value: Double?
}

private func distanceText(_ meters: Double?) -> String {
    guard let meters else { return "--" }
    let absolute = abs(meters)
    if absolute < 1000 {
        return "\(Int(meters.rounded())) m"
    }
    return String(format: "%.1f km", meters / 1000)
}

private func compactDistanceText(_ meters: Double?) -> String {
    guard let meters else { return "--" }
    let kilometers = meters / 1000
    if abs(kilometers) >= 100 {
        return "\(Int(kilometers.rounded()))km"
    }
    if abs(kilometers) >= 10 {
        return "\(Int(kilometers.rounded()))km"
    }
    if abs(meters) >= 1000 {
        return String(format: "%.1fkm", kilometers)
    }
    return "\(Int(meters.rounded()))m"
}

private func distanceValues(from rawPoints: [BaselineMetricChartPoint]) -> [Double] {
    let today = ScoreDateFormatters.calendar.startOfDay(for: Date())
    return rawPoints.compactMap { point in
        guard let value = point.value else { return nil }
        guard let rawDate = point.date, let date = ScoreDateFormatters.apiDate.date(from: rawDate) else {
            return nil
        }
        return ScoreDateFormatters.calendar.startOfDay(for: date) <= today ? value : nil
    }
}

private func distanceAverage(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    return values.reduce(0, +) / Double(values.count)
}

private let distanceMissingColor = Color.secondary.opacity(0.35)

#Preview {
    NavigationStack {
        DistanceDetailView(client: DashboardAPIClient())
    }
}
