import SwiftUI
import OSLog

struct WorkoutDetailView: View {
    let workoutID: String
    let client: DashboardAPIClient

    @StateObject private var fitnessStore: FitnessStore
    @State private var loadState: AsyncLoadState<WorkoutDetail> = .loading
    @State private var showEditor = false
    @State private var isPreparingAction = false
    @State private var actionMessage: String?

    private let logger = Logger(subsystem: "ConceptualFitness", category: "WorkoutDetail")

    init(workoutID: String, client: DashboardAPIClient) {
        self.workoutID = workoutID
        self.client = client
        let authStore = client.authStore ?? AuthStore(baseURL: client.baseURL, session: client.session)
        _fitnessStore = StateObject(wrappedValue: FitnessStore(authStore: authStore, userID: client.userID ?? "preview"))
    }

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                content
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("Workout")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: workoutID) {
            await load()
        }
        .refreshable {
            await load()
        }
        .fullScreenCover(isPresented: $showEditor, onDismiss: {
            Task { await load() }
        }) {
            WorkoutEditorView(store: fitnessStore)
        }
        .alert("Workout unavailable", isPresented: actionAlertPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionMessage ?? "Try again.")
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
            DetailErrorPanel(title: "Could not load workout", message: message) {
                Task { await load() }
            }
        case .loaded(let detail):
            VStack(alignment: .leading, spacing: 18) {
                WorkoutDetailHeader(detail: detail)
                WorkoutSummaryMetricsPanel(detail: detail)
                WorkoutHeartRatePanel(detail: detail)
                WorkoutZonesPanel(detail: detail)
                if detail.showsStrengthSection {
                    WorkoutStrengthDetailSection(
                        detail: detail,
                        isPreparingAction: isPreparingAction,
                        onRetry: { Task { await load() } },
                        onEdit: { prepareEditor(for: detail, repeating: false) },
                        onRepeat: { prepareEditor(for: detail, repeating: true) }
                    )
                }
            }
        }
    }

    private var actionAlertPresented: Binding<Bool> {
        Binding(
            get: { actionMessage != nil },
            set: { if !$0 { actionMessage = nil } }
        )
    }

    @MainActor
    private func load() async {
        loadState = .loading
        do {
            loadState = .loaded(try await client.loadWorkoutDetail(id: workoutID))
        } catch is CancellationError {
            return
        } catch {
            logger.error("Workout detail request failed: \(String(describing: type(of: error)), privacy: .public)")
            loadState = .failed("The backend was unavailable at \(client.baseURL.absoluteString).")
        }
    }

    private func prepareEditor(for detail: WorkoutDetail, repeating: Bool) {
        guard let workout = detail.strengthSession else {
            actionMessage = "Structured workout details are unavailable. Try refreshing this workout."
            return
        }
        guard fitnessStore.draft == nil else {
            actionMessage = "Finish or discard your current workout before \(repeating ? "repeating" : "editing") this one."
            return
        }

        isPreparingAction = true
        Task {
            if repeating {
                await fitnessStore.repeatWorkout(workout)
            } else {
                await fitnessStore.editWorkout(workout)
            }
            isPreparingAction = false
            if fitnessStore.draft != nil {
                showEditor = true
            } else {
                logger.error("Workout \(repeating ? "repeat" : "edit") request failed")
                actionMessage = fitnessStore.syncMessage ?? "This workout could not be opened. Try again."
            }
        }
    }
}

