import SwiftUI

struct HistoricalBackfillView: View {
    @ObservedObject var coordinator: AppSyncCoordinator
    var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("History import").font(.headline)
            if let error = coordinator.historyError {
                Text(error).font(.subheadline)
                Button("Check progress again") { Task { await coordinator.checkHistory() } }
            }
            if expanded && coordinator.history?.coverageState != "untracked" {
                Toggle("Notify me when import finishes", isOn: Binding(
                    get: { coordinator.notifyOnCompletion },
                    set: { enabled in Task { await coordinator.setCompletionNotification(enabled) } }
                ))
                .disabled(!coordinator.historyLoaded)
                Text("Optional local notification. Delivery may wait until the next background check or app opening.")
                    .font(.caption).foregroundStyle(.secondary)
                if let message = coordinator.notificationMessage { Text(message).font(.caption) }
            }
            if let history = coordinator.history, history.coverageState == "untracked" {
                Text("Saved history available").font(.subheadline.weight(.semibold))
                if let start = history.storedFrom, let end = history.storedThrough {
                    Text("Saved records: \(dateLabel(start)) – \(dateLabel(end))")
                        .font(.subheadline)
                }
                Text("Your saved history is available. Older imports weren’t recorded by this progress tracker.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else if let history = coordinator.history {
                Text(history.status == "complete" ? "Import complete" : history.status == "failed" ? "Import needs attention" : "Calibrating your history")
                    .font(.subheadline.weight(.semibold))
                Text("\(history.completedSources) of \(history.totalSources) data types complete")
                    .font(.subheadline)
                ProgressView(value: Double(history.completedSources), total: Double(max(1, history.totalSources)))
                    .accessibilityLabel("History import")
                    .accessibilityValue("\(history.completedSources) of \(history.totalSources) data types complete")
                Text("Import range: \(dateLabel(history.rangeStart)) – \(dateLabel(history.rangeEnd))")
                    .font(.caption).foregroundStyle(.secondary)
                Text(coordinator.currentScoresAvailable
                     ? (history.status == "complete" ? "History is imported. Available scores are ready to use; some scores may still need more data." : "Available scores are ready to use. Baselines improve as each source finishes.")
                     : "Scores appear when enough recent data is available. An empty source can still finish importing.")
                    .font(.subheadline).foregroundStyle(.secondary)
                if expanded {
                    sourceRows(history)
                } else {
                    DisclosureGroup("Sources and date coverage") { sourceRows(history) }
                }
            } else if coordinator.historyLoaded {
                Text("History import hasn’t started yet. Recent data syncs first.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else if coordinator.historyError == nil {
                ProgressView("Checking import progress…")
            }


        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 20)
        .accessibilityElement(children: .contain)
    }

    private func sourceRows(_ history: HistoricalBackfillStatus) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(history.sources) { source in
                VStack(alignment: .leading, spacing: 5) {
                    Text(source.title).font(.subheadline.weight(.semibold))
                    Text(source.status == "succeeded" ? "Complete" : source.status == "failed" ? "Interrupted — retry to resume" : source.status == "running" ? "Importing and updating baselines…" : "Waiting to import")
                        .font(.caption)
                    if let start = source.coverageStart, let end = source.coverageEnd {
                        Text("\(source.pageInProgress == true ? "Processing" : "Checked"): \(dateLabel(start)) – \(dateLabel(end))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("No date coverage confirmed yet").font(.caption).foregroundStyle(.secondary)
                    }
                    if source.status == "failed" {
                        Button(coordinator.retryingSource == source.id ? "Retrying…" : "Retry \(source.title)") {
                            Task { await coordinator.retryHistory(source: source.id) }
                        }
                        .disabled(coordinator.retryingSource != nil)
                        .accessibilityHint("Resumes only this source, preserving completed imports")
                    }
                }
                .accessibilityElement(children: .contain)
            }
        }
        .padding(.top, 8)
    }

    private func dateLabel(_ value: String) -> String {
        guard let date = ScoreDateFormatters.apiDate.date(from: value) else { return value }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

struct ImportProfileView: View {
    @ObservedObject var coordinator: AppSyncCoordinator

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                HistoricalBackfillView(coordinator: coordinator, expanded: true).padding(20)
            }
        }
        .navigationTitle("Profile")
        .refreshable { await coordinator.checkHistory() }
    }
}

#if DEBUG
enum HistoryPreviewState: String {
    case loading, waiting, running, failed, complete, empty, offline

    static var current: Self? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-HistoryPreviewState"), arguments.indices.contains(index + 1) else { return nil }
        return Self(rawValue: arguments[index + 1])
    }

    @MainActor var view: some View {
        let coordinator = AppSyncCoordinator.historyPreview(self)
        return NavigationStack {
            if ProcessInfo.processInfo.arguments.contains("-HistoryProfile") {
                ImportProfileView(coordinator: coordinator)
            } else {
                DashboardView(
                    client: DashboardAPIClient(), syncCoordinator: coordinator,
                    weatherProvider: WeatherProvider(), locationProvider: LocationProvider(),
                    insightProvider: DailyInsightProvider(), firstName: "Alex", weatherEnabled: false,
                    previewLoadState: .loaded(.sample)
                )
            }
        }
    }
}

#Preview("Import needs attention") { HistoryPreviewState.failed.view }
#Preview("Import complete") { HistoryPreviewState.complete.view }
#endif
