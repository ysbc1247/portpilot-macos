import Foundation
import SwiftData

@Model
final class RuntimeInstanceRecord {
    @Attribute(.unique) var id: UUID
    var managedServiceID: UUID
    var processPID: Int
    var executablePath: String?
    var processStartTime: Date?
    var parentRuntimeID: UUID?
    var startedAt: Date
    var lifecycleStateRawValue: String
    var healthStateRawValue: String
    var listenerIDsData: Data
    var exitCode: Int?
    var exitSignal: Int?
    var exitReason: String?
    var exitedAt: Date?
    var logMetadataIDsData: Data
    var lifecycleEventIDsData: Data
    var updatedAt: Date

    init(runtime: RuntimeInstance) throws {
        let encoder = JSONEncoder()
        id = runtime.id
        managedServiceID = runtime.managedServiceID
        processPID = Int(runtime.processFingerprint.pid)
        executablePath = runtime.processFingerprint.executablePath
        processStartTime = runtime.processFingerprint.startTime
        parentRuntimeID = runtime.parentRuntimeID
        startedAt = runtime.startedAt
        lifecycleStateRawValue = runtime.lifecycleState.rawValue
        healthStateRawValue = runtime.healthState.rawValue
        listenerIDsData = try encoder.encode(runtime.listenerIDs.sorted())
        exitCode = runtime.exitResult?.exitCode.map(Int.init)
        exitSignal = runtime.exitResult?.signal.map(Int.init)
        exitReason = runtime.exitResult?.reason
        exitedAt = runtime.exitResult?.exitedAt
        logMetadataIDsData = try encoder.encode(runtime.logMetadataIDs)
        lifecycleEventIDsData = try encoder.encode(runtime.lifecycleEventIDs)
        updatedAt = Date()
    }
}

@Model
final class OwnershipEvidenceRecord {
    @Attribute(.unique) var id: UUID
    var subjectData: Data
    var categoryRawValue: String
    var value: String
    var confidenceRawValue: String
    var evidenceData: Data
    var detectionMethodRawValue: String
    var observedAt: Date

    init(conclusion: OwnershipConclusion) throws {
        let encoder = JSONEncoder()
        id = conclusion.id
        subjectData = try encoder.encode(conclusion.subject)
        categoryRawValue = conclusion.category.rawValue
        value = conclusion.value
        confidenceRawValue = conclusion.confidence.rawValue
        evidenceData = try encoder.encode(conclusion.evidence)
        detectionMethodRawValue = conclusion.detectionMethod.rawValue
        observedAt = conclusion.observedAt
    }
}

@Model
final class ManagedServiceTrustRecord {
    @Attribute(.unique) var managedServiceID: UUID
    var id: UUID
    var stateRawValue: String
    var reasonsData: Data
    var evidenceIDsData: Data
    var assessedAt: Date
    var lastValidatedAt: Date?

    init(assessment: RestartTrustAssessment) throws {
        let encoder = JSONEncoder()
        managedServiceID = assessment.managedServiceID
        id = assessment.id
        stateRawValue = assessment.state.rawValue
        reasonsData = try encoder.encode(assessment.reasons)
        evidenceIDsData = try encoder.encode(assessment.evidenceIDs)
        assessedAt = assessment.assessedAt
        lastValidatedAt = assessment.lastValidatedAt
    }

    func apply(_ assessment: RestartTrustAssessment) throws {
        let encoder = JSONEncoder()
        id = assessment.id
        stateRawValue = assessment.state.rawValue
        reasonsData = try encoder.encode(assessment.reasons)
        evidenceIDsData = try encoder.encode(assessment.evidenceIDs)
        assessedAt = assessment.assessedAt
        lastValidatedAt = assessment.lastValidatedAt
    }
}

@Model
final class WorkspaceSessionRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var projectIDsData: Data
    var capturedAt: Date
    var notes: String?
    var createdAt: Date
    var updatedAt: Date

    init(session: WorkspaceSession) throws {
        id = session.id
        name = session.name
        projectIDsData = try JSONEncoder().encode(session.projectIDs)
        capturedAt = session.capturedAt
        notes = session.notes
        createdAt = Date()
        updatedAt = Date()
    }
}

