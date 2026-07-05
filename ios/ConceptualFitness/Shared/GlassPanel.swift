import SwiftUI

struct AppBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.96, green: 0.98, blue: 1.0),
                Color(red: 0.98, green: 0.98, blue: 0.95),
                Color.white
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

struct CircularProgressMetric<Center: View>: View {
    let progress: Double
    let tint: Color
    var trackColor: Color = .white.opacity(0.55)
    var overflowTint: Color?
    var lineWidth: CGFloat = 11
    var overflowLineWidth: CGFloat = 6
    let accessibilityLabel: String
    @ViewBuilder let center: Center

    var body: some View {
        ZStack {
            Circle()
                .stroke(trackColor, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(tint.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let overflowTint, progress > 1 {
                Circle()
                    .trim(from: 0, to: min(progress - 1, 0.35))
                    .stroke(overflowTint, style: StrokeStyle(lineWidth: overflowLineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            center
        }
        .accessibilityLabel(accessibilityLabel)
    }
}

enum AsyncLoadState<Value> {
    case loading
    case loaded(Value)
    case failed(String)
}

struct MetricDetailScreen<Detail, Content: View>: View {
    let title: String
    let metricName: String
    let errorTitle: String
    let timeframeAccessibilityLabel: String
    let timeframes: [ScoreTimeframe]
    let backendBaseURL: URL
    let load: (Date, ScoreTimeframe) async throws -> Detail
    @ViewBuilder let loadedContent: (Detail, ScoreTimeframe) -> Content

    @State private var timeframe: ScoreTimeframe
    @State private var selectedDate: Date
    @State private var loadState: AsyncLoadState<Detail>
    @State private var calendarSelection: ScoreCalendarSelection?

    init(
        title: String,
        metricName: String,
        errorTitle: String? = nil,
        timeframeAccessibilityLabel: String,
        timeframes: [ScoreTimeframe],
        initialTimeframe: ScoreTimeframe,
        initialSelectedDate: Date = Date(),
        initialLoadState: AsyncLoadState<Detail> = .loading,
        backendBaseURL: URL,
        load: @escaping (Date, ScoreTimeframe) async throws -> Detail,
        @ViewBuilder loadedContent: @escaping (Detail, ScoreTimeframe) -> Content
    ) {
        self.title = title
        self.metricName = metricName
        self.errorTitle = errorTitle ?? "Could not load \(title)"
        self.timeframeAccessibilityLabel = timeframeAccessibilityLabel
        self.timeframes = timeframes
        self.backendBaseURL = backendBaseURL
        self.load = load
        self.loadedContent = loadedContent
        _timeframe = State(initialValue: initialTimeframe)
        _selectedDate = State(initialValue: initialSelectedDate)
        _loadState = State(initialValue: initialLoadState)
    }

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    MetricTimeframePicker(
                        selection: $timeframe,
                        timeframes: timeframes,
                        accessibilityLabel: timeframeAccessibilityLabel
                    )
                    ScoreRangeNavigator(
                        timeframe: timeframe,
                        metricName: metricName,
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
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: loadKey) {
            await loadDetail()
        }
        .refreshable {
            await loadDetail()
        }
        .sheet(item: $calendarSelection) { selection in
            ScoreCalendarPicker(metricName: metricName, selection: selection) { nextDate in
                selectedDate = nextDate
                calendarSelection = nil
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
        case .failed(let message):
            DetailErrorPanel(title: errorTitle, message: message) {
                Task { await loadDetail() }
            }
        case .loaded(let detail):
            loadedContent(detail, timeframe)
        }
    }

    private var loadKey: String {
        "\(timeframe.rawValue)-\(ScoreDateFormatters.apiDate.string(from: selectedDate))"
    }

    @MainActor
    private func loadDetail() async {
        loadState = .loading
        do {
            loadState = .loaded(try await load(selectedDate, timeframe))
        } catch is CancellationError {
            return
        } catch {
            loadState = .failed("The backend was unavailable at \(backendBaseURL.absoluteString).")
        }
    }
}

struct MetricTimeframePicker: View {
    @Binding var selection: ScoreTimeframe
    let timeframes: [ScoreTimeframe]
    let accessibilityLabel: String

    var body: some View {
        Picker("Timeframe", selection: $selection) {
            ForEach(timeframes) { item in
                Text(item.title).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel(accessibilityLabel)
    }
}

struct DetailErrorPanel: View {
    let title: String
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Retry", action: retry)
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 18)
    }
}

struct DetailSection<Content: View>: View {
    let title: String
    let systemImage: String?
    var spacing: CGFloat = 14
    var cornerRadius: CGFloat = 20
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            if let systemImage {
                Label(title, systemImage: systemImage)
                    .font(.headline)
            } else {
                Text(title)
                    .font(.headline)
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: cornerRadius)
    }
}

struct MetricSummaryRow: View {
    let title: String
    let value: String?
    var tint: Color = .primary
    var placeholder: String = "--"
    var monospaced: Bool = false
    var multilineValue: Bool = false

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .layoutPriority(1)
            Spacer()
            Text(value ?? placeholder)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint)
                .multilineTextAlignment(.trailing)
                .lineLimit(multilineValue ? 2 : 1)
                .minimumScaleFactor(0.72)
                .modifier(MonospacedDigitsModifier(enabled: monospaced))
        }
    }
}

struct MetricTrendRow: View {
    let trend: String?
    var upColor: Color = .green
    var downColor: Color = .orange
    var flatColor: Color = .secondary
    var unknownColor: Color = .secondary
    var flatTitle: String = "Steady"
    var unknownTitle: String = "No prior data"

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
                Image(systemName: icon)
                    .font(.caption.weight(.bold))
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .foregroundStyle(color)
        }
    }

    private var title: String {
        switch trend {
        case "up": return "Up"
        case "down": return "Down"
        case "flat": return flatTitle
        default: return unknownTitle
        }
    }

    private var icon: String {
        switch trend {
        case "up": return "chart.line.uptrend.xyaxis"
        case "down": return "chart.line.downtrend.xyaxis"
        case "flat": return "minus"
        default: return "questionmark"
        }
    }

    private var color: Color {
        switch trend {
        case "up": return upColor
        case "down": return downColor
        case "flat": return flatColor
        default: return unknownColor
        }
    }
}

