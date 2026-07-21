import Foundation
import SwiftData

@Model
final class ManagedServiceValidationRecord {
    @Attribute(.unique) var managedServiceID: UUID
    var id: UUID
    var configurationDigest: String
    var statusRawValue: String
    var summary: String
    var evidenceData: Data
    var startedAt: Date
    var completedAt: Date

    init(result: ManagedServiceValidationResult) throws {
        managedServiceID = result.managedServiceID
        id = result.id
        configurationDigest = result.configurationDigest
        statusRawValue = result.status.rawValue
        summary = result.summary
        evidenceData = try JSONEncoder().encode(result.evidence)
        startedAt = result.startedAt
        completedAt = result.completedAt
    }

    func apply(_ result: ManagedServiceValidationResult) throws {
        id = result.id
        configurationDigest = result.configurationDigest
        statusRawValue = result.status.rawValue
        summary = result.summary
        evidenceData = try JSONEncoder().encode(result.evidence)
        startedAt = result.startedAt
        completedAt = result.completedAt
    }

    var result: ManagedServiceValidationResult? {
        guard let status = ManagedServiceValidationStatus(rawValue: statusRawValue),
              let evidence = try? JSONDecoder().decode(
                  [ManagedServiceValidationEvidence].self,
                  from: evidenceData
              ) else { return nil }
        return ManagedServiceValidationResult(
            id: id,
            managedServiceID: managedServiceID,
            configurationDigest: configurationDigest,
            status: status,
            summary: summary,
            evidence: evidence,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }
}

enum DevBerthSchemaV4: VersionedSchema {
    static var versionIdentifier = Schema.Version(4, 0, 0)
    static var models: [any PersistentModel.Type] {
        DevBerthSchemaV3.models + [ManagedServiceValidationRecord.self]
    }
}
