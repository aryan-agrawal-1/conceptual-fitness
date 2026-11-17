import SwiftUI

enum DataSourceDevice: String, CaseIterable, Identifiable {
    case appleWatch = "apple_health"
    case fitbit = "google_health"

    var id: String { rawValue }

    init?(provider: String?) {
        guard let provider, let device = DataSourceDevice(rawValue: provider) else { return nil }
        self = device
    }

    var title: String {
        switch self {
        case .appleWatch: "Apple Watch"
        case .fitbit: "Fitbit / Google devices"
        }
    }

    var detail: String {
        switch self {
        case .appleWatch: "Reads from Apple Health on this iPhone."
        case .fitbit: "Sign in with the Google account you use in the Google Health app."
        }
    }

    var systemImage: String {
        switch self {
        case .appleWatch: "applewatch"
        case .fitbit: "sensor.tag.radiowaves.forward"
        }
    }

    var shortName: String {
        switch self {
        case .appleWatch: "Apple Watch"
        case .fitbit: "Fitbit"
        }
    }

    var disconnectPath: String {
        switch self {
        case .appleWatch: "/connections/apple-health/disconnect"
        case .fitbit: "/connections/google-health/disconnect"
        }
    }
}

private struct ConnectionChangeResponse: Decodable {}

extension HealthConnectionStatus {
    var device: DataSourceDevice? { DataSourceDevice(provider: provider) }
    var activeDevice: DataSourceDevice? { status == .disconnected ? nil : device }
}

extension AuthStore {
    var connectedSession: AuthSession? {
        if case .authenticated(let session) = state { return session }
        return nil
    }

    func connect(_ device: DataSourceDevice) async -> String? {
        switch device {
        case .fitbit:
            let message = await connectFitbit()
            if connectedSession?.healthConnection.activeDevice == .fitbit { AppleHealthSync.shared.disable() }
            return message
        case .appleWatch:
            return await connectAppleWatch()
        }
    }

    func connectAppleWatch() async -> String? {
        guard AppleHealthSync.isAvailable else { return "Apple Health isn’t available on this device." }
        do {
            try await AppleHealthSync.shared.requestAuthorization()
        } catch {
            return "Apple Health access couldn’t be requested. Try again."
        }
        do {
            let _: ConnectionChangeResponse = try await authenticatedJSON(
                path: "/connections/apple-health", method: "POST", body: [String: String]()
            )
            let session = try await refreshSession()
            AppleHealthSync.shared.enable(authStore: self, userID: session.user.id)
            return nil
        } catch {
            return "Apple Watch wasn’t connected. Check your connection and try again."
        }
    }

    func disconnect(_ device: DataSourceDevice) async -> String? {
        if device == .appleWatch { AppleHealthSync.shared.disable() }
        do {
            let body: [String: Bool] = device == .fitbit ? ["revoke": true] : [:]
            let _: ConnectionChangeResponse = try await authenticatedJSON(path: device.disconnectPath, method: "POST", body: body)
            try await refreshSession()
            return nil
        } catch {
            return "The connection couldn’t update. Check its status before trying again."
        }
    }
}

struct DeviceChoiceList: View {
    @Binding var selection: DataSourceDevice?
    var connected: DataSourceDevice?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 12) {
            ForEach(DataSourceDevice.allCases) { device in
                Button { selection = device } label: { row(device) }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == device ? .isSelected : [])
                    .accessibilityValue(connected == device ? "Connected" : "")
            }
        }
    }

    private func row(_ device: DataSourceDevice) -> some View {
        let selected = selection == device
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 14))
        return layout {
            HStack {
                Image(systemName: device.systemImage)
                    .font(.title2)
                    .frame(minWidth: 36)
                    .foregroundStyle(.blue)
                if dynamicTypeSize.isAccessibilitySize {
                    Spacer(minLength: 0)
                    checkmark(selected)
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(device.title).font(.headline)
                Text(device.detail).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if connected == device {
                    Text("Connected").font(.caption.weight(.semibold)).foregroundStyle(.green)
                }
            }
            if !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: 0)
                checkmark(selected)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(selected ? Color.blue : Color.secondary.opacity(0.25), lineWidth: selected ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }

    private func checkmark(_ selected: Bool) -> some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(selected ? .blue : .secondary)
            .accessibilityHidden(true)
    }
}

enum AppleHealthCopy {
    static let noData = "No Apple Watch data has arrived yet. If you turned off access, open Settings, then Privacy & Security, Health, Conceptual Fitness."
}

enum DeviceSwitchCopy {
    static func confirmation(from old: DataSourceDevice, to new: DataSourceDevice) -> String {
        let stop = old == .fitbit ? "Fitbit imports will stop and its Google access will be removed." : "Apple Watch imports will stop."
        return "\(stop) Your history stays. Scores recalibrate over the next few weeks for readings \(new.shortName) measures differently."
    }
}

