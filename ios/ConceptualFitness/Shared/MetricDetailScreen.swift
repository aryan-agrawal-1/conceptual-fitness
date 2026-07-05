import SwiftUI

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

    private var loadKey: String {
        "\(timeframe.rawValue)-\(ScoreDateFormatters.apiDate.string(from: selectedDate))"
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
