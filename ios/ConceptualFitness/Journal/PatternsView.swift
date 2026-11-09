import SwiftUI

enum InsightsSegment: String, CaseIterable, Identifiable {
    case journal = "Journal"
    case patterns = "Patterns"

    var id: String { rawValue }
}

struct InsightsSegmentPicker: View {
    @Binding var selection: InsightsSegment
    var newFindings: Int

    var body: some View {
        Picker("Insights view", selection: $selection) {
            ForEach(InsightsSegment.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 220)
        .accessibilityIdentifier("insights.segment")
        .accessibilityValue(newFindings > 0 ? "\(newFindings) new patterns" : "")
    }
}

struct InsightsView: View {
    @ObservedObject var journal: JournalStore
    @ObservedObject var reminders: JournalReminders
    @ObservedObject var patterns: PatternsStore
    var onboardedAt: Date?
    @State private var segment = InsightsSegment.journal

    init(journal: JournalStore, reminders: JournalReminders, patterns: PatternsStore, onboardedAt: Date?) {
        self.journal = journal
        self.reminders = reminders
        self.patterns = patterns
        self.onboardedAt = onboardedAt
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-OpenPatterns") {
            _segment = State(initialValue: .patterns)
        }
        #endif
    }

    var body: some View {
        Group {
            switch segment {
            case .journal:
                JournalView(store: journal, reminders: reminders, onboardedAt: onboardedAt, segment: $segment,
                            patterns: patterns)
            case .patterns:
                PatternsView(store: patterns, segment: $segment)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if #available(iOS 26.0, *) {
                segmentItem.sharedBackgroundVisibility(.hidden)
            } else {
                segmentItem
            }
        }
        .task { await patterns.load() }
    }

    private var segmentItem: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            InsightsSegmentPicker(selection: $segment, newFindings: patterns.newFindings)
        }
    }
}

struct PatternsBanner: View {
    let count: Int
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.title3)
                    .foregroundStyle(HealthTheme.color(for: .activity))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(count == 1 ? "1 new pattern" : "\(count) new patterns")
                        .font(.subheadline.weight(.semibold))
                    Text("From your latest check of how your inputs line up with sleep and recovery.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .panelSurface(cornerRadius: 22)
        .accessibilityHint("Opens Patterns")
        .accessibilityIdentifier("journal.patternsBanner")
    }
}

struct PatternsView: View {
    @ObservedObject var store: PatternsStore
    @Binding var segment: InsightsSegment
    @State private var group: PatternGroup?
    @State private var heroBehindToolbar = true

    private var ready: (PatternsResponse, PatternRun)? {
        guard let response = store.response, response.status == "ready", let run = response.run else { return nil }
        return (response, run)
    }

