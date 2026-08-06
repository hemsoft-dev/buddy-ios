import Foundation

enum IntegrationProvider: String, Codable, CaseIterable, Sendable {
    case github
}

/// A provider-qualified identity. Provider user IDs are intentionally used instead of
/// mutable display names so credentials and UI state remain attached to the same account.
struct ConnectedAccountID: Hashable, Codable, Comparable, Sendable {
    let provider: IntegrationProvider
    let subject: String

    var rawValue: String { "\(provider.rawValue):\(subject)" }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.provider.rawValue != rhs.provider.rawValue {
            return lhs.provider.rawValue < rhs.provider.rawValue
        }
        return lhs.subject.localizedStandardCompare(rhs.subject) == .orderedAscending
    }
}

struct ConnectedAccountRecord: Identifiable, Codable, Equatable, Sendable {
    let id: ConnectedAccountID
    var username: String
    var displayName: String?
    var avatarURL: URL?
}

protocol ConnectedAccountStoring: Sendable {
    func accounts(for provider: IntegrationProvider) async throws -> [ConnectedAccountRecord]
    func upsert(_ account: ConnectedAccountRecord) async throws
    func remove(_ id: ConnectedAccountID) async throws
}

actor UserDefaultsConnectedAccountStore: ConnectedAccountStoring {
    private static let key = "connected-accounts.v1"

    private let defaults: UserDefaults
    private var records: [ConnectedAccountRecord]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([ConnectedAccountRecord].self, from: data) {
            records = decoded
        } else {
            records = []
        }
    }

    func accounts(for provider: IntegrationProvider) -> [ConnectedAccountRecord] {
        records.filter { $0.id.provider == provider }.sorted { $0.id < $1.id }
    }

    func upsert(_ account: ConnectedAccountRecord) throws {
        records.removeAll { $0.id == account.id }
        records.append(account)
        try persist()
    }

    func remove(_ id: ConnectedAccountID) throws {
        records.removeAll { $0.id == id }
        try persist()
    }

    private func persist() throws {
        defaults.set(try JSONEncoder().encode(records.sorted { $0.id < $1.id }), forKey: Self.key)
    }
}

actor InMemoryConnectedAccountStore: ConnectedAccountStoring {
    private var records: [ConnectedAccountRecord]

    init(records: [ConnectedAccountRecord] = []) {
        self.records = records
    }

    func accounts(for provider: IntegrationProvider) -> [ConnectedAccountRecord] {
        records.filter { $0.id.provider == provider }.sorted { $0.id < $1.id }
    }

    func upsert(_ account: ConnectedAccountRecord) {
        records.removeAll { $0.id == account.id }
        records.append(account)
    }

    func remove(_ id: ConnectedAccountID) {
        records.removeAll { $0.id == id }
    }
}
