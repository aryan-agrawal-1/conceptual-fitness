import Foundation

struct ExperimentResponse: Decodable, Equatable {
    let experiment: Experiment?
}

struct Experiment: Decodable, Equatable, Identifiable {
    let id: String
    let behaviourId: String
    let inputId: String
    let pairId: String
    let stratum: String
    let outcomeId: String
    let outcomeLabel: String
    let title: String
    let changeText: String
    let usualText: String
    let status: String
    let startDate: String
    let endDate: String
    let resultDate: String
    let today: ExperimentDay?
    let days: [ExperimentDay]
    let adherence: ExperimentAdherence
    let result: ExperimentResult?
    var offTrack: ExperimentOffTrack? = nil

    var isActive: Bool { status == "active" }
    var isOffTrack: Bool { status == "off_track" }
    var hasStarted: Bool { today != nil }

    func plan(on day: String) -> ExperimentDay? {
        guard isActive else { return nil }
        return days.first { $0.date == day }
    }

    var statusText: String {
        switch status {
        case "completed": "Finished"
        case "stopped": "Stopped"
        case "off_track": "Off track"
        default:
            if let today { "Day \(today.dayNumber) of \(days.count)" } else { "Starts \(JournalDay.longTitle(startDate))" }
        }
    }
}

struct ExperimentDay: Decodable, Equatable, Identifiable {
    let date: String
    let dayNumber: Int
    let week: Int
    let kind: String
    let washout: Bool
    let plan: String

    var id: String { date }
    var isChange: Bool { kind == "change" }
}

struct ExperimentAdherence: Decodable, Equatable {
    let changeDays: Int
    let loggedDays: Int
    let followedDays: Int
}

struct ExperimentResult: Decodable, Equatable {
    let status: String
    let changeDays: Int
    let usualDays: Int
    let minimumDays: Int
    let difference: Double?
    let unit: String
    let benefit: String?
    let summary: String
    let adherenceText: String?
    let notes: [String]

    var isReady: Bool { status == "ready" && difference != nil }
}

struct ExperimentOffTrack: Decodable, Equatable {
    let date: String?
    let summary: String
    let restartText: String
}

struct ExperimentStartRequest: Encodable {
    let pairId: String
    let stratum: String
    var behaviourId: String? = nil
}

struct ExperimentSetupResponse: Decodable, Equatable {
    let setup: ExperimentSetup
}

struct ExperimentSetup: Decodable, Equatable {
    let pairId: String
    let stratum: String
    let inputId: String
    let outcomeLabel: String
    let usual: ExperimentUsual
    let options: [ExperimentOption]
    let startDate: String
    let endDate: String
    let resultDate: String
    let weeks: Int
    let washoutDays: Int
    let safetyNote: String?
}

struct ExperimentUsual: Decodable, Equatable {
    let loggedDays: Int
    let lines: [String]
    let basis: String?
}

struct ExperimentOption: Decodable, Equatable, Identifiable {
    let id: String
    let title: String
    let changeText: String
    let detail: String
}

extension PatternStory {
    var testableFinding: PatternFinding? {
        findings.first { $0.testable == true }
    }
}

enum ExperimentPin {
    static func behaviour(_ experiment: Experiment?, snapshot: JournalSnapshot,
                          day: String) -> (plan: ExperimentDay, behaviour: JournalBehaviourData)? {
        guard let experiment, let plan = experiment.plan(on: day) else { return nil }
        let sections = JournalDailyList.sections(snapshot, day: day)
        let available = sections.pinned + sections.privatePinned.flatMap(\.behaviours) + sections.others
        guard let behaviour = available.first(where: { $0.id == experiment.inputId }) else { return nil }
        return (plan, behaviour)
    }

    static func screen(_ screen: JournalCheckInScreen, removing id: String) -> JournalCheckInScreen {
        JournalCheckInScreen(
            pinned: screen.pinned.filter { $0.id != id },
            privatePinned: screen.privatePinned.compactMap { section in
                let rows = section.behaviours.filter { $0.id != id }
                return rows.isEmpty ? nil : .init(id: section.id, title: section.title, behaviours: rows)
            },
            topUp: screen.topUp.filter { $0.id != id }
        )
    }
}
