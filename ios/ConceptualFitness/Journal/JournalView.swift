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
    private var day: String { selectedDay ?? store.today }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Your daily journal", systemImage: "book.closed")
                        .font(.title2.bold())
                    Text("A little context, in your own words and numbers.")
                        .foregroundStyle(.secondary)
                    Text("Track around 5–10 things that matter to you. You can always add more.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
                if let timezone = store.timezone {
                    DatePicker("Journal date", selection: dateBinding(timezone), in: ...Date(), displayedComponents: .date)
                        .environment(\.timeZone, TimeZone(identifier: timezone) ?? .gmt)
                        .accessibilityLabel("Journal date")
                        .accessibilityHint("Choose today or any historical date to edit")
                    Text("\(day) · \(timezone)\nDates follow your Profile timezone. Unanswered inputs remain unknown.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                syncStatus
            }

            if store.snapshot.catalogue == nil || store.timezone == nil {
                Section {
                    if store.isSyncing { ProgressView("Loading your journal…") }
                    else {
                        ContentUnavailableView("Journal isn’t ready", systemImage: "book.closed",
                            description: Text("Connect once to download the catalogue and your Profile timezone. Then you can journal offline."))
                        Button("Retry") { Task { await store.synchronize() } }
                    }
                }
            } else {
                suggestions
                savedEntries
                Section {
                    NavigationLink {
                        JournalCatalogueView(store: store, day: day)
                    } label: { Label("Explore all inputs", systemImage: "square.grid.2x2") }
                    NavigationLink {
                        JournalPrivacyView(store: store)
                    } label: { Label("Private categories", systemImage: "lock") }
                    Text("Pins, Profile goals, recent use, record-building needs and daily rotation choose five suggestions. You stay in control.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Saving responses does not complete a check-in. Completion and streaks arrive with the morning check-in.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Insights")
        .sheet(item: $selection) { item in
            JournalEntryEditor(store: store, selection: item)
        }
        .refreshable { await store.synchronize() }
        .task { await store.synchronize() }
    }

    @ViewBuilder private var syncStatus: some View {
        if let message = store.message {
            Text(message).font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("journal.status")
            Button("Retry sync") { Task { await store.synchronize() } }.disabled(store.isSyncing)
        } else if store.isSyncing {
            ProgressView("Syncing journal…").font(.footnote)
        } else if store.pendingCount > 0 {
            Label("Saved on this device · \(store.pendingCount) pending", systemImage: "arrow.triangle.2.circlepath")
                .font(.footnote)
        } else if store.snapshot.catalogue != nil {
            Label("Journal is up to date", systemImage: "checkmark.circle").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var suggestions: some View {
        Section("Five suggestions for \(day)") {
            ForEach(JournalSuggestions.rank(store.snapshot, day: day)) { suggestion in
                VStack(alignment: .leading, spacing: 8) {
                    JournalInputRow(store: store, behaviour: suggestion.behaviour, day: day) {
                        selection = JournalEditorSelection(behaviour: suggestion.behaviour, day: day)
                    }
                    JournalExplanation(reasons: suggestion.reasons)
                }.padding(.vertical, 4)
            }
        }
    }

    private var savedEntries: some View {
        let entries = store.snapshot.entries.filter { $0.journalDate == day && !$0.deleted }
        return Section("Saved for this date") {
            if entries.isEmpty {
                Text("No responses yet. Choose a suggestion or explore the full catalogue.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries.sorted { $0.behaviourId < $1.behaviourId }) { entry in
                    if let item = store.snapshot.catalogue?.behaviours.first(where: { $0.id == entry.behaviourId }) {
                        JournalInputRow(store: store, behaviour: item, day: day) {
                            selection = JournalEditorSelection(behaviour: item, day: day)
                        }
                    }
                }
            }
        }
    }

    private func dateBinding(_ timezone: String) -> Binding<Date> {
        Binding(get: {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(identifier: timezone)
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            return formatter.date(from: "\(day) 12:00") ?? Date()
        }, set: { selectedDay = JournalCoding.day($0, timezone: timezone) })
    }
}

private struct JournalExplanation: View {
    let reasons: [String]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { expanded.toggle() } label: {
                HStack {
                    Text("Why this input?")
                    Spacer()
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded {
                Text(reasons.joined(separator: " · ")).foregroundStyle(.secondary)
            }
        }.font(.footnote)
    }
}

struct JournalInputRow: View {
    @ObservedObject var store: JournalStore
    let behaviour: JournalBehaviourData
    let day: String
    var revealName = false
    let open: () -> Void
    private var label: String { revealName ? behaviour.label : behaviour.displayLabel }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(label, systemImage: behaviour.presentation == "discreet" ? "lock" : "circle.dotted")
                        .font(.body.weight(.medium))
                    Text(summary).font(.footnote).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(behaviour.presentation == "discreet" ? "Opens this private input to reveal its name and response" : "Edit this journal input")
            Button {
                store.set("pin:\(behaviour.id)", value: !store.enabled("pin:\(behaviour.id)"))
            } label: {
                Image(systemName: store.enabled("pin:\(behaviour.id)") ? "pin.fill" : "pin")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("\(store.enabled("pin:\(behaviour.id)") ? "Unpin" : "Pin") \(label)")
            .disabled(store.storageBlocked)
        }
    }

    private var summary: String {
        guard let entry = store.entry(behaviour.id, day: day) else { return "Not answered" }
        if behaviour.presentation == "discreet" { return "Saved privately · tap to view" }
        guard let answer = entry.response?.answer else {
            return (entry.response?.missingReason ?? "not_answered").replacingOccurrences(of: "_", with: " ").capitalized
        }
        return answer.value.text + (answer.unit.map { " \($0)" } ?? "") + (entry.pending ? " · on device" : "")
    }
}

struct JournalCatalogueView: View {
    @ObservedObject var store: JournalStore
    let day: String
    @State private var query = ""
    @State private var selection: JournalEditorSelection?

    var body: some View {
        List {
            if let catalogue = store.snapshot.catalogue {
                ForEach(catalogue.categories) { category in
                    Section(category.label) {
                        if category.requiresOptIn && !store.enabled("opt_in:\(category.id)") {
                            Text("Enable this private category to explore its inputs.").foregroundStyle(.secondary)
                            NavigationLink("Manage private categories") { JournalPrivacyView(store: store) }
                        } else {
                            ForEach(catalogue.behaviours.filter {
                                $0.categoryId == category.id && (query.isEmpty || $0.label.localizedCaseInsensitiveContains(query))
                            }) { item in
                                JournalInputRow(store: store, behaviour: item, day: day, revealName: true) {
                                    selection = JournalEditorSelection(behaviour: item, day: day)
                                }
                            }
                        }
                    }
                }
                Text("\(catalogue.behaviours.count) inputs · \(store.snapshot.preferences.filter { $0.key.hasPrefix("pin:") && $0.value }.count) pinned. Around 5–10 is a useful starting point; there is no maximum.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("All inputs")
        .searchable(text: $query, prompt: "Find an input")
        .sheet(item: $selection) { JournalEntryEditor(store: store, selection: $0) }
    }
}

struct JournalPrivacyView: View {
    @ObservedObject var store: JournalStore
    var body: some View {
        Form {
            Section {
                Text("Choose which private categories you want to use. Names and answers stay discreet in suggestions and saved-entry lists. Exploring an enabled category reveals its input names.")
                Text("A private input can only be suggested after you enable its category and deliberately save an answer. Turning access off stops suggestions and new answers; saved entries remain available to review or delete.")
            }
            ForEach(store.snapshot.catalogue?.categories.filter(\.requiresOptIn) ?? []) { category in
                Toggle(category.label, isOn: Binding(
                    get: { store.enabled("opt_in:\(category.id)") },
                    set: { store.set("opt_in:\(category.id)", value: $0) }))
                .disabled(store.storageBlocked)
            }
            Section {
                Text("Daily notes are private journal data. They are excluded from suggestions and statistical inputs, and this journal does not send them to AI.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let message = store.message { Text(message).font(.footnote) }
            }
        }
        .navigationTitle("Private categories")
    }
}
