import SwiftUI

// Everything here reads the local snapshot, so history stays available offline.
struct JournalCalendarView: View {
    @ObservedObject var store: JournalStore
    let selectedDay: String
    let choose: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var month: String

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
    private var firstWeekday: Int { Calendar.current.firstWeekday }
    private var today: String { store.today }
    private var isCurrentMonth: Bool { JournalDay.monthStart(month) == JournalDay.monthStart(today) }

    init(store: JournalStore, selectedDay: String, choose: @escaping (String) -> Void) {
        self.store = store
        self.selectedDay = selectedDay
        self.choose = choose
        _month = State(initialValue: JournalDay.monthStart(selectedDay))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        monthHeader
                        grid
                        legend
                        jumpPicker
                        Text("Dates follow your Profile timezone, \(store.timezone ?? "UTC").")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(16)
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.large])
    }

    private var monthHeader: some View {
        HStack {
            Button { month = JournalDay.shiftMonth(month, by: -1) } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("Previous month")
            Spacer()
            Text(JournalDay.monthTitle(month)).font(.headline).accessibilityAddTraits(.isHeader)
            Spacer()
            Button { month = JournalDay.shiftMonth(month, by: 1) } label: {
                Image(systemName: "chevron.right").frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .disabled(isCurrentMonth)
            .accessibilityLabel("Next month")
        }
    }

    private var grid: some View {
        let index = JournalDayIndex(store.snapshot, today: today)
        return LazyVGrid(columns: columns, spacing: 4) {
            ForEach(Array(JournalDay.weekdaySymbols(firstWeekday: firstWeekday).enumerated()), id: \.offset) { _, symbol in
                Text(symbol).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).accessibilityHidden(true)
            }
            ForEach(Array(JournalDay.monthGrid(month, firstWeekday: firstWeekday).enumerated()), id: \.offset) { _, day in
                if let day {
                    cell(day, status: index.status(day), value: index.accessibilityValue(day))
                } else {
                    Color.clear.frame(minHeight: 44).accessibilityHidden(true)
                }
            }
        }
        // Seven columns can't reflow, so larger sizes would break the dates across lines.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    private func cell(_ day: String, status: JournalDayStatus, value: String) -> some View {
        Button {
            choose(day)
            dismiss()
        } label: {
            JournalDayMark(status: status, number: JournalDay.dayNumber(day), isToday: day == today)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background {
                    if day == selectedDay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(HealthTheme.color(for: .activity).opacity(0.14))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(status == .upcoming)
        .accessibilityLabel(JournalDay.longTitle(day))
        .accessibilityValue(day == today ? "Today, \(value)" : value)
        .accessibilityAddTraits(day == selectedDay ? .isSelected : [])
        .accessibilityIdentifier("journal.calendar.\(day)")
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem("Completed", .completed)
            legendItem("Incomplete", .incomplete)
            legendItem("Missing", .missing)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
    }

    private func legendItem(_ title: String, _ status: JournalDayStatus) -> some View {
        HStack(spacing: 5) {
            JournalDayShape(status: status).frame(width: 14, height: 14)
            Text(title)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) days are marked with a \(status == .completed ? "filled circle" : status == .incomplete ? "solid ring" : "dashed ring")")
    }

    // Any historical date stays a few taps away, however far back it is.
    private var jumpPicker: some View {
        let timezone = TimeZone(identifier: store.timezone ?? "UTC") ?? .gmt
        return DatePicker("Go to a month", selection: Binding(get: {
            // Midday UTC is still the 1st in every timezone that could shift this month.
            JournalDay.date(month).addingTimeInterval(12 * 3600)
        }, set: {
            month = JournalDay.monthStart(JournalCoding.day($0, timezone: timezone.identifier))
        }), in: ...Date(), displayedComponents: .date)
        .environment(\.timeZone, timezone)
        .font(.subheadline)
    }
}

// Shape carries the state as well as colour, so it reads without relying on hue alone.
struct JournalDayShape: View {
    let status: JournalDayStatus
    private var tint: Color { HealthTheme.color(for: .activity) }

    var body: some View {
        switch status {
        case .completed:
            Circle().fill(tint)
        case .incomplete:
            Circle().strokeBorder(Color.orange, lineWidth: 2)
        case .missing:
            Circle().strokeBorder(Color.red, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
        case .notStarted, .upcoming:
            Color.clear
        }
    }
}

struct JournalDayMark: View {
    let status: JournalDayStatus
    let number: String
    let isToday: Bool

    var body: some View {
        ZStack {
            JournalDayShape(status: status).frame(width: 36, height: 36)
            Text(number)
                .font(.system(.subheadline, design: .rounded, weight: isToday ? .heavy : .medium))
                .foregroundStyle(foreground)
                .underline(isToday)
                .monospacedDigit()
        }
    }

    private var foreground: Color {
        switch status {
        case .completed: .white
        case .upcoming: Color.secondary.opacity(0.5)
        case .notStarted: .secondary
        case .incomplete, .missing: .primary
        }
    }
}