    private var selectedGroup: Binding<PatternGroup> {
        Binding {
            group ?? PatternBoard.preferredGroup(store.response?.stories ?? [])
        } set: { group = $0 }
    }

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    hero
                        .onGeometryChange(for: Bool.self) { $0.frame(in: .global).maxY > 162 } action: {
                            heroBehindToolbar = $0
                        }
                    content
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .modifier(PatternsScrollEdge(hidden: heroBehindToolbar))
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .refreshable { await store.load() }
        .task { await store.load() }
    }

    private var hero: some View {
        let board = ready.map { PatternBoard($0.0.stories, group: selectedGroup.wrappedValue) }
        let unseen = Set((ready?.0.stories ?? []).flatMap(\.findings)
            .filter { $0.unseen && $0.state.isFinding && store.isUnreported($0) }.map(\.group))
        return PatternsHero(run: ready?.1, board: board, group: selectedGroup, unseenGroups: unseen,
                            message: heroMessage)
    }

    private var heroMessage: String? {
        if ready != nil { return nil }
        if let response = store.response {
            switch response.status {
            case "running": return "Your first patterns are being worked out. Pull down to refresh in a minute."
            case "failed": return "The last check didn’t finish. It will run again automatically."
            default: return "After 30 days of logging, you’ll see what lines up with your sleep, recovery and how you feel."
            }
        }
        if store.phase == .failed { return "Patterns aren’t available right now. Your journal still works offline." }
        return "Loading your patterns…"
    }

    @ViewBuilder private var content: some View {
        if let (response, run) = ready {
            if store.refreshFailed || !run.current || run.lastAttemptFailed {
                PatternsStatusNote(run: run, refreshFailed: store.refreshFailed) {
                    Task { await store.load() }
                }
            }
            ExperimentSummaryCard()
            board(PatternBoard(response.stories, group: selectedGroup.wrappedValue), run: run,
                  note: response.generalNote)
            library(response.stories)
        } else if let response = store.response {
            if response.status == "failed" {
                retryButton
            } else if response.status != "running" {
                Button("Go to Journal") { segment = .journal }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
                    .padding(.horizontal, 4)
            }
        } else if store.phase == .failed {
            retryButton
        } else {
            ProgressView().frame(maxWidth: .infinity, minHeight: 120)
        }
    }

    private var retryButton: some View {
        Button("Retry") { Task { await store.load() } }
            .font(.subheadline.weight(.semibold))
            .frame(minHeight: 44)
            .padding(.horizontal, 4)
            .accessibilityIdentifier("patterns.retry")
    }

    @ViewBuilder private func board(_ board: PatternBoard, run: PatternRun, note: String?) -> some View {
        if board.cards.isEmpty && board.neutral.isEmpty {
            Text("No links with \(board.group.noun) yet. The next check is on day \(run.nextCheckpointDay).")
                .font(.subheadline).foregroundStyle(.secondary)
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .panelSurface(cornerRadius: 22)
        } else {
            PatternImpactHeader()
            ForEach(board.cards) { card in
                link(card, reach: board.reach)
                    .onAppear { Task { await store.markSeen(card.rows.map(\.finding)) } }
            }
            if !board.neutral.isEmpty {
                JournalSectionTitle(title: "No clear link")
                VStack(spacing: 0) {
                    ForEach(Array(board.neutral.enumerated()), id: \.element.id) { index, card in
                        if index > 0 { Divider().padding(.leading, 16) }
                        NavigationLink {
                            PatternStoryView(story: card.story, run: store.response?.run, group: board.group)
                        } label: {
                            PatternNeutralRow(card: card)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("patterns.neutral.\(card.id)")
                    }
                }
                .panelSurface(cornerRadius: 22)
            }
        }
        Text([note, "Associations in your own data, not proof of cause. Tap a row for the details."]
            .compactMap { $0 }.joined(separator: " "))
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }

    private func link(_ card: PatternImpactCard, reach: Double) -> some View {
        NavigationLink {
            PatternStoryView(story: card.story, run: store.response?.run, group: selectedGroup.wrappedValue)
        } label: {
            PatternImpactCardView(card: card, reach: reach,
                                  isNew: card.rows.contains { $0.finding.unseen && store.isUnreported($0.finding) })
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("patterns.card.\(card.id)")
    }

    private func library(_ stories: [PatternStory]) -> some View {
        let sections = PatternSections(stories)
        let parts = [
            sections.waiting.isEmpty ? nil : "\(sections.waiting.count) still collecting",
            sections.notLogged.isEmpty ? nil : "\(sections.notLogged.count) not logged yet",
        ].compactMap { $0 }
        return NavigationLink {
            PatternsLibraryView(store: store)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "square.grid.2x2")
                    .font(.title3)
                    .foregroundStyle(HealthTheme.color(for: .activity))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("All inputs").font(.subheadline.weight(.semibold))
                    Text(parts.isEmpty ? "Every input and where it stands" : parts.joined(separator: " · "))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .panelSurface(cornerRadius: 22)
        .padding(.top, 8)
        .accessibilityIdentifier("patterns.library")
    }
}

private struct PatternsScrollEdge: ViewModifier {
    let hidden: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectHidden(hidden, for: .top)
        } else {
            content
        }
    }
}

extension PatternImpact {
    var tint: Color {
        if isNeutral { return HealthTheme.color(for: .neutral) }
        if isUnrated { return Color.secondary }
        return helps ? Self.helpsTint : Self.hurtsTint
    }

    static var helpsTint: Color { HealthTheme.color(for: .positive) }
    static var hurtsTint: Color { HealthTheme.color(for: .risk) }
}