@Model
final class WorkspaceSessionServiceRecord {
    @Attribute(.unique) var id: UUID
    var sessionID: UUID
    var managedServiceID: UUID
    var expectedStateRawValue: String
    var expectedListenersData: Data
    var dependencyServiceIDsData: Data
    var previousHealthStateRawValue: String
    var configurationDigest: String

    init(sessionID: UUID, snapshot: WorkspaceSessionServiceSnapshot) throws {
        let encoder = JSONEncoder()
        id = UUID()
        self.sessionID = sessionID
        managedServiceID = snapshot.managedServiceID
        expectedStateRawValue = snapshot.expectedState.rawValue
        expectedListenersData = try encoder.encode(snapshot.expectedListeners)
        dependencyServiceIDsData = try encoder.encode(snapshot.dependencyServiceIDs)
        previousHealthStateRawValue = snapshot.previousHealthState.rawValue
        configurationDigest = snapshot.configurationDigest
    }
}

@Model
final class SessionRestoreRecord {
    @Attribute(.unique) var id: UUID
    var sessionID: UUID
    var startedAt: Date
    var finishedAt: Date
    var outcomeRawValue: String
    var startedServiceIDsData: Data
    var rolledBackServiceIDsData: Data
    var errorsData: Data

    init(result: SessionRestoreResult) throws {
        let encoder = JSONEncoder()
        id = result.id
        sessionID = result.sessionID
        startedAt = result.startedAt
        finishedAt = result.finishedAt
        outcomeRawValue = result.outcome.rawValue
        startedServiceIDsData = try encoder.encode(result.startedServiceIDs)
        rolledBackServiceIDsData = try encoder.encode(result.rolledBackServiceIDs)
        errorsData = try encoder.encode(result.errors)
    }
}

@Model
final class ProjectDiscoveryRecord {
    @Attribute(.unique) var id: UUID
    var projectID: UUID?
    var rootPath: String
    var adapterIdentifier: String
    var projectType: String
    var evidenceData: Data
    var confidenceRawValue: String
    var discoveredAt: Date
    var importedAt: Date?

    init(metadata: ProjectDiscoveryMetadata) throws {
        id = metadata.id
        projectID = metadata.projectID
        rootPath = metadata.rootPath
        adapterIdentifier = metadata.adapterIdentifier
        projectType = metadata.projectType
        evidenceData = try JSONEncoder().encode(metadata.evidence)
        confidenceRawValue = metadata.confidence.rawValue
        discoveredAt = metadata.discoveredAt
        importedAt = metadata.importedAt
    }
}

@Model
final class LifecycleEventRecord {
    @Attribute(.unique) var id: UUID
    var timestamp: Date
    var runtimeID: UUID?
    var managedServiceID: UUID?
    var projectID: UUID?
    var sessionID: UUID?
    var categoryRawValue: String
    var outcomeRawValue: String
    var summary: String
    var detailsData: Data

    init(event: LifecycleEvent) throws {
        id = event.id
        timestamp = event.timestamp
        runtimeID = event.runtimeID
        managedServiceID = event.managedServiceID
        projectID = event.projectID
        sessionID = event.sessionID
        categoryRawValue = event.category.rawValue
        outcomeRawValue = event.outcome.rawValue
        summary = event.summary
        detailsData = try JSONEncoder().encode(event.details)
    }
}

enum DevBerthSchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] {
        DevBerthSchemaV1.models + [
            RuntimeInstanceRecord.self,
            OwnershipEvidenceRecord.self,
            ManagedServiceTrustRecord.self,
            WorkspaceSessionRecord.self,
            WorkspaceSessionServiceRecord.self,
            SessionRestoreRecord.self,
            ProjectDiscoveryRecord.self,
            LifecycleEventRecord.self
        ]
    }
}
