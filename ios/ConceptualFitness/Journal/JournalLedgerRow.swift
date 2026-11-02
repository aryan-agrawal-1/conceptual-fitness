import SwiftUI

struct JournalLedgerRow: View {
    @ObservedObject var store: JournalStore
    let behaviour: JournalBehaviourData
    let day: String
    let openEditor: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    private var response: JournalResponseData? { store.entry(behaviour.id, day: day)?.response }
    private var allowed: Bool {
        guard let category = store.snapshot.catalogue?.categories.first(where: { $0.id == behaviour.categoryId }) else { return false }
        return !category.requiresOptIn || store.enabled("opt_in:\(category.id)")
    }
    private var showsDetails: Bool {
        allowed && response?.answer?.value == .boolean(true) && !behaviour.details.isEmpty
    }

    var body: some View {
        VStack(spacing: 6) {
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(spacing: 10))
            layout {
                VStack(alignment: .leading, spacing: 1) {
                    Text(allowed ? behaviour.label : behaviour.displayLabel)
                        .font(.body.weight(.semibold))
                    if let status {
                        Text(status).font(.caption.weight(.medium)).foregroundStyle(statusColor)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                control
                    .frame(width: typeSize.isAccessibilitySize ? nil : 176)
                    .disabled(store.storageBlocked)
            }
            .frame(minHeight: 44)
            if showsDetails {
                JournalDetailPanel(store: store, behaviour: behaviour, day: day, openEditor: openEditor)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
        .contextMenu { menu }
    }

    private var status: String? {
        if let reason = response?.missingReason {
            switch reason {
            case "skipped": return "Skipped"
            case "not_applicable": return "Doesn’t apply"
            case "unavailable": return "Unavailable"
            default: return "Not answered"
            }
        }
        guard let answer = response?.answer, behaviour.answer.inputType == "rating",
              case .number(let value) = answer.value else { return nil }
        let index = Int(value) - Int(behaviour.answer.minimum ?? 1)
        return behaviour.answer.ratingLabels.indices.contains(index) ? behaviour.answer.ratingLabels[index] : nil
    }

    private var statusColor: Color {
        response?.missingReason == nil ? HealthTheme.color(for: .recovery) : .secondary
    }

    @ViewBuilder private var control: some View {
        if !allowed {
            openButton("Review")
        } else {
            switch behaviour.answer.inputType {
            case "boolean":
                JournalYesNo(label: behaviour.label, value: response?.answer?.value) { choice in
                    choose(.init(type: "boolean", value: .boolean(choice)), current: .boolean(choice))
                }
            case "rating":
                JournalRatingScale(field: behaviour.answer, label: behaviour.label, value: response?.answer?.value) { value in
                    choose(.init(type: "rating", value: .number(value)), current: .number(value))
                }
            default:
                openButton(response == nil ? "Add" : "Edit")
            }
        }
    }

    private func openButton(_ title: String) -> some View {
        Button(action: openEditor) {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).accessibilityHidden(true)
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .trailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(HealthTheme.color(for: .activity))
        .accessibilityLabel("\(title) \(behaviour.label)")
    }

    // Tapping the chosen answer again clears it, so a mistaken tap is easy to undo.
    private func choose(_ answer: JournalAnswerData, current: JournalScalar) {
        if response?.answer?.value == current {
            store.delete(behaviour.id, day: day)
        } else {
            store.answer(behaviour, day: day, answer: answer, details: response?.details ?? [:])
        }
    }

    @ViewBuilder private var menu: some View {
        if allowed {
            Button {
                store.set("pin:\(behaviour.id)", value: !store.isPinned(behaviour))
            } label: {
                let pinned = store.isPinned(behaviour)
                Label(pinned ? "Unpin" : "Pin to daily list", systemImage: pinned ? "pin.slash" : "pin")
            }
            Button { store.answer(behaviour, day: day, answer: nil, missingReason: "skipped") } label: {
                Label("Skip for today", systemImage: "forward")
            }
            Button { store.answer(behaviour, day: day, answer: nil, missingReason: "not_applicable") } label: {
                Label("Doesn’t apply", systemImage: "nosign")
            }
        }
        Button(action: openEditor) { Label("Open details", systemImage: "slider.horizontal.3") }
        if response != nil {
            Button(role: .destructive) { store.delete(behaviour.id, day: day) } label: {
                Label("Clear answer", systemImage: "xmark")
            }
        }
    }
}

struct JournalYesNo: View {
    let label: String
    let value: JournalScalar?
    let choose: (Bool) -> Void

    var body: some View {
        HStack(spacing: 0) {
            option("No", false)
            option("Yes", true)
        }
        .padding(2)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .sensoryFeedback(.selection, trigger: value)
    }

    private func option(_ title: String, _ choice: Bool) -> some View {
        let selected = value == .boolean(choice)
        return Button { choose(choice) } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? HealthTheme.color(for: .sleep) : .primary.opacity(0.75))
                .frame(maxWidth: .infinity, minHeight: 40)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.white).shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label): \(title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct JournalRatingScale: View {
    let field: JournalFieldData
    let label: String
    let value: JournalScalar?
    let choose: (Double) -> Void
    private var tint: Color { HealthTheme.color(for: .recovery) }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(field.ratingLabels.enumerated()), id: \.offset) { index, title in
                let step = Double(index) + (field.minimum ?? 1)
                let filled: Bool = { if case .number(let current) = value { return step <= current } else { return false } }()
                Button { choose(step) } label: {
                    Capsule()
                        .fill(filled ? tint : Color.primary.opacity(0.14))
                        .frame(height: 10)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(label): \(title)")
                .accessibilityAddTraits(value == .number(step) ? .isSelected : [])
            }
        }
        .sensoryFeedback(.selection, trigger: value)
    }
}

struct JournalDetailPanel: View {
    @ObservedObject var store: JournalStore
    let behaviour: JournalBehaviourData
    let day: String
    let openEditor: () -> Void
    private var inlineFields: [JournalFieldData] { JournalDetailPanel.inlineFields(behaviour.details) }

