import SwiftUI

struct JournalEditorSelection: Identifiable {
    let behaviour: JournalBehaviourData
    let day: String
    var id: String { "\(day)/\(behaviour.id)" }
}

struct JournalView: View {
    @ObservedObject var store: JournalStore
    @ObservedObject var reminders: JournalReminders
    var onboardedAt: Date?
    @State private var selectedDay: String?
    @State private var selection: JournalEditorSelection?
    @State private var checkIn: JournalCheckInSelection?
    @State private var choosingDate = false
    @State private var othersExpanded: Bool?
    @Environment(\.dynamicTypeSize) private var typeSize
    private var day: String { selectedDay ?? store.today }
    private var dayIndex: JournalDayIndex { JournalDayIndex(store.snapshot, today: store.today) }
    private var isReady: Bool { store.snapshot.catalogue != nil && store.timezone != nil }

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if isReady {
                        checkInCard
                        weekStrip
                        dayHeader
                        dayNote
                        syncStatus
                        rows
                    } else {
                        loadingState
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle("Insights")
        .toolbar {
            if isReady {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { choosingDate = true } label: { Image(systemName: "calendar") }
                        .accessibilityLabel("History")
                    NavigationLink { JournalPrivacyView(store: store) } label: {
                        Image(systemName: "lock")
                    }
                    .accessibilityLabel("Private categories")
                }
            }
        }
        .sheet(item: $selection) { JournalEntryEditor(store: store, selection: $0) }
        .sheet(isPresented: $choosingDate) {
            JournalCalendarView(store: store, selectedDay: day) { chosen in
                selectedDay = chosen
                othersExpanded = nil
            }
        }
        .sheet(item: $checkIn) { JournalCheckInView(store: store, reminders: reminders, day: $0.day) }
        .refreshable { await store.synchronize() }
        .task { await store.synchronize() }
    }

    // Stays until yesterday is completed, for anyone who chose "Not now".
    @ViewBuilder private var checkInCard: some View {
        if JournalCheckIn.isDue(store.snapshot, onboardedAt: onboardedAt) {
            let yesterday = JournalDay.previous(store.today)
            Button { checkIn = JournalCheckInSelection(day: yesterday) } label: {
                let layout = typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                    : AnyLayout(HStackLayout())
                layout {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Check in for yesterday").font(.subheadline.weight(.semibold))
                        Text("\(JournalDay.longTitle(yesterday)) · \(dayIndex.answerCount(yesterday)) of \(JournalDailyList.dailyTarget)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 8) {
                        Text("Start").font(.subheadline.weight(.semibold))
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).accessibilityHidden(true)
                    }
                    .foregroundStyle(HealthTheme.color(for: .activity))
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .panelSurface(cornerRadius: 18)
            .accessibilityIdentifier("journal.checkin.card")
        }
    }

    private var weekStrip: some View {
        let index = dayIndex
        return HStack(spacing: 2) {
            ForEach(JournalDay.week(endingOn: store.today)) { item in
                let selected = item.id == day
                Button { selectedDay = item.id; othersExpanded = nil } label: {
                    VStack(spacing: 2) {
                        Text(item.letter).font(.caption2.weight(.medium))
                        Text(item.number).font(.system(.subheadline, design: .rounded, weight: .bold))
                        weekMark(index.status(item.id), selected: selected)
                    }
                    .foregroundStyle(selected ? .white : .primary.opacity(0.75))
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(HealthTheme.color(for: .activity))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(JournalDay.title(item.id, today: store.today))
                .accessibilityValue(index.accessibilityValue(item.id))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        // Seven columns can't reflow, so larger sizes would break the dates across lines.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    @ViewBuilder private func weekMark(_ status: JournalDayStatus, selected: Bool) -> some View {
        Group {
            switch status {
            case .completed: Circle().fill(selected ? .white : HealthTheme.color(for: .activity))
            case .incomplete: Circle().strokeBorder(selected ? .white : .orange, lineWidth: 1.5)
            case .missing, .notStarted, .upcoming: Color.clear
            }
        }
        .frame(width: 6, height: 6)
        .accessibilityHidden(true)
    }

    private var dayHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(JournalDay.title(day, today: store.today)).font(.title3.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            let logged = dayIndex.answerCount(day)
            if dayIndex.isCompleted(day) {
                Label(store.completion(day: day).map(JournalCheckIn.isLate) == true ? "Completed late" : "Completed",
                      systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(HealthTheme.color(for: .readiness))
            } else if JournalDailyList.reachedTarget(logged) {
                // Sits in the header's existing space, so reaching five doesn't move any rows.
                Button("Complete check-in", action: completeSelectedDay)
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .tint(HealthTheme.color(for: .activity))
                    .disabled(store.storageBlocked)
                    .accessibilityIdentifier("journal.header.complete")
            } else {
                Text("\(logged)/\(JournalDailyList.dailyTarget)")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(logged) of \(JournalDailyList.dailyTarget) logged")
            }
        }
    }

    @ViewBuilder private var dayNote: some View {
        if let note = JournalStreak.dayNote(day: day, today: store.today, completion: store.completion(day: day),
                                            isCompleted: dayIndex.isCompleted(day)) {
            Text(note).font(.footnote).foregroundStyle(.secondary)
        }
    }

    // Today and yesterday go on to the optional step. Older days are usually backfilled in a run.
    private func completeSelectedDay() {
        guard store.complete(day: day) else { return }
        if day >= JournalDay.previous(store.today) { checkIn = JournalCheckInSelection(day: day) }
    }

    // Normal saves stay silent so rows don't move. This only appears when a sync needs attention.
    @ViewBuilder private var syncStatus: some View {
        if let message = store.message {
            VStack(alignment: .leading, spacing: 4) {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("journal.status")
                Button("Retry") { Task { await store.synchronize() } }
                    .font(.caption.weight(.semibold))
                    .frame(minHeight: 44)
                    .disabled(store.isSyncing)
            }
            .padding(.horizontal, 12).padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    @ViewBuilder private var rows: some View {
        let sections = JournalDailyList.sections(store.snapshot, day: day)
        panel(sections.pinned)
        ForEach(sections.privatePinned) { section in
            sectionTitle(section.title)
            panel(section.behaviours)
        }
        if !sections.others.isEmpty {
            let hasAnswers = sections.others.contains { store.entry($0.id, day: day) != nil }
            let expanded = othersExpanded ?? hasAnswers
            Button {
                withAnimation(.snappy) { othersExpanded = !expanded }
            } label: {
                HStack {
                    Text(expanded ? "Hide other inputs" : "Show other inputs")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(HealthTheme.color(for: .activity))
                    Spacer()
                    if !expanded { Text("\(sections.others.count) more").font(.footnote).foregroundStyle(.secondary) }
                }
                .frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded { panel(sections.others) }
        }
        if !sections.turnedOff.isEmpty {
            sectionTitle("Saved in categories that are off")
            panel(sections.turnedOff)
        }
    }

    private func sectionTitle(_ title: String) -> some View { JournalSectionTitle(title: title) }

    private func panel(_ behaviours: [JournalBehaviourData]) -> some View {
        JournalRowPanel(store: store, behaviours: behaviours, day: day) {
            selection = JournalEditorSelection(behaviour: $0, day: day)
        }
    }

    @ViewBuilder private var loadingState: some View {
        if store.isSyncing {
            ProgressView("Loading your journal…").frame(maxWidth: .infinity, minHeight: 240)
        } else {
            ContentUnavailableView {
                Label("Journal isn’t ready", systemImage: "book.closed")
            } description: {
                Text("Connect once to download your inputs. After that, you can log offline.")
            } actions: {
                Button("Retry") { Task { await store.synchronize() } }
            }
        }
    }
}

struct JournalPrivacyView: View {
    @ObservedObject var store: JournalStore

    var body: some View {
        ZStack {
            AppBackground()
            Form {
                Section {
                    Text("Turn on what you want to record. Its inputs are pinned to your daily list and shown by name in Insights and your check-in. They stay out of notifications.")
                    Text("Turning a category off removes its rows and stops new answers. Saved answers stay, so you can review or delete them.")
                }
                ForEach(store.snapshot.catalogue?.categories.filter(\.requiresOptIn) ?? []) { category in
                    Toggle(category.label, isOn: Binding(
                        get: { store.enabled("opt_in:\(category.id)") },
                        set: { store.setCategory(category.id, enabled: $0) }))
                    .disabled(store.storageBlocked)
                }
                Section {
                    Text("Daily notes are just for you. They aren’t used in patterns, and the app’s AI can’t read them.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let message = store.message { Text(message).font(.footnote) }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Private categories")
    }
}
