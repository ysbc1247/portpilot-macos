import Foundation

enum RuntimeLifecycleState: String, Codable, CaseIterable, Sendable {
    case starting
    case running
    case stopping
    case exited
    case failed
}

enum RuntimeHealthState: String, Codable, CaseIterable, Sendable {
    case unknown
    case waitingForReadiness
    case ready
    case healthy
    case degraded
    case unhealthy
    case stopped
}

struct RuntimeExitResult: Hashable, Codable, Sendable {
    let exitedAt: Date
    let exitCode: Int32?
    let signal: Int32?
    let reason: String?

    var succeeded: Bool { exitCode == 0 && signal == nil }
}

struct RuntimeInstance: Hashable, Codable, Sendable, Identifiable {
    let id: UUID
    let managedServiceID: UUID
    let processIdentity: ProcessIdentity
    let startedAt: Date
    let parentRuntimeID: UUID?
    var lifecycleState: RuntimeLifecycleState
    var healthState: RuntimeHealthState
    var listenerIDs: Set<String>
    var exitResult: RuntimeExitResult?
    var logMetadataIDs: [UUID]
    var lifecycleEventIDs: [UUID]

    init(
        id: UUID = UUID(),
        managedServiceID: UUID,
        processIdentity: ProcessIdentity,
        startedAt: Date,
        parentRuntimeID: UUID? = nil,
        lifecycleState: RuntimeLifecycleState = .starting,
        healthState: RuntimeHealthState = .unknown,
        listenerIDs: Set<String> = [],
        exitResult: RuntimeExitResult? = nil,
        logMetadataIDs: [UUID] = [],
        lifecycleEventIDs: [UUID] = []
    ) {
        self.id = id
        self.managedServiceID = managedServiceID
        self.processIdentity = processIdentity
        self.startedAt = startedAt
        self.parentRuntimeID = parentRuntimeID
        self.lifecycleState = lifecycleState
        self.healthState = healthState
        self.listenerIDs = listenerIDs
        self.exitResult = exitResult
        self.logMetadataIDs = logMetadataIDs
        self.lifecycleEventIDs = lifecycleEventIDs
    }
}
