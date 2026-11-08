import Foundation
import OSLog
import SwiftUI

@MainActor
final class PatternsStore: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed
    }

    @Published private(set) var response: PatternsResponse?
    @Published private(set) var phase = Phase.idle
    @Published private(set) var refreshFailed = false
    private let authStore: AuthStore
    private let dataEpoch: Int
    private let perform: @MainActor (URLRequest) async throws -> Data
    private let logger = Logger(subsystem: "ConceptualFitness", category: "Patterns")
    @Published private var reported = Set<PatternSeenKey>()

    init(authStore: AuthStore, perform: (@MainActor (URLRequest) async throws -> Data)? = nil) {
        self.authStore = authStore
        self.perform = perform ?? { try await authStore.authenticatedData(for: $0) }
        dataEpoch = authStore.localDataEpoch
    }

    var newFindings: Int {
        (response?.stories ?? []).filter { story in
            story.findings.contains { $0.unseen && !reported.contains(PatternSeenKey(pairId: $0.pairId, stratum: $0.stratum)) }
        }.count
    }

    func isUnreported(_ finding: PatternFinding) -> Bool {
        !reported.contains(PatternSeenKey(pairId: finding.pairId, stratum: finding.stratum))
    }

    func load() async {
        guard authStore.localDataEpoch == dataEpoch, phase != .loading else { return }
        phase = .loading
        do {
            let request = URLRequest(url: authStore.baseURL.appendingPathComponent("insights/patterns"))
            let data = try await perform(request)
            let next = try JournalCoding.decoder().decode(PatternsResponse.self, from: data)
            guard authStore.localDataEpoch == dataEpoch else { return }
            response = next
            refreshFailed = false
            phase = .loaded
            logger.info("Patterns loaded; status=\(next.status, privacy: .public); stories=\(next.stories.count)")
        } catch where error is CancellationError || (error as? URLError)?.code == .cancelled {
            phase = response == nil ? .idle : .loaded
        } catch {
            let status = (error as? HTTPResponseError)?.statusCode ?? 0
            refreshFailed = true
            phase = response == nil ? .failed : .loaded
            logger.error("Patterns load failed; status=\(status); reason=request_failure")
        }
    }

    func markSeen(_ story: PatternStory) async {
        await markSeen(story.findings)
    }

    func markSeen(_ findings: [PatternFinding]) async {
        let keys = findings.filter { $0.unseen && $0.state.isFinding }
            .map { PatternSeenKey(pairId: $0.pairId, stratum: $0.stratum) }
            .filter { !reported.contains($0) }
        guard !keys.isEmpty, authStore.localDataEpoch == dataEpoch else { return }
        reported.formUnion(keys)
        do {
            var request = URLRequest(url: authStore.baseURL.appendingPathComponent("insights/patterns/seen"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JournalCoding.encoder().encode(PatternSeenRequest(patterns: keys))
            _ = try await perform(request)
            logger.info("Patterns marked seen; count=\(keys.count)")
        } catch {
            reported.subtract(keys)
            let status = (error as? HTTPResponseError)?.statusCode ?? 0
            logger.error("Patterns seen failed; status=\(status); reason=request_failure")
        }
    }
}
