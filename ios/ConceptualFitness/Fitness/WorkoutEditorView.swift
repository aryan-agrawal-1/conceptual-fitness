import SwiftUI
import UIKit

struct WorkoutEditorView: View {
    @ObservedObject var store: FitnessStore
    @Environment(\.dismiss) private var dismiss
    @State private var showExercisePicker = false
    @State private var showReview = false
    @State private var showDiscardConfirmation = false
    @State private var restEnd: Date?
    @State private var restTotal = 90

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                if let draft = store.draft {
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            workoutHeader(draft)
                            ForEach(draft.exercises) { exercise in
                                ExerciseLogCard(
                                    exercise: exercise,
                                    store: store,
                                    onCompletedSet: { startRest(seconds: exercise.restSeconds) }
                                )
                            }
                            addExerciseButton
                            finishButton(draft)
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, restEnd == nil ? 28 : 96)
                    }
                    .scrollDismissesKeyboard(.interactively)
                } else {
                    ContentUnavailableView("Workout finished", systemImage: "checkmark.circle.fill")
                }
            }
            .navigationTitle(store.draft?.isRetrospective == true ? "Edit workout" : "Live workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .accessibilityLabel("Close workout")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Discard workout", role: .destructive) {
                            showDiscardConfirmation = true
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let restEnd {
                    RestTimerBar(
                        end: restEnd,
                        total: restTotal,
                        onAdjust: adjustRest,
                        onSkip: { self.restEnd = nil }
                    )
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
                }
            }
        }
        .interactiveDismissDisabled()
        .sheet(isPresented: $showExercisePicker) {
            ExercisePickerView(client: store.client) { exercise in
                store.addExercise(exercise)
            }
        }
        .sheet(isPresented: $showReview) {
            FinishWorkoutSheet(store: store) {
                dismiss()
            }
        }
        .confirmationDialog(
            "Discard this workout?",
            isPresented: $showDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard workout", role: .destructive) {
                Task {
                    if await store.discardDraft() {
                        dismiss()
                    }
                }
            }
        } message: {
            Text("The local draft will be removed. A copy already synced to the backend may remain in your history.")
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private func workoutHeader(_ draft: LocalWorkoutDraft) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(draft.title ?? "Strength Workout")
                        .font(.title2.weight(.bold))
                    Text(draft.startTime.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if draft.isRetrospective {
                    Label("Past", systemImage: "clock.arrow.circlepath")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(HealthTheme.color(for: .activity))
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(elapsed(from: draft.startTime, to: context.date))
                            .font(.system(.title3, design: .rounded, weight: .semibold))
                            .monospacedDigit()
                    }
                }
            }
            HStack(spacing: 18) {
                Label("\(draft.exercises.count) exercises", systemImage: "dumbbell")
                Label("\(completedSets(draft)) sets", systemImage: "checkmark.circle")
                if store.isSyncing {
                    Label("Syncing", systemImage: "arrow.triangle.2.circlepath")
                } else {
                    Label("Saved", systemImage: "checkmark.icloud")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(17)
        .glassSurface(cornerRadius: 22)
    }

    private var addExerciseButton: some View {
        Button {
            showExercisePicker = true
        } label: {
            Label("Add exercise", systemImage: "plus.circle.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.bordered)
        .tint(HealthTheme.color(for: .activity))
    }

    private func finishButton(_ draft: LocalWorkoutDraft) -> some View {
        Button {
            showReview = true
        } label: {
            Text(draft.isRetrospective ? "Review & save" : "Finish workout")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
        }
        .buttonStyle(.borderedProminent)
        .tint(HealthTheme.color(for: .positive))
        .disabled(draft.exercises.isEmpty || completedSets(draft) == 0)
        .padding(.top, 4)
    }

    private func completedSets(_ draft: LocalWorkoutDraft) -> Int {
        draft.exercises.reduce(0) { $0 + $1.sets.filter(\.isCompleted).count }
    }

    private func elapsed(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }

    private func startRest(seconds: Int) {
        guard seconds > 0 else { return }
        restTotal = seconds
        restEnd = Date().addingTimeInterval(TimeInterval(seconds))
    }

    private func adjustRest(_ seconds: Int) {
        guard let restEnd else { return }
        self.restEnd = restEnd.addingTimeInterval(TimeInterval(seconds))
        restTotal = max(1, restTotal + seconds)
    }
}

private struct ExerciseLogCard: View {
    let exercise: LocalWorkoutExercise
    @ObservedObject var store: FitnessStore
    let onCompletedSet: () -> Void
    @State private var showDetails = ProcessInfo.processInfo.arguments.contains("-OpenExerciseDetails")

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(exercise.name)
                        .font(.headline)
                    Text(schemaDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showDetails = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.title3)
                }
                .accessibilityLabel("Exercise instructions")
                Menu {
                    Button("Remove exercise", role: .destructive) {
                        store.removeExercise(exercise.id)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                }
                .accessibilityLabel("Exercise options")
            }

            setHeader
            ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { index, set in
                SetInputRow(
                    number: index + 1,
                    schema: exercise.measurementSchema,
                    perImplement: exercise.recordsPerImplement,
                    setType: setBinding(set.id, \.setType, default: "working"),
                    reps: setBinding(set.id, \.reps, default: ""),
                    load: setBinding(set.id, \.load, default: ""),
                    duration: setBinding(set.id, \.durationSeconds, default: ""),
                    distance: setBinding(set.id, \.distanceMeters, default: ""),
                    isCompleted: completedBinding(set.id),
                    canDelete: exercise.sets.count > 1,
                    onDelete: { store.removeSet(set.id, from: exercise.id) }
                )
            }

            HStack {
                Button {
                    store.addSet(to: exercise.id)
                } label: {
                    Label("Add set", systemImage: "plus")
                }
                Spacer()
                Menu {
                    ForEach([45, 60, 75, 90, 120, 150, 180, 240], id: \.self) { seconds in
                        Button(restLabel(seconds)) {
                            store.updateDraft { draft in
                                guard let index = draft.exercises.firstIndex(where: { $0.id == exercise.id }) else { return }
                                draft.exercises[index].restSeconds = seconds
                            }
                        }
                    }
                } label: {
                    Label(restLabel(exercise.restSeconds), systemImage: "timer")
                        .font(.caption.weight(.medium))
                }
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(16)
        .glassSurface(cornerRadius: 22)
        .sheet(isPresented: $showDetails) {
            ExerciseDetailsView(exercise: exercise)
        }
    }

    @ViewBuilder
    private var setHeader: some View {
        HStack(spacing: 8) {
            Text("SET").frame(width: 36)
            switch exercise.measurementSchema {
            case "duration", "duration_load":
                Text("SECONDS").frame(maxWidth: .infinity)
                if exercise.measurementSchema == "duration_load" {
                    Text("KG").frame(maxWidth: .infinity)
                }
            case "carry", "cardio":
                Text("METRES").frame(maxWidth: .infinity)
                Text("SECONDS").frame(maxWidth: .infinity)
            default:
                Text("REPS").frame(maxWidth: .infinity)
                Text(loadHeader).frame(maxWidth: .infinity)
            }
            Color.clear.frame(width: 36)
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(.secondary)
    }

    private var schemaDescription: String {
        switch exercise.measurementSchema {
        case "assisted_reps": return "Reps · assistance in kg"
        case "bodyweight_reps": return "Reps · optional added load"
        case "duration": return "Timed hold"
        case "duration_load": return "Time · load"
        case "carry": return "Distance · time"
        case "cardio": return "Distance · time"
        default:
            return exercise.recordsPerImplement ? "Reps · kg per dumbbell" : "Reps · total load"
        }
    }

    private var loadHeader: String {
        if exercise.measurementSchema == "assisted_reps" { return "ASSIST KG" }
        if exercise.recordsPerImplement { return "KG EACH" }
        return "KG"
    }

    private func setBinding<Value>(
        _ setID: UUID,
        _ keyPath: WritableKeyPath<LocalWorkoutSet, Value>,
        default fallback: Value
    ) -> Binding<Value> {
        Binding(
            get: {
                currentSet(setID)?[keyPath: keyPath] ?? fallback
            },
            set: { value in
                store.updateDraft { draft in
                    guard let exerciseIndex = draft.exercises.firstIndex(where: { $0.id == exercise.id }),
                          let setIndex = draft.exercises[exerciseIndex].sets.firstIndex(where: { $0.id == setID }) else { return }
                    draft.exercises[exerciseIndex].sets[setIndex][keyPath: keyPath] = value
                }
            }
        )
    }

    private func completedBinding(_ setID: UUID) -> Binding<Bool> {
        Binding(
            get: { currentSet(setID)?.isCompleted ?? false },
            set: { completed in
                store.updateDraft { draft in
                    guard let exerciseIndex = draft.exercises.firstIndex(where: { $0.id == exercise.id }),
                          let setIndex = draft.exercises[exerciseIndex].sets.firstIndex(where: { $0.id == setID }) else { return }
                    draft.exercises[exerciseIndex].sets[setIndex].isCompleted = completed
                    draft.exercises[exerciseIndex].sets[setIndex].completedAt = completed ? Date() : nil
                }
                if completed {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    onCompletedSet()
                }
            }
        )
    }

    private func currentSet(_ setID: UUID) -> LocalWorkoutSet? {
        store.draft?.exercises.first(where: { $0.id == exercise.id })?.sets.first(where: { $0.id == setID })
    }

    private func restLabel(_ seconds: Int) -> String {
        seconds >= 60 && seconds % 60 == 0 ? "\(seconds / 60) min rest" : "\(seconds)s rest"
    }
}

private struct SetInputRow: View {
    let number: Int
    let schema: String
    let perImplement: Bool
    @Binding var setType: String
    @Binding var reps: String
    @Binding var load: String
    @Binding var duration: String
    @Binding var distance: String
    @Binding var isCompleted: Bool
    let canDelete: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Working") { setType = "working" }
                Button("Warm-up") { setType = "warmup" }
                Button("Drop") { setType = "drop" }
            } label: {
                Text(setBadge)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(setType == "working" ? .primary : HealthTheme.color(for: .activity))
                    .frame(width: 34, height: 34)
                    .background(.secondary.opacity(0.10), in: Circle())
            }
            .accessibilityLabel("Set \(number), \(setType)")

            switch schema {
            case "duration", "duration_load":
                numericField("Sec", text: $duration)
                if schema == "duration_load" { numericField("kg", text: $load) }
            case "carry", "cardio":
                numericField("m", text: $distance)
                numericField("sec", text: $duration)
            default:
                numericField("Reps", text: $reps)
                numericField(perImplement ? "Each" : "kg", text: $load, decimal: true)
            }

            Button {
                isCompleted.toggle()
            } label: {
                Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isCompleted ? HealthTheme.color(for: .positive) : .secondary)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel(isCompleted ? "Mark set incomplete" : "Complete set")
        }
        .padding(.vertical, 2)
        .contextMenu {
            if canDelete {
                Button("Delete set", role: .destructive, action: onDelete)
            }
        }
    }

    private var setBadge: String {
        switch setType {
        case "warmup": return "W"
        case "drop": return "D"
        default: return "\(number)"
        }
    }

    private func numericField(
        _ prompt: String,
        text: Binding<String>,
        width: CGFloat? = nil,
        decimal: Bool = false
    ) -> some View {
        TextField(prompt, text: text)
            .keyboardType(decimal ? .decimalPad : .numberPad)
            .multilineTextAlignment(.center)
            .font(.body.monospacedDigit())
            .padding(.horizontal, 5)
            .frame(maxWidth: width == nil ? .infinity : width, minHeight: 36)
            .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
            .accessibilityLabel(prompt)
    }
}

