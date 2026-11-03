import OSLog
import SwiftUI
import UserNotifications

struct JournalReminderSettings: Codable, Equatable {
    var enabled = false
    var hour = 9
    var minute = 0
}

enum JournalReminderPlan {
    static let title = "Daily check-in"
    static let body = "Your check-in is ready."
    static let identifierPrefix = "journalReminder."
    // Individual dates rather than a repeat, because a repeat can't skip a day that's already done.
    static let horizonDays = 30
    static let eveningHour = 12

    static func fireDates(_ settings: JournalReminderSettings, snapshot: JournalSnapshot, now: Date = Date(),
                          calendar: Calendar = .current) -> [Date] {
        guard settings.enabled, let timezone = snapshot.timezone else { return [] }
        let index = JournalDayIndex(snapshot, today: JournalCoding.day(now, timezone: timezone))
        let start = calendar.startOfDay(for: now)
        return (0..<horizonDays).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start),
                  let fire = calendar.date(bySettingHour: settings.hour, minute: settings.minute, second: 0, of: day),
                  fire > now else { return nil }
            let journalDay = JournalCoding.day(fire, timezone: timezone)
            if index.isCompleted(journalDay) { return nil }
            if settings.hour < eveningHour, index.isCompleted(JournalDay.previous(journalDay)) { return nil }
            return fire
        }
    }
}

@MainActor
final class JournalReminders: ObservableObject {
    @Published private(set) var settings: JournalReminderSettings
    @Published private(set) var offered: Bool
    @Published private(set) var permissionDenied = false
    private let userID: String
    private let logger = Logger(subsystem: "ConceptualFitness", category: "Journal")
    private var scheduling: Task<Void, Never>?
    private var latest: JournalSnapshot?
    private var stopped = false
    private var settingsKey: String { "journalReminder.\(userID)" }
    private var offeredKey: String { "journalReminderOffered.\(userID)" }

    init(userID: String) {
        self.userID = userID
        settings = UserDefaults.standard.data(forKey: "journalReminder.\(userID)")
            .flatMap { try? JSONDecoder().decode(JournalReminderSettings.self, from: $0) } ?? JournalReminderSettings()
        offered = UserDefaults.standard.bool(forKey: "journalReminderOffered.\(userID)")
    }

    var shouldOffer: Bool { !offered && !settings.enabled }

    var time: Date {
        Calendar.current.date(bySettingHour: settings.hour, minute: settings.minute, second: 0, of: Date()) ?? Date()
    }

    func declineOffer() { markOffered() }

    func setEnabled(_ enabled: Bool) async {
        markOffered()
        guard enabled else {
            update { $0.enabled = false }
            return
        }
        let allowed = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
        permissionDenied = !allowed
        update { $0.enabled = allowed }
    }

    func setTime(_ date: Date) {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        update {
            $0.hour = parts.hour ?? $0.hour
            $0.minute = parts.minute ?? $0.minute
        }
    }

    func refreshPermission() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        permissionDenied = settings.enabled && status == .denied
    }

    func refresh(_ snapshot: JournalSnapshot) {
        latest = snapshot
        schedule()
    }

    func stop() {
        stopped = true
        scheduling?.cancel()
        let prefix = "\(JournalReminderPlan.identifierPrefix)\(userID)."
        Task {
            let center = UNUserNotificationCenter.current()
            let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
            center.removePendingNotificationRequests(withIdentifiers: pending)
        }
    }

    private func markOffered() {
        offered = true
        UserDefaults.standard.set(true, forKey: offeredKey)
    }

    private func update(_ change: (inout JournalReminderSettings) -> Void) {
        change(&settings)
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: settingsKey) }
        schedule()
    }

    private func schedule() {
        guard !stopped, let latest else { return }
        let settings = settings
        let prefix = "\(JournalReminderPlan.identifierPrefix)\(userID)."
        scheduling?.cancel()
        scheduling = Task { [logger] in
            let center = UNUserNotificationCenter.current()
            let calendar = Calendar.current
            let wanted = Dictionary(uniqueKeysWithValues: JournalReminderPlan.fireDates(settings, snapshot: latest).map {
                ("\(prefix)\(JournalCoding.day($0, timezone: calendar.timeZone.identifier))", $0)
            })
            let pending = await center.pendingNotificationRequests()
            guard !Task.isCancelled else { return }
            let current = pending.filter { $0.identifier.hasPrefix(prefix) }
            let stale = current.map(\.identifier).filter { wanted[$0] == nil }
            center.removePendingNotificationRequests(withIdentifiers: stale)
            for (identifier, fire) in wanted {
                let content = UNMutableNotificationContent()
                content.title = JournalReminderPlan.title
                content.body = JournalReminderPlan.body
                content.sound = .default
                let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
                do {
                    try await center.add(UNNotificationRequest(
                        identifier: identifier, content: content,
                        trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
                } catch {
                    logger.error("Journal reminder failed; reason=schedule")
                    return
                }
            }
        }
    }
}

// Set at launch so that tapping a reminder from a cold start still reaches the check-in.
final class JournalNotificationRouter: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = JournalNotificationRouter()
    @MainActor @Published var openRequested = false

    // Not the async form: that finishes off the main thread, and UIKit then aborts the app.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let isReminder = response.notification.request.identifier.hasPrefix(JournalReminderPlan.identifierPrefix)
        DispatchQueue.main.async {
            if isReminder { self.openRequested = true }
            completionHandler()
        }
    }
}

struct JournalReminderSection: View {
    @ObservedObject var reminders: JournalReminders
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            Toggle("Daily check-in reminder", isOn: Binding(
                get: { reminders.settings.enabled },
                set: { enabled in Task { await reminders.setEnabled(enabled) } }))
            if reminders.settings.enabled {
                DatePicker("Time", selection: Binding(
                    get: { reminders.time },
                    set: { reminders.setTime($0) }), displayedComponents: .hourAndMinute)
            }
            if reminders.permissionDenied {
                Text("Notifications are off for this app. Turn them on in Settings to get reminders.")
                    .font(.footnote)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Reminders only say “\(JournalReminderPlan.body)” and never name what you track. They skip days you’ve already completed and are set on this device only.")
        }
        .task { await reminders.refreshPermission() }
    }
}
