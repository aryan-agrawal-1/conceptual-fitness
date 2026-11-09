import SwiftUI

struct ExperimentTestSection: View {
    let story: PatternStory
    var group: PatternGroup?
    @EnvironmentObject private var store: ExperimentStore

    var body: some View {
        if let finding = story.testableFinding {
            VStack(alignment: .leading, spacing: 10) {
                if store.isRunning(story), let active = store.active {
                    NavigationLink { ExperimentDetailView() } label: { runningRow(active) }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens your experiment")
                } else if store.active != nil {
                    Text("You already have an experiment running. Stop it to test this pattern.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 12) {
                        Image(systemName: "flask").font(.title3).foregroundStyle(HealthTheme.color(for: .activity))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Test this yourself").font(.subheadline.weight(.semibold))
                            Text("4-week experiment on \(finding.outcomeLabel.lowercased())")
                                .font(.footnote).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        NavigationLink {
                            ExperimentSetupView(story: story, finding: finding, group: group ?? finding.group)
                        } label: {
                            Text("Test").font(.subheadline.weight(.semibold)).frame(minHeight: 30)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .tint(HealthTheme.color(for: .activity))
                        .accessibilityLabel("Test this yourself")
                        .accessibilityHint("Sets up a 4-week experiment")
                        .accessibilityIdentifier("experiment.test")
                    }
                    .frame(minHeight: 44)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panelSurface(cornerRadius: 22)
        }
    }

    private func runningRow(_ experiment: Experiment) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "flask").font(.title3).foregroundStyle(HealthTheme.color(for: .activity))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Experiment running").font(.subheadline.weight(.semibold))
                Text(experiment.statusText).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct ExperimentSummaryCard: View {
    @EnvironmentObject private var store: ExperimentStore

    var body: some View {
        Group {
            if let experiment = store.experiment {
                NavigationLink { ExperimentDetailView() } label: { card(experiment) }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens your experiment")
                    .accessibilityIdentifier("experiment.card")
            } else if store.phase == .failed {
                HStack {
                    Text("Couldn’t load your experiment.").font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button("Retry") { Task { await store.load() } }
                        .font(.footnote.weight(.semibold)).frame(minHeight: 44)
                        .accessibilityIdentifier("experiment.retry")
                }
                .padding(.horizontal, 14)
                .panelSurface(cornerRadius: 22)
            } else if store.phase == .loading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityLabel("Loading your experiment")
            }
        }
        .task { if store.phase == .idle { await store.load() } }
    }

    private func card(_ experiment: Experiment) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "flask").font(.title3).foregroundStyle(HealthTheme.color(for: .activity))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(experiment.isActive ? "Your experiment" : experiment.isOffTrack ? "Experiment ended"
                     : "Experiment result")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                Text(experiment.title).font(.subheadline.weight(.semibold))
                Text(experiment.isOffTrack ? "Off track · you can restart it"
                     : experiment.today?.plan ?? experiment.statusText)
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .panelSurface(cornerRadius: 22)
        .accessibilityElement(children: .combine)
    }
}

