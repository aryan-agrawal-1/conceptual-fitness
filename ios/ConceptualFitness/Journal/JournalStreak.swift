import Foundation

struct JournalStreak: Equatable {
    let current: Int
    let longest: Int
    let openDays: [String]
    let endsTonight: Bool

    init(_ completions: [JournalCompletionData], today: String) {
        let earned = Set(completions.filter { !JournalCheckIn.isLate($0) }.map(\.journalDate))
        let late = Set(completions.filter(JournalCheckIn.isLate).map(\.journalDate))
        let yesterday = JournalDay.previous(today)

        var count = 0
        var day = max(today, earned.max() ?? today)
        while earned.contains(day) || (day >= yesterday && !late.contains(day)) {
            if earned.contains(day) { count += 1 }
            day = JournalDay.previous(day)
        }

        var longestRun = 0
        var run = 0
        var previous: String?
        for day in earned.sorted() {
            run = previous.map(JournalDay.next) == day ? run + 1 : 1
            longestRun = max(longestRun, run)
            previous = day
        }

        current = count
        longest = max(longestRun, count)
        openDays = [yesterday, today].filter { !earned.contains($0) && !late.contains($0) }
        endsTonight = openDays.contains(yesterday) && count > (earned.contains(today) ? 1 : 0)
    }

    static func dayNote(day: String, today: String, completion: JournalCompletionData?, isCompleted: Bool) -> String? {
        let late = completion.map(JournalCheckIn.isLate) == true
        if isCompleted {
            return late ? "Completed after its deadline, so this day doesn’t count toward your streak." : nil
        }
        if completion != nil {
            let streakEffect = late ? "It doesn’t count toward your streak." : "Your streak isn’t affected."
            return "This day fell below five answers. Complete it again when you’re ready. \(streakEffect)"
        }
        guard day < JournalDay.previous(today) else { return nil }
        return "You’re editing a past day. Completing it now won’t restore a streak."
    }
}

struct JournalStreakSummary: Equatable {
    struct Action: Equatable {
        let day: String
        let title: String
        let progress: String?
    }

    let count: Int
    let message: String
    let answeredToday: Int
    let action: Action?

    init(_ snapshot: JournalSnapshot, today: String, onboardedAt: Date? = nil) {
        let index = JournalDayIndex(snapshot, today: today)
        let streak = JournalStreak(snapshot.completions, today: today)
        let yesterday = JournalDay.previous(today)
        let target = JournalDailyList.dailyTarget
        let answered = index.answerCount(today)
        let onboardedToday = snapshot.timezone.flatMap { timezone in
            onboardedAt.map { JournalCoding.day($0, timezone: timezone) == today }
        } ?? false

        let action: Action?
        if !onboardedToday && !index.isCompleted(yesterday) {
            action = Action(day: yesterday, title: "Check in for yesterday",
                            progress: "\(index.answerCount(yesterday)) of \(target)")
        } else if index.isCompleted(today) {
            action = nil
        } else {
            let title = JournalDailyList.reachedTarget(answered) ? "Complete check-in"
                : answered > 0 ? "Continue check-in" : "Start check-in"
            action = Action(day: today, title: title, progress: nil)
        }

        count = streak.current
        answeredToday = min(answered, target)
        self.action = action
        if streak.endsTonight {
            message = "Your \(streak.current)-day streak ends at midnight. Don’t lose it!"
        } else if streak.current == 0 {
            message = "Check in to start a new streak."
        } else if action?.day == yesterday && streak.openDays.contains(yesterday) {
            message = "Yesterday still counts until midnight."
        } else if index.isCompleted(today) {
            message = "You’re on fire. See you tomorrow."
        } else {
            message = "Don’t lose your \(streak.current)-day streak. Check in today."
        }
    }
}
