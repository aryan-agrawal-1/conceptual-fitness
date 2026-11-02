import SwiftUI

struct JournalFieldDraft {
    var text = ""
    var unit = ""

    init(field: JournalFieldData, answer: JournalAnswerData?) {
        unit = answer?.unit ?? field.units.first ?? ""
        if let answer {
            if case .boolean(let value) = answer.value { text = value ? "yes" : "no" }
            else { text = answer.value.text }
        }
    }

    func answer(for field: JournalFieldData) -> JournalAnswerData? {
        switch field.inputType {
        case "boolean":
            guard ["yes", "no"].contains(text) else { return nil }
            return JournalAnswerData(type: "boolean", value: .boolean(text == "yes"))
        case "text", "time":
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return JournalAnswerData(type: field.inputType, value: .text(text))
        default:
            // Decimal keypads type a comma in many locales.
            guard let value = Double(text.replacingOccurrences(of: ",", with: ".")), value.isFinite else { return nil }
            return JournalAnswerData(type: field.inputType, value: .number(value), unit: field.units.isEmpty ? nil : unit)
        }
    }

    func valid(for field: JournalFieldData, units: [JournalUnitData]) -> Bool {
        guard let answer = answer(for: field) else { return false }
        switch answer.value {
        case .number(let entered):
            if ["count", "rating"].contains(field.inputType), entered.rounded() != entered { return false }
            let canonical = entered * (units.first { $0.id == unit }?.multiplier ?? 1)
            return canonical >= (field.minimum ?? 0) && canonical <= (field.maximum ?? 1_000_000_000)
        case .text(let text):
            if field.inputType == "time" {
                return text.range(of: #"^([01][0-9]|2[0-3]):[0-5][0-9]$"#, options: .regularExpression) != nil
            }
            return text.count <= 2000
        case .boolean: return true
        }
    }
}

struct JournalEntryEditor: View {
    @ObservedObject var store: JournalStore
    let selection: JournalEditorSelection
    @Environment(\.dismiss) private var dismiss
    @State private var mode: String
    @State private var fields: [String: JournalFieldDraft]
    @State private var saveError: String?
    private var item: JournalBehaviourData { selection.behaviour }
    private var existing: JournalEntryData? { store.entry(item.id, day: selection.day) }
    private var entryTimezone: String { existing?.response?.timezone ?? store.timezone ?? "UTC" }
    private var allowed: Bool {
        guard let category = store.snapshot.catalogue?.categories.first(where: { $0.id == item.categoryId }) else { return false }
        return !category.requiresOptIn || store.enabled("opt_in:\(category.id)")
    }

