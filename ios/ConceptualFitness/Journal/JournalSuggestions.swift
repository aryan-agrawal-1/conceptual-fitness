import Foundation

struct JournalSuggestion: Identifiable {
    let behaviour: JournalBehaviourData
    let reasons: [String]
    let score: Int
    var id: String { behaviour.id }
}

enum JournalSuggestions {
    // Fixed rules, independent of AI. These keywords also make free-form Profile goals useful.
    static let goalRules: [(words: [String], behaviours: Set<String>)] = [
        (["sleep", "circadian", "rest"], ["screen_in_bed", "worked_late", "night_shift", "sleep_mask", "caffeine"]),
        (["strength", "muscle", "exercise", "fitness", "recovery", "endurance"], ["energy", "muscle_soreness", "sauna", "stress"]),
        (["stress", "mental", "wellbeing", "well-being", "mood"], ["mood", "stress", "energy", "worked_late"]),
        (["weight", "nutrition", "health"], ["energy", "mood", "alcohol", "stress"])
    ]
    static let defaults: Set<String> = ["mood", "stress", "energy", "screen_in_bed", "worked_late"]

    static func rank(_ snapshot: JournalSnapshot, day: String) -> [JournalSuggestion] {
        guard let catalogue = snapshot.catalogue else { return [] }
        let enabled = Set(snapshot.preferences.filter(\.value).map(\.key))
        let goals = snapshot.goals.joined(separator: " ").lowercased()
        let relevant = goalRules.filter { rule in rule.words.contains { goals.contains($0) } }
            .reduce(into: Set<String>()) { $0.formUnion($1.behaviours) }
        let sensitive = Set(catalogue.categories.filter(\.requiresOptIn).map(\.id))
        let date = dayDate(day)
        let recentStart = JournalCoding.day(date.addingTimeInterval(-29 * 86400), timezone: "UTC")
        let recent = snapshot.entries.filter {
            !$0.deleted && $0.response?.answer != nil && $0.journalDate >= recentStart && $0.journalDate <= day
        }
        let deliberatelyUsed = Set(snapshot.entries.filter {
            !$0.deleted && $0.response?.answer != nil && $0.journalDate <= day
        }.map(\.behaviourId))
        let dayNumber = Int(date.timeIntervalSince1970 / 86400)
        let eligible = catalogue.behaviours.filter {
            $0.statisticalInput && (!sensitive.contains($0.categoryId)
                || (enabled.contains("opt_in:\($0.categoryId)") && deliberatelyUsed.contains($0.id)))
        }
        return eligible.enumerated().map { index, item in
            var reasons: [String] = []
            var score = 0
            if enabled.contains("pin:\(item.id)") { score += 1000; reasons.append("Pinned by you") }
            if defaults.contains(item.id) { score += 60; reasons.append("Everyday starting point") }
            if relevant.contains(item.id) { score += 80; reasons.append("Matches a Profile goal") }
            let observations = recent.filter { $0.behaviourId == item.id }
            if !observations.isEmpty {
                score += 20; reasons.append("Used in the last 30 days")
                let yesCount = observations.filter { $0.response?.answer?.value == .boolean(true) }.count
                let noCount = observations.filter { $0.response?.answer?.value == .boolean(false) }.count
                let needsVariation = item.answer.inputType == "boolean" && (yesCount < 3 || noCount < 3)
                if observations.count < 10 || needsVariation {
                    score += 30
                    reasons.append(observations.count < 10
                        ? "Building a record: \(observations.count)/10 recent entries"
                        : "More observations needed for comparisons")
                }
            }
            // Coprime daily offset rotates both unpinned and large pinned sets.
            score += (index * 17 + ((dayNumber % 79) + 79) % 79 * 31) % 79
            reasons.append("Daily rotation")
            return JournalSuggestion(behaviour: item, reasons: reasons, score: score)
        }.sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }.prefix(5).map { $0 }
    }

    private static func dayDate(_ day: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .gmt
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: day) ?? .distantPast
    }
}
