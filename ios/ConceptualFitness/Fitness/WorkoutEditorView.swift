import SwiftUI
import UIKit

struct WorkoutEditorView: View {
    @ObservedObject var store: FitnessStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showExercisePicker = false
    @State private var showReview = false
    @State private var showDiscardConfirmation = false
    @State private var restEnd: Date?

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                if let draft = store.draft {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            workoutStatus(draft)
                            ForEach(draft.exercises) { exercise in
                                ExerciseLogCard(
                                    exercise: exercise,
                                    previousSets: exercise.catalogID.flatMap { store.previousSets[$0] } ?? [],
                                    store: store,
                                    showsRestControls: !draft.isEditingExistingWorkout,
                                    onCompletedSet: {
                                        guard !draft.isEditingExistingWorkout else { return }
                                        startRest(seconds: exercise.restSeconds)
                                    }
                                )
                            }
                            addExerciseButton
                            finishButton(draft)
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 28)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .task(id: draft.exercises.compactMap(\.catalogID)) {
                        await store.loadPreviousSets()
                    }
                } else {
                    ContentUnavailableView("Workout finished", systemImage: "checkmark.circle.fill")
                }
            }
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
                ToolbarItem(placement: .principal) {
                    editorHeading
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(discardActionTitle, role: .destructive) {
                            showDiscardConfirmation = true
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("More")
                }
            }
            .tint(HealthTheme.ink)
            .safeAreaInset(edge: .bottom) {
                ZStack {
                    if store.draft?.isEditingExistingWorkout != true, let restEnd {
                        RestTimerBar(
                            end: restEnd,
                            onAdjust: adjustRest,
                            onSkip: { self.restEnd = nil }
                        )
                        .padding(.horizontal, 16)
                        .padding(.bottom, 4)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.smooth(duration: restEnd == nil ? 0.2 : 0.35), value: restEnd != nil)
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
            discardConfirmationTitle,
            isPresented: $showDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button(discardActionTitle, role: .destructive) {
                Task {
                    if await store.discardDraft() {
                        dismiss()
                    }
                }
            }
        } message: {
            Text(discardConfirmationMessage)
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    @ViewBuilder
    private var editorHeading: some View {
        if let draft = store.draft {
            VStack(spacing: 0) {
                Text(draft.title ?? "Strength Workout")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(HealthTheme.secondaryInk)
                    .lineLimit(1)
                if draft.isEditingExistingWorkout {
                    Text("Editing").font(.system(.headline, design: .rounded, weight: .bold))
                } else if draft.isRetrospective {
                    Text(draft.startTime.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(.headline, design: .rounded, weight: .bold))
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(elapsed(from: draft.startTime, to: context.date))
                            .font(.system(.title3, design: .rounded, weight: .bold))
                            .monospacedDigit()
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var discardActionTitle: String {
        store.draft?.isEditingExistingWorkout == true ? "Discard changes" : "Discard workout"
    }

    private var discardConfirmationTitle: String {
        store.draft?.isEditingExistingWorkout == true ? "Discard your changes?" : "Discard this workout?"
    }

    private var discardConfirmationMessage: String {
        if store.draft?.isEditingExistingWorkout == true {
            return "Your unsaved edits will be removed. The original workout will remain in your history."
        }
        return "This workout and its local draft will be removed."
    }

    private func workoutStatus(_ draft: LocalWorkoutDraft) -> some View {
        let total = draft.exercises.reduce(0) { $0 + $1.sets.count }
        let exercises = "\(draft.exercises.count) exercise\(draft.exercises.count == 1 ? "" : "s")"
        return HStack {
            Text("\(exercises) · \(completedSets(draft)) of \(total) sets")
            Spacer()
            if draft.isEditingExistingWorkout {
                Text("Changes stay local")
            } else if store.isSyncing {
                Text("Syncing")
            } else {
                Label("Saved", systemImage: "checkmark")
            }
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(HealthTheme.secondaryInk)
        .padding(.horizontal, 4)
        .padding(.top, 6)
    }

    private var addExerciseButton: some View {
        Button {
            showExercisePicker = true
        } label: {
            Text("Add exercise")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(HealthTheme.ink)
                .frame(maxWidth: .infinity, minHeight: 50)
                .panelSurface(cornerRadius: 16)
        }
        .buttonStyle(.pressScale)
    }

    private func finishButton(_ draft: LocalWorkoutDraft) -> some View {
        let isDisabled = draft.exercises.isEmpty || completedSets(draft) == 0
        return Button {
            showReview = true
        } label: {
            PrimaryActionLabel(title: draft.isRetrospective ? "Review and save" : "Finish workout")
        }
        .buttonStyle(.pressScale)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1)
    }

    private func completedSets(_ draft: LocalWorkoutDraft) -> Int {
        draft.exercises.reduce(0) { $0 + $1.sets.filter(\.isCompleted).count }
    }

    private func elapsed(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func startRest(seconds: Int) {
        guard seconds > 0 else { return }
        restEnd = Date().addingTimeInterval(TimeInterval(seconds))
    }

    private func adjustRest(_ seconds: Int) {
        guard let restEnd else { return }
        self.restEnd = restEnd.addingTimeInterval(TimeInterval(seconds))
    }
}

private enum SetRowLayout {
    static let badge: CGFloat = 36
    static let field: CGFloat = 66
    static let tick: CGFloat = 40
    static let spacing: CGFloat = 6
}

private struct ExerciseLogCard: View {
    @Environment(\.profileUnits) private var units
    let exercise: LocalWorkoutExercise
    let previousSets: [FitnessWorkoutSet]
    @ObservedObject var store: FitnessStore
    let showsRestControls: Bool
    let onCompletedSet: () -> Void
    @State private var showDetails = ProcessInfo.processInfo.arguments.contains("-OpenExerciseDetails")

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(exercise.name)
                        .font(.body.weight(.semibold))
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(HealthTheme.secondaryInk)
                }
                Spacer()
                Menu {
                    Button {
                        showDetails = true
                    } label: {
                        Label("Instructions", systemImage: "info.circle")
                    }
                    Button("Remove exercise", role: .destructive) {
                        store.removeExercise(exercise.id)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(HealthTheme.secondaryInk)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Exercise options")
            }
            .padding(.leading, 16)
            .padding(.trailing, 6)
            .padding(.top, 10)
            .padding(.bottom, 4)

            setHeader
                .padding(.horizontal, 12)
                .padding(.bottom, 4)

            ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { index, set in
                SetInputRow(
                    number: index + 1,
                    schema: exercise.measurementSchema,
                    perImplement: exercise.recordsPerImplement,
                    previous: previousText(index),
                    setType: setBinding(set.id, \.setType, default: "working"),
                    reps: setBinding(set.id, \.reps, default: ""),
                    load: setBinding(set.id, \.load, default: ""),
                    duration: setBinding(set.id, \.durationSeconds, default: ""),
                    distance: setBinding(set.id, \.distanceMeters, default: ""),
                    isCompleted: completedBinding(set.id),
                    canDelete: exercise.sets.count > 1,
                    onDelete: { store.removeSet(set.id, from: exercise.id) }
                )
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            }

            Rectangle()
                .fill(HealthTheme.hairline)
                .frame(height: 1)
                .padding(.top, 4)
            HStack {
                Button("Add set") {
                    store.addSet(to: exercise.id)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(HealthTheme.ink)
                .frame(minHeight: 44)
                Spacer()
                if showsRestControls {
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
                        Text("Rest \(restClock(exercise.restSeconds))")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(HealthTheme.secondaryInk)
                            .frame(minHeight: 44)
                    }
                    .accessibilityLabel("Rest time, \(restLabel(exercise.restSeconds))")
                }
            }
            .padding(.horizontal, 16)
        }
        .panelSurface(cornerRadius: 22)
        .sheet(isPresented: $showDetails) {
            ExerciseDetailsView(exercise: exercise)
        }
    }

    private var setHeader: some View {
        HStack(spacing: SetRowLayout.spacing) {
            Text("Set").frame(width: SetRowLayout.badge)
            Text("Prev").frame(maxWidth: .infinity)
            switch exercise.measurementSchema {
            case "duration":
                Text("Seconds").frame(width: SetRowLayout.field)
            case "duration_load":
                Text("Seconds").frame(width: SetRowLayout.field)
                Text(units.massSymbol).frame(width: SetRowLayout.field)
            case "carry", "cardio":
                Text(units.shortDistanceSymbol).frame(width: SetRowLayout.field)
                Text("Seconds").frame(width: SetRowLayout.field)
            default:
                Text(loadHeader).frame(width: SetRowLayout.field)
                Text(exercise.recordsPerSide ? "Reps/side" : "Reps").frame(width: SetRowLayout.field)
            }
            Color.clear.frame(width: SetRowLayout.tick, height: 1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(HealthTheme.secondaryInk)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 4)
    }

    private var subtitle: String {
        let parts = [exercise.primaryMuscles.first, exercise.equipment]
            .compactMap { $0?.replacingOccurrences(of: "_", with: " ").capitalized }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? schemaDescription : parts.joined(separator: " · ")
    }

    private var schemaDescription: String {
        let reps = exercise.recordsPerSide ? "Reps per side" : "Reps"
        switch exercise.measurementSchema {
        case "assisted_reps": return "\(reps) · assistance in \(units.massSymbol)"
        case "bodyweight_reps": return "\(reps) · optional added load"
        case "duration": return "Timed hold"
        case "duration_load": return "Time · load"
        case "carry": return "Distance · time"
        case "cardio": return "Distance · time"
        default:
            return exercise.recordsPerImplement ? "\(reps) · \(units.massSymbol) per dumbbell" : "\(reps) · total load"
        }
    }

    private var loadHeader: String {
        if exercise.measurementSchema == "assisted_reps" { return "Assist \(units.massSymbol)" }
        if exercise.recordsPerImplement { return "\(units.massSymbol) each" }
        return units.massSymbol
    }

    private func previousText(_ index: Int) -> String {
        guard previousSets.indices.contains(index) else { return "–" }
        let set = previousSets[index]
        let load = (set.loadPerImplement ?? set.loadValue ?? set.addedLoadKG ?? set.assistanceKG).map {
            units.mass($0).formatted(.number.precision(.fractionLength(0...1)))
        }
        switch exercise.measurementSchema {
        case "duration", "duration_load":
            guard let seconds = set.durationSeconds else { return "–" }
            return load.map { "\($0) × \(seconds)s" } ?? "\(seconds)s"
        case "carry", "cardio":
            guard let meters = set.distanceMeters else { return "–" }
            return units.distanceText(meters, compact: true)
        default:
            guard let reps = set.reps else { return "–" }
            return load.map { "\($0) × \(reps)" } ?? "\(reps)"
        }
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
                if completed { onCompletedSet() }
            }
        )
    }

    private func currentSet(_ setID: UUID) -> LocalWorkoutSet? {
        store.draft?.exercises.first(where: { $0.id == exercise.id })?.sets.first(where: { $0.id == setID })
    }

    private func restLabel(_ seconds: Int) -> String {
        seconds >= 60 && seconds % 60 == 0 ? "\(seconds / 60) min rest" : "\(seconds)s rest"
    }

    private func restClock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct SetInputRow: View {
    @Environment(\.profileUnits) private var units
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let number: Int
    let schema: String
    let perImplement: Bool
    let previous: String
    @Binding var setType: String
    @Binding var reps: String
    @Binding var load: String
    @Binding var duration: String
    @Binding var distance: String
    @Binding var isCompleted: Bool
    let canDelete: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: SetRowLayout.spacing) {
            Menu {
                Button("Working") { setType = "working" }
                Button("Warm-up") { setType = "warmup" }
                Button("Drop") { setType = "drop" }
            } label: {
                Text(setBadge)
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(setType == "working" ? HealthTheme.ink : HealthTheme.secondaryInk)
                    .frame(width: SetRowLayout.badge, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Set \(number), \(setType)")

            Text(previous)
                .font(.system(.subheadline, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(HealthTheme.secondaryInk)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(previous == "–" ? "No previous set" : "Previous \(previous)")

            switch schema {
            case "duration", "duration_load":
                SetNumberField(title: "Seconds", text: $duration, isCompleted: isCompleted)
                if schema == "duration_load" {
                    WorkoutMeasurementField(title: units.massSymbol, canonical: $load, units: units, isDistance: false, setNumber: number, isCompleted: isCompleted)
                }
            case "carry", "cardio":
                WorkoutMeasurementField(title: units.shortDistanceSymbol, canonical: $distance, units: units, isDistance: true, setNumber: number, isCompleted: isCompleted)
                SetNumberField(title: "Seconds", text: $duration, isCompleted: isCompleted)
            default:
                WorkoutMeasurementField(title: perImplement ? "\(units.massSymbol) each" : units.massSymbol, canonical: $load, units: units, isDistance: false, setNumber: number, isCompleted: isCompleted)
                SetNumberField(title: "Reps", text: $reps, isCompleted: isCompleted)
            }

            Button {
                withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .smooth(duration: 0.2)) {
                    isCompleted.toggle()
                }
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(HealthTheme.secondaryInk, lineWidth: 2)
                    if isCompleted {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(HealthTheme.inverseInk)
                            .frame(width: 30, height: 30)
                            .background(HealthTheme.ink, in: Circle())
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
                    }
                }
                .frame(width: 30, height: 30)
                .frame(width: SetRowLayout.tick, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.impact(weight: .light), trigger: isCompleted) { _, completed in completed }
            .accessibilityLabel(isCompleted ? "Mark set incomplete" : "Complete set")
        }
        .padding(.horizontal, 4)
        .frame(minHeight: 46)
        .background {
            if isCompleted {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(HealthTheme.track)
                    .transition(.opacity)
            }
        }
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
}

private struct SetFieldChrome: ViewModifier {
    let isCompleted: Bool
    let isFocused: Bool

    func body(content: Content) -> some View {
        content
            .multilineTextAlignment(.center)
            .font(.system(.body, design: .rounded, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(HealthTheme.ink)
            .frame(width: SetRowLayout.field, height: 38)
            .background {
                if !isCompleted {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(HealthTheme.card)
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(HealthTheme.ink.opacity(isFocused ? 1 : 0.2), lineWidth: isFocused ? 2 : 1.5)
                }
            }
    }
}

private struct SetNumberField: View {
    let title: String
    @Binding var text: String
    let isCompleted: Bool
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $text)
            .keyboardType(.numberPad)
            .focused($isFocused)
            .modifier(SetFieldChrome(isCompleted: isCompleted, isFocused: isFocused))
            .accessibilityLabel(title)
    }
}

private struct WorkoutMeasurementField: View {
    let title: String
    @Binding var canonical: String
    let units: ProfileUnits
    let isDistance: Bool
    let setNumber: Int
    let isCompleted: Bool
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $text)
            .keyboardType(.decimalPad)
            .focused($isFocused)
            .modifier(SetFieldChrome(isCompleted: isCompleted, isFocused: isFocused))
            .accessibilityLabel("Set \(setNumber) \(isDistance ? "distance" : "load"), \(title)")
            .onAppear(perform: displayCanonical)
            .onChange(of: units) { _, _ in displayCanonical() }
            .onChange(of: canonical) { _, _ in if !isFocused { displayCanonical() } }
            .onChange(of: text) { _, value in
                guard isFocused else { return }
                if let number = ProfileInput.decimal(value) {
                    canonical = String(isDistance ? units.meters(number) : units.kilograms(number))
                } else {
                    canonical = value
                }
            }
    }

    private func displayCanonical() {
        guard let value = Double(canonical) else { text = canonical; return }
        text = ProfileInput.number(isDistance ? units.shortDistance(value) : units.mass(value))
    }
}

private struct RestTimerBar: View {
    let end: Date
    let onAdjust: (Int) -> Void
    let onSkip: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, Int(end.timeIntervalSince(context.date).rounded(.up)))
            VStack(spacing: 0) {
                Text("Rest")
                    .font(.caption.weight(.semibold))
                    .opacity(0.72)
                HStack(spacing: 0) {
                    Color.clear.frame(width: 60, height: 1)
                    HStack(spacing: 12) {
                        adjustButton("−15", seconds: -15)
                        Text(timerText(remaining))
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .frame(minWidth: 74)
                        adjustButton("+15", seconds: 15)
                    }
                    .frame(maxWidth: .infinity)
                    Button("Skip", action: onSkip)
                        .font(.subheadline.weight(.semibold))
                        .opacity(0.72)
                        .frame(width: 60, height: 44)
                }
            }
            .foregroundStyle(HealthTheme.inverseInk)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .padding(.horizontal, 8)
            .background(HealthTheme.ink, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 14, y: 8)
            .onChange(of: remaining) { _, value in
                if value == 0 {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    onSkip()
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Rest timer, \(remaining) seconds left")
        }
    }

    private func adjustButton(_ title: String, seconds: Int) -> some View {
        Button {
            onAdjust(seconds)
        } label: {
            Text(title)
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .frame(width: 52, height: 44)
                .background(HealthTheme.inverseInk.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.pressScale)
        .accessibilityLabel(seconds < 0 ? "15 seconds less" : "15 seconds more")
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
                                    .background(HealthTheme.track, in: RoundedRectangle(cornerRadius: 20))
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
        .panelSurface(cornerRadius: 20)
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
            ZStack {
                AppBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        summaryCard
                        sectionTitle("Optional")
                        VStack(spacing: 0) {
                            effortRow
                            divider
                            TextField("Workout notes", text: notesBinding, axis: .vertical)
                                .lineLimit(2...7)
                                .padding(.vertical, 14)
                        }
                        .padding(.horizontal, 16)
                        .panelSurface(cornerRadius: 22)

                        sectionTitle("Routine")
                        VStack(spacing: 0) {
                            if let routine = store.sourceRoutine {
                                Toggle("Update \(routine.name)", isOn: $updateSavedRoutine)
                                    .frame(minHeight: 54)
                                divider
                            }
                            Toggle("Save as a new routine", isOn: $saveAsRoutine.animation(.smooth(duration: 0.25)))
                                .frame(minHeight: 54)
                            if saveAsRoutine {
                                divider
                                TextField("Routine name", text: $routineName)
                                    .frame(minHeight: 54)
                                divider
                                weekdayPicker
                                    .padding(.vertical, 12)
                            }
                        }
                        .tint(HealthTheme.color(for: .positive))
                        .padding(.horizontal, 16)
                        .panelSurface(cornerRadius: 22)
                        Text("Routines keep this exercise order and your latest sets.")
                            .font(.footnote)
                            .foregroundStyle(HealthTheme.secondaryInk)
                            .padding(.horizontal, 4)

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(HealthTheme.color(for: .risk))
                                .padding(.horizontal, 4)
                                .padding(.top, 4)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Review workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") { dismiss() }
                }
            }
            .tint(HealthTheme.ink)
            .safeAreaInset(edge: .bottom) {
                Button {
                    Task { await finish() }
                } label: {
                    PrimaryActionLabel(title: store.isSyncing ? "Saving" : "Save workout")
                }
                .buttonStyle(.pressScale)
                .disabled(cannotSave)
                .opacity(cannotSave ? 0.4 : 1)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)
                .background(HealthTheme.page)
            }
        }
        .interactiveDismissDisabled(store.isSyncing)
    }

    private var cannotSave: Bool {
        store.isSyncing || (saveAsRoutine && routineName.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private var divider: some View {
        Rectangle().fill(HealthTheme.hairline).frame(height: 1)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(HealthTheme.secondaryInk)
            .padding(.horizontal, 4)
            .padding(.top, 8)
            .accessibilityAddTraits(.isHeader)
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.draft?.title ?? "Strength Workout")
                    .font(.system(.title2, design: .rounded, weight: .bold))
                if let start = store.draft?.startTime {
                    Text(start.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute()))
                        .font(.subheadline)
                        .foregroundStyle(HealthTheme.secondaryInk)
                }
            }
            HStack(spacing: 8) {
                summaryStat(duration, label: "Duration")
                summaryStat("\(completedSets)", label: "Sets")
                summaryStat("\(store.draft?.exercises.count ?? 0)", label: "Exercises")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface(cornerRadius: 24)
    }

    private func summaryStat(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(HealthTheme.secondaryInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var effort: Int? {
        Double(store.draft?.sessionRPE ?? "").map { Int($0.rounded()) }
    }

    private var effortRow: some View {
        HStack(spacing: 10) {
            Text("Effort")
            Spacer()
            effortStep("minus", label: "Lower effort") {
                guard let effort else { return }
                rpeBinding.wrappedValue = effort > 0 ? "\(effort - 1)" : ""
            }
            Group {
                if let effort {
                    Text("\(effort) ").fontWeight(.bold) + Text("of 10").foregroundStyle(HealthTheme.secondaryInk)
                } else {
                    Text("Not set").foregroundStyle(HealthTheme.secondaryInk)
                }
            }
            .font(.system(.body, design: .rounded))
            .monospacedDigit()
            .frame(minWidth: 66)
            effortStep("plus", label: "Raise effort") {
                rpeBinding.wrappedValue = "\(min((effort ?? 4) + 1, 10))"
            }
        }
        .frame(minHeight: 54)
        .accessibilityElement(children: .contain)
    }

    private func effortStep(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(HealthTheme.ink)
                .frame(width: 44, height: 38)
                .background(HealthTheme.track, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.pressScale)
        .accessibilityLabel(label)
    }

    private var weekdayPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Scheduled days")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(HealthTheme.secondaryInk)
            HStack {
                ForEach(1...7, id: \.self) { day in
                    let selected = weekdays.contains(day)
                    Button {
                        if selected { weekdays.remove(day) } else { weekdays.insert(day) }
                    } label: {
                        Text(dayLetter(day))
                            .font(.subheadline.weight(selected ? .bold : .semibold))
                            .foregroundStyle(selected ? HealthTheme.inverseInk : HealthTheme.ink)
                            .frame(width: 40, height: 40)
                            .background {
                                if selected {
                                    Circle().fill(HealthTheme.ink)
                                } else {
                                    Circle().strokeBorder(HealthTheme.ink.opacity(0.24), lineWidth: 1.5)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(dayName(day))
                    .accessibilityAddTraits(selected ? .isSelected : [])
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
