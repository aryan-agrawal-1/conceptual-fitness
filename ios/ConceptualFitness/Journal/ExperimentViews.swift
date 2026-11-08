import SwiftUI

enum ExperimentCopy {
    static let explanation = "For 4 weeks you’ll alternate: one week making the change, one week as usual, twice. "
        + "Each day, the check-in shows that day’s plan at the top. You still log what you actually did yourself. "
        + "The first 2 days of each week are left out of the result so the switch can settle. "
        + "You can stop at any time."
}

struct ExperimentTestSection: View {
    let story: PatternStory
    @EnvironmentObject private var store: ExperimentStore
    @State private var confirming = false

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
                    Text("Test this yourself")
                        .font(.headline).accessibilityAddTraits(.isHeader)
                    Text("Try a 4-week experiment to see how \(finding.outcomeLabel.lowercased()) looks on change weeks compared with usual weeks.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { confirming = true } label: {
                        HStack {
                            if store.action == .working { ProgressView().tint(.white) }
                            Text("Test this").font(.body.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(HealthTheme.color(for: .activity))
                    .disabled(store.action == .working)
                    .accessibilityHint("Explains the experiment and asks you to confirm")
                    .accessibilityIdentifier("experiment.test")
                    if case .failed(let message) = store.action {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("experiment.error")
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panelSurface(cornerRadius: 22)
            .alert("Start a 4-week experiment?", isPresented: $confirming) {
                Button("Start") { Task { await store.start(finding) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(ExperimentCopy.explanation)
            }
            .onAppear { store.clearError() }
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
                Text(experiment.isActive ? "Your experiment" : "Experiment result")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                Text(experiment.title).font(.subheadline.weight(.semibold))
                Text(experiment.today?.plan ?? experiment.statusText).font(.footnote).foregroundStyle(.secondary)
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
            Text("Change days logged so far: \(experiment.adherence.followedDays) of \(experiment.adherence.changeDays) followed the plan.")
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
            Text("Compared \(result.changeDays) change days with \(result.usualDays) usual days.")
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