private struct WorkoutStrengthDetailSection: View {
    let detail: WorkoutDetail
    let isPreparingAction: Bool
    let onRetry: () -> Void
    let onEdit: () -> Void
    let onRepeat: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch detail.sessionStructureStatus {
            case "available":
                if let session = detail.strengthSession {
                    availableContent(session)
                } else {
                    unavailableContent(
                        title: "Strength details unavailable",
                        message: "The recorded exercises could not be loaded.",
                        symbol: "exclamationmark.triangle"
                    )
                }
            case "pending":
                unavailableContent(
                    title: "Strength details are still syncing",
                    message: "The workout is here. Its exercises and sets will appear after syncing finishes.",
                    symbol: "arrow.triangle.2.circlepath"
                )
            default:
                unavailableContent(
                    title: "No strength details recorded",
                    message: "This workout does not include structured exercises or sets.",
                    symbol: "dumbbell"
                )
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface(cornerRadius: 20)
    }

    private func availableContent(_ session: FitnessWorkout) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Strength Session")
                    .font(.headline)
                Spacer()
                Text(session.strengthSummary)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if let sessionRPE = session.sessionRPE {
                Label("Effort \(sessionRPE.clean) out of 10", systemImage: "gauge.with.dots.needle.33percent")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if let notes = session.notes, !notes.isEmpty {
                Text(notes)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                ForEach(session.exercises) { exercise in
                    WorkoutStrengthExerciseCard(exercise: exercise)
                }
            }

            HStack(spacing: 12) {
                Button(action: onEdit) {
                    Label("Edit", systemImage: "pencil")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(action: onRepeat) {
                    Label("Repeat", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(HealthTheme.color(for: .activity))
            }
            .disabled(isPreparingAction)
            .overlay {
                if isPreparingAction { ProgressView() }
            }
        }
    }

    private func unavailableContent(title: String, message: String, symbol: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(HealthTheme.color(for: .activity))
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Check again", action: onRetry)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

private struct WorkoutStrengthExerciseCard: View {
    let exercise: FitnessWorkoutExercise

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(exercise.name)
                    .font(.subheadline.weight(.bold))
                Spacer()
                Text("\(exercise.completedSetCount)/\(exercise.plannedSetCount) sets")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if let notes = exercise.notes, !notes.isEmpty {
                Text(notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { index, set in
                    WorkoutStrengthSetRow(number: index + 1, set: set, isUnilateral: exercise.isUnilateral)
                }
            }
        }
        .padding(14)
        .background(.white.opacity(0.38), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

private struct WorkoutStrengthSetRow: View {
    let number: Int
    let set: FitnessWorkoutSet
    let isUnilateral: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(set.badge(number: number))
                .font(.caption.weight(.bold))
                .frame(width: 32, height: 32)
                .background(.secondary.opacity(0.10), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(set.recordedValues(isUnilateral: isUnilateral))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                if let notes = set.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)

            if set.status != "completed" {
                Text(set.status.displayTitle)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Set \(number), \(set.recordedValues(isUnilateral: isUnilateral)), \(set.status.displayTitle)")
    }
}

private struct WorkoutDetailHeader: View {
    let detail: WorkoutDetail

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: detail.summaryIconName)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(detail.summaryTint.gradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(detail.summaryDisplayName)
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(detail.workoutDateLine)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(detail.durationRangeLine)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            Spacer(minLength: 8)

            if let intensity = detail.presentation.intensityLabel {
                StatusPill(title: intensity, color: detail.presentation.strainAccent)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface(cornerRadius: 20)
    }
}

private struct WorkoutSummaryMetricsPanel: View {
    let detail: WorkoutDetail

    private var columns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Workout Summary")
                .font(.headline)

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(detail.summaryTiles) { tile in
                    WorkoutMetricTile(tile: tile)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface(cornerRadius: 20)
    }
}

private struct WorkoutMetricTile: View {
    let tile: WorkoutMetricTileData

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: tile.systemImage)
                .font(.headline)
                .foregroundStyle(tile.tint)

            VStack(alignment: .leading, spacing: 3) {
                Text(tile.value)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Text(tile.title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        .background(.white.opacity(0.38), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct WorkoutHeartRatePanel: View {
    let detail: WorkoutDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Heart Rate")
                    .font(.headline)
                Spacer()
                Text(detail.heartRateSampleText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                WorkoutHeartRateStat(label: "Avg", value: detail.heartRate?.averageBPM)
                WorkoutHeartRateStat(label: "Min", value: detail.heartRate?.minBPM)
                WorkoutHeartRateStat(label: "Max", value: detail.heartRate?.maxBPM)
            }

            if detail.plottableHeartRateSamples.isEmpty {
                Text("No heart-rate samples were found for this workout.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 150, alignment: .center)
            } else {
                WorkoutHeartRateChart(detail: detail)
                    .frame(height: 210)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface(cornerRadius: 20)
    }
}

private struct WorkoutHeartRateStat: View {
    let label: String
    let value: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value?.clean ?? "--")
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                if value != nil {
                    Text("bpm")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WorkoutHeartRateChart: View {
    let detail: WorkoutDetail
    @State private var selectedProgress: Double?

    private var samples: [WorkoutHeartRatePlotPoint] {
        detail.heartRatePlotPoints
    }

    private var selectedPoint: WorkoutHeartRatePlotPoint? {
        if let selectedProgress {
            return samples.min { left, right in
                abs(left.progress - selectedProgress) < abs(right.progress - selectedProgress)
            }
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            selectedReadout

            GeometryReader { proxy in
                let chartSamples = samples
                let topPadding: CGFloat = 14
                let bottomPadding: CGFloat = 28
                let labelGutter: CGFloat = 34
                let plotWidth = max(1, proxy.size.width - labelGutter)
                let plotHeight = max(1, proxy.size.height - topPadding - bottomPadding)
                let bounds = heartRateBounds(for: chartSamples)
                let bands = zoneBands(bounds: bounds)

                ZStack(alignment: .topLeading) {
                    ForEach(bands) { band in
                        zoneBand(
                            band,
                            bounds: bounds,
                            plotWidth: plotWidth,
                            labelGutter: labelGutter,
                            plotHeight: plotHeight,
                            topPadding: topPadding
                        )
                    }

                    ForEach(lineSegments(for: chartSamples, bands: bands)) { segment in
                        Path { path in
                            path.move(to: location(
                                for: segment.start,
                                bounds: bounds,
                                plotWidth: plotWidth,
                                plotHeight: plotHeight,
                                topPadding: topPadding
                            ))
                            path.addLine(to: location(
                                for: segment.end,
                                bounds: bounds,
                                plotWidth: plotWidth,
                                plotHeight: plotHeight,
                                topPadding: topPadding
                            ))
                        }
                        .stroke(heartRateZoneColor(segment.zone), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    }

                    if let selectedPoint {
                        let selectedLocation = location(
                            for: selectedPoint,
                            bounds: bounds,
                            plotWidth: plotWidth,
                            plotHeight: plotHeight,
                            topPadding: topPadding
                        )
                        Path { path in
                            path.move(to: CGPoint(x: selectedLocation.x, y: topPadding))
                            path.addLine(to: CGPoint(x: selectedLocation.x, y: topPadding + plotHeight))
                        }
                        .stroke(.primary.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                        Circle()
                            .fill(heartRateZoneColor(zone(for: selectedPoint.value, in: bands)))
                            .overlay {
                                Circle().stroke(.white, lineWidth: 2)
                            }
                            .frame(width: 12, height: 12)
                            .position(selectedLocation)
                    }

                    if let first = chartSamples.first {
                        Text(first.timeLabel)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .position(x: 0, y: topPadding + plotHeight + 18)
                    }
                    if let last = chartSamples.last {
                        Text(last.timeLabel)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .position(x: plotWidth, y: topPadding + plotHeight + 18)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            selectedProgress = min(1, max(0, value.location.x / plotWidth))
                        }
                )
            }
        }
    }

    @ViewBuilder
    private var selectedReadout: some View {
        if let selectedPoint {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(selectedPoint.value.clean)
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                    Text("bpm")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                Text(selectedPoint.timeLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Drag across the chart to inspect heart rate.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func zoneBand(
        _ band: WorkoutZoneBand,
        bounds: WorkoutHeartRateBounds,
        plotWidth: CGFloat,
        labelGutter: CGFloat,
        plotHeight: CGFloat,
        topPadding: CGFloat
    ) -> some View {
        let top = yPosition(for: band.upperBound, bounds: bounds, plotHeight: plotHeight, topPadding: topPadding)
        let bottom = yPosition(for: band.lowerBound, bounds: bounds, plotHeight: plotHeight, topPadding: topPadding)
        let height = max(1, bottom - top)
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(heartRateZoneColor(band.zone).opacity(0.1))
                .frame(width: plotWidth, height: height)
                .position(x: plotWidth / 2, y: top + height / 2)

            Path { path in
                path.move(to: CGPoint(x: 0, y: top))
                path.addLine(to: CGPoint(x: plotWidth, y: top))
            }
            .stroke(.white.opacity(0.42), lineWidth: 1)

            Text(band.shortLabel)
                .font(.caption2.weight(.bold))
                .foregroundStyle(heartRateZoneColor(band.zone))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .position(x: plotWidth + labelGutter / 2, y: top + height / 2)
        }
    }

    private func location(
        for point: WorkoutHeartRatePlotPoint,
        bounds: WorkoutHeartRateBounds,
        plotWidth: CGFloat,
        plotHeight: CGFloat,
        topPadding: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: plotWidth * CGFloat(point.progress),
            y: yPosition(for: point.value, bounds: bounds, plotHeight: plotHeight, topPadding: topPadding)
        )
    }

    private func yPosition(
        for value: Double,
        bounds: WorkoutHeartRateBounds,
        plotHeight: CGFloat,
        topPadding: CGFloat
    ) -> CGFloat {
        topPadding + plotHeight - plotHeight * CGFloat((value - bounds.min) / max(1, bounds.max - bounds.min))
    }

    private func heartRateBounds(for samples: [WorkoutHeartRatePlotPoint]) -> WorkoutHeartRateBounds {
        let values = samples.map(\.value)
        let minValue = values.min() ?? 0
        let maxValue = values.max() ?? 1
        let thresholdValues = detail.zoneThresholdValues
        let lower = min(minValue, thresholdValues.min() ?? minValue)
        let upper = max(maxValue, thresholdValues.max() ?? maxValue)
        if upper - lower < 10 {
            return WorkoutHeartRateBounds(min: max(0, lower - 5), max: upper + 5)
        }
        return WorkoutHeartRateBounds(min: max(0, lower - 8), max: upper + 8)
    }

    private func zoneBands(bounds: WorkoutHeartRateBounds) -> [WorkoutZoneBand] {
        if let thresholdBands = detail.thresholdZoneBands(bounds: bounds), !thresholdBands.isEmpty {
            return thresholdBands
        }
        let span = max(1, bounds.max - bounds.min)
        return ["zone_1", "zone_2", "zone_3", "zone_4"].enumerated().map { index, zone in
            let lower = bounds.min + span * Double(index) / 4
            let upper = bounds.min + span * Double(index + 1) / 4
            return WorkoutZoneBand(zone: zone, lowerBound: lower, upperBound: upper)
        }
    }

    private func lineSegments(
        for samples: [WorkoutHeartRatePlotPoint],
        bands: [WorkoutZoneBand]
    ) -> [WorkoutHeartRateSegment] {
        zip(samples, samples.dropFirst()).enumerated().map { index, pair in
            let midpoint = (pair.0.value + pair.1.value) / 2
            return WorkoutHeartRateSegment(
                id: "\(pair.0.id)-\(pair.1.id)-\(index)",
                start: pair.0,
                end: pair.1,
                zone: zone(for: midpoint, in: bands)
            )
        }
    }

    private func zone(for value: Double, in bands: [WorkoutZoneBand]) -> String {
        bands.first { value >= $0.lowerBound && value <= $0.upperBound }?.zone
            ?? bands.last?.zone
            ?? "zone_1"
    }
}

private struct WorkoutHeartRateBounds {
    let min: Double
    let max: Double
}

private struct WorkoutZoneBand: Identifiable {
    let zone: String
    let lowerBound: Double
    let upperBound: Double

    var id: String { zone }

    var shortLabel: String {
        heartRateZoneShortLabel(zone)
    }
}

private struct WorkoutHeartRateSegment: Identifiable {
    let id: String
    let start: WorkoutHeartRatePlotPoint
    let end: WorkoutHeartRatePlotPoint
    let zone: String
}

private struct WorkoutZonesPanel: View {
    let detail: WorkoutDetail

    private var activeZones: [WorkoutHeartRateZone] {
        detail.heartRateZones.filter { $0.seconds > 0 }
    }

    private var totalSeconds: Int {
        detail.heartRateZones.reduce(0) { $0 + $1.seconds }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Heart Rate Zones")
                    .font(.headline)
                Spacer()
                Text(detail.zoneSourceText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            if activeZones.isEmpty {
                Text("No zone data was found for this workout.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90, alignment: .center)
            } else {
                WorkoutZoneStackedBar(zones: activeZones, totalSeconds: totalSeconds)
                    .frame(height: 16)

                VStack(spacing: 10) {
                    ForEach(detail.heartRateZones) { zone in
                        WorkoutZoneRow(zone: zone, totalSeconds: totalSeconds)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface(cornerRadius: 20)
    }
}

private struct WorkoutZoneStackedBar: View {
    let zones: [WorkoutHeartRateZone]
    let totalSeconds: Int

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 3) {
                ForEach(zones) { zone in
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(heartRateZoneColor(zone.zone).gradient)
                        .frame(width: max(4, proxy.size.width * CGFloat(zone.seconds) / CGFloat(max(1, totalSeconds))))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct WorkoutZoneRow: View {
    let zone: WorkoutHeartRateZone
    let totalSeconds: Int

    private var ratio: Double {
        Double(zone.seconds) / Double(max(1, totalSeconds))
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(heartRateZoneColor(zone.zone))
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(zone.zoneDisplayTitle)
                    .font(.subheadline.weight(.bold))
                if let thresholdText = zone.thresholdText {
                    Text(thresholdText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(durationText(seconds: zone.seconds))
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                Text("\(Int((ratio * 100).rounded()))%")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}

private struct WorkoutMetricTileData: Identifiable {
    let id: String
    let title: String
    let value: String
    let systemImage: String
    let tint: Color
}

private struct WorkoutHeartRatePlotPoint: Identifiable {
    let id: String
    let value: Double
    let progress: Double
    let timeLabel: String
}

private extension WorkoutDetail {
    var presentation: WorkoutPresentation {
        WorkoutPresentationFactory.make(type: workoutType, intensity: intensity, strainLoadPoints: strainLoadPoints)
    }

    var summaryIconName: String {
        presentation.symbolName
    }

    var summaryTint: Color {
        presentation.activityAccent
    }

    var summaryDisplayName: String {
        strengthSession?.title ?? presentation.displayName
    }

    var workoutDateLine: String {
        if let startDate {
            return DashboardFormatters.shortDate.string(from: startDate)
        }
        return date ?? "Recent workout"
    }

    var durationRangeLine: String {
        let range = [startDate, endDate]
            .compactMap { $0.map(DashboardFormatters.workoutTime.string) }
            .joined(separator: "-")
        if range.isEmpty {
            return durationText(seconds: durationSeconds)
        }
        return "\(range)  \(durationText(seconds: durationSeconds))"
    }

    var startDate: Date? {
        DashboardFormatters.parseBackendDateTime(startTime)
    }

    var endDate: Date? {
        DashboardFormatters.parseBackendDateTime(endTime)
    }

    var summaryTiles: [WorkoutMetricTileData] {
        var tiles = [
            WorkoutMetricTileData(id: "duration", title: "Duration", value: durationText(seconds: durationSeconds), systemImage: "clock.fill", tint: .blue)
        ]

        if let distanceMeters {
            tiles.append(WorkoutMetricTileData(id: "distance", title: "Distance", value: distanceText(meters: distanceMeters), systemImage: "point.topleft.down.curvedto.point.bottomright.up", tint: .mint))
        }

        if let activeCalories {
            tiles.append(WorkoutMetricTileData(id: "calories", title: "Active Calories", value: "\(activeCalories.clean) kcal", systemImage: "flame.fill", tint: .orange))
        }

        if let strainLoadPoints {
            tiles.append(WorkoutMetricTileData(id: "strain", title: "Strain Load", value: strainLoadPoints.clean, systemImage: "bolt.heart.fill", tint: .red))
        } else if let average = heartRate?.averageBPM {
            tiles.append(WorkoutMetricTileData(id: "heart_rate", title: "Average HR", value: "\(average.clean) bpm", systemImage: "heart.fill", tint: .red))
        }

        return tiles
    }

    var plottableHeartRateSamples: [WorkoutHeartRateSample] {
        heartRateSamples.filter { $0.value != nil }
    }

    var heartRatePlotPoints: [WorkoutHeartRatePlotPoint] {
        let samples = plottableHeartRateSamples
        guard !samples.isEmpty else { return [] }
        let parsedDates = samples.map { DashboardFormatters.parseBackendDateTime($0.observedAt) }
        let start = startDate ?? parsedDates.compactMap(\.self).first
        let end = endDate ?? parsedDates.compactMap(\.self).last
        let duration = max(1, (end?.timeIntervalSince(start ?? end ?? Date()) ?? Double(samples.count - 1)))

        return samples.enumerated().compactMap { index, sample in
            guard let value = sample.value else { return nil }
            let sampleDate = parsedDates[index]
            let progress: Double
            if let sampleDate, let start {
                progress = min(1, max(0, sampleDate.timeIntervalSince(start) / duration))
            } else if samples.count > 1 {
                progress = Double(index) / Double(samples.count - 1)
            } else {
                progress = 0.5
            }
            return WorkoutHeartRatePlotPoint(
                id: "\(sample.observedAt ?? "sample")-\(index)",
                value: value,
                progress: progress,
                timeLabel: sampleDate.map(DashboardFormatters.workoutTime.string) ?? "\(index + 1)"
            )
        }
    }

    var zoneThresholdValues: [Double] {
        heartRateZones.flatMap { zone in
            (zone.thresholds ?? [:]).values.flatMap { threshold in
                [threshold.minBPM, threshold.maxBPM].compactMap(\.self)
            }
        }
    }

    func thresholdZoneBands(bounds: WorkoutHeartRateBounds) -> [WorkoutZoneBand]? {
        guard let thresholds = heartRateZones.compactMap(\.thresholds).first else { return nil }
        let orderedZones = ["zone_1", "zone_2", "zone_3", "zone_4"]
        let bands = orderedZones.compactMap { zone -> WorkoutZoneBand? in
            guard let threshold = thresholds[zone] else { return nil }
            let lower = threshold.minBPM ?? bounds.min
            let upper = threshold.maxBPM ?? bounds.max
            guard upper > lower else { return nil }
            return WorkoutZoneBand(
                zone: zone,
                lowerBound: max(bounds.min, lower),
                upperBound: min(bounds.max, upper)
            )
        }
        return bands.count == orderedZones.count ? bands : nil
    }

    var heartRateSampleText: String {
        let count = heartRate?.sampleCount ?? heartRateSamples.count
        return "\(count) \(count == 1 ? "sample" : "samples")"
    }

    var zoneSourceText: String {
        switch zoneSource {
        case "provider_workout_summary": return "Provider zones"
        case "time_in_heart_rate_zone": return "Time-in-zone data"
        case "heart_rate_reserve_inferred": return "Estimated zones"
        case "missing": return "No zone data"
        case .some(let value): return value.displayTitle
        case .none: return "Unknown"
        }
    }

}

private extension WorkoutHeartRateZone {
    var zoneDisplayTitle: String {
        switch zone {
        case "zone_1": return "Zone 1 Easy"
        case "zone_2": return "Zone 2 Aerobic"
        case "zone_3": return "Zone 3 Hard"
        case "zone_4": return "Zone 4 Peak"
        default: return zone.displayTitle
        }
    }

    var thresholdText: String? {
        guard let threshold = thresholds?[zone] else { return nil }
        switch (threshold.minBPM, threshold.maxBPM) {
        case (.some(let min), .some(let max)):
            return "\(min.clean)-\(max.clean) bpm"
        case (.some(let min), .none):
            return "\(min.clean)+ bpm"
        case (.none, .some(let max)):
            return "Up to \(max.clean) bpm"
        default:
            return nil
        }
    }
}

private func durationText(seconds: Int?) -> String {
    guard let seconds else { return "--" }
    let minutes = max(0, Int((Double(seconds) / 60).rounded()))
    if minutes >= 60 {
        return "\(minutes / 60)h \(minutes % 60)m"
    }
    return "\(minutes)m"
}

private func distanceText(meters: Double) -> String {
    if meters >= 1000 {
        return String(format: "%.1f km", meters / 1000)
    }
    return "\(meters.clean) m"
}

private extension WorkoutDetail {
    var showsStrengthSection: Bool {
        if strengthSession != nil { return true }
        switch presentation.family {
        case .strength: return true
        default: return false
        }
    }
}

private extension FitnessWorkout {
    var strengthSummary: String {
        var values = [
            "\(summary.exerciseCount) \(summary.exerciseCount == 1 ? "exercise" : "exercises")",
            "\(summary.completedSetCount) \(summary.completedSetCount == 1 ? "set" : "sets")",
        ]
        if summary.volumeKG > 0 {
            values.append("\(summary.volumeKG.clean) kg")
        }
        return values.joined(separator: " · ")
    }
}

private extension FitnessWorkoutSet {
    func badge(number: Int) -> String {
        switch setType {
        case "warmup": return "W"
        case "drop": return "D"
        default: return "\(number)"
        }
    }

    func recordedValues(isUnilateral: Bool) -> String {
        var values: [String] = []
        if let reps {
            values.append("\(reps) reps\(isUnilateral ? "/side" : "")")
        }
        if let loadPerImplement {
            let count = implementCount.map { " × \($0)" } ?? ""
            values.append("\(loadPerImplement.clean) kg each\(count)")
        } else if let loadValue {
            values.append("\(loadValue.clean) \(loadUnit ?? "kg")")
        }
        if let durationSeconds {
            values.append(durationText(seconds: durationSeconds))
        }
        if let distanceMeters {
            values.append(distanceText(meters: distanceMeters))
        }
        if let assistanceKG {
            values.append("\(assistanceKG.clean) kg assistance")
        }
        if let addedLoadKG {
            values.append("+\(addedLoadKG.clean) kg")
        }
        if let rir {
            values.append("RIR \(rir.clean)")
        }
        return values.isEmpty ? "No values recorded" : values.joined(separator: " · ")
    }
}

#Preview("Workout detail") {
    NavigationStack {
        WorkoutDetailPreview(detail: .sample)
    }
}

private struct WorkoutDetailPreview: View {
    let detail: WorkoutDetail

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    WorkoutDetailHeader(detail: detail)
                    WorkoutSummaryMetricsPanel(detail: detail)
                    WorkoutHeartRatePanel(detail: detail)
                    WorkoutZonesPanel(detail: detail)
                }
                .padding(20)
            }
        }
    }
}

private extension WorkoutDetail {
    static let sample = WorkoutDetail(
        id: "sample-workout",
        workoutType: "run",
        startTime: "2026-06-19T08:00:00Z",
        endTime: "2026-06-19T08:40:00Z",
        date: "2026-06-19",
        durationSeconds: 2400,
        distanceMeters: 5000,
        activeCalories: 420,
        heartRate: HeartRateSummary(averageBPM: 144, minBPM: 96, maxBPM: 178, sampleCount: 9),
        heartRateZones: [
            WorkoutHeartRateZone(zone: "zone_1", seconds: 300, minutes: 5, source: "provider_workout_summary", sourceZones: ["LIGHT"], thresholds: nil, maxHeartRate: nil, maxHeartRateSource: nil, restingHeartRate: nil),
            WorkoutHeartRateZone(zone: "zone_2", seconds: 1200, minutes: 20, source: "provider_workout_summary", sourceZones: ["MODERATE"], thresholds: nil, maxHeartRate: nil, maxHeartRateSource: nil, restingHeartRate: nil),
            WorkoutHeartRateZone(zone: "zone_3", seconds: 600, minutes: 10, source: "provider_workout_summary", sourceZones: ["VIGOROUS"], thresholds: nil, maxHeartRate: nil, maxHeartRateSource: nil, restingHeartRate: nil),
            WorkoutHeartRateZone(zone: "zone_4", seconds: 300, minutes: 5, source: "provider_workout_summary", sourceZones: ["PEAK"], thresholds: nil, maxHeartRate: nil, maxHeartRateSource: nil, restingHeartRate: nil)
        ],
        zoneSource: "provider_workout_summary",
        intensity: "moderate",
        strainLoadPoints: 32.4,
        heartRateSamples: [
            WorkoutHeartRateSample(observedAt: "2026-06-19T08:00:00Z", value: 96, unit: "bpm", sourcePlatform: "Google Health", sourceDevice: "Pixel Watch"),
            WorkoutHeartRateSample(observedAt: "2026-06-19T08:05:00Z", value: 122, unit: "bpm", sourcePlatform: "Google Health", sourceDevice: "Pixel Watch"),
            WorkoutHeartRateSample(observedAt: "2026-06-19T08:10:00Z", value: 138, unit: "bpm", sourcePlatform: "Google Health", sourceDevice: "Pixel Watch"),
            WorkoutHeartRateSample(observedAt: "2026-06-19T08:15:00Z", value: 151, unit: "bpm", sourcePlatform: "Google Health", sourceDevice: "Pixel Watch"),
            WorkoutHeartRateSample(observedAt: "2026-06-19T08:20:00Z", value: 162, unit: "bpm", sourcePlatform: "Google Health", sourceDevice: "Pixel Watch"),
            WorkoutHeartRateSample(observedAt: "2026-06-19T08:25:00Z", value: 178, unit: "bpm", sourcePlatform: "Google Health", sourceDevice: "Pixel Watch"),
            WorkoutHeartRateSample(observedAt: "2026-06-19T08:30:00Z", value: 161, unit: "bpm", sourcePlatform: "Google Health", sourceDevice: "Pixel Watch"),
            WorkoutHeartRateSample(observedAt: "2026-06-19T08:35:00Z", value: 148, unit: "bpm", sourcePlatform: "Google Health", sourceDevice: "Pixel Watch"),
            WorkoutHeartRateSample(observedAt: "2026-06-19T08:40:00Z", value: 132, unit: "bpm", sourcePlatform: "Google Health", sourceDevice: "Pixel Watch")
        ],
        sessionStructureStatus: "unavailable",
        strengthSession: nil,
        provenance: WorkoutProvenance(
            originalSource: "google_health",
            currentOrigin: "wearable",
            isUserEdited: false,
            lastEditedAt: nil
        )
    )
}