    init(store: JournalStore, selection: JournalEditorSelection) {
        self.store = store
        self.selection = selection
        let response = store.entry(selection.behaviour.id, day: selection.day)?.response
        _mode = State(initialValue: response?.missingReason ?? "answer")
        var drafts = ["answer": JournalFieldDraft(field: selection.behaviour.answer, answer: response?.answer)]
        for detail in selection.behaviour.details {
            drafts[detail.id] = JournalFieldDraft(field: detail, answer: response?.details[detail.id])
        }
        _fields = State(initialValue: drafts)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(item.question).font(.title3.bold())
                    Text("\(selection.day) · \(entryTimezone)")
                        .font(.footnote).foregroundStyle(.secondary)
                    if entryTimezone != store.timezone {
                        Text("Input times use this entry’s original timezone. The selected journal date stays the same.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if !allowed {
                        Text("Enable this private category before adding or changing an answer. You can still review or delete the saved response.")
                            .foregroundStyle(.secondary)
                        NavigationLink("Manage private categories") { JournalPrivacyView(store: store) }
                    }
                }
                Section {
                    Picker("Response", selection: $mode) {
                        Text("Provide an answer").tag("answer")
                        Text("Not answered").tag("not_answered")
                        Text("Skip for now").tag("skipped")
                        Text("Not applicable").tag("not_applicable")
                        Text("Unavailable").tag("unavailable")
                    }
                    .disabled(!allowed)
                    if mode == "answer" {
                        JournalFieldControl(field: item.answer, draft: binding("answer"), units: store.snapshot.catalogue?.units ?? [])
                            .disabled(!allowed)
                    }
                } footer: {
                    Text("No and zero are explicit answers. Missing or skipped responses remain unknown.")
                }
                if showDetails && !item.details.isEmpty {
                    Section("Optional details") {
                        ForEach(item.details) { field in
                            JournalFieldControl(field: field, draft: binding(field.id), units: store.snapshot.catalogue?.units ?? [])
                        }
                    }.disabled(!allowed)
                }
                if item.answer.inputType == "text" {
                    Section { Text("This note is saved for you. It is excluded from statistical inputs and is not sent to AI by this journal.").font(.footnote).foregroundStyle(.secondary) }
                }
                if let saveError {
                    Section { Text(saveError).foregroundStyle(.red).accessibilityIdentifier("journal.saveError") }
                }
                if existing != nil {
                    Section {
                        Button("Delete response", role: .destructive) {
                            if store.delete(item.id, day: selection.day) { dismiss() }
                            else { saveError = store.message }
                        }.disabled(store.storageBlocked)
                    } footer: {
                        Text("Your updates apply to this journal date and will be used when insights are calculated. Saving or deleting a response does not mark a day complete.")
                    }
                }
            }
            .navigationTitle(item.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!canSave)
                }
            }
        }
    }

    private var showDetails: Bool {
        mode == "answer" && (item.answer.inputType != "boolean" || fields["answer"]?.text == "yes")
    }
    private var canSave: Bool {
        guard allowed, !store.storageBlocked else { return false }
        if mode != "answer" { return true }
        let units = store.snapshot.catalogue?.units ?? []
        guard fields["answer"]?.valid(for: item.answer, units: units) == true else { return false }
        return !showDetails || item.details.allSatisfy { field in
            guard let draft = fields[field.id], !draft.text.isEmpty else { return true }
            return draft.valid(for: field, units: units)
        }
    }

    private func binding(_ key: String) -> Binding<JournalFieldDraft> {
        Binding(get: { fields[key] ?? JournalFieldDraft(field: item.answer, answer: nil) }, set: { fields[key] = $0 })
    }

    private func save() {
        var details: [String: JournalAnswerData] = [:]
        if showDetails {
            for field in item.details { details[field.id] = fields[field.id]?.answer(for: field) }
        }
        let response = JournalResponseData(
            catalogueVersion: store.snapshot.catalogue?.version ?? 1,
            journalDate: selection.day, timezone: entryTimezone,
            recordedAt: existing?.response?.recordedAt ?? JournalCoding.timestamp(),
            observedAt: existing?.response?.observedAt, behaviourId: item.id,
            answer: mode == "answer" ? fields["answer"]?.answer(for: item.answer) : nil,
            details: details, missingReason: mode == "answer" ? nil : mode)
        if store.save(response) { dismiss() }
        else { saveError = store.message }
    }
}

private struct JournalFieldControl: View {
    let field: JournalFieldData
    @Binding var draft: JournalFieldDraft
    let units: [JournalUnitData]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch field.inputType {
            case "boolean":
                Picker(field.label, selection: $draft.text) {
                    Text("Choose…").tag("")
                    Text("Yes").tag("yes")
                    Text("No").tag("no")
                }
            case "rating":
                Picker(field.label, selection: $draft.text) {
                    Text("Choose…").tag("")
                    ForEach(Array(field.ratingLabels.enumerated()), id: \.offset) { index, label in
                        Text(label).tag(String(index + Int(field.minimum ?? 1)))
                    }
                }
            case "text":
                TextField(field.label, text: $draft.text, axis: .vertical)
                    .lineLimit(4...10).accessibilityLabel(field.label)
                Text("\(draft.text.count)/2000 characters").font(.caption).foregroundStyle(.secondary)
            case "time":
                TextField("\(field.label) (HH:mm)", text: $draft.text)
                    .keyboardType(.numbersAndPunctuation).accessibilityLabel("\(field.label), 24 hour time, HH colon mm")
            default:
                TextField(field.label, text: $draft.text).keyboardType(.decimalPad)
                    .accessibilityLabel(field.label)
                if !field.units.isEmpty {
                    Picker("\(field.label) unit", selection: $draft.unit) {
                        ForEach(field.units, id: \.self) { id in Text(units.first { $0.id == id }?.label ?? id).tag(id) }
                    }
                }
                if let maximum = field.maximum {
                    let multiplier = units.first { $0.id == draft.unit }?.multiplier ?? 1
                    Text("Range: \(((field.minimum ?? 0) / multiplier).formatted())–\((maximum / multiplier).formatted()) \(draft.unit)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !draft.text.isEmpty && !draft.valid(for: field, units: units) {
                Text("Enter a valid \(field.inputType) within the shown limits.")
                    .font(.footnote).foregroundStyle(.red)
            }
        }
    }
}
