import SwiftUI

struct JournalEditorSelection: Identifiable {
    let behaviour: JournalBehaviourData
    let day: String
    var id: String { "\(day)/\(behaviour.id)" }
}

struct JournalView: View {
    @ObservedObject var store: JournalStore
    @State private var selectedDay: String?
    @State private var selection: JournalEditorSelection?
    @State private var choosingDate = false
    @State private var othersExpanded: Bool?
    private var day: String { selectedDay ?? store.today }
    private var isReady: Bool { store.snapshot.catalogue != nil && store.timezone != nil }

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if isReady {
                        weekStrip
                        dayHeader
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
                        .accessibilityLabel("Choose a date")
                    NavigationLink { JournalPrivacyView(store: store) } label: {
                        Image(systemName: "lock")
                    }
                    .accessibilityLabel("Private categories")
                }
            }
        }
        .sheet(item: $selection) { JournalEntryEditor(store: store, selection: $0) }
        .sheet(isPresented: $choosingDate) { datePicker }
        .refreshable { await store.synchronize() }
        .task { await store.synchronize() }
    }

    private var weekStrip: some View {
        HStack(spacing: 2) {
            ForEach(JournalDay.week(endingOn: store.today)) { item in
                let selected = item.id == day
                let logged = JournalDailyList.loggedCount(store.snapshot, day: item.id) > 0
                Button { selectedDay = item.id; othersExpanded = nil } label: {
                    VStack(spacing: 1) {
                        Text(item.letter).font(.caption2.weight(.medium))
                        Text(item.number).font(.system(.subheadline, design: .rounded, weight: .bold))
                    }
                    .foregroundStyle(selected ? .white : (logged ? HealthTheme.color(for: .activity) : .primary.opacity(0.75)))
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
                .accessibilityValue(logged ? "Has answers" : "No answers")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private var dayHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(JournalDay.title(day, today: store.today)).font(.title3.weight(.bold))
            Spacer()
            let logged = JournalDailyList.loggedCount(store.snapshot, day: day)
            if JournalDailyList.reachedTarget(logged) {
                Label("Daily target reached", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(HealthTheme.color(for: .readiness))
            } else {
                Text("\(logged)/\(JournalDailyList.dailyTarget)")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(logged) of \(JournalDailyList.dailyTarget) logged")
            }
        }
        .accessibilityElement(children: .combine)
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

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 4).padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private func panel(_ behaviours: [JournalBehaviourData]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(behaviours.enumerated()), id: \.element.id) { index, item in
                JournalLedgerRow(store: store, behaviour: item, day: day) {
                    selection = JournalEditorSelection(behaviour: item, day: day)
                }
                if index < behaviours.count - 1 { Divider().padding(.horizontal, 14) }
            }
        }
        .panelSurface(cornerRadius: 22)
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

    private var datePicker: some View {
        NavigationStack {
            let timezone = store.timezone ?? "UTC"
            VStack(alignment: .leading) {
                DatePicker("Date", selection: dateBinding(timezone), in: ...Date(), displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .environment(\.timeZone, TimeZone(identifier: timezone) ?? .gmt)
                Text("Dates follow your Profile timezone, \(timezone).")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
            .navigationTitle("Choose a date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { choosingDate = false } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func dateBinding(_ timezone: String) -> Binding<Date> {
        Binding(get: {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(identifier: timezone)
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            return formatter.date(from: "\(day) 12:00") ?? Date()
        }, set: {
            selectedDay = JournalCoding.day($0, timezone: timezone)
            othersExpanded = nil
        })
    }
}

struct JournalPrivacyView: View {
    @ObservedObject var store: JournalStore

    var body: some View {
        ZStack {
            AppBackground()
            Form {
                Section {
                    Text("Turn on what you want to record. Its inputs are pinned to your daily list and shown by name in Insights. They stay out of notifications.")
                    Text("Turning a category off removes its rows and stops new answers. Saved answers stay, so you can review or delete them.")
                }
                ForEach(store.snapshot.catalogue?.categories.filter(\.requiresOptIn) ?? []) { category in
                    Toggle(category.label, isOn: Binding(
                        get: { store.enabled("opt_in:\(category.id)") },
                        set: { store.setCategory(category.id, enabled: $0) }))
                    .disabled(store.storageBlocked)
                }
                Section {
                    Text("Daily notes are just for you. They aren’t used in patterns or sent to AI.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let message = store.message { Text(message).font(.footnote) }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Private categories")
    }
}