struct PatternImpactHeader: View {
    var body: some View {
        HStack {
            tag("Hurts", symbol: "arrowtriangle.down.fill", tint: PatternImpact.hurtsTint)
            Spacer()
            Text("% vs usual").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            tag("Helps", symbol: "arrowtriangle.up.fill", tint: PatternImpact.helpsTint)
        }
        .padding(.top, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Bars to the left go with a worse value than usual, bars to the right with a better one.")
    }

    private func tag(_ text: String, symbol: String, tint: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.footnote.weight(.semibold))
            .labelStyle(PatternTagLabelStyle())
            .foregroundStyle(tint)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

private struct PatternTagLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 8, weight: .bold))
            configuration.title
        }
    }
}

struct PatternImpactCardView: View {
    let card: PatternImpactCard
    let reach: Double
    let isNew: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(card.story.title).font(.headline)
                    if isNew { PatternTag(text: "New", prominent: true) }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                if let subtitle = card.subtitle {
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary)
                }
            }
            ForEach(card.rows) { row in
                VStack(spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.finding.outcomeShortLabel).font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Text(row.impact.percentText)
                            .font(.headline.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(row.impact.tint)
                    }
                    PatternImpactBar(impact: row.impact, reach: reach, early: row.finding.state == .earlySignal)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityText(row))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface(cornerRadius: 22)
        .accessibilityElement(children: .contain)
        .accessibilityLabel([isNew ? "New" : nil, card.story.title, card.subtitle].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Shows what this is based on and its limitations")
    }

    private func accessibilityText(_ row: PatternImpactRow) -> String {
        let size = Int(abs(row.impact.percent).rounded())
        let change = row.impact.isNeutral ? "no clear change"
            : "\(size) percent \(row.impact.percent < 0 ? "lower" : "higher") than usual\(verdict(row.impact))"
        return "\(row.finding.outcomeShortLabel), \(change)"
    }

    private func verdict(_ impact: PatternImpact) -> String {
        if impact.isUnrated { return "" }
        return impact.helps ? ", better" : ", worse"
    }
}

struct PatternNeutralRow: View {
    let card: PatternImpactCard

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "equal.circle")
                .foregroundStyle(HealthTheme.color(for: .neutral))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.story.title).font(.subheadline.weight(.semibold))
                Text(card.rows.map(\.finding.outcomeShortLabel).joined(separator: " · "))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("No clear link was seen. Shows the details")
    }
}

struct PatternImpactBar: View {
    let impact: PatternImpact
    let reach: Double
    let early: Bool
    var showsRange = false

    private static let tickWidth: CGFloat = 3
    private static let pitch: CGFloat = 7
    private static let height: CGFloat = 16

    var body: some View {
        Canvas { context, size in
            let sides = max(Int((size.width / 2 - Self.tickWidth) / Self.pitch), 4)
            let middle = size.width / 2
            let filled = steps(impact.scaled(impact.percent), sides: sides)
            let range = showsRange ? rangeSteps(sides: sides) : nil
            for offset in -sides...sides {
                let x = middle + CGFloat(offset) * Self.pitch - Self.tickWidth / 2
                let center = offset == 0
                let tall = center ? Self.height : Self.height * 0.7
                let rect = CGRect(x: x, y: (Self.height - tall) / 2, width: Self.tickWidth, height: tall)
                context.fill(Path(roundedRect: rect, cornerRadius: Self.tickWidth / 2),
                             with: .color(color(offset: offset, filled: filled, range: range)))
            }
        }
        .frame(height: Self.height)
        .accessibilityHidden(true)
    }

    private func steps(_ value: Double, sides: Int) -> Int {
        guard !impact.isNeutral, value != 0 else { return 0 }
        let share = min(abs(value) / reach, 1)
        let count = max(Int((share * Double(sides)).rounded()), 1)
        return value > 0 ? count : -count
    }

    private func rangeSteps(sides: Int) -> ClosedRange<Int>? {
        guard let low = impact.low, let high = impact.high else { return nil }
        let edges = [impact.scaled(low), impact.scaled(high)].map { value -> Int in
            let share = min(max(value / reach, -1), 1)
            return Int((share * Double(sides)).rounded())
        }.sorted()
        return edges[0]...edges[1]
    }

