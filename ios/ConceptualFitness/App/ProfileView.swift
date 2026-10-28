import SwiftUI

struct ProfileView: View {
    @ObservedObject var store: ProfileStore
    @ObservedObject var coordinator: AppSyncCoordinator
    @ObservedObject var authStore: AuthStore
    let userID: String
    @State private var connectionAction: ConnectionAction?
    @State private var isUpdatingConnection = false
    @State private var connectionError: String?

    private enum ConnectionAction: String, Identifiable {
        case disconnect, signOut
        var id: String { rawValue }
    }

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

            Section("Connections and sync") {
                LabeledContent("Google Health", value: connectionTitle)
                if let connected = DashboardFormatters.parseBackendDateTime(session?.googleHealth.connectedAt) {
                    LabeledContent("Connected", value: connected.formatted(date: .abbreviated, time: .omitted))
                }
                LabeledContent("Last synced", value: coordinator.lastSyncAt?.formatted(date: .abbreviated, time: .shortened) ?? "Not synced yet")
                if let message = coordinator.failureMessage { Text(message).foregroundStyle(.secondary) }
                if isUpdatingConnection {
                    ProgressView("Updating connection…")
                } else if session?.googleHealth.status == .connected {
                    Button(coordinator.isSyncing ? "Syncing…" : "Sync now") { Task { await coordinator.retry() } }
                        .disabled(coordinator.isSyncing)
                    Button("Disconnect Google Health", role: .destructive) { connectionAction = .disconnect }
                } else {
                    Button("Reconnect Google Health") { Task { await reconnect() } }
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
                Button("Sign out", role: .destructive) { connectionAction = .signOut }
                    .disabled(isUpdatingConnection)
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
        .confirmationDialog(
            connectionAction == .disconnect ? "Disconnect Google Health?" : "Sign out of this device?",
            isPresented: Binding(get: { connectionAction != nil }, set: { if !$0 { connectionAction = nil } }),
            titleVisibility: .visible
        ) {
            if connectionAction == .disconnect {
                Button("Disconnect Google Health", role: .destructive) { Task { await disconnect() } }
            } else {
                Button("Sign out", role: .destructive) { Task { await authStore.signOut() } }
            }
            Button("Cancel", role: .cancel) { connectionAction = nil }
        } message: {
            Text(connectionAction == .disconnect
                ? "Future imports will stop. Saved health data stays in your account, and you can reconnect here."
                : "Your account and saved health data will remain available when you sign in again.")
        }
    }

    private var connectionTitle: String {
        switch session?.googleHealth.status {
        case .connected: "Connected"
        case .errored: "Needs attention"
        case .disconnected: "Disconnected"
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

    @MainActor private func disconnect() async {
        isUpdatingConnection = true
        connectionError = nil
        defer { isUpdatingConnection = false }
        do {
            let _: [String: String] = try await authStore.authenticatedJSON(
                path: "/connections/google-health/disconnect", method: "POST", body: ["revoke": true]
            )
            try await authStore.refreshSession()
        } catch {
            store.logFailure("disconnect", error: error)
            connectionError = "The connection couldn’t update. Check its status before trying again."
        }
    }

    @MainActor private func reconnect() async {
        guard !isUpdatingConnection else { return }
        isUpdatingConnection = true
        connectionError = nil
        defer { isUpdatingConnection = false }
        await authStore.reconnectGoogleHealth()
        if session?.googleHealth.status != .connected {
            connectionError = "Google Health wasn’t reconnected. You can try again."
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
                Text("Google Health access is read-only. Disconnecting stops future imports; it does not erase records already saved in your account.")
                Text("Your account stores imported health data, workouts, journal entries, derived scores, and your profile preferences. Daily briefs and unfinished workout drafts may also be stored on this device.")
            }
            Section("Location") {
                Text("Location supports local weather. You can turn weather off, choose a timezone manually, or change the app’s location permission in iOS Settings.")
            }
            Section("Export and deletion") {
                Text("Export lets you choose categories for a machine-readable archive. Export and account deletion require Face ID or device passcode confirmation on a supported iPhone.")
                Text("Deleting your account immediately suspends access and stops imports. You can restore it with the same Google account for 14 days; after that, application data is permanently erased.")
                Text("Infrastructure backup retention is managed separately and is not available in the app. Files you save or share outside the app remain under your control.")
            }
        }
        .navigationTitle("Privacy and data")
        .navigationBarTitleDisplayMode(.inline)
    }
}
