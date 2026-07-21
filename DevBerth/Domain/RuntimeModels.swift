import Foundation

enum RuntimeLifecycleState: String, Codable, CaseIterable, Sendable {
    case stopped
    case starting
    case waitingForDependency
    case waitingForPort
    case waitingForReadiness
    case running
    case stopping
    case exited
    case failed
    case unknown
    case externallyManaged
}

enum RuntimeHealthState: String, Codable, CaseIterable, Sendable {
    case unknown
    case checking
    case waitingForReadiness
    case ready
    case healthy
    case degraded
    case unhealthy
    case stopped
}

struct ManagedServiceRuntimeStatus: Hashable, Codable, Sendable, Identifiable {
    var id: UUID { managedServiceID }
    let managedServiceID: UUID
    let runtimeID: UUID?
    let lifecycleState: RuntimeLifecycleState
    let healthState: RuntimeHealthState
    let processRunning: Bool
    let openListenerIDs: Set<String>
    let statusMessage: String
    let changedAt: Date

    var isReady: Bool {
        switch healthState {
        case .ready, .healthy, .degraded: true
        default: false
        }
    }

    var isHealthy: Bool { healthState == .healthy }
}

struct RuntimeExitResult: Hashable, Codable, Sendable {
    let exitedAt: Date
    let exitCode: Int32?
    let signal: Int32?
    let reason: String?

    var succeeded: Bool { exitCode == 0 && signal == nil }
}

struct ManagedProcessExitNotice: Sendable {
    let profile: ManagedServiceConfiguration
    let runtime: ManagedRuntimeHandle
    let result: RuntimeExitResult
    let intentional: Bool
}

struct RuntimeLifecycleSnapshot: Sendable {
    let statuses: [UUID: ManagedServiceRuntimeStatus]
    let incidents: [UUID: RuntimeIncidentSummary]
}

enum ProjectOperationKind: String, Hashable, Sendable {
    case start
    case stop
}

enum ProjectOperationPhase: String, Hashable, Sendable {
    case running
    case succeeded
    case failed
}

struct ProjectOperationStatus: Hashable, Sendable, Identifiable {
    var id: UUID { projectID }
    let projectID: UUID
    let kind: ProjectOperationKind
    let phase: ProjectOperationPhase
    let completedServiceCount: Int
    let totalServiceCount: Int
    let message: String
    let startedAt: Date
    let finishedAt: Date?

    var isRunning: Bool { phase == .running }

    var fractionCompleted: Double {
        guard totalServiceCount > 0 else { return phase == .running ? 0 : 1 }
        return min(1, Double(completedServiceCount) / Double(totalServiceCount))
    }
}

enum RestartPolicyEvaluator {
    static func shouldRestart(
        policy: RestartPolicy,
        result: RuntimeExitResult,
        intentional: Bool
    ) -> Bool {
        guard !intentional else { return false }
        return switch policy {
        case .never: false
        case .onFailure: !result.succeeded
        case .always: true
        }
    }

    static func delaySeconds(forAttempt attempt: Int) -> Double {
        pow(2, Double(max(0, attempt - 1)))
    }
}

struct AutomaticRestartLimiter: Sendable {
    let maximumAttempts: Int
    let windowSeconds: Double
    private(set) var attempts: [Date] = []

    init(maximumAttempts: Int = 3, windowSeconds: Double = 60) {
        self.maximumAttempts = maximumAttempts
        self.windowSeconds = windowSeconds
    }

    mutating func registerAttempt(at date: Date) -> Int? {
        attempts = attempts.filter { date.timeIntervalSince($0) < windowSeconds }
        guard attempts.count < maximumAttempts else { return nil }
        attempts.append(date)
        return attempts.count
    }
}

struct RuntimeInstance: Hashable, Codable, Sendable, Identifiable {
    let id: UUID
    let managedServiceID: UUID
    let processFingerprint: ProcessFingerprint
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
        processFingerprint: ProcessFingerprint,
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
        self.processFingerprint = processFingerprint
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
