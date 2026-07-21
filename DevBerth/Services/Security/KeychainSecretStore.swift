import Foundation
import Security

protocol KeychainAccessing: Sendable {
    func save(data: Data, service: String, account: String) throws
    func read(service: String, account: String) throws -> Data?
    func delete(service: String, account: String) throws
}

struct SecurityKeychainAccessor: KeychainAccessing {
    func save(data: Data, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var insert = query
            attributes.forEach { insert[$0.key] = $0.value }
            let status = SecItemAdd(insert as CFDictionary, nil)
            guard status == errSecSuccess else { throw Self.error(status, operation: "save") }
        } else if updateStatus != errSecSuccess {
            throw Self.error(updateStatus, operation: "update")
        }
    }

    func read(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw Self.error(status, operation: "read")
        }
        return data
    }

    func delete(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.error(status, operation: "delete")
        }
    }

    private static func error(_ status: OSStatus, operation: String) -> DevBerthError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain status \(status)"
        return .unexpected("Could not \(operation) the Keychain item: \(message)")
    }
}

actor KeychainSecretStore: SecretStoring {
    private let accessor: any KeychainAccessing
    private let currentService: String
    private let legacyServices: [String]

    init(
        accessor: any KeychainAccessing = SecurityKeychainAccessor(),
        currentService: String = ProductIdentity.currentKeychainService,
        legacyServices: [String] = [ProductIdentity.legacyKeychainService]
    ) {
        self.accessor = accessor
        self.currentService = currentService
        self.legacyServices = legacyServices.filter { $0 != currentService }
    }

    func save(value: String, reference: UUID) async throws {
        guard let data = value.data(using: .utf8) else {
            throw DevBerthError.unexpected("The secret could not be encoded for Keychain storage.")
        }
        try accessor.save(data: data, service: currentService, account: reference.uuidString)
    }

    func value(for reference: UUID) async throws -> String? {
        if let current = try accessor.read(service: currentService, account: reference.uuidString) {
            return String(data: current, encoding: .utf8)
        }
        for legacyService in legacyServices {
            guard let legacy = try accessor.read(service: legacyService, account: reference.uuidString) else { continue }
            try accessor.save(data: legacy, service: currentService, account: reference.uuidString)
            return String(data: legacy, encoding: .utf8)
        }
        return nil
    }

    func delete(reference: UUID) async throws {
        try accessor.delete(service: currentService, account: reference.uuidString)
        for legacyService in legacyServices {
            try accessor.delete(service: legacyService, account: reference.uuidString)
        }
    }
}