    // One main control keeps the row compact. Everything else sits behind More details.
    static func inlineFields(_ details: [JournalFieldData]) -> [JournalFieldData] {
        if let count = details.first(where: { $0.inputType == "count" }) { return [count] }
        return details.first.map { $0.inputType == "time" ? [] : [$0] } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(inlineFields) { field in
                JournalDetailField(behaviour: behaviour, field: field,
                                   units: store.snapshot.catalogue?.units ?? [],
                                   value: store.entry(behaviour.id, day: day)?.response?.details[field.id]) { answer in
                    update(field, answer)
                }
            }
            if inlineFields.count < behaviour.details.count {
                Button("More details", action: openEditor)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(HealthTheme.color(for: .activity))
                    .frame(minHeight: 32)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HealthTheme.color(for: .sleep).opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func update(_ field: JournalFieldData, _ answer: JournalAnswerData?) {
        guard let response = store.entry(behaviour.id, day: day)?.response else { return }
        var details = response.details
        details[field.id] = answer
        store.answer(behaviour, day: day, answer: response.answer, details: details)
    }
}

// Slider ranges are everyday limits. Larger values can still be typed in the answer sheet.
struct JournalSliderSpec {
    let unit: String
    let label: String
    let range: ClosedRange<Double>
    let step: Double

    static func spec(behaviour: String, field: JournalFieldData) -> JournalSliderSpec? {
        if field.units.contains("uk_alcohol_unit") {
            return .init(unit: "uk_alcohol_unit", label: "units", range: 0...15, step: 0.5)
        }
        if field.units.contains("mg") { return .init(unit: "mg", label: "mg", range: 0...1000, step: 25) }
        if field.units.contains("min") {
            return behaviour == "cold_exposure"
                ? .init(unit: "min", label: "min", range: 0...30, step: 1)
                : .init(unit: "min", label: "min", range: 0...120, step: 5)
        }
        return nil
    }
}

private struct JournalDetailField: View {
    let behaviour: JournalBehaviourData
    let field: JournalFieldData
    let units: [JournalUnitData]
    let value: JournalAnswerData?
    let update: (JournalAnswerData?) -> Void
    @State private var dragging: Double?

    var body: some View {
        switch field.inputType {
        case "rating": ratingField
        case "count": countField
        case "time": JournalTimeField(label: field.label, text: timeBinding)
        default:
            if let spec = JournalSliderSpec.spec(behaviour: behaviour.id, field: field) {
                sliderField(spec)
            }
        }
    }

    private var number: Double? { if case .number(let number) = value?.value { number } else { nil } }

    private var ratingField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(field.label).font(.footnote).foregroundStyle(.primary.opacity(0.65))
            HStack(spacing: 5) {
                ForEach(Array(field.ratingLabels.enumerated()), id: \.offset) { index, title in
                    let step = Double(index) + (field.minimum ?? 1)
                    let selected = number == step
                    Button { update(selected ? nil : .init(type: "rating", value: .number(step))) } label: {
                        Text(title)
                            .font(.caption.weight(selected ? .semibold : .medium))
                            .lineLimit(2).minimumScaleFactor(0.8)
                            .foregroundStyle(selected ? HealthTheme.color(for: .sleep) : .primary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(selected ? HealthTheme.color(for: .sleep).opacity(0.13) : .white.opacity(0.7),
                                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .strokeBorder(selected ? HealthTheme.color(for: .sleep) : .primary.opacity(0.12))
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(field.label): \(title)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }

    private var countField: some View {
        Stepper(value: Binding(
            get: { number ?? 0 },
            set: { update(.init(type: "count", value: .number($0))) }
        ), in: (field.minimum ?? 0)...(field.maximum ?? 1000)) {
            HStack {
                Text(field.label).font(.footnote).foregroundStyle(.primary.opacity(0.65))
                Spacer()
                Text(number.map { String(Int($0)) } ?? "–")
                    .font(.system(.body, design: .rounded, weight: .bold)).monospacedDigit()
            }
        }
    }

    @ViewBuilder private func sliderField(_ spec: JournalSliderSpec) -> some View {
        // An answer saved in another unit keeps its value until edited in the sheet.
        if let number, let unit = value?.unit, unit != spec.unit {
            HStack {
                Text(field.label).font(.footnote).foregroundStyle(.primary.opacity(0.65))
                Spacer()
                Text("\(JournalScalar.number(number).text) \(units.first { $0.id == unit }?.label ?? unit)")
                    .font(.footnote.weight(.semibold))
            }
        } else {
            let upper = Swift.max(spec.range.upperBound, number ?? 0)
            let current = dragging ?? number
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(field.label).font(.footnote).foregroundStyle(.primary.opacity(0.65))
                    Spacer()
                    Text(current.map { "\(JournalScalar.number($0).text) \(spec.label)" } ?? "–")
                        .font(.system(.subheadline, design: .rounded, weight: .bold)).monospacedDigit()
                }
                Slider(value: Binding(get: { current ?? 0 }, set: { dragging = $0 }),
                       in: spec.range.lowerBound...upper, step: spec.step) { editing in
                    guard !editing, let dragging else { return }
                    update(.init(type: field.inputType, value: .number(dragging), unit: spec.unit))
                    self.dragging = nil
                }
                .tint(HealthTheme.color(for: .sleep))
                .accessibilityLabel(field.label)
                .accessibilityValue(current.map { "\(JournalScalar.number($0).text) \(spec.label)" } ?? "Not set")
            }
        }
    }

    private var timeBinding: Binding<String> {
        Binding(get: { value?.value.text ?? "" }, set: { update($0.isEmpty ? nil : .init(type: "time", value: .text($0))) })
    }
}

struct JournalTimeField: View {
    let label: String
    @Binding var text: String

    private static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .gmt
        formatter.dateFormat = "HH:mm"
        return formatter
    }

    var body: some View {
        if text.isEmpty {
            HStack {
                Text(label).font(.footnote).foregroundStyle(.primary.opacity(0.65))
                Spacer()
                Button("Add time") { text = "12:00" }
                    .font(.footnote.weight(.semibold))
                    .frame(minHeight: 44)
            }
        } else {
            DatePicker(selection: Binding(
                get: { Self.formatter().date(from: text) ?? Date(timeIntervalSince1970: 12 * 3600) },
                set: { text = Self.formatter().string(from: $0) }
            ), displayedComponents: .hourAndMinute) {
                Text(label).font(.footnote).foregroundStyle(.primary.opacity(0.65))
            }
            .environment(\.timeZone, .gmt)
        }
    }
}
