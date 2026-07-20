import Foundation
import Security

actor KeychainSecretStore: SecretStoring {
    private let service = "com.ysbc.portpilot.secrets"

    func save(value: String, reference: UUID) async throws {
        guard let data = value.data(using: .utf8) else {
            throw PortPilotError.unexpected("The secret could not be encoded for Keychain storage.")
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference.uuidString
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
            guard status == errSecSuccess else { throw keychainError(status, operation: "save") }
        } else if updateStatus != errSecSuccess {
            throw keychainError(updateStatus, operation: "update")
        }
    }

    func value(for reference: UUID) async throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw keychainError(status, operation: "read")
        }
        return String(data: data, encoding: .utf8)
    }

    func delete(reference: UUID) async throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference.uuidString
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status, operation: "delete")
        }
    }

    private func keychainError(_ status: OSStatus, operation: String) -> PortPilotError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain status \(status)"
        return .unexpected("Could not \(operation) the Keychain item: \(message)")
    }
}

