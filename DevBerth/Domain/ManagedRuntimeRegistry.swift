import Foundation

struct ManagedRuntimeRegistration: Sendable, Identifiable {
    var id: UUID { runtime.id }
    let runtime: ManagedRuntimeHandle
    let configuration: ManagedServiceConfiguration
    var latestSnapshot: ProcessGroupSnapshot
    let registeredAt: Date
}

actor ManagedRuntimeRegistry {
    private var registrationsByServiceID: [UUID: ManagedRuntimeRegistration] = [:]

    func register(
        runtime: ManagedRuntimeHandle,
        configuration: ManagedServiceConfiguration,
        snapshot: ProcessGroupSnapshot
    ) {
        registrationsByServiceID[configuration.id] = ManagedRuntimeRegistration(
            runtime: runtime,
            configuration: configuration,
            latestSnapshot: snapshot,
            registeredAt: Date()
        )
    }

    func update(snapshot: ProcessGroupSnapshot, forServiceID serviceID: UUID) {
        guard var registration = registrationsByServiceID[serviceID] else { return }
        registration.latestSnapshot = snapshot
        registrationsByServiceID[serviceID] = registration
    }

    func remove(serviceID: UUID, runtimeID: UUID) {
        guard registrationsByServiceID[serviceID]?.runtime.id == runtimeID else { return }
        registrationsByServiceID.removeValue(forKey: serviceID)
    }

    func registration(serviceID: UUID) -> ManagedRuntimeRegistration? {
        registrationsByServiceID[serviceID]
    }

    func registration(
        matching fingerprint: ProcessFingerprint,
        processGroupID: Int32?
    ) -> ManagedRuntimeRegistration? {
        registrationsByServiceID.values.first { registration in
            if registration.runtime.processGroupID == processGroupID { return true }
            if ProcessFingerprintVerifier.differences(
                expected: registration.runtime.leaderFingerprint,
                actual: fingerprint
            ).isEmpty { return true }
            return registration.latestSnapshot.members.contains {
                $0.fingerprint.pid == fingerprint.pid
                    && ProcessFingerprintVerifier.differences(expected: $0.fingerprint, actual: fingerprint).isEmpty
            }
        }
    }

    func activeRegistrations() -> [ManagedRuntimeRegistration] {
        registrationsByServiceID.values.sorted { $0.configuration.name < $1.configuration.name }
    }
}
