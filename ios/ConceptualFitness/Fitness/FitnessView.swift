import SwiftUI

struct FitnessView: View {
    @StateObject private var store: FitnessStore
    @State private var showEditor = false
    @State private var showPastWorkout = false

    init(authStore: AuthStore, userID: String) {
        _store = StateObject(wrappedValue: FitnessStore(authStore: authStore, userID: userID))
    }

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    header
                    if let draft = store.draft {
                        resumeCard(draft)
                    } else {
                        startActions
                    }
                    if let message = store.syncMessage {
                        syncBanner(message)
                    }
                    matchSection
                    routineSection
                    recentSection
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .refreshable { await store.refresh() }
        }
        .navigationTitle("Fitness")
        .navigationBarTitleDisplayMode(.large)
        .task {
            await store.load()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-OpenWorkoutEditor"), store.draft != nil {
                showEditor = true
            }
            #endif
        }
        .fullScreenCover(isPresented: $showEditor) {
            WorkoutEditorView(store: store)
        }
        .sheet(isPresented: $showPastWorkout) {
            PastWorkoutSheet { date, duration in
                guard store.startWorkout(at: date, retrospective: true) else { return }
                store.updateDraft { draft in
                    draft.endTime = date.addingTimeInterval(duration)
                }
                showEditor = true
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Train, log, repeat.")
                .font(.title2.weight(.bold))
            Text("Your live strength log and wearable activities, together in one timeline.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    private func resumeCard(_ draft: LocalWorkoutDraft) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Workout in progress", systemImage: "bolt.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(HealthTheme.color(for: .activity))
                    Text(draft.title ?? "Strength Workout")
                        .font(.title3.weight(.bold))
                    Text("\(draft.exercises.count) exercises · \(completedSets(in: draft)) sets logged")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !draft.isRetrospective {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(elapsed(from: draft.startTime, to: context.date))
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .monospacedDigit()
                    }
                }
            }
            Button {
                showEditor = true
            } label: {
                Label("Resume workout", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
            }
            .buttonStyle(.borderedProminent)
            .tint(HealthTheme.color(for: .activity))
        }
        .padding(18)
        .glassSurface(cornerRadius: 24, interactive: true)
        .accessibilityElement(children: .contain)
    }

    private var startActions: some View {
        VStack(spacing: 12) {
            Button {
                if store.startWorkout() {
                    showEditor = true
                }
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "plus")
                        .font(.title2.weight(.bold))
                        .frame(width: 44, height: 44)
                        .background(.white.opacity(0.2), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Start workout")
                            .font(.headline)
                        Text("Log sets as you train")
                            .font(.caption)
                            .opacity(0.85)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                .foregroundStyle(.white)
                .padding(16)
                .background(
                    LinearGradient(
                        colors: [HealthTheme.color(for: .activity), Color.indigo.opacity(0.85)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens an empty live strength workout")

            HStack(spacing: 12) {
                Button {
                    showPastWorkout = true
                } label: {
                    actionTile("Log past workout", symbol: "calendar.badge.plus")
                }
                if let last = store.overview?.recentWorkouts.first {
                    Button {
                        Task {
                            await store.repeatWorkout(last)
                            if store.draft != nil { showEditor = true }
                        }
                    } label: {
                        actionTile("Repeat last", symbol: "arrow.counterclockwise")
                    }
                }
            }
        }
    }

    private func actionTile(_ title: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(HealthTheme.color(for: .activity))
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(15)
        .glassSurface(cornerRadius: 19, interactive: true)
    }

    @ViewBuilder
    private var matchSection: some View {
        if !store.matchSuggestions.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Needs review")
                    .font(.title3.weight(.bold))
                ForEach(store.matchSuggestions) { suggestion in
                    VStack(alignment: .leading, spacing: 13) {
                        Label("Possible duplicate workout", systemImage: "square.on.square")
                            .font(.headline)
                        Text("\(suggestion.targetWorkout.title) and \(suggestion.candidate.workout.title) overlap in time and may be the same activity.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Keep separate") {
                                Task { await store.keepSeparate(suggestion) }
                            }
                            .buttonStyle(.bordered)
                            Spacer()
                            Button("Combine") {
                                Task { await store.merge(suggestion) }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(HealthTheme.color(for: .activity))
                        }
                    }
                    .padding(16)
                    .glassSurface(cornerRadius: 20)
                }
            }
        }
    }

    @ViewBuilder
    private var routineSection: some View {
        let routines = store.overview?.routines ?? []
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Saved workouts")
                    .font(.title3.weight(.bold))
                Spacer()
                if !routines.isEmpty {
                    Text("\(routines.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            if store.loadState == .loading && routines.isEmpty {
                routinePlaceholder
                    .redacted(reason: .placeholder)
            } else if routines.isEmpty {
                ContentUnavailableView(
                    "No saved workouts yet",
                    systemImage: "bookmark",
                    description: Text("Finish a workout, then save it as a routine for quick access here.")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(routines) { routine in
                            routineCard(routine)
                        }
                    }
                }
                .contentMargins(.horizontal, 1, for: .scrollContent)
            }
        }
    }

    private var routinePlaceholder: some View {
        RoundedRectangle(cornerRadius: 20)
            .fill(.white.opacity(0.7))
            .frame(width: 250, height: 150)
    }

    private func routineCard(_ routine: FitnessRoutine) -> some View {
        Button {
            Task {
                await store.startRoutine(routine)
                if store.draft != nil { showEditor = true }
            }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: routine.isFavorite ? "bookmark.fill" : "dumbbell.fill")
                        .foregroundStyle(HealthTheme.color(for: .activity))
                    Spacer()
                    if store.overview?.dueRoutines.contains(where: { $0.id == routine.id }) == true {
                        Text("TODAY")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(HealthTheme.color(for: .activity).opacity(0.12), in: Capsule())
                    }
                }
                Text(routine.name)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text("\(routine.exercises.count) exercises")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !routine.scheduledWeekdays.isEmpty {
                    Text(weekdaySummary(routine.scheduledWeekdays))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 220, alignment: .leading)
            .padding(16)
            .glassSurface(cornerRadius: 20, interactive: true)
        }
        .buttonStyle(.plain)
        .disabled(store.draft != nil)
        .accessibilityHint("Starts this saved workout")
    }

    @ViewBuilder
    private var recentSection: some View {
        let recent = store.overview?.recentWorkouts ?? []
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent activities")
                .font(.title3.weight(.bold))
            if store.loadState == .loading && recent.isEmpty {
                ForEach(0..<3, id: \.self) { _ in
                    recentPlaceholder.redacted(reason: .placeholder)
                }
            } else if case .failed(let message) = store.loadState, recent.isEmpty {
                ContentUnavailableView("Couldn’t load activities", systemImage: "wifi.slash", description: Text(message))
                    .frame(maxWidth: .infinity)
            } else if recent.isEmpty {
                ContentUnavailableView(
                    "No activities yet",
                    systemImage: "figure.strengthtraining.traditional",
                    description: Text("Logged and wearable workouts will appear together here.")
                )
                .frame(maxWidth: .infinity)
            } else {
                ForEach(recent) { workout in
                    HStack(spacing: 8) {
                        NavigationLink(value: AppRoute.workout(workout.id)) {
                            recentRow(workout)
                        }
                        .buttonStyle(.plain)
                        Menu {
                            Button {
                                Task {
                                    await store.editWorkout(workout)
                                    if store.draft != nil { showEditor = true }
                                }
                            } label: {
                                Label("Edit workout", systemImage: "pencil")
                            }
                            Button {
                                Task {
                                    await store.repeatWorkout(workout)
                                    if store.draft != nil { showEditor = true }
                                }
                            } label: {
                                Label("Repeat workout", systemImage: "arrow.counterclockwise")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .frame(width: 36, height: 44)
                        }
                        .accessibilityLabel("Workout actions")
                    }
                    .padding(15)
                    .glassSurface(cornerRadius: 19, interactive: true)
                }
            }
        }
    }

    private var recentPlaceholder: some View {
        RoundedRectangle(cornerRadius: 19)
            .fill(.white.opacity(0.7))
            .frame(height: 92)
    }

    private func recentRow(_ workout: FitnessWorkout) -> some View {
        let presentation = WorkoutPresentationFactory.make(
            type: workout.workoutType,
            intensity: nil,
            strainLoadPoints: nil
        )
        return HStack(spacing: 14) {
            Image(systemName: presentation.symbolName)
                .font(.title3)
                .foregroundStyle(presentation.activityAccent)
                .frame(width: 44, height: 44)
                .background(presentation.activityAccent.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(workout.title)
                    .font(.headline)
                HStack(spacing: 7) {
                    Text(relativeDate(workout.startTime))
                    Text("·")
                    Text(duration(workout.durationSeconds))
                    if workout.summary.completedSetCount > 0 {
                        Text("·")
                        Text("\(workout.summary.completedSetCount) sets")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if workout.awaitingWearable {
                    Label("Waiting for wearable data", systemImage: "waveform.path.ecg")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(HealthTheme.color(for: .activity))
                }
            }
            Spacer()
        }
    }

    private func syncBanner(_ message: String) -> some View {
        Label(message, systemImage: "icloud.and.arrow.up")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func completedSets(in draft: LocalWorkoutDraft) -> Int {
        draft.exercises.reduce(0) { $0 + $1.sets.filter(\.isCompleted).count }
    }

    private func elapsed(from start: Date, to end: Date) -> String {
        duration(max(0, Int(end.timeIntervalSince(start))))
    }

    private func duration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(max(1, minutes))m"
    }

    private func relativeDate(_ value: String) -> String {
        guard let date = FitnessDate.parse(value) else { return value }
        return date.formatted(.relative(presentation: .named))
    }

    private func weekdaySummary(_ weekdays: [Int]) -> String {
        let symbols = Calendar.current.shortWeekdaySymbols
        return weekdays.compactMap { day in
            let index = day == 7 ? 0 : day
            return symbols.indices.contains(index) ? symbols[index] : nil
        }.joined(separator: " · ")
    }
}

private struct PastWorkoutSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var startDate = Date().addingTimeInterval(-3600)
    @State private var durationMinutes = 60
    let onCreate: (Date, TimeInterval) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("When") {
                    DatePicker("Started", selection: $startDate, in: ...Date())
                    Stepper("Duration: \(durationMinutes) min", value: $durationMinutes, in: 5...360, step: 5)
                }
                Section {
                    Text("You’ll use the same set-by-set editor as a live workout, with the completed time fixed to this window.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Log past workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") {
                        onCreate(startDate, TimeInterval(durationMinutes * 60))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}
