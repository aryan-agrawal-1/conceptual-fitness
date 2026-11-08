import Foundation

enum PatternState: String, Decodable, CaseIterable {
    case consistent
    case possible
    case earlySignal = "early_signal"
    case inconclusive
    case neutral
    case overlapping
    case insufficientVariation = "insufficient_variation"
    case collecting
    case held

    var isFinding: Bool { [.consistent, .possible, .earlySignal].contains(self) }
    var isChecked: Bool { isFinding || self == .neutral || self == .inconclusive }

    var symbol: String {
        switch self {
        case .consistent: "checkmark.seal.fill"
        case .possible: "circle.lefthalf.filled"
        case .earlySignal: "sparkle"
        case .inconclusive: "questionmark.circle"
        case .neutral: "equal.circle"
        case .overlapping: "square.on.square"
        case .insufficientVariation: "minus.circle"
        case .collecting: "hourglass"
        case .held: "pause.circle"
        }
    }
}

struct PatternsResponse: Decodable, Equatable {
    let status: String
    let run: PatternRun?
    let stories: [PatternStory]
    let newFindings: Int
    var generalNote: String? = nil
}

struct PatternRun: Decodable, Equatable {
    let id: String
    let windowStart: String
    let windowEnd: String
    let trackingDay: Int
    let checkpointDay: Int?
    let nextCheckpointDay: Int
    let completedAt: String?
    let current: Bool
    let lastAttemptFailed: Bool
}

struct PatternStory: Decodable, Equatable, Identifiable {
    let id: String
    let inputId: String
    let stratum: String
    let title: String
    let tier: String
    let state: PatternState
    let stateLabel: String
    let headline: String
    let findings: [PatternFinding]
    let unseen: Bool
    let neverLogged: Bool
    var safetyNote: String? = nil
}

struct PatternFinding: Decodable, Equatable, Identifiable {
    let pairId: String
    let stratum: String
    let outcomeId: String
    let outcomeLabel: String
    let outcomeShortLabel: String
    let group: PatternGroup
    let impact: PatternImpact?
    let tier: String
    let state: PatternState
    let stateLabel: String
    let summary: String
    let effects: [PatternEffect]
    let needs: String?
    let sample: PatternSample
    let window: PatternWindow
    let adjustments: [String]
    let limitations: [String]
    let unseen: Bool
    let neverLogged: Bool
    let testable: Bool?

    var id: String { "\(pairId)/\(stratum)" }
}

struct PatternEffect: Decodable, Equatable {
    let term: String
    let value: Double
    let low: Double
    let high: Double
    let unit: String
    let per: String
    let percent: Double?
    let text: String?
    let rangeText: String
}

enum PatternGroup: String, Decodable, CaseIterable, Identifiable {
    case sleep
    case recovery
    case feel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sleep: "Sleep"
        case .recovery: "Recovery"
        case .feel: "How you feel"
        }
    }

    var noun: String {
        switch self {
        case .sleep: "your sleep"
        case .recovery: "your recovery"
        case .feel: "how you feel"
        }
    }
}

struct PatternImpact: Decodable, Equatable {
    let percent: Double
    let low: Double?
    let high: Double?
    let caption: String?
    let benefit: String
    let better: Int

    var helps: Bool { benefit == "helps" }
    var isNeutral: Bool { benefit == "none" }

    func scaled(_ value: Double) -> Double { value * Double(better) }

    var reach: Double {
        [percent, low ?? percent, high ?? percent].map(abs).max() ?? 0
    }

    var percentText: String {
        let size = abs(percent)
        let sign = percent < 0 ? "−" : "+"
        if isNeutral { return "≈0%" }
        if size < 1 { return "\(sign)<1%" }
        return "\(sign)\(Int(size.rounded()))%"
    }
}

struct PatternImpactRow: Identifiable, Equatable {
    let story: PatternStory
    let finding: PatternFinding
    let impact: PatternImpact

    var id: String { finding.id }
}

struct PatternImpactCard: Identifiable, Equatable {
    let story: PatternStory
    let rows: [PatternImpactRow]

    var id: String { story.id }
    var findings: [PatternImpactRow] { rows.filter { $0.finding.state.isFinding && !$0.impact.isNeutral } }
    var isNeutral: Bool { findings.isEmpty }

