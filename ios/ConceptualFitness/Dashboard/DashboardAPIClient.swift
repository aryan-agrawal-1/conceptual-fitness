import Foundation

struct DashboardAPIClient {
    var baseURL: URL = URL(string: "http://127.0.0.1:8000")!
    var session: URLSession = .shared

    func loadDashboard() async throws -> DashboardBundle {
        let dateString = Self.apiDate.string(from: Date())
        return try await fetch("/dashboard/bundle?date=\(dateString)")
    }

    private func fetch<T: Decodable>(_ path: String) async throws -> T {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw URLError(.badURL)
        }
        let (data, response) = try await session.data(from: url)
        try validate(response: response)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func validate(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    private static let apiDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
