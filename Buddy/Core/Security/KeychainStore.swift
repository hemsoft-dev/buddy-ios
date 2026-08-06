import Foundation
import Security

actor KeychainStore {
    private let service: String

    init(service: String = Bundle.main.bundleIdentifier ?? "com.hemsoft.buddy") {
        self.service = service
    }

    func set(_ data: Data, for account: String) throws {
        let query = baseQuery(for: account)
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unhandledStatus(addStatus)
            }
        } else if status != errSecSuccess {
            throw KeychainError.unhandledStatus(status)
        }
    }

    /// Atomically restores a credential only when no newer value exists.
    func setIfMissing(_ data: Data, for account: String) throws -> Bool {
        guard try self.data(for: account) == nil else { return false }
        try set(data, for: account)
        return true
    }

    func data(for account: String) throws -> Data? {
        var query = baseQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.unhandledStatus(status)
        }

        return data
    }

    func removeData(for account: String) throws {
        let status = SecItemDelete(baseQuery(for: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledStatus(status)
        }
    }

    /// Atomically compares and removes within this actor so a concurrent reconnect
    /// cannot have its replacement credential deleted by a stale request.
    func removeData(for account: String, ifMatches expectedData: Data) throws -> Bool {
        guard try data(for: account) == expectedData else { return false }
        try removeData(for: account)
        return true
    }

    private func baseQuery(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
    }
}

enum KeychainError: Error, Equatable {
    case unhandledStatus(OSStatus)
}
