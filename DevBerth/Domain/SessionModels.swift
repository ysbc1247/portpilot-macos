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