struct DataSourcesView: View {
    @ObservedObject var authStore: AuthStore
    @ObservedObject var coordinator: AppSyncCoordinator
    @State private var selection: DataSourceDevice?
    @State private var pendingSwitch: DataSourceDevice?
    @State private var confirmsDisconnect = false
    @State private var isUpdating = false
    @State private var errorMessage: String?

    private var connection: HealthConnectionStatus? { authStore.connectedSession?.healthConnection }
    private var active: DataSourceDevice? { connection?.activeDevice }

    var body: some View {
        Form {
            Section {
                DeviceChoiceList(selection: $selection, connected: connection?.status == .connected ? active : nil)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            } footer: {
                Text("One device at a time.")
            }

            if let active, connection?.status == .errored {
                Section {
                    Label("\(active.shortName) needs attention", systemImage: "exclamationmark.triangle")
                    Text("Imports stopped. Reconnect to continue.").foregroundStyle(.secondary)
                }
            }

            Section {
                if isUpdating {
                    ProgressView("Updating connection…")
                } else if let selection {
                    if selection == active && connection?.status == .connected {
                        Button("Disconnect \(selection.shortName)", role: .destructive) { confirmsDisconnect = true }
                    } else {
                        Button(selection == active ? "Reconnect \(selection.shortName)" : "Connect \(selection.shortName)") {
                            if let active, active != selection, connection?.status == .connected {
                                pendingSwitch = selection
                            } else {
                                Task { await connect(selection) }
                            }
                        }
                    }
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                        .accessibilityLabel("Connection error: \(errorMessage)")
                }
            }

            if active != nil && connection?.status == .connected {
                Section("Sync") {
                    LabeledContent("Last synced", value: coordinator.lastSyncAt?.formatted(date: .abbreviated, time: .shortened) ?? "Not synced yet")
                    if let connected = DashboardFormatters.parseBackendDateTime(connection?.connectedAt) {
                        LabeledContent("Connected", value: connected.formatted(date: .abbreviated, time: .omitted))
                    }
                    if let message = coordinator.failureMessage { Text(message).foregroundStyle(.secondary) }
                    if active == .appleWatch && coordinator.appleHealthLooksEmpty {
                        Text(AppleHealthCopy.noData).font(.footnote).foregroundStyle(.secondary)
                    }
                    Button(coordinator.isSyncing ? "Syncing…" : "Sync now") { Task { await coordinator.retry() } }
                        .disabled(coordinator.isSyncing)
                }
            }
        }
        .navigationTitle("Data sources")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if selection == nil { selection = active ?? connection?.device } }
        .confirmationDialog(
            "Switch to \(pendingSwitch?.shortName ?? "")?",
            isPresented: Binding(get: { pendingSwitch != nil }, set: { if !$0 { pendingSwitch = nil } }),
            titleVisibility: .visible,
            presenting: pendingSwitch
        ) { device in
            Button("Switch to \(device.shortName)") { Task { await connect(device) } }
            Button("Cancel", role: .cancel) {}
        } message: { device in
            if let active { Text(DeviceSwitchCopy.confirmation(from: active, to: device)) }
        }
        .confirmationDialog(
            "Disconnect \(active?.shortName ?? "")?",
            isPresented: $confirmsDisconnect,
            titleVisibility: .visible
        ) {
            if let active {
                Button("Disconnect \(active.shortName)", role: .destructive) { Task { await disconnect(active) } }
            }
        } message: {
            Text("Imports stop and scores pause until you connect a source. Saved data stays in your account.")
        }
    }

    @MainActor private func connect(_ device: DataSourceDevice) async {
        guard !isUpdating else { return }
        isUpdating = true
        errorMessage = nil
        errorMessage = await authStore.connect(device)
        isUpdating = false
        if errorMessage == nil { await coordinator.retry() }
    }

    @MainActor private func disconnect(_ device: DataSourceDevice) async {
        isUpdating = true
        errorMessage = await authStore.disconnect(device)
        isUpdating = false
    }
}

struct ConnectSourceCard<Destination: View>: View {
    let connection: HealthConnectionStatus?
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: needsAttention ? "exclamationmark.triangle" : "link.badge.plus")
                .font(.headline)
            Text(message)
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            NavigationLink(needsAttention ? "Reconnect" : "Choose a device", destination: destination)
                .buttonStyle(.borderedProminent)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal)
        .accessibilityElement(children: .contain)
    }

    private var needsAttention: Bool { connection?.status == .errored }

    private var title: String {
        if needsAttention, let device = connection?.device { return "\(device.shortName) needs attention" }
        return "Connect a source"
    }

    private var message: String {
        if needsAttention { return "Imports stopped. Reconnect to keep your scores up to date." }
        return "Scores need an Apple Watch or Fitbit. Journal and workouts work without one."
    }
}
