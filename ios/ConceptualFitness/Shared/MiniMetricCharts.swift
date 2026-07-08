import SwiftUI

enum MiniMetricChartKind {
    case baselineLine
    case thresholdLine
    case bars
    case rangeLine
    case intradayLine
    case sleepStages
    case empty
}

struct MiniMetricChartPoint: Identifiable, Decodable {
    let date: String?
    let bucketStart: String?
    let observedAt: String?
    let value: Double?
    let unit: String?
    let dataQuality: String?
    let minValue: Double?
    let maxValue: Double?
    let baselineValue: Double?
    let baselineLowerBound: Double?
    let baselineUpperBound: Double?
    let comparison: String?
    let stage: String?
    let startClock: String?
    let endClock: String?
    let offsetStartMinutes: Double?
    let offsetEndMinutes: Double?
    let durationMinutes: Double?

    var id: String {
        [
            date,
            bucketStart,
            observedAt,
            stage,
            startClock,
            endClock,
            value?.clean,
            durationMinutes?.clean
        ]
            .compactMap(\.self)
            .joined(separator: "-")
    }

    enum CodingKeys: String, CodingKey {
        case date
        case bucketStart = "bucket_start"
        case observedAt = "observed_at"
        case value
        case unit
        case dataQuality = "data_quality"
        case minValue = "min_value"
        case maxValue = "max_value"
        case baselineValue = "baseline_value"
        case baselineLowerBound = "baseline_lower_bound"
        case baselineUpperBound = "baseline_upper_bound"
        case comparison
        case stage
        case startClock = "start_clock"
        case endClock = "end_clock"
        case offsetStartMinutes = "offset_start_minutes"
        case offsetEndMinutes = "offset_end_minutes"
        case durationMinutes = "duration_minutes"
    }
}

struct MiniMetricChart: View {
    let points: [MiniMetricChartPoint]
    let kind: MiniMetricChartKind
    let tint: Color

    var body: some View {
        Group {
            if kind == .empty || (points.compactMap(\.value).isEmpty && kind != .sleepStages) {
                MiniEmptyChart(tint: tint)
            } else {
                switch kind {
                case .bars:
                    MiniBarChart(points: points, tint: tint)
                case .intradayLine:
                    MiniLineChart(points: points, tint: tint, showsBand: false)
                case .sleepStages:
                    MiniSleepStageChart(points: points)
                case .baselineLine, .thresholdLine, .rangeLine:
                    MiniLineChart(points: points, tint: tint, showsBand: kind != .thresholdLine)
                case .empty:
                    MiniEmptyChart(tint: tint)
                }
            }
        }
        .frame(height: 42)
        .accessibilityHidden(true)
    }
}

private struct MiniLineChart: View {
    let points: [MiniMetricChartPoint]
    let tint: Color
    let showsBand: Bool

