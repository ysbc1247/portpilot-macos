import Foundation
import XCTest
@testable import DevBerth

final class KeychainMigrationTests: XCTestCase {
    func testLegacySecretIsCopiedToCurrentServiceOnFirstRead() async throws {
        let accessor = InMemoryKeychainAccessor()
        let reference = UUID()
        try accessor.save(
            data: Data("legacy secret".utf8),
            service: ProductIdentity.legacyKeychainService,
            account: reference.uuidString
        )
        let store = KeychainSecretStore(accessor: accessor)

        let migratedValue = try await store.value(for: reference)
        XCTAssertEqual(migratedValue, "legacy secret")
        XCTAssertEqual(
            try accessor.read(service: ProductIdentity.currentKeychainService, account: reference.uuidString),
            Data("legacy secret".utf8)
        )
    }

    func testCurrentSecretWinsAndDeleteCleansBothServices() async throws {
        let accessor = InMemoryKeychainAccessor()
        let reference = UUID()
        try accessor.save(data: Data("legacy".utf8), service: ProductIdentity.legacyKeychainService, account: reference.uuidString)
        try accessor.save(data: Data("current".utf8), service: ProductIdentity.currentKeychainService, account: reference.uuidString)
        let store = KeychainSecretStore(accessor: accessor)

        let currentValue = try await store.value(for: reference)
        XCTAssertEqual(currentValue, "current")
        try await store.delete(reference: reference)
        XCTAssertNil(try accessor.read(service: ProductIdentity.currentKeychainService, account: reference.uuidString))
        XCTAssertNil(try accessor.read(service: ProductIdentity.legacyKeychainService, account: reference.uuidString))
    }
}

private final class InMemoryKeychainAccessor: KeychainAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func save(data: Data, service: String, account: String) throws {
        lock.withLock { values[key(service: service, account: account)] = data }
    }

    func read(service: String, account: String) throws -> Data? {
        lock.withLock { values[key(service: service, account: account)] }
    }

    func delete(service: String, account: String) throws {
        _ = lock.withLock { values.removeValue(forKey: key(service: service, account: account)) }
    }

    private func key(service: String, account: String) -> String { "\(service):\(account)" }
}
