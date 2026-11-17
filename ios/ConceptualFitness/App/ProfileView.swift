import SwiftUI

struct ProfileView: View {
    @ObservedObject var store: ProfileStore
    @ObservedObject var coordinator: AppSyncCoordinator
    @ObservedObject var authStore: AuthStore
    let userID: String
    var journalReminders: JournalReminders?
    @State private var confirmsSignOut = false
    @State private var connectionError: String?


    private var session: AuthSession? {
        if case .authenticated(let session) = authStore.state { return session }
        return nil
    }

    private var displayName: String {
        let name = [session?.user.firstName, session?.user.lastName].compactMap { $0 }.joined(separator: " ")
        return name.isEmpty ? "Your account" : name
    }

    var body: some View {
        Form {
            Section {
                deviceHeader
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            if store.isLoading && store.profile == nil {
                Section { ProgressView("Loading profile…").accessibilityIdentifier("profile.loading") }
                    .listRowBackground(HealthTheme.card)
            }
            if let message = store.loadError {
                Section {
                    Text(message)
                    if store.profile != nil {
                        Text("Showing the last loaded details.").font(.footnote).foregroundStyle(HealthTheme.secondaryInk)
                    }
                    Button("Try again") { Task { await store.load() } }
                        .disabled(store.isLoading)
                }
                .listRowBackground(HealthTheme.card)
            }

            if let profile = store.profile {
                Section {
                    NavigationLink { ProfileDetailsEditor(store: store, profile: profile, user: session?.user) } label: {
                        row("Personal details")
                    }
                    NavigationLink { ProfileGoalsEditor(store: store, profile: profile) } label: {
                        row("Goals and sleep", value: profile.primaryGoal ?? "Not set")
                    }
                    NavigationLink { ProfileConstraintsEditor(store: store, profile: profile) } label: {
                        row("Schedule and constraints")
                    }
                    NavigationLink { ProfileUnitsEditor(store: store, profile: profile) } label: {
                        row("Units", value: profile.unitSystem.title)
                    }
                    NavigationLink { ProfileBodyEditor(store: store, profile: profile) } label: {
                        row("Body measurements")
                    }
                    NavigationLink { ProfileWeatherEditor(store: store, profile: profile) } label: {
                        row("Location and weather", value: profile.weatherEnabled ? "On" : "Off")
                    }
                }
                .listRowBackground(HealthTheme.card)
            }

            if let journalReminders {
                JournalReminderSection(reminders: journalReminders)
                    .listRowBackground(HealthTheme.card)
                    .tint(HealthTheme.color(for: .positive))
            }

            Section("Data") {
                NavigationLink { DataSourcesView(authStore: authStore, coordinator: coordinator) } label: {
                    row("Data sources", value: sourceTitle)
                }
                if let connectionError {
                    Text(connectionError).foregroundStyle(HealthTheme.color(for: .risk))
                    Button("Check connection again") { Task { await refreshConnection() } }
                }
                NavigationLink {
                    ScrollView { HistoricalBackfillView(coordinator: coordinator, expanded: true).padding() }
                        .navigationTitle("History import")
                        .navigationBarTitleDisplayMode(.inline)
                        .refreshable { await coordinator.checkHistory() }
                } label: {
                    row("History import", value: historyTitle)
                }
            }
            .listRowBackground(HealthTheme.card)

            Section("Privacy and account") {
                NavigationLink { ProfilePrivacyView() } label: { row("Privacy and data") }
                NavigationLink { AccountExportView(authStore: authStore, userID: userID) } label: {
                    row("Export your data")
                }
                .accessibilityHint("Choose categories for a portable account archive")
                Button { confirmsSignOut = true } label: { row("Sign out") }
                NavigationLink { AccountDeletionView(authStore: authStore, userID: userID) } label: {
                    Text("Delete account").foregroundStyle(HealthTheme.color(for: .risk))
                }
                .accessibilityHint("Review permanent deletion and the 14-day recovery period")
            }
            .listRowBackground(HealthTheme.card)
        }
        .scrollContentBackground(.hidden)
        .background(HealthTheme.page)
        .tint(HealthTheme.ink)
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await store.load()
            await coordinator.checkHistory()
            await refreshConnection()
        }
        .task {
            if store.profile == nil { await store.load() }
            await refreshConnection()
        }
        .confirmationDialog("Sign out of this device?", isPresented: $confirmsSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { Task { await authStore.signOut() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your account and saved health data will remain available when you sign in again.")
        }
    }

    private var sourceTitle: String {
        session?.healthConnection.activeDevice?.shortName ?? "Connect a source"
    }

    private var historyTitle: String {
        if coordinator.historyError != nil { return "Unavailable" }
        guard let history = coordinator.history else { return coordinator.historyLoaded ? "Not started" : "Checking" }
        if history.coverageState == "untracked" { return "Available" }
        if history.status == "failed" { return "Needs attention" }
        return history.status == "complete" ? "Complete" : "\(history.completedSources) of \(history.totalSources)"
    }

    private func row(_ title: String, value: String? = nil) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .foregroundStyle(HealthTheme.ink)
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(HealthTheme.secondaryInk)
                    .lineLimit(1)
            }
        }
    }

    private var deviceHeader: some View {
        let device = session?.healthConnection.activeDevice
        return ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [Color(hex: 0x232A3D), Color(hex: 0x141824), Color(hex: 0x0C0E15)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            ZStack {
                Circle()
                    .fill(RadialGradient(
                        colors: [Color(hex: 0x9FB2E8).opacity(0.30), Color(hex: 0x9FB2E8).opacity(0)],
                        center: .center, startRadius: 0, endRadius: 110
                    ))
                    .frame(width: 220, height: 220)
                    .offset(y: -6)
                Ellipse()
                    .fill(RadialGradient(
                        colors: [.black.opacity(0.55), .black.opacity(0)],
                        center: .center, startRadius: 0, endRadius: 58
                    ))
                    .frame(width: 116, height: 18)
                    .offset(y: 70)
                if let device, let still = UIImage(named: "DeviceStill-\(device.rawValue)") {
                    Image(uiImage: still)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 124, height: 132)
                } else {
                    Image(systemName: "applewatch")
                        .font(.system(size: 72, weight: .light))
                        .foregroundStyle(.white.opacity(0.86))
                }
            }
            .frame(width: 150)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .padding(.trailing, 14)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(displayName)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                Text(deviceLine)
                    .font(.subheadline.weight(.medium))
                    .opacity(0.82)
                Text(statusTitle)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(statusColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .foregroundStyle(.white)
            .padding(20)
            .frame(maxWidth: 220, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(height: 176)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var deviceLine: String {
        guard session?.healthConnection.status == .connected, let synced = coordinator.lastSyncAt else { return sourceTitle }
        return "\(sourceTitle) · Synced \(synced.formatted(date: .omitted, time: .shortened))"
    }

    private var statusTitle: String {
        switch session?.healthConnection.status {
        case .connected: "Connected"
        case .errored: "Needs attention"
        case .disconnected: "Not connected"
        case nil: "Status unavailable"
        }
    }

    private var statusColor: Color {
        switch session?.healthConnection.status {
        case .connected: Color(hex: 0x6FE0A2)
        case .errored: Color(hex: 0xF0A840)
        default: Color(hex: 0xA4A9B4)
        }
    }

    @MainActor private func refreshConnection() async {
        do {
            try await authStore.refreshSession()
            connectionError = nil
        } catch {
            store.logFailure("connection status", error: error)
            connectionError = "Connection status couldn’t load. Check your connection and try again."
        }
    }
}

private struct ProfilePrivacyView: View {
    var body: some View {
        Form {
            Section("Your health data") {
                Text("Apple Health and Fitbit access are read-only. Disconnecting stops future imports; it does not erase records already saved in your account.")
                Text("Your account stores imported health data, workouts, journal entries, derived scores, and your profile preferences. Daily briefs and unfinished workout drafts may also be stored on this device. Daily notes sync to your account and are encrypted when stored on the server.")
            }
            Section("Location") {
                Text("Location supports local weather. You can turn weather off, choose a timezone manually, or change the app’s location permission in iOS Settings.")
            }
            Section("Export and deletion") {
                Text("Export lets you choose categories for a machine-readable archive. Export and account deletion require Face ID or device passcode confirmation on a supported iPhone.")
                Text("Deleting your account immediately suspends access and stops imports. You can restore it for 14 days by signing in the same way; after that, application data is permanently erased.")
                Text("Infrastructure backup retention is managed separately and is not available in the app. Files you save or share outside the app remain under your control.")
            }
        }
        .navigationTitle("Privacy and data")
        .navigationBarTitleDisplayMode(.inline)
    }
}
