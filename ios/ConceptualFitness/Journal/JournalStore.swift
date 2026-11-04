import Foundation
import OSLog
import SwiftUI

@MainActor
final class JournalStore: ObservableObject {
    @Published private(set) var snapshot = JournalSnapshot()
    @Published private(set) var isSyncing = false
    @Published private(set) var hasSettled = false
    @Published private(set) var message: String?
    @Published private(set) var storageBlocked = false
    private let authStore: AuthStore
    private let fileURL: URL
    private let logger = Logger(subsystem: "ConceptualFitness", category: "Journal")
    private var worker: Task<Void, Never>?
    private var syncAgain = false
    private var isActive = true
    private var lastSyncFailed = false
    private let dataEpoch: Int
    private let perform: @MainActor (URLRequest) async throws -> Data

    init(authStore: AuthStore, userID: String, fileURL: URL? = nil,
         perform: (@MainActor (URLRequest) async throws -> Data)? = nil) {
        self.authStore = authStore
        self.perform = perform ?? { try await authStore.authenticatedData(for: $0) }
        dataEpoch = authStore.localDataEpoch
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Journal", isDirectory: true).appendingPathComponent("\(userID).json")
        restore()
    }

    var pendingCount: Int {
        snapshot.entries.filter(\.pending).count + snapshot.preferences.filter(\.pending).count
            + snapshot.completions.filter(\.pending).count
    }
    var timezone: String? { snapshot.timezone }
    private var syncableEntries: [JournalEntryData] {
        let sensitive = Set(snapshot.catalogue?.categories.filter(\.requiresOptIn).map(\.id) ?? [])
        return snapshot.entries.filter { entry in
            guard entry.pending else { return false }
            if entry.deleted { return true }
            guard let item = snapshot.catalogue?.behaviours.first(where: { $0.id == entry.behaviourId }) else { return false }
            return !sensitive.contains(item.categoryId) || enabled("opt_in:\(item.categoryId)")
        }
    }
    var needsRetry: Bool {
        lastSyncFailed || snapshot.catalogue == nil || !syncableEntries.isEmpty
            || snapshot.preferences.contains(where: \.pending)
            || snapshot.completions.contains(where: \.pending)
    }
    var today: String { JournalCoding.day(Date(), timezone: timezone ?? "UTC") }
    func enabled(_ key: String) -> Bool { snapshot.preferences.first { $0.key == key }?.value == true }
    func entry(_ behaviour: String, day: String) -> JournalEntryData? {
        snapshot.entries.first { $0.behaviourId == behaviour && $0.journalDate == day && !$0.deleted }
    }

    func save(_ response: JournalResponseData) -> Bool {
        var next = snapshot
        let entry = JournalEntryData(journalDate: response.journalDate, behaviourId: response.behaviourId,
                                     editedAt: nextStamp(), mutationId: UUID().uuidString.lowercased(),
                                     deleted: false, response: response, pending: true)
        next.entries.removeAll { $0.id == entry.id }
        next.entries.append(entry)
        withdrawCompletionIfNeeded(response.journalDate, in: &next)
        guard persist(next) else { return false }
        scheduleSync()
        return true
    }

    @discardableResult
    func delete(_ behaviour: String, day: String) -> Bool {
        var next = snapshot
        let entry = JournalEntryData(journalDate: day, behaviourId: behaviour, editedAt: nextStamp(),
                                     mutationId: UUID().uuidString.lowercased(), deleted: true,
                                     response: nil, pending: true)
        next.entries.removeAll { $0.id == entry.id }
        next.entries.append(entry)
        withdrawCompletionIfNeeded(day, in: &next)
        guard persist(next) else { return false }
        scheduleSync()
        return true
    }

    @discardableResult
    func complete(day: String) -> Bool {
        guard JournalDailyList.reachedTarget(JournalDailyList.loggedCount(snapshot, day: day)) else { return false }
        var next = snapshot
        let stamp = nextStamp()
        let existing = snapshot.completions.first { $0.journalDate == day }
        next.completions.removeAll { $0.journalDate == day }
        next.completions.append(JournalCompletionData(
            journalDate: day, completed: true, firstCompletedAt: existing?.firstCompletedAt ?? stamp,
            timezone: existing?.timezone ?? timezone ?? "UTC", editedAt: stamp,
            mutationId: UUID().uuidString.lowercased(), pending: true))
        guard persist(next) else { return false }
        scheduleSync()
        return true
    }

    func completion(day: String) -> JournalCompletionData? {
        snapshot.completions.first { $0.journalDate == day }
    }