    var body: some View {
        GeometryReader { proxy in
            let rect = CGRect(origin: .zero, size: proxy.size)
            let bounds = valueBounds

            ZStack {
                if showsBand, let bandPath = baselineBandPath(in: rect, bounds: bounds) {
                    bandPath.fill(tint.opacity(0.14))
                }

                linePath(in: rect, bounds: bounds, value: \.baselineValue)
                    .stroke(tint.opacity(0.30), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))

                linePath(in: rect, bounds: bounds, value: \.value)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private var valueBounds: ClosedRange<Double> {
        let values = points.flatMap { point in
            [point.value, point.baselineValue, point.baselineLowerBound, point.baselineUpperBound].compactMap(\.self)
        }
        guard let minValue = values.min(), let maxValue = values.max() else { return 0...1 }
        let span = max(maxValue - minValue, 1)
        return (minValue - span * 0.18)...(maxValue + span * 0.18)
    }

    private func linePath(
        in rect: CGRect,
        bounds: ClosedRange<Double>,
        value: KeyPath<MiniMetricChartPoint, Double?>
    ) -> Path {
        var path = Path()
        var hasStarted = false
        let denominator = max(points.count - 1, 1)
        for (index, point) in points.enumerated() {
            guard let rawValue = point[keyPath: value] else {
                hasStarted = false
                continue
            }
            let x = rect.minX + CGFloat(index) / CGFloat(denominator) * rect.width
            let y = yPosition(rawValue, in: rect, bounds: bounds)
            if hasStarted {
                path.addLine(to: CGPoint(x: x, y: y))
            } else {
                path.move(to: CGPoint(x: x, y: y))
                hasStarted = true
            }
        }
        return path
    }

    private func baselineBandPath(in rect: CGRect, bounds: ClosedRange<Double>) -> Path? {
        let bandPoints = points.enumerated().compactMap { index, point -> (Int, Double, Double)? in
            guard let lower = point.baselineLowerBound, let upper = point.baselineUpperBound else { return nil }
            return (index, lower, upper)
        }
        guard bandPoints.count >= 2 else { return nil }
        let denominator = max(points.count - 1, 1)
        var path = Path()
        for item in bandPoints {
            let x = rect.minX + CGFloat(item.0) / CGFloat(denominator) * rect.width
            let y = yPosition(item.2, in: rect, bounds: bounds)
            if item.0 == bandPoints.first?.0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        for item in bandPoints.reversed() {
            let x = rect.minX + CGFloat(item.0) / CGFloat(denominator) * rect.width
            let y = yPosition(item.1, in: rect, bounds: bounds)
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.closeSubpath()
        return path
    }

    private func yPosition(_ value: Double, in rect: CGRect, bounds: ClosedRange<Double>) -> CGFloat {
        let span = max(bounds.upperBound - bounds.lowerBound, 0.001)
        let progress = (value - bounds.lowerBound) / span
        return rect.maxY - CGFloat(progress) * rect.height
    }
}

private struct MiniBarChart: View {
    let points: [MiniMetricChartPoint]
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let values = points.map(\.value)
            let maxValue = max(values.compactMap(\.self).max() ?? 1, 1)
            let spacing: CGFloat = 3
            let width = max(2, (proxy.size.width - spacing * CGFloat(max(points.count - 1, 0))) / CGFloat(max(points.count, 1)))

            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(Array(points.enumerated()), id: \.element.id) { _, point in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(tint.opacity(point.value == nil ? 0.16 : 0.72))
                        .frame(width: width, height: max(4, CGFloat((point.value ?? 0) / maxValue) * proxy.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }
}

private struct MiniSleepStageChart: View {
    let points: [MiniMetricChartPoint]

    private var summaryPoints: [MiniMetricChartPoint] {
        points.filter { $0.stage != nil && ($0.durationMinutes ?? 0) > 0 }
    }

    var body: some View {
        GeometryReader { proxy in
            summaryChart(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private func summaryChart(width: CGFloat, height: CGFloat) -> some View {
        let total = max(summaryPoints.compactMap(\.durationMinutes).reduce(0, +), 1)
        return HStack(alignment: .center, spacing: 3) {
            ForEach(summaryPoints) { point in
                if let stage = point.stage {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(stageColor(stage).gradient)
                        .frame(
                            width: max(5, width * CGFloat((point.durationMinutes ?? 0) / total)),
                            height: max(10, height * 0.72)
                        )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func normalizedStage(_ stage: String) -> String {
        let value = stage.uppercased()
        if value.contains("AWAKE") { return "AWAKE" }
        if value.contains("REM") { return "REM" }
        if value.contains("DEEP") { return "DEEP" }
        if value.contains("LIGHT") { return "LIGHT" }
        return value
    }

    private func stageColor(_ stage: String) -> Color {
        switch normalizedStage(stage) {
        case "AWAKE":
            return Color(red: 0.95, green: 0.62, blue: 0.32)
        case "LIGHT":
            return Color(red: 0.42, green: 0.61, blue: 0.96)
        case "DEEP":
            return Color(red: 0.28, green: 0.28, blue: 0.72)
        case "REM":
            return Color(red: 0.67, green: 0.43, blue: 0.91)
        default:
            return HealthTheme.sleep
        }
    }
}

private struct MiniEmptyChart: View {
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<7, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(tint.opacity(0.10 + Double(index % 3) * 0.035))
                    .frame(height: CGFloat(12 + (index % 3) * 7))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}
