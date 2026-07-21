import Foundation

enum ExpectedServiceState: String, Codable, CaseIterable, Sendable {
    case running
    case stopped
}

struct WorkspaceSessionServiceSnapshot: Hashable, Codable, Sendable, Identifiable {
    var id: UUID { managedServiceID }
    let managedServiceID: UUID
    let expectedState: ExpectedServiceState
    let expectedListeners: [ExpectedListenerConfiguration]
    let dependencyServiceIDs: [UUID]
    let previousHealthState: RuntimeHealthState
    let configurationDigest: String
}

struct WorkspaceSession: Hashable, Codable, Sendable, Identifiable {
    let id: UUID
    var name: String
    let projectIDs: [UUID]
    let serviceSnapshots: [WorkspaceSessionServiceSnapshot]
    let capturedAt: Date
    var notes: String?

    init(
        id: UUID = UUID(),
        name: String,
        projectIDs: [UUID],
        serviceSnapshots: [WorkspaceSessionServiceSnapshot],
        capturedAt: Date = Date(),
        notes: String? = nil
    ) {
        self.id = id
        self.name = name
        self.projectIDs = projectIDs
        self.serviceSnapshots = serviceSnapshots
        self.capturedAt = capturedAt
        self.notes = notes
    }
}

enum SessionRestoreOutcome: String, Codable, CaseIterable, Sendable {
    case succeeded
    case partiallySucceeded
    case failed
    case cancelled
    case dryRun
}

struct SessionRestoreResult: Hashable, Codable, Sendable, Identifiable {
    let id: UUID
    let sessionID: UUID
    let startedAt: Date
    let finishedAt: Date
    let outcome: SessionRestoreOutcome
    let startedServiceIDs: [UUID]
    let rolledBackServiceIDs: [UUID]
    let errors: [String]
}

struct WorkspaceSessionCurrentState: Sendable {
    let runningServiceIDs: Set<UUID>
    let healthStates: [UUID: RuntimeHealthState]
    let listeners: [ObservedListener]
    let selectedProjectRootPaths: Set<String>
}

enum SessionRestoreActionKind: String, Codable, CaseIterable, Sendable {
    case start
    case alreadyRunning
    case stop
    case alreadyStopped
    case missing

    var title: String {
        switch self {
        case .start: "Start"
        case .alreadyRunning: "Already running"
        case .stop: "Stop after successful startup"
        case .alreadyStopped: "Already stopped"
        case .missing: "Missing service"
        }
    }
}

struct SessionRestoreAction: Hashable, Codable, Sendable, Identifiable {
    var id: String { "\(serviceID.uuidString):\(kind.rawValue)" }
    let serviceID: UUID
    let serviceName: String
    let projectID: UUID?
    let kind: SessionRestoreActionKind
    let expectedPorts: [UInt16]
    let dependencyServiceIDs: [UUID]
    let reason: String
}

enum SessionRestoreIssueKind: String, Codable, CaseIterable, Sendable {
    case configurationDrift
    case missingWorkingDirectory
    case missingExecutable
    case missingSecret
    case occupiedPort
    case conflictingProject
    case unverifiedDefinition
    case missingService
    case missingDependency
    case dependencyCycle
    case expectedStoppedServiceRunning
}

enum SessionRestoreIssueSeverity: String, Codable, CaseIterable, Sendable {
    case warning
    case confirmationRequired
    case blocking
}

struct SessionRestoreIssue: Hashable, Codable, Sendable, Identifiable {
    let id: String
    let kind: SessionRestoreIssueKind
    let severity: SessionRestoreIssueSeverity
    let serviceID: UUID?
    let summary: String
    let recoverySuggestion: String
}

struct SessionRestorePlan: Hashable, Codable, Sendable {
    let sessionID: UUID
    let createdAt: Date
    let actions: [SessionRestoreAction]
    let issues: [SessionRestoreIssue]
    let orderedStartLayers: [[UUID]]

    var estimatedMutationCount: Int {
        actions.filter { $0.kind == .start || $0.kind == .stop }.count
    }

    var blockingIssues: [SessionRestoreIssue] {
        issues.filter { $0.severity == .blocking }
    }

    var confirmationIssues: [SessionRestoreIssue] {
        issues.filter { $0.severity == .confirmationRequired }
    }
}

struct SessionRestoreOptions: Hashable, Codable, Sendable {
    var dryRun: Bool
    var rollbackStartedServicesOnFailure: Bool
    var applyExpectedStoppedState: Bool
    var confirmedIssueIDs: Set<String>

    init(
        dryRun: Bool = false,
        rollbackStartedServicesOnFailure: Bool = true,
        applyExpectedStoppedState: Bool = false,
        confirmedIssueIDs: Set<String> = []
    ) {
        self.dryRun = dryRun
        self.rollbackStartedServicesOnFailure = rollbackStartedServicesOnFailure
        self.applyExpectedStoppedState = applyExpectedStoppedState
        self.confirmedIssueIDs = confirmedIssueIDs
    }
}

struct SessionRestoreExecution: Sendable {
    let plan: SessionRestorePlan
    let result: SessionRestoreResult
    let stoppedServiceIDs: [UUID]
}

struct SessionPortChange: Hashable, Sendable, Identifiable {
    var id: UUID { serviceID }
    let serviceID: UUID
    let serviceName: String
    let savedPorts: Set<UInt16>
    let currentPorts: Set<UInt16>
}

struct SessionHealthChange: Hashable, Sendable, Identifiable {
    var id: UUID { serviceID }
    let serviceID: UUID
    let serviceName: String
    let saved: RuntimeHealthState
    let current: RuntimeHealthState
}

struct WorkspaceSessionComparison: Sendable {
    let addedServiceIDs: [UUID]
    let missingServiceIDs: [UUID]
    let configurationDriftServiceIDs: [UUID]
    let portChanges: [SessionPortChange]
    let healthChanges: [SessionHealthChange]
    let unexpectedListeners: [ObservedListener]

    var changeCount: Int {
        addedServiceIDs.count
            + missingServiceIDs.count
            + configurationDriftServiceIDs.count
            + portChanges.count
            + healthChanges.count
            + unexpectedListeners.count
    }
}

enum WorkspaceSessionRestoreError: LocalizedError, Equatable {
    case blocked([String])
    case confirmationsRequired([String])

    var errorDescription: String? {
        switch self {
        case let .blocked(reasons):
            "Session restore is blocked: \(reasons.joined(separator: " "))"
        case let .confirmationsRequired(reasons):
            "Review and confirm these restore changes: \(reasons.joined(separator: " "))"
        }
    }
}