    private func withdrawCompletionIfNeeded(_ day: String, in next: inout JournalSnapshot) {
        guard let index = next.completions.firstIndex(where: { $0.journalDate == day && $0.completed }),
              !JournalDailyList.reachedTarget(JournalDailyList.loggedCount(next, day: day)) else { return }
        next.completions[index].completed = false
        next.completions[index].editedAt = nextStamp()
        next.completions[index].mutationId = UUID().uuidString.lowercased()
        next.completions[index].pending = true
    }

    func set(_ key: String, value: Bool) {
        var next = snapshot
        next.preferences.removeAll { $0.key == key }
        next.preferences.append(JournalSettingData(key: key, value: value, editedAt: nextStamp(),
                                                   mutationId: UUID().uuidString.lowercased(), pending: true))
        if persist(next) { scheduleSync() }
    }

    func isPinned(_ behaviour: JournalBehaviourData) -> Bool {
        JournalDailyList.isPinned(behaviour, in: snapshot)
    }

    @discardableResult
    func answer(_ behaviour: JournalBehaviourData, day: String, answer: JournalAnswerData?,
                details: [String: JournalAnswerData] = [:], missingReason: String? = nil) -> Bool {
        save(.updating(entry(behaviour.id, day: day)?.response, behaviourId: behaviour.id, day: day,
                       catalogueVersion: snapshot.catalogue?.version ?? 1, timezone: timezone ?? "UTC",
                       answer: answer, details: details, missingReason: missingReason))
    }

    func setCategory(_ category: String, enabled: Bool) {
        set("opt_in:\(category)", value: enabled)
    }

