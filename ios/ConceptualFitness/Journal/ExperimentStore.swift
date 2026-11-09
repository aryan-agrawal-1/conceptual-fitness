import Foundation
import OSLog
import SwiftUI

@MainActor
final class ExperimentStore: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed
    }

    enum Action: Equatable {
        case idle
        case working
        case failed(String)
    }

    @Published private(set) var experiment: Experiment?
    @Published private(set) var phase = Phase.idle
    @Published private(set) var action = Action.idle
    private let authStore: AuthStore
    private let dataEpoch: Int
    private let perform: @MainActor (URLRequest) async throws -> Data
    private let logger = Logger(subsystem: "ConceptualFitness", category: "Experiments")

    init(authStore: AuthStore, perform: (@MainActor (URLRequest) async throws -> Data)? = nil) {
        self.authStore = authStore
        self.perform = perform ?? { try await authStore.authenticatedData(for: $0) }
        dataEpoch = authStore.localDataEpoch
    }

    var active: Experiment? { experiment?.isActive == true ? experiment : nil }

    func isRunning(_ story: PatternStory) -> Bool {
        guard let active else { return false }
        return active.inputId == story.inputId && active.stratum == story.stratum
    }

    func load() async {
        guard authStore.localDataEpoch == dataEpoch, phase != .loading else { return }
        phase = .loading
        do {
            let next = try await send(URLRequest(url: url("insights/experiment")))
            guard authStore.localDataEpoch == dataEpoch else { return }
            experiment = next.experiment
            phase = .loaded
            logger.info("Experiment loaded; present=\(next.experiment != nil)")
        } catch where error is CancellationError || (error as? URLError)?.code == .cancelled {
            phase = experiment == nil ? .idle : .loaded
        } catch {
            phase = experiment == nil ? .failed : .loaded
            logger.error("Experiment load failed; status=\(Self.status(error)); reason=request_failure")
        }
    }

    func setup(for finding: PatternFinding) async throws -> ExperimentSetup {
        guard var components = URLComponents(url: url("insights/experiment/setup"), resolvingAgainstBaseURL: false)
        else { throw URLError(.badURL) }
        components.queryItems = [URLQueryItem(name: "pair_id", value: finding.pairId),
                                 URLQueryItem(name: "stratum", value: finding.stratum)]
        guard let address = components.url else { throw URLError(.badURL) }
        let data = try await perform(URLRequest(url: address))
        return try JournalCoding.decoder().decode(ExperimentSetupResponse.self, from: data).setup
    }

    @discardableResult
    func start(_ finding: PatternFinding, change: String? = nil) async -> Bool {
        var request = URLRequest(url: url("insights/experiment"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JournalCoding.encoder().encode(
                ExperimentStartRequest(pairId: finding.pairId, stratum: finding.stratum, behaviourId: change))
        } catch {
            return false
        }
        return await run(request, name: "start")
    }

    @discardableResult
    func restart() async -> Bool {
        var request = URLRequest(url: url("insights/experiment/restart"))
        request.httpMethod = "POST"
        return await run(request, name: "restart")
    }

    @discardableResult
    func stop() async -> Bool {
        var request = URLRequest(url: url("insights/experiment/stop"))
        request.httpMethod = "POST"
        return await run(request, name: "stop")
    }

    func clearError() {
        if case .failed = action { action = .idle }
    }

    private func run(_ request: URLRequest, name: String) async -> Bool {
        guard authStore.localDataEpoch == dataEpoch, action != .working else { return false }
        action = .working
        do {
            let next = try await send(request)
            guard authStore.localDataEpoch == dataEpoch else { return false }
            experiment = next.experiment
            phase = .loaded
            action = .idle
            logger.info("Experiment \(name, privacy: .public) succeeded")
            return true
        } catch {
            let code = (error as? HTTPResponseError)?.code
            action = .failed(Self.message(code, name: name))
            logger.error("Experiment \(name, privacy: .public) failed; status=\(Self.status(error)); code=\(code ?? "none", privacy: .public)")
            if ["experiment_active", "no_active_experiment", "nothing_to_restart"].contains(code) { await reload() }
            return false
        }
    }

    private func reload() async {
        phase = .idle
        await load()
    }

    private func send(_ request: URLRequest) async throws -> ExperimentResponse {
        try JournalCoding.decoder().decode(ExperimentResponse.self, from: try await perform(request))
    }

    private func url(_ path: String) -> URL { authStore.baseURL.appendingPathComponent(path) }

    private static func status(_ error: Error) -> Int { (error as? HTTPResponseError)?.statusCode ?? 0 }

    static func message(_ code: String?, name: String) -> String {
        switch code {
        case "experiment_active": "Another experiment is already running. Stop it first to start a new one."
        case "not_testable": "This pattern can’t be tested right now. It may have changed since you opened it."
        case "no_active_experiment": "This experiment has already ended."
        case "change_not_available": "That change isn’t available any more. Go back and pick another one."
        case "nothing_to_restart": "This experiment can’t be restarted any more."
        default: "Couldn’t \(name) the experiment. Check your connection and try again."
        }
    }
}
