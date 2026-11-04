import SwiftUI

struct JournalCheckInSelection: Identifiable {
    let day: String
    var id: String { day }
}

struct JournalRowPanel: View {
    @ObservedObject var store: JournalStore
    let behaviours: [JournalBehaviourData]
    let day: String
    let open: (JournalBehaviourData) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(behaviours.enumerated()), id: \.element.id) { index, item in
                JournalLedgerRow(store: store, behaviour: item, day: day) { open(item) }
                if index < behaviours.count - 1 { Divider().padding(.horizontal, 14) }
            }
        }
        .panelSurface(cornerRadius: 22)
    }
}

struct JournalSectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 4).padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

struct JournalCheckInView: View {
    @ObservedObject var store: JournalStore
    @ObservedObject var reminders: JournalReminders
    let day: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var selection: JournalEditorSelection?
    @State private var answeringReminder = false

    private var logged: Int { JournalDailyList.loggedCount(store.snapshot, day: day) }
    private var completed: Bool { JournalDayIndex(store.snapshot, today: store.today).isCompleted(day) }
    private var screen: JournalCheckInScreen { JournalCheckIn.screen(store.snapshot, day: day) }
    private var celebration: JournalStreakCelebration? {
        JournalStreakCelebration(store.snapshot.completions, day: day, today: store.today)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                if completed { completedPage } else { quickPage }
            }
            .safeAreaInset(edge: .bottom) {
                if !completed && !typeSize.isAccessibilitySize {
                    completeControls
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.bar)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !completed {
                    ToolbarItem(placement: .cancellationAction) { Button("Not now") { dismiss() } }
                }
            }
            .sheet(item: $selection) { JournalEntryEditor(store: store, selection: $0) }
            .sensoryFeedback(.success, trigger: completed) { _, isCompleted in isCompleted }
            .task(id: completed) {
                guard completed, !reminders.shouldOffer else { return }
                do { try await Task.sleep(for: .seconds(celebration == nil ? 2 : 3)) } catch { return }
                dismiss()
            }
        }
    }

    private var quickPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                dateHeader
                rows
                if typeSize.isAccessibilitySize { completeControls }
                if let message = store.message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("journal.checkin.status")
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    private var dateHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Check in for \(JournalDay.title(day, today: store.today).lowercased())")
                .font(.title2.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Text(JournalDay.longTitle(day)).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 12) {
            let screen = screen
            if !screen.pinned.isEmpty { panel(screen.pinned) }
            ForEach(screen.privatePinned) { section in
                JournalSectionTitle(title: section.title)
                panel(section.behaviours)
            }
            if !screen.topUp.isEmpty {
                JournalSectionTitle(title: "To reach five")
                panel(screen.topUp)
            }
        }
    }

    private var completeControls: some View {
        let remaining = max(0, JournalDailyList.dailyTarget - logged)
        return VStack(spacing: 8) {
            ProgressView(value: Double(min(logged, JournalDailyList.dailyTarget)),
                         total: Double(JournalDailyList.dailyTarget))
                .tint(HealthTheme.color(for: .activity))
                .accessibilityLabel("\(logged) of \(JournalDailyList.dailyTarget) answered")
            Button(action: complete) {
                Text("Complete check-in").font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(HealthTheme.color(for: .activity))
            .disabled(remaining > 0 || store.storageBlocked)
            .accessibilityIdentifier("journal.checkin.complete")
            if remaining > 0 {
                Text("Answer \(remaining) more to complete. No counts as an answer.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
    }

    private var completedPage: some View {
        let celebration = celebration
        return GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 20) {
                    Spacer(minLength: 24)
                    if let celebration {
                        JournalStreakMark(celebration: celebration)
                    } else {
                        JournalCompleteMark()
                        Text("Check-in complete")
                            .font(.title.weight(.bold))
                            .multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)
                    }
                    Spacer(minLength: 24)
                    if offersReminder {
                        reminderOffer(onFire: celebration != nil)
                            .padding(.bottom, celebration == nil ? 0 : 150)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: proxy.size.height - 24)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
        .background {
            if celebration != nil {
                JournalFireBackground(lean: 1, reach: offersReminder ? 0.24 : 0.5, rises: true).ignoresSafeArea()
            }
        }
    }

    private var offersReminder: Bool { reminders.shouldOffer || answeringReminder }

    private func reminderOffer(onFire: Bool) -> some View {
        VStack(spacing: 14) {
            Text("Want a daily reminder?")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(onFire ? .white : .primary)
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 10))
                : AnyLayout(HStackLayout(spacing: 10))
            layout {
                Button {
                    answeringReminder = true
                    Task {
                        await reminders.setEnabled(true)
                        dismiss()
                    }
                } label: {
                    Text("Turn on").font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(onFire ? JournalFirePalette.deep : .white)
                }
                .buttonStyle(.borderedProminent)
                .tint(onFire ? .white : HealthTheme.color(for: .activity))
                let decline = Button {
                    reminders.declineOffer()
                    dismiss()
                } label: {
                    Text("No thanks").font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                }
                if onFire {
                    decline.buttonStyle(.borderedProminent).tint(JournalFirePalette.ember)
                } else {
                    decline.buttonStyle(.bordered)
                }
            }
            .controlSize(.large)
            .disabled(answeringReminder)
        }
    }

    private func panel(_ behaviours: [JournalBehaviourData]) -> some View {
        JournalRowPanel(store: store, behaviours: behaviours, day: day) {
            selection = JournalEditorSelection(behaviour: $0, day: day)
        }
    }

    private func complete() {
        guard withAnimation(.snappy, { store.complete(day: day) }) else { return }
        let streak = celebration.map { " \($0.to) day streak." } ?? ""
        AccessibilityNotification.Announcement("Check-in complete.\(streak)").post()
    }
}

private struct JournalCheckmark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.04))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY - rect.height * 0.08))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.08))
        return path
    }
}

struct JournalCompleteMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 128
    @State private var circleShown = false
    @State private var tickDrawn = false

    var body: some View {
        ZStack {
            Circle().fill(HealthTheme.color(for: .readiness))
            JournalCheckmark()
                .trim(from: 0, to: tickDrawn ? 1 : 0)
                .stroke(.white, style: StrokeStyle(lineWidth: size * 0.09, lineCap: .round, lineJoin: .round))
                .padding(size * 0.28)
        }
        .frame(width: size, height: size)
        .scaleEffect(circleShown ? 1 : 0.4)
        .opacity(circleShown ? 1 : 0)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else {
                circleShown = true
                tickDrawn = true
                return
            }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.62)) { circleShown = true }
            withAnimation(.easeOut(duration: 0.35).delay(0.2)) { tickDrawn = true }
        }
    }
}