    var lead: PatternImpactRow {
        findings.max { abs($0.impact.percent) < abs($1.impact.percent) } ?? rows[0]
    }

    var subtitle: String? {
        let state = lead.finding.state.isFinding ? lead.finding.state.shortLabel : nil
        let parts = [lead.impact.caption?.capitalizedFirstLetter, state].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct PatternBoard: Equatable {
    let group: PatternGroup
    let cards: [PatternImpactCard]
    let neutral: [PatternImpactCard]

    init(_ stories: [PatternStory], group: PatternGroup) {
        self.group = group
        let all = stories.compactMap { story -> PatternImpactCard? in
            let rows = story.findings.compactMap { finding -> PatternImpactRow? in
                guard finding.group == group, let impact = finding.impact else { return nil }
                return PatternImpactRow(story: story, finding: finding, impact: impact)
            }
            return rows.isEmpty ? nil : PatternImpactCard(story: story, rows: rows)
        }
        cards = all.filter { !$0.isNeutral }
            .sorted { $0.lead.impact.scaled($0.lead.impact.percent) > $1.lead.impact.scaled($1.lead.impact.percent) }
        neutral = all.filter(\.isNeutral).sorted { $0.story.title < $1.story.title }
    }

    var rows: [PatternImpactRow] { cards.flatMap(\.findings) }

    var reach: Double {
        let largest = (cards + neutral).flatMap(\.rows).map(\.impact.reach).max() ?? 0
        return [5.0, 8, 10, 15, 20, 30, 50, 100].first { $0 >= largest } ?? 100
    }

    var strongest: PatternImpactRow? {
        rows.max { abs($0.impact.percent) < abs($1.impact.percent) }
    }

    static func preferredGroup(_ stories: [PatternStory]) -> PatternGroup {
        PatternGroup.allCases.first { !PatternBoard(stories, group: $0).cards.isEmpty } ?? .sleep
    }
}

private extension String {
    var capitalizedFirstLetter: String { prefix(1).uppercased() + dropFirst() }
}

struct PatternSample: Decodable, Equatable {
    let exposedDays: Int
    let comparisonDays: Int
    let exposedLabel: String
    let comparisonLabel: String
    let excluded: [PatternExclusion]
}

struct PatternExclusion: Decodable, Equatable {
    let reason: String
    let text: String
    let days: Int
}

struct PatternWindow: Decodable, Equatable {
    let start: String
    let end: String
}

struct PatternSeenKey: Encodable, Equatable, Hashable {
    let pairId: String
    let stratum: String
}

struct PatternSeenRequest: Encodable {
    let patterns: [PatternSeenKey]
}

struct PatternSections: Equatable {
    let findings: [PatternStory]
    let checked: [PatternStory]
    let waiting: [PatternStory]
    let notLogged: [PatternStory]

    init(_ stories: [PatternStory]) {
        findings = stories.filter { $0.state.isFinding }
        checked = stories.filter { !$0.state.isFinding && $0.state.isChecked }
        let rest = stories.filter { !$0.state.isChecked }
        waiting = rest.filter { !$0.neverLogged }
        notLogged = rest.filter(\.neverLogged)
    }
}

enum PatternDates {
    static func display(_ iso: String) -> String {
        let parser = DateFormatter()
        parser.calendar = Calendar(identifier: .gregorian)
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = .gmt
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: String(iso.prefix(10))) else { return iso }
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
        style.timeZone = .gmt
        return date.formatted(style)
    }

    static func updated(_ iso: String?, today: Date = .now) -> String {
        guard let iso else { return "Not updated yet" }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .gmt
        formatter.dateFormat = "yyyy-MM-dd"
        let day = String(iso.prefix(10))
        if day == formatter.string(from: today) { return "Updated today" }
        if let yesterday = Calendar(identifier: .gregorian).date(byAdding: .day, value: -1, to: today),
           day == formatter.string(from: yesterday) { return "Updated yesterday" }
        return "Updated \(display(day))"
    }

    static func range(_ window: PatternWindow) -> String {
        "\(display(window.start)) – \(display(window.end))"
    }
}
