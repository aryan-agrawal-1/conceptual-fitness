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
                HStack(spacing: 16) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(HealthTheme.color(for: .activity))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayName)
                            .font(.title3.weight(.semibold))
                        Text(session?.user.email ?? "Email unavailable")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
            }

            if store.isLoading && store.profile == nil {
                Section { ProgressView("Loading profile…").accessibilityIdentifier("profile.loading") }
            }
            if let message = store.loadError {
                Section {
                    Label("Profile unavailable", systemImage: "wifi.exclamationmark")
                    Text(message)
                    if store.profile != nil { Text("Showing the last loaded details.").font(.footnote).foregroundStyle(.secondary) }
                    Button("Try loading profile again") { Task { await store.load() } }
                        .disabled(store.isLoading)
                }
            }

            if let profile = store.profile {
                Section("Personalization") {
                    NavigationLink { ProfileDetailsEditor(store: store, profile: profile, user: session?.user) } label: {
                        Label("Personal details", systemImage: "person.text.rectangle")
                    }
                    NavigationLink { ProfileGoalsEditor(store: store, profile: profile) } label: {
                        profileLink("Goals and sleep", subtitle: profile.primaryGoal ?? "No primary goal set", icon: "target")
                    }
                    NavigationLink { ProfileConstraintsEditor(store: store, profile: profile) } label: {
                        Label("Schedule and constraints", systemImage: "slider.horizontal.3")
                    }
                    NavigationLink { ProfileUnitsEditor(store: store, profile: profile) } label: {
                        profileLink("Units", subtitle: profile.unitSystem.title, icon: "ruler")
                    }
                    NavigationLink { ProfileBodyEditor(store: store, profile: profile) } label: {
                        Label("Body measurements and sources", systemImage: "figure.stand")
                    }
                    NavigationLink { ProfileWeatherEditor(store: store, profile: profile) } label: {
                        profileLink("Location and weather", subtitle: profile.weatherEnabled ? "Weather enabled" : "Weather off", icon: "location")
                    }
                }
            }

            if let journalReminders { JournalReminderSection(reminders: journalReminders) }

            Section("Data sources") {
                NavigationLink { DataSourcesView(authStore: authStore, coordinator: coordinator) } label: {
                    profileLink(sourceTitle, subtitle: connectionTitle, icon: session?.healthConnection.activeDevice?.systemImage ?? "link")
                }
                if let connectionError {
                    Text(connectionError).foregroundStyle(.red)
                    Button("Check connection again") { Task { await refreshConnection() } }
                }
            }

            Section {
                NavigationLink {
                    ScrollView { HistoricalBackfillView(coordinator: coordinator, expanded: true).padding() }
                        .navigationTitle("History import")
                        .navigationBarTitleDisplayMode(.inline)
                        .refreshable { await coordinator.checkHistory() }
                } label: {
                    profileLink("History import", subtitle: historyTitle, icon: "clock.arrow.circlepath")
                }
            }

            Section("Privacy and account") {
                NavigationLink { ProfilePrivacyView() } label: { Label("Privacy and data", systemImage: "hand.raised") }
                NavigationLink { AccountExportView(authStore: authStore, userID: userID) } label: {
                    Label("Export your data", systemImage: "square.and.arrow.up")
                }
                .accessibilityHint("Choose categories for a portable account archive")
                NavigationLink { AccountDeletionView(authStore: authStore, userID: userID) } label: {
                    Label("Delete account", systemImage: "trash").foregroundStyle(.red)
                }
                .accessibilityHint("Review permanent deletion and the 14-day recovery period")
                Button("Sign out", role: .destructive) { confirmsSignOut = true }
            }
        }
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
        session?.healthConnection.activeDevice?.title ?? "Connect a source"
    }

    private var connectionTitle: String {
        switch session?.healthConnection.status {
        case .connected:
            coordinator.lastSyncAt.map { "Last synced \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Connected"
        case .errored: "Needs attention"
        case .disconnected: "No device connected"
        case nil: "Status unavailable"
        }
    }

    private var historyTitle: String {
        if coordinator.historyError != nil { return "Progress unavailable — check again" }
        guard let history = coordinator.history else { return coordinator.historyLoaded ? "Not started yet" : "Checking progress…" }
        if history.coverageState == "untracked" { return "Saved history available" }
        if history.status == "failed" { return "Import needs attention" }
        return history.status == "complete" ? "Import complete" : "\(history.completedSources) of \(history.totalSources) data types complete"
    }

    private func profileLink(_ title: String, subtitle: String, icon: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        } icon: { Image(systemName: icon) }
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
