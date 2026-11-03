import Foundation

enum JournalAIConsumer: String, CaseIterable {
    case dailyBrief = "daily_brief"
    case coach

    var consentKey: String { "ai_context:\(rawValue):reflection" }
}

struct JournalAINote: Equatable {
    let journalDate: String
    let text: String
}

enum JournalAIContext {
    private static let categoryId = "reflection"

    static func canRead(_ consumer: JournalAIConsumer, in snapshot: JournalSnapshot) -> Bool {
        let enabled = Set(snapshot.preferences.filter(\.value).map(\.key))
        return enabled.contains("opt_in:\(categoryId)") && enabled.contains(consumer.consentKey)
    }

    static func notes(for consumer: JournalAIConsumer, in snapshot: JournalSnapshot, limit: Int) -> [JournalAINote] {
        guard canRead(consumer, in: snapshot), let catalogue = snapshot.catalogue else { return [] }
        let behaviours = Set(catalogue.behaviours.filter { $0.categoryId == categoryId }.map(\.id))
        let notes = snapshot.entries.compactMap { entry -> JournalAINote? in
            guard !entry.deleted, behaviours.contains(entry.behaviourId),
                  case .text(let text)? = entry.response?.answer?.value else { return nil }
            return JournalAINote(journalDate: entry.journalDate, text: text)
        }
        return Array(notes.sorted { $0.journalDate > $1.journalDate }.prefix(limit))
    }
}
