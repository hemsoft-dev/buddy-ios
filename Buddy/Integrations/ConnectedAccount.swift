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
    func upsertIfMissing(_ account: ConnectedAccountRecord) async throws -> Bool
    func replace(
        _ expected: ConnectedAccountRecord,
        with replacement: ConnectedAccountRecord?
    ) async throws -> Bool
    func remove(_ id: ConnectedAccountID) async throws
}

actor UserDefaultsConnectedAccountStore: ConnectedAccountStoring {
    static let key = "connected-accounts.v1"

    private let defaults: UserDefaults
    private var records: [ConnectedAccountRecord]
    private let loadingError: Error?

    init(defaults: sending UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.key) else {
            records = []
            loadingError = nil
            return
        }
        do {
            records = try JSONDecoder().decode([ConnectedAccountRecord].self, from: data)
            loadingError = nil
        } catch {
            records = []
            loadingError = error
        }
    }

    func accounts(for provider: IntegrationProvider) throws -> [ConnectedAccountRecord] {
        try ensureLoaded()
        return records.filter { $0.id.provider == provider }.sorted { $0.id < $1.id }
    }

    func upsert(_ account: ConnectedAccountRecord) throws {
        try ensureLoaded()
        records.removeAll { $0.id == account.id }
        records.append(account)
        try persist()
    }

    func upsertIfMissing(_ account: ConnectedAccountRecord) throws -> Bool {
        try ensureLoaded()
        guard !records.contains(where: { $0.id == account.id }) else { return false }
        records.append(account)
        try persist()
        return true
    }

    func replace(
        _ expected: ConnectedAccountRecord,
        with replacement: ConnectedAccountRecord?
    ) throws -> Bool {
        try ensureLoaded()
        guard let index = records.firstIndex(where: { $0.id == expected.id }),
              records[index] == expected
        else {
            return false
        }
        if let replacement {
            records[index] = replacement
        } else {
            records.remove(at: index)
        }
        try persist()
        return true
    }

    func remove(_ id: ConnectedAccountID) throws {
        try ensureLoaded()
        records.removeAll { $0.id == id }
        try persist()
    }

    private func persist() throws {
        defaults.set(try JSONEncoder().encode(records.sorted { $0.id < $1.id }), forKey: Self.key)
    }

    private func ensureLoaded() throws {
        if let loadingError { throw loadingError }
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

    func upsertIfMissing(_ account: ConnectedAccountRecord) -> Bool {
        guard !records.contains(where: { $0.id == account.id }) else { return false }
        records.append(account)
        return true
    }

    func replace(
        _ expected: ConnectedAccountRecord,
        with replacement: ConnectedAccountRecord?
    ) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == expected.id }),
              records[index] == expected
        else {
            return false
        }
        if let replacement {
            records[index] = replacement
        } else {
            records.remove(at: index)
        }
        return true
    }

    func remove(_ id: ConnectedAccountID) {
        records.removeAll { $0.id == id }
    }
}