private struct RestTimerBar: View {
    let end: Date
    let total: Int
    let onAdjust: (Int) -> Void
    let onSkip: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, Int(end.timeIntervalSince(context.date).rounded(.up)))
            HStack(spacing: 12) {
                Button("−15") { onAdjust(-15) }
                    .buttonStyle(.bordered)
                VStack(spacing: 2) {
                    Text("REST")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(timerText(remaining))
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity)
                Button("+15") { onAdjust(15) }
                    .buttonStyle(.bordered)
                Button("Skip", action: onSkip)
                    .font(.caption.weight(.semibold))
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            .overlay(alignment: .bottomLeading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(HealthTheme.color(for: .activity))
                        .frame(width: proxy.size.width * min(1, CGFloat(remaining) / CGFloat(max(1, total))), height: 3)
                }
                .frame(height: 3)
            }
            .onChange(of: remaining) { _, value in
                if value == 0 {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    onSkip()
                }
            }
        }
    }

    private func timerText(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct ExerciseDetailsView: View {
    @Environment(\.dismiss) private var dismiss
    let exercise: LocalWorkoutExercise

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if !exercise.media.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(exercise.media, id: \.url) { media in
                                    AsyncImage(url: URL(string: media.url)) { phase in
                                        if let image = phase.image {
                                            image.resizable().scaledToFit()
                                        } else if phase.error != nil {
                                            Image(systemName: "photo")
                                                .font(.largeTitle)
                                                .foregroundStyle(.secondary)
                                        } else {
                                            ProgressView()
                                        }
                                    }
                                    .frame(width: 230, height: 230)
                                    .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 20))
                                    .accessibilityLabel(media.role.replacingOccurrences(of: "_", with: " "))
                                }
                            }
                        }
                    }
                    MuscleMapView(primary: exercise.primaryMuscles, secondary: exercise.secondaryMuscles)
                    if !exercise.instructions.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("How to perform it")
                                .font(.title3.weight(.bold))
                            ForEach(Array(exercise.instructions.enumerated()), id: \.offset) { index, instruction in
                                HStack(alignment: .top, spacing: 12) {
                                    Text("\(index + 1)")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.white)
                                        .frame(width: 25, height: 25)
                                        .background(HealthTheme.color(for: .activity), in: Circle())
                                    Text(instruction)
                                        .font(.body)
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(AppBackground())
            .navigationTitle(exercise.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct MuscleMapView: View {
    let primary: [String]
    let secondary: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Muscles trained")
                .font(.title3.weight(.bold))
            AnatomeMuscleMapView(primary: primary, secondary: secondary)
                .frame(height: 250)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilitySummary)
            HStack(spacing: 14) {
                legend(color: HealthTheme.color(for: .strain), label: "Primary")
                legend(color: HealthTheme.color(for: .activity).opacity(0.65), label: "Secondary")
            }
            Text("Muscle naming follows Anatome’s canonical map; path data is kept in-app for private, offline rendering.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .glassSurface(cornerRadius: 20)
    }

    private var accessibilitySummary: String {
        let primarySummary = primary.map(\.displayTitle).joined(separator: ", ")
        let secondarySummary = secondary.map(\.displayTitle).joined(separator: ", ")
        return "Primary muscles: \(primarySummary). Secondary muscles: \(secondarySummary)."
    }

    private func legend(color: Color, label: String) -> some View {
        Label {
            Text(label).font(.caption)
        } icon: {
            Circle().fill(color).frame(width: 9, height: 9)
        }
    }
}

private struct FinishWorkoutSheet: View {
    @ObservedObject var store: FitnessStore
    @Environment(\.dismiss) private var dismiss
    @State private var saveAsRoutine = false
    @State private var updateSavedRoutine = true
    @State private var routineName = ""
    @State private var weekdays: Set<Int> = []
    @State private var errorMessage: String?
    let onFinished: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Summary") {
                    LabeledContent("Exercises", value: "\(store.draft?.exercises.count ?? 0)")
                    LabeledContent("Completed sets", value: "\(completedSets)")
                    LabeledContent("Duration", value: duration)
                }
                Section("Optional effort") {
                    TextField("Session RPE (0–10)", text: rpeBinding)
                        .keyboardType(.decimalPad)
                    TextField("Workout notes", text: notesBinding, axis: .vertical)
                        .lineLimit(3...7)
                }
                Section {
                    if let routine = store.sourceRoutine {
                        Toggle("Update \(routine.name)", isOn: $updateSavedRoutine)
                    }
                    Toggle("Save as a routine", isOn: $saveAsRoutine)
                    if saveAsRoutine {
                        TextField("Routine name", text: $routineName)
                        weekdayPicker
                    }
                } footer: {
                    Text("Saved routines keep this exercise order and your latest set targets.")
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "icloud.slash")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Review workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await finish() }
                    }
                    .fontWeight(.semibold)
                    .disabled(store.isSyncing || (saveAsRoutine && routineName.trimmingCharacters(in: .whitespaces).isEmpty))
                }
            }
        }
        .interactiveDismissDisabled(store.isSyncing)
    }

    private var weekdayPicker: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Scheduled days")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                ForEach(1...7, id: \.self) { day in
                    Button {
                        if weekdays.contains(day) { weekdays.remove(day) } else { weekdays.insert(day) }
                    } label: {
                        Text(dayLetter(day))
                            .font(.caption.weight(.bold))
                            .frame(width: 30, height: 30)
                            .foregroundStyle(weekdays.contains(day) ? .white : .primary)
                            .background(
                                weekdays.contains(day) ? HealthTheme.color(for: .activity) : Color.secondary.opacity(0.10),
                                in: Circle()
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(dayName(day))
                    .accessibilityAddTraits(weekdays.contains(day) ? .isSelected : [])
                }
            }
        }
    }

    private var rpeBinding: Binding<String> {
        Binding(
            get: { store.draft?.sessionRPE ?? "" },
            set: { value in store.updateDraft { $0.sessionRPE = value } }
        )
    }

    private var notesBinding: Binding<String> {
        Binding(
            get: { store.draft?.notes ?? "" },
            set: { value in store.updateDraft { $0.notes = value } }
        )
    }

    private var completedSets: Int {
        store.draft?.exercises.reduce(0) { $0 + $1.sets.filter(\.isCompleted).count } ?? 0
    }

    private var duration: String {
        guard let draft = store.draft else { return "—" }
        let end = draft.endTime ?? Date()
        let minutes = max(1, Int(end.timeIntervalSince(draft.startTime)) / 60)
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    private func finish() async {
        let rpe = store.draft?.sessionRPE.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !rpe.isEmpty, Double(rpe) == nil {
            errorMessage = "Session RPE must be a number between 0 and 10."
            return
        }
        if let value = Double(rpe), !(0...10).contains(value) {
            errorMessage = "Session RPE must be between 0 and 10."
            return
        }
        do {
            try await store.finish(
                saveRoutineName: saveAsRoutine ? routineName : nil,
                weekdays: weekdays.sorted(),
                updateSourceRoutine: store.sourceRoutine != nil && updateSavedRoutine
            )
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
            onFinished()
        } catch {
            errorMessage = "Saved offline. Keep this screen open and try again when the backend is available."
        }
    }

    private func dayLetter(_ day: Int) -> String {
        String(dayName(day).prefix(1))
    }

    private func dayName(_ day: Int) -> String {
        let iso = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
        return iso[max(0, min(6, day - 1))]
    }
}
