import XCTest
@testable import DevBerth

final class SecretLifecycleTests: XCTestCase {
    func testEnvironmentParserSeparatesSensitiveDuplicateAndInvalidFieldsWithoutValues() {
        let parsed = ManagedEnvironmentParser.parse(
            """
            MODE=development
            API_TOKEN=private-value
            MODE=duplicate
            NOT VALID
            """
        )

        XCTAssertEqual(parsed.values, ["MODE": "development"])
        XCTAssertEqual(parsed.sensitiveNames, ["API_TOKEN"])
        XCTAssertEqual(parsed.duplicateNames, ["MODE"])
        XCTAssertEqual(parsed.invalidLines, ["NOT VALID"])
        XCTAssertFalse(String(describing: parsed).contains("private-value"))
    }

    func testStagedReplacementRollsBackExistingAndNewKeychainValues() async throws {
        let store = MemorySecretStore()
        let existingReference = UUID()
        try await store.save(value: "old-value", reference: existingReference)
        let coordinator = SecretLifecycleCoordinator(store: store)

        let staged = try await coordinator.stage(
            existingReferences: ["API_TOKEN": existingReference],
            retainedNames: ["API_TOKEN", "DATABASE_URL"],
            replacements: ["API_TOKEN": "new-value", "DATABASE_URL": "database-value"]
        )
        let newReference = try XCTUnwrap(staged.references["DATABASE_URL"])
        let updatedValue = try await store.value(for: existingReference)
        let newValue = try await store.value(for: newReference)
        XCTAssertEqual(updatedValue, "new-value")
        XCTAssertEqual(newValue, "database-value")

        await coordinator.rollback(staged)

        let restoredValue = try await store.value(for: existingReference)
        let removedNewValue = try await store.value(for: newReference)
        XCTAssertEqual(restoredValue, "old-value")
        XCTAssertNil(removedNewValue)
    }

    func testFinalizeDeletesRemovedSecretOnlyWhenNoProfileStillReferencesIt() async throws {
        let store = MemorySecretStore()
        let reference = UUID()
        try await store.save(value: "shared-value", reference: reference)
        let coordinator = SecretLifecycleCoordinator(store: store)
        let staged = try await coordinator.stage(
            existingReferences: ["API_TOKEN": reference],
            retainedNames: [],
            replacements: [:]
        )

        try await coordinator.finalize(staged, referencesStillInUse: [reference])
        let retained = try await store.value(for: reference)
        XCTAssertEqual(retained, "shared-value")

        try await coordinator.finalize(staged, referencesStillInUse: [])
        let deleted = try await store.value(for: reference)
        XCTAssertNil(deleted)
    }

    func testDuplicateClonesKeychainReferencesInsteadOfSharingThem() async throws {
        let store = MemorySecretStore()
        let sourceReference = UUID()
        try await store.save(value: "source-value", reference: sourceReference)
        let coordinator = SecretLifecycleCoordinator(store: store)

        let clone = try await coordinator.clone(["API_TOKEN": sourceReference])
        let clonedReference = try XCTUnwrap(clone.references["API_TOKEN"])
        let clonedValue = try await store.value(for: clonedReference)

        XCTAssertNotEqual(clonedReference, sourceReference)
        XCTAssertEqual(clonedValue, "source-value")
    }
}

private actor MemorySecretStore: SecretStoring {
    private var values: [UUID: String] = [:]
    func save(value: String, reference: UUID) async throws { values[reference] = value }
    func value(for reference: UUID) async throws -> String? { values[reference] }
    func delete(reference: UUID) async throws { values.removeValue(forKey: reference) }
}