struct ExperimentDetailView: View {
    @EnvironmentObject private var store: ExperimentStore
    @State private var confirmingStop = false

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let experiment = store.experiment {
                        header(experiment)
                        if let offTrack = experiment.offTrack { ExperimentOffTrackCard(offTrack: offTrack) }
                        if experiment.isActive { plan(experiment) }
                        ExperimentWeeksStrip(experiment: experiment)
                        if let result = experiment.result { ExperimentResultView(experiment: experiment, result: result) }
                        if experiment.isActive { stopControls }
                    } else if store.phase == .failed {
                        Text("Couldn’t load your experiment.").font(.subheadline).foregroundStyle(.secondary)
                        Button("Retry") { Task { await store.load() } }.frame(minHeight: 44)
                    } else if store.phase == .loading {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                    } else {
                        Text("No experiment yet. Open a pattern marked as testable to start one.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle("Experiment")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.load() }
        .alert("Stop this experiment?", isPresented: $confirmingStop) {
            Button("Stop", role: .destructive) { Task { await store.stop() } }
            Button("Keep going", role: .cancel) {}
        } message: {
            Text("The check-in will stop showing a daily plan. Days so far are kept, but there may be too few to compare.")
        }
    }

    private func header(_ experiment: Experiment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(experiment.title).font(.system(.title, design: .rounded, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            Text("\(experiment.statusText) · Looking at \(experiment.outcomeLabel.lowercased())")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    private func plan(_ experiment: Experiment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let today = experiment.today {
                ExperimentPlanBanner(plan: today)
            } else {
                Text("Your first change week starts \(JournalDay.longTitle(experiment.startDate)).")
                    .font(.subheadline)
            }
            Text("Log what you actually did in your check-in. Nothing is filled in for you.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface(cornerRadius: 22)
    }

    private var stopControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(role: .destructive) { confirmingStop = true } label: {
                Text("Stop experiment").font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(store.action == .working)
            .accessibilityHint("Asks you to confirm before stopping")
            .accessibilityIdentifier("experiment.stop")
            if case .failed(let message) = store.action {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct ExperimentPlanBanner: View {
    let plan: ExperimentDay

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: plan.isChange ? "flask.fill" : "circle.dashed")
                .foregroundStyle(plan.isChange ? HealthTheme.color(for: .activity) : HealthTheme.color(for: .neutral))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(plan.plan).font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(plan.washout ? "Day \(plan.dayNumber) of 28 · settling-in day, not counted"
                     : "Day \(plan.dayNumber) of 28")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("experiment.plan")
    }
}

struct ExperimentWeeksStrip: View {
    let experiment: Experiment

    private var weeks: [(week: Int, change: Bool)] {
        Dictionary(grouping: experiment.days, by: \.week).keys.sorted().map { week in
            (week, experiment.days.first { $0.week == week }?.isChange ?? false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Schedule").font(.headline).accessibilityAddTraits(.isHeader)
            HStack(spacing: 6) {
                ForEach(weeks, id: \.week) { item in
                    let current = experiment.today?.week == item.week
                    VStack(spacing: 4) {
                        Text("Week \(item.week)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        Text(item.change ? "Change" : "Usual").font(.footnote.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 32)
                            .background(item.change ? HealthTheme.color(for: .activity).opacity(current ? 0.35 : 0.15)
                                        : Color.secondary.opacity(current ? 0.3 : 0.12),
                                        in: RoundedRectangle(cornerRadius: 10))
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Week \(item.week), \(item.change ? "change" : "usual") week\(current ? ", this week" : "")")
                }
            }
            Text("Days in change weeks you stuck to so far: \(experiment.adherence.followedDays) of \(experiment.adherence.changeDays).")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface(cornerRadius: 22)
    }
}

struct ExperimentResultView: View {
    let experiment: Experiment
    let result: ExperimentResult

    private var tint: Color {
        result.benefit == "helps" || result.benefit == "hurts" ? HealthTheme.color(for: .activity)
            : HealthTheme.color(for: .neutral)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your result").font(.headline).accessibilityAddTraits(.isHeader)
            if result.isReady {
                Label(result.benefit == "none" ? "No clear difference" : "Difference seen",
                      systemImage: result.benefit == "none" ? "equal.circle" : "circle.lefthalf.filled")
                    .font(.caption.weight(.semibold)).foregroundStyle(tint)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(tint.opacity(0.1), in: Capsule())
            }
            Text(result.summary).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("experiment.result")
            Text("Compared \(result.changeDays) days in change weeks with \(result.usualDays) in usual weeks.")
                .font(.footnote).foregroundStyle(.secondary)
            if let adherence = result.adherenceText {
                Text(adherence).font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(result.notes, id: \.self) { note in
                Label { Text(note).fixedSize(horizontal: false, vertical: true) } icon: {
                    Image(systemName: "info.circle").accessibilityHidden(true)
                }
                .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface(cornerRadius: 22)
    }
}

struct ExperimentCheckInPin: View {
    let plan: ExperimentDay

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            JournalSectionTitle(title: "Your experiment")
            ExperimentPlanBanner(plan: plan)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .panelSurface(cornerRadius: 22)
        }
    }
}

struct ExperimentOffTrackCard: View {
    let offTrack: ExperimentOffTrack
    @EnvironmentObject private var store: ExperimentStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Off track", systemImage: "arrow.uturn.backward.circle")
                .font(.headline).foregroundStyle(HealthTheme.color(for: .activity))
                .accessibilityAddTraits(.isHeader)
            Text(offTrack.summary).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            Text(offTrack.restartText).font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button { Task { await store.restart() } } label: {
                HStack {
                    if store.action == .working { ProgressView().tint(.white) }
                    Text("Restart from tomorrow").font(.body.weight(.semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(HealthTheme.color(for: .activity))
            .disabled(store.action == .working)
            .accessibilityIdentifier("experiment.restart")
            if case .failed(let message) = store.action {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface(cornerRadius: 22)
        .accessibilityIdentifier("experiment.offTrack")
    }
}

struct ExperimentSetupView: View {
    enum Step: Int, CaseIterable {
        case usual
        case change
        case plan

        var title: String {
            switch self {
            case .usual: "Your usual"
            case .change: "Pick your change"
            case .plan: "How it works"
            }
        }
    }

    let story: PatternStory
    let finding: PatternFinding
    let group: PatternGroup
    @EnvironmentObject private var store: ExperimentStore
    @Environment(\.dismiss) private var dismiss
    @State private var setup: ExperimentSetup?
    @State private var loadFailed = false
    @State private var step = Step.usual
    @State private var choice: String?
    @State private var heroBehindToolbar = true

    private var chosen: ExperimentOption? { setup?.options.first { $0.id == choice } }

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                        .onGeometryChange(for: Bool.self) { $0.frame(in: .global).maxY > 150 } action: {
                            heroBehindToolbar = $0
                        }
                    if let setup {
                        content(setup)
                        controls(setup)
                    } else if loadFailed {
                        failure
                    } else {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                            .accessibilityLabel("Loading your usual week")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                .animation(.snappy, value: step)
            }
            .modifier(PatternsScrollEdge(hidden: heroBehindToolbar))
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { if setup == nil { await load() } }
        .onAppear { store.clearError() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Step \(step.rawValue + 1) of \(Step.allCases.count) · \(story.title)")
                .font(.footnote.weight(.medium)).foregroundStyle(.white.opacity(0.75))
                .fadesNearTop(from: 122, to: 96)
            Text(step.title)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .accessibilityAddTraits(.isHeader)
                .fadesNearTop(from: 122, to: 96)
            Text(subtitle).font(.subheadline).foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .fadesNearTop(from: 122, to: 96)
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { item in
                    Capsule().fill(.white.opacity(item.rawValue <= step.rawValue ? 0.9 : 0.3))
                        .frame(height: 4)
                }
            }
            .padding(.top, 8)
            .accessibilityHidden(true)
            .fadesNearTop(from: 122, to: 96)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
        .padding(.bottom, PatternsSky.bottomFade - 8)
        .background { PatternsSky(group: group).padding(.horizontal, -16) }
    }

    private var subtitle: String {
        switch step {
        case .usual: "What a normal week looks like for you, from your own logs."
        case .change: "What you’ll do on change weeks."
        case .plan:
            if let setup { "\(setup.weeks) weeks, starting \(JournalDay.longTitle(setup.startDate))." } else { "" }
        }
    }

    @ViewBuilder
    private func content(_ setup: ExperimentSetup) -> some View {
        switch step {
        case .usual: usual(setup)
        case .change: changes(setup)
        case .plan: plan(setup)
        }
    }

    private func usual(_ setup: ExperimentSetup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(setup.usual.lines, id: \.self) { line in
                Label { Text(line).fixedSize(horizontal: false, vertical: true) } icon: {
                    Image(systemName: "calendar").foregroundStyle(HealthTheme.color(for: .activity))
                }
                .font(.body)
            }
            if let basis = setup.usual.basis {
                Text(basis).font(.footnote).foregroundStyle(.secondary)
            }
            Divider()
            Text("On usual weeks you carry on like this. Only change weeks are different.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface(cornerRadius: 22)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("experiment.usual")
    }

    private func changes(_ setup: ExperimentSetup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(setup.options) { option in
                let selected = option.id == choice
                Button { choice = option.id } label: {
                    HStack(spacing: 12) {
                        Text(option.title).font(.headline)
                        Spacer(minLength: 8)
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(selected ? HealthTheme.color(for: .activity) : Color.secondary)
                            .accessibilityHidden(true)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .panelSurface(cornerRadius: 22)
                    .overlay {
                        RoundedRectangle(cornerRadius: 22)
                            .strokeBorder(HealthTheme.color(for: .activity), lineWidth: selected ? 2 : 0)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("experiment.option.\(option.id)")
            }
        }
    }

    private func plan(_ setup: ExperimentSetup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ExperimentWeeksPreview(weeks: setup.weeks)
            VStack(alignment: .leading, spacing: 14) {
                ExperimentStepRow(icon: "flask", title: "Change weeks", text: chosen?.detail ?? "")
                ExperimentStepRow(icon: "circle.dashed", title: "Usual weeks", text: "Carry on as you normally do.")
                ExperimentStepRow(icon: "checklist", title: "Every day",
                                  text: "Your check-in shows that day’s plan at the top. You still log what you actually did.")
                ExperimentStepRow(icon: "hourglass", title: "Settling in",
                                  text: "The first \(setup.washoutDays) days of each week aren’t counted, so each switch can settle.")
                ExperimentStepRow(icon: "exclamationmark.circle", title: "Don’t slip!",
                                  text: "Logging something that breaks the plan in a change week ends the experiment. You can restart it from the next day.")
                ExperimentStepRow(icon: "chart.bar", title: "Your result",
                                  text: "Ready \(JournalDay.longTitle(setup.resultDate)), comparing \(setup.outcomeLabel.lowercased()) in change and usual weeks.")
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panelSurface(cornerRadius: 22)
            if let note = setup.safetyNote { PatternSafetyNote(text: note) }
        }
    }

    private func controls(_ setup: ExperimentSetup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if case .failed(let message) = store.action {
                Text(message).font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("experiment.error")
            }
            HStack(spacing: 10) {
                if step != .usual {
                    Button { back() } label: {
                        Text("Back").font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                }
                Button { Task { await advance(setup) } } label: {
                    HStack {
                        if store.action == .working { ProgressView().tint(.white) }
                        Text(step == .plan ? "Start experiment" : "Next").font(.body.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(HealthTheme.color(for: .activity))
                .disabled(store.action == .working || (step != .usual && chosen == nil))
                .accessibilityIdentifier(step == .plan ? "experiment.start" : "experiment.next")
            }
        }
        .padding(.top, 4)
    }

    private var failure: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Couldn’t load your usual week.").font(.subheadline).foregroundStyle(.secondary)
            Button("Retry") { Task { await load() } }.frame(minHeight: 44)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface(cornerRadius: 22)
    }

    private func load() async {
        loadFailed = false
        do {
            let next = try await store.setup(for: finding)
            setup = next
            choice = choice ?? next.options.first?.id
        } catch {
            loadFailed = true
        }
    }

    private func back() {
        store.clearError()
        step = Step(rawValue: step.rawValue - 1) ?? .usual
    }

    private func advance(_ setup: ExperimentSetup) async {
        store.clearError()
        guard step == .plan else {
            step = Step(rawValue: step.rawValue + 1) ?? .plan
            return
        }
        if await store.start(finding, change: choice) { dismiss() }
    }
}

struct ExperimentStepRow: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.body).foregroundStyle(HealthTheme.color(for: .activity))
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(text).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct ExperimentWeeksPreview: View {
    let weeks: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...max(weeks, 1), id: \.self) { week in
                let change = week % 2 == 1
                VStack(spacing: 4) {
                    Text("Week \(week)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text(change ? "Change" : "Usual").font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background(change ? HealthTheme.color(for: .activity).opacity(0.18) : Color.secondary.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 10))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Week \(week), \(change ? "change" : "usual") week")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface(cornerRadius: 22)
    }
}
