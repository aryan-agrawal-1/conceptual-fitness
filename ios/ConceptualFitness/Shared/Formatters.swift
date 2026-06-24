import Foundation

extension String {
    var displayTitle: String {
        split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

enum DashboardFormatters {
    static let workoutTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    static let lastSyncedTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static let shortDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    static func parseBackendDateTime(_ value: String?) -> Date? {
        guard let value else { return nil }
        if let date = ISO8601DateFormatter.backend.date(from: value) {
            return date
        }
        return ISO8601DateFormatter.fractionalBackend.date(from: value)
    }
}

extension ISO8601DateFormatter {
    static let backend: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static let fractionalBackend: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
