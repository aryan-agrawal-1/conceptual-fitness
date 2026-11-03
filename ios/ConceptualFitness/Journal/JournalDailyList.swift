import Foundation

struct JournalDailySections {
    struct Section: Identifiable {
        let id: String
        let title: String
        let behaviours: [JournalBehaviourData]
    }

    var pinned: [JournalBehaviourData] = []
    var privatePinned: [Section] = []
    var others: [JournalBehaviourData] = []
    var turnedOff: [JournalBehaviourData] = []
}

enum JournalDailyList {
    static let defaultPins = ["mood", "stress", "energy", "worked_late", "screen_in_bed"]
    static let dailyTarget = 5

    static func reachedTarget(_ logged: Int) -> Bool { logged >= dailyTarget }

    static let goalRules: [(words: [String], behaviours: Set<String>)] = [
        (["sleep", "circadian", "rest"], ["screen_in_bed", "worked_late", "night_shift", "sleep_mask", "caffeine"]),
        (["strength", "muscle", "exercise", "fitness", "recovery", "endurance"], ["energy", "muscle_soreness", "sauna", "stress"]),
        (["stress", "mental", "wellbeing", "well-being", "mood"], ["mood", "stress", "energy", "worked_late"]),
        (["weight", "nutrition", "health"], ["energy", "mood", "alcohol", "stress"])
    ]

    static func isPinned(_ behaviour: JournalBehaviourData, in snapshot: JournalSnapshot) -> Bool {
        let isPrivate = snapshot.catalogue?.categories.first { $0.id == behaviour.categoryId }?.requiresOptIn == true
        let enabled = Set(snapshot.preferences.filter(\.value).map(\.key))
        if isPrivate && !enabled.contains("opt_in:\(behaviour.categoryId)") { return false }
        if let explicit = snapshot.preferences.first(where: { $0.key == "pin:\(behaviour.id)" }) { return explicit.value }
        return isPrivate || defaultPins.contains(behaviour.id)
    }

    static func sections(_ snapshot: JournalSnapshot, day: String) -> JournalDailySections {
        guard let catalogue = snapshot.catalogue else { return JournalDailySections() }
        let enabled = Set(snapshot.preferences.filter(\.value).map(\.key))
        let privateCategories = catalogue.categories.filter(\.requiresOptIn)
        let hidden = Set(privateCategories.filter { !enabled.contains("opt_in:\($0.id)") }.map(\.id))
        let privateIds = Set(privateCategories.map(\.id))
        let pinned = catalogue.behaviours.filter { isPinned($0, in: snapshot) }

        var result = JournalDailySections()
        let standard = pinned.filter { !privateIds.contains($0.categoryId) }
        result.pinned = standard.sorted { order($0.id) == order($1.id) ? $0.id < $1.id : order($0.id) < order($1.id) }
        result.privatePinned = privateCategories.compactMap { category in
            let rows = pinned.filter { $0.categoryId == category.id }
            return rows.isEmpty ? nil : .init(id: category.id, title: category.label, behaviours: rows)
        }
        let rest = catalogue.behaviours.filter { !isPinned($0, in: snapshot) && !hidden.contains($0.categoryId) }
        result.others = ranked(rest, snapshot: snapshot, day: day)
        result.turnedOff = catalogue.behaviours.filter { item in
            hidden.contains(item.categoryId) && snapshot.entries.contains {
                $0.behaviourId == item.id && $0.journalDate == day && !$0.deleted
            }
        }
        return result
    }

    static func loggedCount(_ snapshot: JournalSnapshot, day: String) -> Int {
        snapshot.entries.filter { $0.journalDate == day && !$0.deleted && $0.response?.answer != nil }.count
    }

    private static func order(_ id: String) -> Int { defaultPins.firstIndex(of: id) ?? defaultPins.count }

    private static func ranked(_ items: [JournalBehaviourData], snapshot: JournalSnapshot,
                               day: String) -> [JournalBehaviourData] {
        let goals = snapshot.goals.joined(separator: " ").lowercased()
        let relevant = goalRules.filter { rule in rule.words.contains { goals.contains($0) } }
            .reduce(into: Set<String>()) { $0.formUnion($1.behaviours) }
        let recentStart = JournalCoding.day(JournalDay.date(day).addingTimeInterval(-29 * 86400), timezone: "UTC")
        let recent = Set(snapshot.entries.filter {
            !$0.deleted && $0.response?.answer != nil && $0.journalDate >= recentStart && $0.journalDate < day
        }.map(\.behaviourId))
        func score(_ item: JournalBehaviourData) -> Int {
            (relevant.contains(item.id) ? 2 : 0) + (recent.contains(item.id) ? 1 : 0)
        }
        return items.sorted { score($0) == score($1) ? $0.id < $1.id : score($0) > score($1) }
    }
}

enum JournalDay {
    struct Item: Identifiable {
        let id: String
        let letter: String
        let number: String
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .gmt
        formatter.dateFormat = format
        return formatter
    }

    static func date(_ day: String) -> Date {
        let parser = formatter("yyyy-MM-dd")
        parser.locale = Locale(identifier: "en_US_POSIX")
        return parser.date(from: day) ?? .distantPast
    }

    static func week(endingOn today: String) -> [Item] {
        let end = date(today)
        return (0..<7).reversed().map { offset in
            let value = end.addingTimeInterval(Double(-offset) * 86400)
            return Item(id: JournalCoding.day(value, timezone: "UTC"),
                        letter: String(formatter("EEEEE").string(from: value)),
                        number: formatter("d").string(from: value))
        }
    }

    static func title(_ day: String, today: String) -> String {
        if day == today { return "Today" }
        if day == JournalCoding.day(date(today).addingTimeInterval(-86400), timezone: "UTC") { return "Yesterday" }
        return formatter("EEE d MMM").string(from: date(day))
    }

    static func longTitle(_ day: String) -> String { formatter("EEEE d MMMM").string(from: date(day)) }
    static func dayNumber(_ day: String) -> String { formatter("d").string(from: date(day)) }
    static func monthTitle(_ day: String) -> String { formatter("MMMM yyyy").string(from: date(day)) }
    static func previous(_ day: String) -> String { JournalCoding.day(date(day).addingTimeInterval(-86400), timezone: "UTC") }
    static func next(_ day: String) -> String { JournalCoding.day(date(day).addingTimeInterval(86400), timezone: "UTC") }
    static func monthStart(_ day: String) -> String { String(day.prefix(8)) + "01" }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    static func shiftMonth(_ day: String, by months: Int) -> String {
        let moved = utcCalendar.date(byAdding: .month, value: months, to: date(monthStart(day))) ?? date(day)
        return JournalCoding.day(moved, timezone: "UTC")
    }

    static func weekdaySymbols(firstWeekday: Int) -> [String] {
        let symbols = formatter("EEEEE").veryShortStandaloneWeekdaySymbols ?? []
        guard symbols.count == 7 else { return symbols }
        return Array(symbols[(firstWeekday - 1)...] + symbols[..<(firstWeekday - 1)])
    }

    static func monthGrid(_ day: String, firstWeekday: Int) -> [String?] {
        let calendar = utcCalendar
        let start = date(monthStart(day))
        let count = calendar.range(of: .day, in: .month, for: start)?.count ?? 0
        let blanks = (calendar.component(.weekday, from: start) - firstWeekday + 7) % 7
        let days = (0..<count).map { JournalCoding.day(start.addingTimeInterval(Double($0) * 86400), timezone: "UTC") as String? }
        return Array(repeating: nil, count: blanks) + days
    }
}
