import Foundation

enum JournalDayStatus: Equatable {
    case completed, incomplete, missing, notStarted, upcoming
}

struct JournalDayIndex {
    let today: String
    private let answers: [String: Int]
    private let touched: Set<String>
    private let completions: Set<String>
    private let firstUse: String?

    init(_ snapshot: JournalSnapshot, today: String) {
        self.today = today
        var answers: [String: Int] = [:]
        var touched = Set<String>()
        for entry in snapshot.entries where !entry.deleted {
            touched.insert(entry.journalDate)
            if entry.response?.answer != nil { answers[entry.journalDate, default: 0] += 1 }
        }
        self.answers = answers
        self.touched = touched
        completions = Set(snapshot.completions.filter(\.completed).map(\.journalDate))
        firstUse = touched.min()
    }

    func answerCount(_ day: String) -> Int { answers[day] ?? 0 }

    func isCompleted(_ day: String) -> Bool {
        completions.contains(day) && JournalDailyList.reachedTarget(answerCount(day))
    }

    func status(_ day: String) -> JournalDayStatus {
        if day > today { return .upcoming }
        if isCompleted(day) { return .completed }
        if touched.contains(day) { return .incomplete }
        if day == today { return .notStarted }
        if let firstUse, day >= firstUse { return .missing }
        return .notStarted
    }

    func accessibilityValue(_ day: String) -> String {
        switch status(day) {
        case .completed: "Completed"
        case .incomplete: "Incomplete, \(answerCount(day)) of \(JournalDailyList.dailyTarget)"
        case .missing: "Missing"
        case .notStarted: "Not started"
        case .upcoming: "Upcoming"
        }
    }
}

struct JournalCheckInScreen {
    var pinned: [JournalBehaviourData] = []
    var privatePinned: [JournalDailySections.Section] = []
    var topUp: [JournalBehaviourData] = []
}

enum JournalCheckIn {
    static let promptFloorHour = 4

    static func screen(_ snapshot: JournalSnapshot, day: String) -> JournalCheckInScreen {
        let sections = JournalDailyList.sections(snapshot, day: day)
        let pinnedCount = sections.pinned.count + sections.privatePinned.reduce(0) { $0 + $1.behaviours.count }
        let missing = max(0, JournalDailyList.dailyTarget - pinnedCount)
        return JournalCheckInScreen(pinned: sections.pinned, privatePinned: sections.privatePinned,
                                    topUp: Array(sections.others.prefix(missing)))
    }

    static func isDue(_ snapshot: JournalSnapshot, now: Date = Date(), onboardedAt: Date? = nil) -> Bool {
        guard snapshot.catalogue != nil, let timezone = snapshot.timezone,
              let zone = TimeZone(identifier: timezone) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard calendar.component(.hour, from: now) >= promptFloorHour else { return false }
        let today = JournalCoding.day(now, timezone: timezone)
        if let onboardedAt, JournalCoding.day(onboardedAt, timezone: timezone) == today { return false }
        return !JournalDayIndex(snapshot, today: today).isCompleted(JournalDay.previous(today))
    }

    static func shouldPrompt(_ snapshot: JournalSnapshot, now: Date = Date(), onboardedAt: Date? = nil,
                             lastPromptDay: String?) -> Bool {
        guard isDue(snapshot, now: now, onboardedAt: onboardedAt), let timezone = snapshot.timezone else { return false }
        return lastPromptDay != JournalCoding.day(now, timezone: timezone)
    }

    static func reminderTarget(_ snapshot: JournalSnapshot, today: String) -> String {
        let yesterday = JournalDay.previous(today)
        return JournalDayIndex(snapshot, today: today).isCompleted(yesterday) ? today : yesterday
    }

    static func isLate(_ completion: JournalCompletionData) -> Bool {
        let first = JournalCoding.day(JournalCoding.instant(completion.firstCompletedAt), timezone: completion.timezone)
        return first > JournalDay.next(completion.journalDate)
    }
}
