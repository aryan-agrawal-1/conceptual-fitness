import SwiftUI

enum ScoreTimeframe: String, CaseIterable, Identifiable {
    case day
    case week
    case month
    case year

    var id: String { rawValue }

    var title: String {
        rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }
}

typealias StrainTimeframe = ScoreTimeframe

struct ScoreCalendarSelection: Identifiable {
    let id = UUID()
    let timeframe: ScoreTimeframe
    let date: Date
}

struct ScoreRangeNavigator: View {
    let timeframe: ScoreTimeframe
    let metricName: String
    @Binding var selectedDate: Date
    @Binding var calendarSelection: ScoreCalendarSelection?

    private let calendar = ScoreDateFormatters.calendar

    var body: some View {
        HStack(spacing: 12) {
            Button {
                selectedDate = shiftedDate(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline.weight(.bold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Previous \(timeframe.rawValue)")

            Button {
                calendarSelection = ScoreCalendarSelection(timeframe: timeframe, date: selectedDate)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "calendar")
                        .font(.subheadline.weight(.bold))
                    Text(rangeTitle)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Select \(metricName) \(timeframe.rawValue)")

            Button {
                selectedDate = shiftedDate(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.headline.weight(.bold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .disabled(!canMoveForward)
            .opacity(canMoveForward ? 1 : 0.35)
            .accessibilityLabel("Next \(timeframe.rawValue)")
        }
        .padding(10)
        .glassSurface(cornerRadius: 18)
    }

    private var rangeTitle: String {
        ScoreDateFormatters.rangeTitle(for: timeframe, date: selectedDate, calendar: calendar)
    }

    private var canMoveForward: Bool {
        periodStart(for: shiftedDate(by: 1)) <= periodStart(for: Date())
    }

    private func shiftedDate(by value: Int) -> Date {
        switch timeframe {
        case .day:
            return calendar.date(byAdding: .day, value: value, to: selectedDate) ?? selectedDate
        case .week:
            return calendar.date(byAdding: .weekOfYear, value: value, to: selectedDate) ?? selectedDate
        case .month:
            return calendar.date(byAdding: .month, value: value, to: selectedDate) ?? selectedDate
        case .year:
            return calendar.date(byAdding: .year, value: value, to: selectedDate) ?? selectedDate
        }
    }

    private func periodStart(for date: Date) -> Date {
        switch timeframe {
        case .day:
            return calendar.startOfDay(for: date)
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        case .month:
            return calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
        case .year:
            return calendar.dateInterval(of: .year, for: date)?.start ?? calendar.startOfDay(for: date)
        }
    }
}

struct ScoreCalendarPicker: View {
    let metricName: String
    let selection: ScoreCalendarSelection
    let onSelect: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draftDate: Date

    init(metricName: String, selection: ScoreCalendarSelection, onSelect: @escaping (Date) -> Void) {
        self.metricName = metricName
        self.selection = selection
        self.onSelect = onSelect
        _draftDate = State(initialValue: selection.date)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                DatePicker(
                    "Select \(selection.timeframe.rawValue)",
                    selection: $draftDate,
                    in: ...Date(),
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .padding(.horizontal)

                Text("The selected date anchors the \(selection.timeframe.rawValue) shown on the \(metricName) page.")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .navigationTitle("Select \(selection.timeframe.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onSelect(draftDate)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

enum ScoreDateFormatters {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 2
        return calendar
    }()

    static let apiDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static let weekday: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "E"
        return formatter
    }()

    static let compactDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM"
        return formatter
    }()

    static let weekdayDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "E d MMM"
        return formatter
    }()

    static let compactDateWithYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM yy"
        return formatter
    }()

    static let monthYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM yyyy"
        return formatter
    }()

    static let year: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy"
        return formatter
    }()

    static let month: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM"
        return formatter
    }()

    static func weekdayLabel(from value: String) -> String {
        guard let date = apiDate.date(from: value) else { return value }
        return weekday.string(from: date)
    }

    static func shortDateLabel(from value: String) -> String {
        guard let date = apiDate.date(from: value) else { return value }
        return compactDate.string(from: date)
    }

    static func monthLabel(from value: String) -> String {
        guard let date = apiDate.date(from: value) else { return value }
        return month.string(from: date)
    }

    static func monthReadoutLabel(from value: String) -> String {
        guard let date = apiDate.date(from: value) else { return value }
        return monthYear.string(from: date)
    }

    static func weeklySelectedDateLabel(from value: String) -> String {
        guard let date = apiDate.date(from: value) else { return value }
        return weekdayDate.string(from: date)
    }

    static func rangeTitle(for timeframe: ScoreTimeframe, date: Date, calendar: Calendar) -> String {
        switch timeframe {
        case .day:
            return dayTitle(date, calendar: calendar)
        case .week:
            let interval = calendar.dateInterval(of: .weekOfYear, for: date)
            let start = interval?.start ?? calendar.startOfDay(for: date)
            let end = calendar.date(byAdding: .day, value: 6, to: start) ?? start
            return "\(dayTitle(start, calendar: calendar)) - \(dayTitle(end, calendar: calendar))"
        case .month:
            return monthYear.string(from: date)
        case .year:
            return year.string(from: date)
        }
    }

    private static func dayTitle(_ date: Date, calendar: Calendar) -> String {
        if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
            return compactDate.string(from: date)
        }
        return compactDateWithYear.string(from: date)
    }
}
