import Foundation

struct JournalStreak: Equatable {
    let current: Int
    let longest: Int
    let openDays: [String]

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
