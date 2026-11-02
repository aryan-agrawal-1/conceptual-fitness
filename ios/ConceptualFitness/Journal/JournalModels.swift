import Foundation

struct JournalCatalogueData: Codable {
    let version: Int
    let schemaVersion: Int
    let categories: [JournalCategoryData]
    let behaviours: [JournalBehaviourData]
    let units: [JournalUnitData]
}

struct JournalCategoryData: Codable, Identifiable {
    let id: String
    let label: String
    let requiresOptIn: Bool
}

struct JournalUnitData: Codable {
    let id: String
    let label: String
    let canonicalUnit: String
    let multiplier: Double
}

struct JournalFieldData: Codable, Identifiable {
    let id: String
    let label: String
    let inputType: String
    let minimum: Double?
    let maximum: Double?
    let units: [String]
    let ratingLabels: [String]
}

struct JournalBehaviourData: Codable, Identifiable {
    let id: String
    let categoryId: String
    let label: String
    let question: String
    let answer: JournalFieldData
    let details: [JournalFieldData]
    let presentation: String
    let discreetLabel: String
    let statisticalInput: Bool
    var displayLabel: String { presentation == "discreet" ? discreetLabel : label }
}

enum JournalScalar: Codable, Equatable {
    case boolean(Bool), number(Double), text(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else { self = .text(try container.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .boolean(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .text(let value): try container.encode(value)
        }
    }

    var text: String {
        switch self {
        case .boolean(let value): value ? "Yes" : "No"
        case .number(let value): value.rounded() == value ? String(Int(value)) : String(value)
        case .text(let value): value
        }
    }
}

struct JournalAnswerData: Codable, Equatable {
    let type: String
    let value: JournalScalar
    var unit: String?
}

struct JournalResponseData: Codable {
    var schemaVersion = 1
    var kind = "manual"
    var catalogueVersion: Int
    var journalDate: String
    var timezone: String
    var recordedAt: String
    var observedAt: String?
    var behaviourId: String
    var answer: JournalAnswerData?
    var details: [String: JournalAnswerData] = [:]
    var missingReason: String?
}

extension JournalResponseData {
    // Keeps the original timezone and recording time when an answer changes.
    static func updating(_ existing: JournalResponseData?, behaviourId: String, day: String, catalogueVersion: Int,
                         timezone: String, answer: JournalAnswerData?, details: [String: JournalAnswerData] = [:],
                         missingReason: String? = nil) -> JournalResponseData {
        let keptDetails = answer?.value == .boolean(false) ? [:] : details
        return JournalResponseData(
            catalogueVersion: catalogueVersion, journalDate: day, timezone: existing?.timezone ?? timezone,
            recordedAt: existing?.recordedAt ?? JournalCoding.timestamp(), observedAt: existing?.observedAt,
            behaviourId: behaviourId, answer: answer, details: answer == nil ? [:] : keptDetails,
            missingReason: answer == nil ? missingReason : nil)
    }
}

struct JournalEntryData: Codable, Identifiable {
    var journalDate: String
    var behaviourId: String
    var editedAt: String
    var mutationId: String
    var deleted: Bool
    var response: JournalResponseData?
    var revision: Int = 0
    var pending = false
    var id: String { "\(journalDate)/\(behaviourId)" }
}

struct JournalSettingData: Codable, Identifiable {
    var key: String
    var value: Bool
    var editedAt: String
    var mutationId: String
    var revision: Int = 0
    var pending = false
    var id: String { key }
}

// Wire projections exclude local queue bookkeeping and derived server fields.
struct JournalEntryWrite: Encodable {
    let journalDate: String
    let behaviourId: String
    let editedAt: String
    let mutationId: String
    let deleted: Bool
    let response: JournalResponseData?
    init(_ entry: JournalEntryData) {
        journalDate = entry.journalDate; behaviourId = entry.behaviourId
        editedAt = entry.editedAt; mutationId = entry.mutationId
        deleted = entry.deleted; response = entry.response
    }
}

struct JournalSettingWrite: Encodable {
    let key: String
    let value: Bool
    let editedAt: String
    let mutationId: String
    init(_ setting: JournalSettingData) {
        key = setting.key; value = setting.value
        editedAt = setting.editedAt; mutationId = setting.mutationId
    }
}

struct JournalPush: Encodable {
    let entries: [JournalEntryWrite]
    let preferences: [JournalSettingWrite]
}

struct JournalChange: Decodable {
    let entry: JournalEntryData?
    let setting: JournalSettingData?

    enum CodingKeys: String, CodingKey { case kind }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decode(String.self, forKey: .kind) == "entry" {
            entry = try JournalEntryData(from: decoder); setting = nil
        } else {
            entry = nil; setting = try JournalSettingData(from: decoder)
        }
    }
}

struct JournalPage: Decodable {
    let changes: [JournalChange]
    let cursor: Int
    let hasMore: Bool
    let timezone: String
    let today: String
    let goals: [String]
    let analysisRevision: Int
    let catalogueVersion: Int?
}

struct JournalReceipt: Decodable {
    let acknowledgements: [JournalChange]
}

struct JournalSnapshot: Codable {
    var catalogue: JournalCatalogueData?
    var timezone: String?
    var goals: [String] = []
    var entries: [JournalEntryData] = []
    var preferences: [JournalSettingData] = []
    var cursor = 0
    var analysisRevision = 0
}

enum JournalCoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
    static func timestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .gmt
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    static func instant(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value) ?? .distantPast
    }
    static func newer(_ stamp: String, _ token: String, than otherStamp: String, _ otherToken: String) -> Bool {
        let first = instant(stamp), second = instant(otherStamp)
        return first == second ? token > otherToken : first > second
    }
    static func day(_ date: Date, timezone: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: timezone)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

extension JournalEntryData {
    enum CodingKeys: String, CodingKey {
        case journalDate, behaviourId, editedAt, mutationId, deleted, response, revision, pending
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        journalDate = try values.decode(String.self, forKey: .journalDate)
        behaviourId = try values.decode(String.self, forKey: .behaviourId)
        editedAt = try values.decode(String.self, forKey: .editedAt)
        mutationId = try values.decode(String.self, forKey: .mutationId)
        deleted = try values.decode(Bool.self, forKey: .deleted)
        response = try values.decodeIfPresent(JournalResponseData.self, forKey: .response)
        revision = try values.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        pending = try values.decodeIfPresent(Bool.self, forKey: .pending) ?? false
    }
}

extension JournalSettingData {
    enum CodingKeys: String, CodingKey { case key, value, editedAt, mutationId, revision, pending }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        key = try values.decode(String.self, forKey: .key)
        value = try values.decode(Bool.self, forKey: .value)
        editedAt = try values.decode(String.self, forKey: .editedAt)
        mutationId = try values.decode(String.self, forKey: .mutationId)
        revision = try values.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        pending = try values.decodeIfPresent(Bool.self, forKey: .pending) ?? false
    }
}