struct StatusPill: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }
}

struct HeroMetricValue: View {
    let value: String?
    let unit: String?
    let caption: String
    let accessibilityLabel: String
    var valueSize: CGFloat = 48
    var placeholder: String = "--"

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value ?? placeholder)
                    .font(.system(size: valueSize, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                if let unit {
                    Text(unit)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
            Text(caption)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel(accessibilityLabel)
    }
}

struct SelectedChartReadout: View {
    let title: String
    let subtitle: String
    let value: String
    var valueTint: Color = .primary
    var monospaced: Bool = true

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
                .foregroundStyle(valueTint)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .modifier(MonospacedDigitsModifier(enabled: monospaced))
        }
        .padding(.top, 2)
    }
}

private struct MonospacedDigitsModifier: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.monospacedDigit()
        } else {
            content
        }
    }
}

enum SharedChartGeometry {
    static func xPosition(index: Int, count: Int, width: CGFloat) -> CGFloat {
        guard count > 1 else { return width / 2 }
        return CGFloat(index) / CGFloat(count - 1) * width
    }

    static func yPosition(value: Double, bounds: ClosedRange<Double>, height: CGFloat) -> CGFloat {
        let span = max(bounds.upperBound - bounds.lowerBound, 0.0001)
        return height - CGFloat((value - bounds.lowerBound) / span) * height
    }

    static func evenlySpacedIndexes(count: Int, maxCount: Int) -> [Int] {
        guard count > 0 else { return [] }
        guard count > maxCount else { return Array(0..<count) }
        let step = Double(count - 1) / Double(maxCount - 1)
        return (0..<maxCount).map { Int((Double($0) * step).rounded()) }
    }

    static func nearestIndex(to x: CGFloat, width: CGFloat, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard count > 1 else { return 0 }
        guard width > 0 else { return 0 }
        let step = width / CGFloat(count - 1)
        let index = Int((x / step).rounded())
        return min(max(index, 0), count - 1)
    }

    static func nearestBucketIndex(to x: CGFloat, width: CGFloat, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard width > 0 else { return 0 }
        let step = width / CGFloat(count)
        let index = Int((x / step).rounded(.down))
        return min(max(index, 0), count - 1)
    }
}

extension View {
    @ViewBuilder
    func glassSurface(cornerRadius: CGFloat = 22, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(
                interactive ? .regular.interactive() : .regular,
                in: .rect(cornerRadius: cornerRadius)
            )
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.55), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.08), radius: 20, y: 10)
        }
    }
}