    func restore() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            snapshot = try JournalCoding.decoder().decode(JournalSnapshot.self, from: Data(contentsOf: fileURL))
            storageBlocked = false
            message = nil
        } catch {
            storageBlocked = true
            message = "The saved journal couldn’t open. Unlock your device and retry. Your saved file has been preserved."
            logger.error("Journal restore failed; reason=local_storage")
        }
    }

    func synchronize() async {
        guard isActive, authStore.localDataEpoch == dataEpoch else { return }
        if storageBlocked { restore() }
        guard !storageBlocked else { return }
        guard !isSyncing else { syncAgain = true; return }
        isSyncing = true
        defer {
            isSyncing = false
            hasSettled = true
        }
        do {
            if snapshot.catalogue == nil { try await downloadCatalogue() }
            repeat {
                syncAgain = false
                try await pullChanges()
                let pendingEntries = Array(syncableEntries.prefix(100))
                let pendingSettings = Array(snapshot.preferences.filter(\.pending).prefix(100))
                let pendingCompletions = Array(snapshot.completions.filter(\.pending).prefix(100))
                if !pendingEntries.isEmpty || !pendingSettings.isEmpty || !pendingCompletions.isEmpty {
                    let receipt: JournalReceipt = try await send(JournalPush(
                        entries: pendingEntries.map(JournalEntryWrite.init),
                        preferences: pendingSettings.map(JournalSettingWrite.init),
                        completions: pendingCompletions.map(JournalCompletionWrite.init)))
                    var next = snapshot
                    merge(receipt.acknowledgements, into: &next)
                    guard persist(next) else { return }
                    try await pullChanges()
                }
            } while syncAgain || !syncableEntries.isEmpty || snapshot.preferences.contains(where: \.pending)
                || snapshot.completions.contains(where: \.pending)
            lastSyncFailed = false
            message = pendingCount > 0 ? "Private changes are saved on this device. Enable their categories to sync them, or delete the responses." : nil
        } catch is CancellationError {
        } catch {
            let status = (error as? HTTPResponseError)?.statusCode ?? 0
            if status == 422 { try? await pullChanges() }
            lastSyncFailed = true
            message = Self.failureMessage(for: error)
            logger.error("Journal sync failed; status=\(status); reason=request_failure")
        }
    }

    static func failureMessage(for error: Error) -> String {
        let response = error as? HTTPResponseError
        if response?.code == "clock_ahead" {
            return "Your device clock is ahead, so changes can’t sync. Set the date and time automatically in Settings. Saved entries stay on this device."
        }
        return response?.statusCode == 422
            ? "Some saved changes need attention. Check private category access and answer limits, then retry."
            : "Journal is offline. Saved entries stay on this device and will retry when you reconnect."
    }

    private func pullChanges() async throws {
        var hasMore = true
        while hasMore {
            try Task.checkCancellation()
            let page: JournalPage = try await get("/journal/changes?after=\(snapshot.cursor)")
            hasMore = page.hasMore
            if let version = page.catalogueVersion, version > snapshot.catalogue?.version ?? 0 {
                try await downloadCatalogue(version: version)
            }
            guard !page.changes.isEmpty || page.cursor != snapshot.cursor || page.timezone != snapshot.timezone
                    || page.goals != snapshot.goals || page.analysisRevision != snapshot.analysisRevision
            else { continue }
            var next = snapshot
            merge(page.changes, into: &next)
            next.cursor = page.cursor
            next.timezone = page.timezone
            next.goals = page.goals
            next.analysisRevision = page.analysisRevision
            guard persist(next) else { throw CancellationError() }
        }
    }

    private func downloadCatalogue(version: Int? = nil) async throws {
        let catalogue: JournalCatalogueData = try await get(
            "/journal/catalogue" + (version.map { "?version=\($0)" } ?? ""))
        var next = snapshot
        next.catalogue = catalogue
        guard persist(next) else { throw CancellationError() }
    }

    func stop() {
        isActive = false
        worker?.cancel()
    }

    static func pendingExport(userID: String) throws -> JournalPush {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Journal", isDirectory: true).appendingPathComponent("\(userID).json")
        guard FileManager.default.fileExists(atPath: url.path) else { return JournalPush(entries: [], preferences: []) }
        let snapshot = try JournalCoding.decoder().decode(JournalSnapshot.self, from: Data(contentsOf: url))
        return JournalPush(entries: snapshot.entries.filter(\.pending).map(JournalEntryWrite.init),
                           preferences: snapshot.preferences.filter(\.pending).map(JournalSettingWrite.init),
                           completions: snapshot.completions.filter(\.pending).map(JournalCompletionWrite.init))
    }

    private func nextStamp() -> String {
        let latest = (snapshot.entries.map(\.editedAt) + snapshot.preferences.map(\.editedAt)
                      + snapshot.completions.map(\.editedAt))
            .map(JournalCoding.instant).max() ?? .distantPast
        return JournalCoding.timestamp(max(Date(), latest.addingTimeInterval(0.001)))
    }

    private func scheduleSync() {
        if isSyncing { syncAgain = true; return }
        worker?.cancel()
        worker = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            await self?.synchronize()
        }
    }

    private func merge(_ changes: [JournalChange], into next: inout JournalSnapshot) {
        for change in changes {
            if let remote = change.entry {
                if let index = next.entries.firstIndex(where: { $0.id == remote.id }) {
                    let local = next.entries[index]
                    if local.mutationId == remote.mutationId || JournalCoding.newer(
                        remote.editedAt, remote.mutationId, than: local.editedAt, local.mutationId) {
                        next.entries[index] = remote
                    }
                } else { next.entries.append(remote) }
            }
            if let remote = change.setting {
                if let index = next.preferences.firstIndex(where: { $0.key == remote.key }) {
                    let local = next.preferences[index]
                    if local.mutationId == remote.mutationId || JournalCoding.newer(
                        remote.editedAt, remote.mutationId, than: local.editedAt, local.mutationId) {
                        next.preferences[index] = remote
                    }
                } else { next.preferences.append(remote) }
            }
            if let remote = change.completion {
                if let index = next.completions.firstIndex(where: { $0.id == remote.id }) {
                    let local = next.completions[index]
                    var winner = local.mutationId == remote.mutationId || JournalCoding.newer(
                        remote.editedAt, remote.mutationId, than: local.editedAt, local.mutationId) ? remote : local
                    let earliest = JournalCoding.instant(remote.firstCompletedAt) < JournalCoding.instant(local.firstCompletedAt)
                        ? remote : local
                    winner.firstCompletedAt = earliest.firstCompletedAt
                    winner.timezone = earliest.timezone
                    next.completions[index] = winner
                } else { next.completions.append(remote) }
            }
        }
    }

    private func persist(_ next: JournalSnapshot) -> Bool {
        guard !storageBlocked, isActive, authStore.localDataEpoch == dataEpoch else { return false }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JournalCoding.encoder().encode(next)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
            var url = fileURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
            snapshot = next
            return true
        } catch {
            message = "Couldn’t save on this device. Free some storage or unlock your device, then retry before leaving this screen."
            logger.error("Journal save failed; reason=local_storage")
            return false
        }
    }

    private func get<Response: Decodable>(_ path: String) async throws -> Response {
        let request = URLRequest(url: URL(string: path, relativeTo: authStore.baseURL)!.absoluteURL)
        let data = try await perform(request)
        return try JournalCoding.decoder().decode(Response.self, from: data)
    }

    private func send(_ body: JournalPush) async throws -> JournalReceipt {
        var request = URLRequest(url: authStore.baseURL.appendingPathComponent("journal/sync"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JournalCoding.encoder().encode(body)
        let data = try await perform(request)
        return try JournalCoding.decoder().decode(JournalReceipt.self, from: data)
    }
}