    private func color(offset: Int, filled: Int, range: ClosedRange<Int>?) -> Color {
        if offset == 0 { return impact.isNeutral ? HealthTheme.color(for: .neutral) : Color.primary.opacity(0.55) }
        let lit = filled > 0 ? (offset > 0 && offset <= filled) : (offset < 0 && offset >= filled)
        if lit { return impact.tint.opacity(early ? 0.55 : 1) }
        if let range, range.contains(offset) { return impact.tint.opacity(0.22) }
        return Color.primary.opacity(0.1)
    }
}

struct PatternsLibraryView: View {
    @ObservedObject var store: PatternsStore
    @State private var waitingExpanded = false
    @State private var notLoggedExpanded = false

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let stories = store.response?.stories {
                        sections(PatternSections(stories))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .navigationTitle("All inputs")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func sections(_ sections: PatternSections) -> some View {
        if !sections.findings.isEmpty {
            JournalSectionTitle(title: "Patterns")
            ForEach(sections.findings) { link($0) }
        }
        if !sections.checked.isEmpty {
            JournalSectionTitle(title: "Checked, no clear link")
            ForEach(sections.checked) { link($0) }
        }
        if !sections.waiting.isEmpty {
            disclosure(title: "Still collecting", count: sections.waiting.count, expanded: $waitingExpanded)
            if waitingExpanded { ForEach(sections.waiting) { link($0) } }
        }
        if !sections.notLogged.isEmpty {
            disclosure(title: "Not logged yet", count: sections.notLogged.count, expanded: $notLoggedExpanded)
            if notLoggedExpanded { ForEach(sections.notLogged) { link($0) } }
        }
    }

    private func link(_ story: PatternStory) -> some View {
        NavigationLink {
            PatternStoryView(story: story, run: store.response?.run)
        } label: {
            PatternStoryCard(story: story)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("patterns.story.\(story.id)")
    }

    private func disclosure(title: String, count: Int, expanded: Binding<Bool>) -> some View {
        Button {
            withAnimation(.snappy) { expanded.wrappedValue.toggle() }
        } label: {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                    .foregroundStyle(HealthTheme.color(for: .activity))
                Spacer()
                Text("\(count)").font(.footnote).foregroundStyle(.secondary)
                Image(systemName: expanded.wrappedValue ? "chevron.up" : "chevron.down")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(expanded.wrappedValue ? "Expanded" : "Collapsed")
    }
}

struct PatternsStatusNote: View {
    let run: PatternRun
    let refreshFailed: Bool
    let retry: () -> Void

    private var message: String {
        if refreshFailed { return "Couldn’t refresh. Showing the results you last loaded." }
        if run.lastAttemptFailed { return "The latest check didn’t finish. Showing the previous results." }
        return "Recent journal changes are still being checked."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message).font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("patterns.status")
            if refreshFailed || run.lastAttemptFailed {
                Button("Retry", action: retry).font(.caption.weight(.semibold)).frame(minHeight: 44)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, refreshFailed || run.lastAttemptFailed ? 0 : 10)
        .padding(.top, refreshFailed || run.lastAttemptFailed ? 8 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct PatternStateBadge: View {
    let state: PatternState
    let label: String

    private var tint: Color {
        switch state {
        case .consistent, .possible, .earlySignal: HealthTheme.color(for: .activity)
        default: HealthTheme.color(for: .neutral)
        }
    }

    var body: some View {
        Label(label, systemImage: state.symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(tint.opacity(state == .consistent ? 0.18 : 0.1), in: Capsule())
    }
}

struct PatternTag: View {
    let text: String
    var prominent = false

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(prominent ? .white : .secondary)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(prominent ? AnyShapeStyle(HealthTheme.color(for: .activity)) : AnyShapeStyle(.thinMaterial),
                        in: Capsule())
    }
}

struct PatternStoryCard: View {
    let story: PatternStory

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(story.title).font(.headline)
                if story.unseen { PatternTag(text: "New", prominent: true) }
                if story.tier == "exploratory" { PatternTag(text: "Exploratory") }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            PatternStateBadge(state: story.state, label: story.stateLabel)
            Text(story.headline).font(.subheadline).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            let others = story.findings.filter { $0.state.isFinding }.count - (story.state.isFinding ? 1 : 0)
            if others > 0 {
                Text(others == 1 ? "1 more linked outcome" : "\(others) more linked outcomes")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface(cornerRadius: 22)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows the days used, the range and the limitations")
    }
}

struct PatternStoryView: View {
    let story: PatternStory
    let run: PatternRun?
    var group: PatternGroup?
    @State private var heroBehindToolbar = true

    private var lead: PatternFinding {
        story.findings.filter { $0.state.isFinding && $0.impact != nil }
            .max { abs($0.impact?.percent ?? 0) < abs($1.impact?.percent ?? 0) } ?? story.findings[0]
    }

    private var groups: [(PatternGroup, [(title: String, finding: PatternFinding)])] {
        let order = PatternGroup.allCases.sorted { ($0 == group ? 0 : 1) < ($1 == group ? 0 : 1) }
        return order.compactMap { group in
            let findings = story.findings.filter { $0.group == group }.sorted { rank($0) < rank($1) }
            return findings.isEmpty ? nil : (group, merged(findings))
        }
    }

    private func merged(_ findings: [PatternFinding]) -> [(title: String, finding: PatternFinding)] {
        var items: [(title: String, finding: PatternFinding)] = []
        for finding in findings {
            if finding.impact == nil, let index = items.firstIndex(where: {
                $0.finding.impact == nil && $0.finding.state == finding.state && $0.finding.needs == finding.needs
            }) {
                items[index].title += ", " + finding.outcomeShortLabel
            } else {
                items.append((finding.outcomeShortLabel, finding))
            }
        }
        return items
    }

    private func rank(_ finding: PatternFinding) -> Int {
        guard let impact = finding.impact else { return 2 }
        return impact.isNeutral ? 1 : 0
    }

    private var reach: Double {
        let largest = story.findings.compactMap(\.impact).map(\.reach).max() ?? 0
        return [5.0, 8, 10, 15, 20, 30, 50, 100].first { $0 >= largest } ?? 100
    }

    private var subtitle: String {
        var parts: [String] = []
        if let caption = lead.impact?.caption { parts.append(caption.capitalizedFirst) }
        if lead.state.isFinding, let state = lead.state.shortLabel { parts.append(state) }
        if story.tier == "exploratory" { parts.append("Exploratory") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                        .onGeometryChange(for: Bool.self) { $0.frame(in: .global).maxY > 150 } action: {
                            heroBehindToolbar = $0
                        }
                    if let note = story.safetyNote {
                        PatternSafetyNote(text: note)
                    }
                    ExperimentTestSection(story: story)
                    ForEach(groups, id: \.0) { group, findings in
                        VStack(alignment: .leading, spacing: 16) {
                            Text(group.title).font(.headline).accessibilityAddTraits(.isHeader)
                            ForEach(findings, id: \.finding.id) { item in
                                PatternDetailRow(title: item.title, finding: item.finding, reach: reach, headline: lead.state)
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .panelSurface(cornerRadius: 22)
                    }
                    PatternMethod(story: story, run: run)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .modifier(PatternsScrollEdge(hidden: heroBehindToolbar))
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(story.title)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .accessibilityAddTraits(.isHeader)
                .fadesNearTop(from: 122, to: 96)
            if !subtitle.isEmpty {
                Text(subtitle).font(.subheadline).foregroundStyle(.white.opacity(0.8))
                    .fadesNearTop(from: 122, to: 96)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
        .padding(.bottom, PatternsSky.bottomFade - 8)
        .background { PatternsSky(group: group ?? lead.group).padding(.horizontal, -16) }
    }
}

struct PatternSafetyNote: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(HealthTheme.color(for: .activity))
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface(cornerRadius: 22)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Safety note. \(text)")
        .accessibilityIdentifier("patterns.safetyNote")
    }
}

struct PatternDetailRow: View {
    let title: String
    let finding: PatternFinding
    let reach: Double
    let headline: PatternState

    private var effect: PatternEffect? {
        guard let impact = finding.impact else { return finding.effects.first }
        return finding.effects.first { $0.percent == impact.percent } ?? finding.effects.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                if let impact = finding.impact {
                    Text(impact.percentText).font(.headline).monospacedDigit().foregroundStyle(impact.tint)
                } else {
                    Text(finding.state.shortLabel ?? finding.stateLabel)
                        .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            if let impact = finding.impact {
                PatternImpactBar(impact: impact, reach: reach, early: finding.state == .earlySignal, showsRange: true)
            }
            if let caption {
                Text(caption).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title). \(finding.summary) \(finding.needs ?? "")")
    }

    private var caption: String? {
        if let impact = finding.impact, let effect {
            let change: String = impact.isNeutral ? "No clear change" : effect.shortText
            let range: String = effect.rangeShortText
            var text: String = change + " (likely " + range + ")"
            if !impact.isNeutral, finding.state != headline, let state = finding.state.shortLabel {
                text += " · \(state)"
            }
            return text
        }
        if finding.state == .held { return finding.summary }
        return finding.needs
    }
}

struct PatternMethod: View {
    let story: PatternStory
    let run: PatternRun?

    private var measured: [PatternFinding] { story.findings.filter { !$0.effects.isEmpty } }

    private var compared: String? {
        guard let first = measured.first else { return nil }
        func span(_ values: [Int]) -> String {
            let low = values.min() ?? 0, high = values.max() ?? 0
            return low == high ? "\(low)" : "\(low)–\(high)"
        }
        let exposed: String = span(measured.map(\.sample.exposedDays))
        let comparison: String = span(measured.map(\.sample.comparisonDays))
        return "\(exposed) \(first.sample.exposedLabel) · \(comparison) \(first.sample.comparisonLabel)"
    }

    private var leftOut: String? {
        var days: [String: Int] = [:]
        var order: [String] = []
        for item in measured.flatMap(\.sample.excluded) {
            if days[item.text] == nil { order.append(item.text) }
            days[item.text] = max(days[item.text] ?? 0, item.days)
        }
        return order.isEmpty ? nil : order.map { "\(days[$0] ?? 0) \($0)" }.joined(separator: ", ")
    }

    private func unique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How this was worked out").font(.headline).accessibilityAddTraits(.isHeader)
            if let compared { item("Days compared", compared) }
            if let window = measured.first?.window { item("Window", PatternDates.range(window)) }
            let adjustments = unique(measured.flatMap(\.adjustments))
            if !adjustments.isEmpty { item("Accounted for", adjustments.joined(separator: ", ").capitalizedFirst) }
            if let leftOut { item("Left out", leftOut) }
            let limitations = unique(story.findings.flatMap(\.limitations))
            if !limitations.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Keep in mind").font(.footnote.weight(.semibold))
                    ForEach(limitations, id: \.self) { text in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•").accessibilityHidden(true)
                            Text(text).fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            Divider()
            Text(cadence).font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface(cornerRadius: 22)
    }

    private var cadence: String {
        let next = run.map { ", next on day \($0.nextCheckpointDay)" } ?? ""
        return "Numbers update after journal edits and at least weekly. Confidence labels are reviewed every 30 days\(next)."
    }

    private func item(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.footnote.weight(.semibold))
            Text(value).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

extension PatternState {
    var shortLabel: String? {
        switch self {
        case .consistent: "Consistent"
        case .possible: "Possible"
        case .earlySignal: "Early signal"
        case .neutral: "No clear link"
        case .inconclusive: "Unclear"
        case .overlapping: "Overlaps"
        case .insufficientVariation: "Too little variation"
        case .collecting: "Still collecting"
        case .held: "Held back"
        }
    }
}

extension PatternEffect {
    private static func amount(_ value: Double) -> String {
        let size = abs(value)
        let sign: String = value < 0 ? "−" : "+"
        if size >= 10 { return sign + String(Int(size.rounded())) }
        let text: String = String(format: "%.1f", size)
        return sign + (text.hasSuffix(".0") ? String(text.dropLast(2)) : text)
    }

    var shortText: String {
        let size: String = Self.amount(value)
        let single: Bool = unit == "points" && (size == "+1" || size == "−1")
        return size + " " + (single ? "point" : unit)
    }
    var rangeShortText: String { "\(Self.amount(low)) to \(Self.amount(high)) \(unit)" }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
