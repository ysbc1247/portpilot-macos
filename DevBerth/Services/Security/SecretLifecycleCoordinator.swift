import Foundation

struct StagedSecretMutation: Sendable {
    let references: [String: UUID]
    let referencesRemovedFromConfiguration: Set<UUID>
    fileprivate let rollbackEntries: [SecretRollbackEntry]
}

private struct SecretRollbackEntry: Sendable {
    let reference: UUID
    let previousValue: String?
    let wasCreated: Bool
}

actor SecretLifecycleCoordinator {
    private let store: any SecretStoring

    init(store: any SecretStoring = KeychainSecretStore()) {
        self.store = store
    }

    func stage(
        existingReferences: [String: UUID],
        retainedNames: Set<String>,
        replacements: [String: String]
    ) async throws -> StagedSecretMutation {
        let normalizedRetained = Set(retainedNames.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        })
        for name in normalizedRetained where !ManagedEnvironmentParser.isValidVariableName(name) {
            throw DevBerthError.launchValidation("‘\(name)’ is not a valid environment variable name.")
        }
        var references = existingReferences.filter { normalizedRetained.contains($0.key) }
        var rollbackEntries: [SecretRollbackEntry] = []
        do {
            for (rawName, value) in replacements.sorted(by: { $0.key < $1.key }) {
                let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard ManagedEnvironmentParser.isValidVariableName(name) else {
                    throw DevBerthError.launchValidation("‘\(name)’ is not a valid environment variable name.")
                }
                guard !value.isEmpty else {
                    throw DevBerthError.launchValidation("Enter a non-empty Keychain value for ‘\(name)’.")
                }
                let existingReference = existingReferences[name]
                let reference = existingReference ?? UUID()
                let previousValue: String?
                if let existingReference {
                    previousValue = try await store.value(for: existingReference)
                } else {
                    previousValue = nil
                }
                try await store.save(value: value, reference: reference)
                references[name] = reference
                rollbackEntries.append(SecretRollbackEntry(
                    reference: reference,
                    previousValue: previousValue,
                    wasCreated: existingReference == nil
                ))
            }
        } catch {
            await rollback(entries: rollbackEntries)
            throw error
        }
        let removed = Set(existingReferences.compactMap { name, reference in
            references[name] == nil ? reference : nil
        })
        return StagedSecretMutation(
            references: references,
            referencesRemovedFromConfiguration: removed,
            rollbackEntries: rollbackEntries
        )
    }

    func clone(
        _ sourceReferences: [String: UUID]
    ) async throws -> StagedSecretMutation {
        var references: [String: UUID] = [:]
        var rollbackEntries: [SecretRollbackEntry] = []
        do {
            for (name, sourceReference) in sourceReferences.sorted(by: { $0.key < $1.key }) {
                guard let value = try await store.value(for: sourceReference) else {
                    throw DevBerthError.missingSecret(name)
                }
                let clonedReference = UUID()
                try await store.save(value: value, reference: clonedReference)
                references[name] = clonedReference
                rollbackEntries.append(SecretRollbackEntry(
                    reference: clonedReference,
                    previousValue: nil,
                    wasCreated: true
                ))
            }
        } catch {
            await rollback(entries: rollbackEntries)
            throw error
        }
        return StagedSecretMutation(
            references: references,
            referencesRemovedFromConfiguration: [],
            rollbackEntries: rollbackEntries
        )
    }

    func rollback(_ staged: StagedSecretMutation) async {
        await rollback(entries: staged.rollbackEntries)
    }

    func finalize(
        _ staged: StagedSecretMutation,
        referencesStillInUse: Set<UUID>
    ) async throws {
        for reference in staged.referencesRemovedFromConfiguration
            where !referencesStillInUse.contains(reference) {
            try await store.delete(reference: reference)
        }
    }

    func deleteUnused(
        _ candidates: Set<UUID>,
        referencesStillInUse: Set<UUID>
    ) async throws {
        for reference in candidates where !referencesStillInUse.contains(reference) {
            try await store.delete(reference: reference)
        }
    }

    private func rollback(entries: [SecretRollbackEntry]) async {
        for entry in entries.reversed() {
            if entry.wasCreated {
                try? await store.delete(reference: entry.reference)
            } else if let previousValue = entry.previousValue {
                try? await store.save(value: previousValue, reference: entry.reference)
            }
        }
    }
}
