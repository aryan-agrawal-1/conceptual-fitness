import SwiftUI

struct FitnessView: View {
    @StateObject private var store: FitnessStore
    @State private var showEditor = false
    @State private var showPastWorkout = false
    @State private var week = FitnessWeek()
    @State private var sceneBehindStatusBar = true
    @Environment(\.profileUnits) private var units
    private let strainClient: DashboardAPIClient

    init(authStore: AuthStore, userID: String) {
        _store = StateObject(wrappedValue: FitnessStore(authStore: authStore, userID: userID))
        strainClient = DashboardAPIClient(authStore: authStore)
    }

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 10) {
                        FitnessHero(week: week)
                            .padding(.bottom, -18)
                            .onGeometryChange(for: Bool.self) { $0.frame(in: .global).maxY > 110 } action: { sceneBehindStatusBar = $0 }
                        if let draft = store.draft {
                            resumeCard(draft)
                        } else {
                            startActions
                        }
                        if let message = store.syncMessage {
                            syncBanner(message)
                        }
                    }
                    matchSection
                    routineSection
                    recentSection
                }
                .padding(.horizontal, FitnessHero.sideInset)
                .padding(.bottom, 32)
            }
            .refreshable {
                await store.refresh()
                await loadWeek()
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(sceneBehindStatusBar ? .dark : nil, for: .navigationBar)
        .task {
            await store.load()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-OpenWorkoutEditor"), store.draft != nil {
                showEditor = true
            }
            #endif
        }
        .task { await loadWeek() }
        .onChange(of: showEditor) { _, isShowing in
            if !isShowing { Task { await loadWeek() } }
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

    private func loadWeek() async {
        guard let detail = try? await strainClient.loadStrainDetail(timeframe: .week) else { return }
        week = FitnessWeek(detail: detail)
    }

    private func resumeCard(_ draft: LocalWorkoutDraft) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(draft.isEditingExistingWorkout ? "Editing workout" : "Workout in progress")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(HealthTheme.secondaryInk)
                    Text(draft.title ?? "Strength Workout")
                        .font(.system(.title3, design: .rounded, weight: .bold))
                    Text(resumeSummary(draft))
                        .font(.subheadline)
                        .foregroundStyle(HealthTheme.secondaryInk)
                }
                Spacer()
                if !draft.isRetrospective {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(elapsed(from: draft.startTime, to: context.date))
                            .font(.system(.headline, design: .rounded, weight: .bold))
                            .monospacedDigit()
                    }
                }
            }
            Button {
                showEditor = true
            } label: {
                PrimaryActionLabel(title: draft.isEditingExistingWorkout ? "Continue editing" : "Resume workout")
            }
            .buttonStyle(.pressScale)
        }
        .padding(18)
        .panelSurface(cornerRadius: 24)
        .accessibilityElement(children: .contain)
    }

    private var startActions: some View {
        VStack(spacing: 10) {
            Button {
                if store.startWorkout() {
                    showEditor = true
                }
            } label: {
                PrimaryActionLabel(title: "Start workout")
            }
            .buttonStyle(.pressScale)
            .accessibilityHint("Opens an empty live strength workout")

            HStack(spacing: 10) {
                Button {
                    showPastWorkout = true
                } label: {
                    secondaryAction("Log past", symbol: "calendar.badge.plus")
                }
                .buttonStyle(.pressScale)
                if let last = store.overview?.recentWorkouts.first {
                    Button {
                        Task {
                            await store.repeatWorkout(last)
                            if store.draft != nil { showEditor = true }
                        }
                    } label: {
                        secondaryAction("Repeat last", symbol: "arrow.counterclockwise")
                    }
                    .buttonStyle(.pressScale)
                }
            }
        }
    }

    private func secondaryAction(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(HealthTheme.ink)
            .frame(maxWidth: .infinity, minHeight: 48)
            .panelSurface(cornerRadius: 16)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(.title3, design: .rounded, weight: .bold))
            .padding(.horizontal, 4)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var matchSection: some View {
        if !store.matchSuggestions.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Needs review")
                ForEach(store.matchSuggestions) { suggestion in
                    VStack(alignment: .leading, spacing: 13) {
                        Text("Possible duplicate workout")
                            .font(.headline)
                        Text("\(suggestion.targetWorkout.title) and \(suggestion.candidate.workout.title) overlap in time and may be the same activity.")
                            .font(.subheadline)
                            .foregroundStyle(HealthTheme.secondaryInk)
                        HStack(spacing: 10) {
                            Button {
                                Task { await store.keepSeparate(suggestion) }
                            } label: {
                                secondaryAction("Keep separate", symbol: "square.split.2x1")
                            }
                            .buttonStyle(.pressScale)
                            Button {
                                Task { await store.merge(suggestion) }
                            } label: {
                                Text("Combine")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(HealthTheme.inverseInk)
                                    .frame(maxWidth: .infinity, minHeight: 48)
                                    .background(HealthTheme.ink, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }
                            .buttonStyle(.pressScale)
                        }
                    }
                    .padding(16)
                    .panelSurface(cornerRadius: 22)
                }
            }
        }
    }

    @ViewBuilder
    private var routineSection: some View {
        let routines = store.overview?.routines ?? []
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Saved workouts")
            if store.loadState == .loading && routines.isEmpty {
                placeholder(height: 132)
            } else if routines.isEmpty {
                Text("Finish a workout and save it as a routine to start it from here.")
                    .font(.subheadline)
                    .foregroundStyle(HealthTheme.secondaryInk)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .panelSurface(cornerRadius: 22)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(routines.enumerated()), id: \.element.id) { index, routine in
                        if index > 0 { rowDivider }
                        routineRow(routine)
                    }
                }
                .panelSurface(cornerRadius: 22)
            }
        }
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(HealthTheme.hairline)
            .frame(height: 1)
            .padding(.leading, 66)
    }

    private func placeholder(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(HealthTheme.track)
            .frame(height: height)
            .accessibilityHidden(true)
    }

    private func rowIcon(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.body.weight(.semibold))
            .foregroundStyle(tint)
            .frame(width: 40, height: 40)
            .background(tint.opacity(0.14), in: Circle())
    }

    private func routineRow(_ routine: FitnessRoutine) -> some View {
        let isDue = store.overview?.dueRoutines.contains(where: { $0.id == routine.id }) == true
        let tint = HealthTheme.color(for: .recovery)
        return Button {
            Task {
                await store.startRoutine(routine)
                if store.draft != nil { showEditor = true }
            }
        } label: {
            HStack(spacing: 12) {
                rowIcon("dumbbell.fill", tint: tint)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(routine.name)
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                        if isDue {
                            Text("Today")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(tint)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                    Text(routineSummary(routine))
                        .font(.subheadline)
                        .foregroundStyle(HealthTheme.secondaryInk)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "play.fill")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(isDue ? HealthTheme.inverseInk : HealthTheme.ink)
                    .frame(width: 44, height: 44)
                    .background {
                        if isDue {
                            Circle().fill(HealthTheme.ink)
                        } else {
                            Circle().strokeBorder(HealthTheme.ink.opacity(0.14), lineWidth: 1)
                        }
                    }
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressScale)
        .disabled(store.draft != nil)
        .opacity(store.draft == nil ? 1 : 0.5)
        .accessibilityLabel("Start \(routine.name)")
    }

    private func routineSummary(_ routine: FitnessRoutine) -> String {
        let exercises = "\(routine.exercises.count) exercise\(routine.exercises.count == 1 ? "" : "s")"
        guard !routine.scheduledWeekdays.isEmpty else { return exercises }
        return "\(exercises) · \(weekdaySummary(routine.scheduledWeekdays))"
    }

    @ViewBuilder
    private var recentSection: some View {
        let recent = store.overview?.recentWorkouts ?? []
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Recent")
            if store.loadState == .loading && recent.isEmpty {
                placeholder(height: 196)
            } else if case .failed(let message) = store.loadState, recent.isEmpty {
                ContentUnavailableView("Couldn’t load activities", systemImage: "wifi.slash", description: Text(message))
                    .frame(maxWidth: .infinity)
            } else if recent.isEmpty {
                Text("Logged and wearable workouts appear here.")
                    .font(.subheadline)
                    .foregroundStyle(HealthTheme.secondaryInk)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .panelSurface(cornerRadius: 22)
            } else {
                ForEach(recentGroups(recent), id: \.title) { group in
                    Text(group.title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(HealthTheme.secondaryInk)
                        .padding(.horizontal, 4)
                        .padding(.top, 2)
                    VStack(spacing: 0) {
                        ForEach(Array(group.workouts.enumerated()), id: \.element.id) { index, workout in
                            if index > 0 { rowDivider }
                            NavigationLink(value: AppRoute.workout(workout.id)) {
                                recentRow(workout)
                            }
                            .buttonStyle(.pressScale)
                            .contextMenu {
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
                            }
                        }
                    }
                    .panelSurface(cornerRadius: 22)
                }
            }
        }
    }

    private func recentGroups(_ workouts: [FitnessWorkout]) -> [(title: String, workouts: [FitnessWorkout])] {
        var groups: [(title: String, workouts: [FitnessWorkout])] = []
        for workout in workouts {
            let title = dayTitle(workout.startTime)
            if groups.last?.title == title {
                groups[groups.count - 1].workouts.append(workout)
            } else {
                groups.append((title, [workout]))
            }
        }
        return groups
    }

    private func dayTitle(_ value: String) -> String {
        guard let date = FitnessDate.parse(value) else { return value }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: .now)).day ?? 7
        return date.formatted(days < 7 ? .dateTime.weekday(.wide) : .dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    private func recentRow(_ workout: FitnessWorkout) -> some View {
        let presentation = WorkoutPresentationFactory.make(
            type: workout.workoutType,
            intensity: nil,
            strainLoadPoints: nil
        )
        let extra = week.workouts[workout.id]
        return HStack(spacing: 12) {
            rowIcon(presentation.symbolName, tint: presentation.activityAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(rowTitle(workout))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(HealthTheme.ink)
                    .lineLimit(1)
                Text(recentSummary(workout, distanceMeters: extra?.distanceMeters))
                    .font(.subheadline)
                    .foregroundStyle(HealthTheme.secondaryInk)
                    .lineLimit(1)
                if workout.awaitingWearable {
                    Text("Waiting for wearable data")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(HealthTheme.secondaryInk)
                }
            }
            Spacer(minLength: 8)
            if let strain = extra?.strain {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(strain.clean)
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(HealthTheme.ink)
                    Text("strain")
                        .font(.caption)
                        .foregroundStyle(HealthTheme.secondaryInk)
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func rowTitle(_ workout: FitnessWorkout) -> String {
        let suffix = " Workout"
        guard workout.title.hasSuffix(suffix), workout.title.count > suffix.count else { return workout.title }
        return String(workout.title.dropLast(suffix.count))
    }

    private func recentSummary(_ workout: FitnessWorkout, distanceMeters: Double?) -> String {
        var parts: [String] = []
        if let date = FitnessDate.parse(workout.startTime) {
            parts.append(date.formatted(date: .omitted, time: .shortened))
        }
        parts.append(duration(workout.durationSeconds))
        if workout.summary.completedSetCount > 0 {
            parts.append(workout.summary.completedSetCount == 1 ? "1 set" : "\(workout.summary.completedSetCount) sets")
        } else if let distanceMeters, distanceMeters > 0 {
            parts.append(units.distanceText(distanceMeters))
        }
        return parts.joined(separator: " · ")
    }

    private func syncBanner(_ message: String) -> some View {
        Label(message, systemImage: "icloud.and.arrow.up")
            .font(.caption)
            .foregroundStyle(HealthTheme.secondaryInk)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HealthTheme.track, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func completedSets(in draft: LocalWorkoutDraft) -> Int {
        draft.exercises.reduce(0) { $0 + $1.sets.filter(\.isCompleted).count }
    }

    private func resumeSummary(_ draft: LocalWorkoutDraft) -> String {
        if draft.isEditingExistingWorkout {
            return "From \(draft.startTime.formatted(date: .abbreviated, time: .shortened))"
        }
        return "\(draft.exercises.count) exercises · \(completedSets(in: draft)) sets logged"
    }

    private func elapsed(from start: Date, to end: Date) -> String {
        duration(max(0, Int(end.timeIntervalSince(start))))
    }

    private func duration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(max(1, minutes)) min"
    }

    private func weekdaySummary(_ weekdays: [Int]) -> String {
        let symbols = Calendar.current.shortWeekdaySymbols
        return weekdays.compactMap { day in
            let index = day == 7 ? 0 : day
            return symbols.indices.contains(index) ? symbols[index] : nil
        }.joined(separator: ", ")
    }
}

private struct PastWorkoutSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var startDate = Date().addingTimeInterval(-3600)
    @State private var durationMinutes = 60
    let onCreate: (Date, TimeInterval) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                VStack(alignment: .leading, spacing: 12) {
                    VStack(spacing: 0) {
                        DatePicker("Started", selection: $startDate, in: ...Date())
                            .frame(minHeight: 54)
                        Rectangle()
                            .fill(HealthTheme.hairline)
                            .frame(height: 1)
                        Stepper("Duration: \(durationMinutes) min", value: $durationMinutes, in: 5...360, step: 5)
                            .frame(minHeight: 54)
                    }
                    .padding(.horizontal, 16)
                    .panelSurface(cornerRadius: 22)

                    Text("You’ll log sets in the usual editor, with the time fixed to this window.")
                        .font(.footnote)
                        .foregroundStyle(HealthTheme.secondaryInk)
                        .padding(.horizontal, 4)

                    Spacer()

                    Button {
                        onCreate(startDate, TimeInterval(durationMinutes * 60))
                        dismiss()
                    } label: {
                        PrimaryActionLabel(title: "Continue")
                    }
                    .buttonStyle(.pressScale)
                }
                .padding(16)
                .tint(HealthTheme.ink)
            }
            .navigationTitle("Log past workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .tint(HealthTheme.ink)
                }
            }
        }
    }
}
