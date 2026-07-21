import Foundation
import SwiftData

@Model
final class LifecycleEventContextRecord {
    @Attribute(.unique) var lifecycleEventID: UUID
    var severityRawValue: String
    var sourceRawValue: String
    var triggerRawValue: String
    var processFingerprintData: Data?
    var listenerID: String?
    var durationSeconds: Double?
    var relatedEventIDsData: Data

    init(event: LifecycleEvent) throws {
        lifecycleEventID = event.id
        severityRawValue = event.severity.rawValue
        sourceRawValue = event.source.rawValue
        triggerRawValue = event.trigger.rawValue
        processFingerprintData = try event.processFingerprint.map(JSONEncoder().encode)
        listenerID = event.listenerID
        durationSeconds = event.durationSeconds
        relatedEventIDsData = try JSONEncoder().encode(event.relatedEventIDs)
    }
}

@Model
final class RuntimeIncidentSummaryRecord {
    @Attribute(.unique) var id: UUID
    var managedServiceID: UUID
    var runtimeID: UUID?
    var title: String
    var cause: String
    var suggestedAction: String
    var stepsData: Data
    var relatedEventIDsData: Data
    var generatedAt: Date

    init(summary: RuntimeIncidentSummary) throws {
        let encoder = JSONEncoder()
        id = summary.id
        managedServiceID = summary.managedServiceID
        runtimeID = summary.runtimeID
        title = summary.title
        cause = summary.cause
        suggestedAction = summary.suggestedAction
        stepsData = try encoder.encode(summary.steps)
        relatedEventIDsData = try encoder.encode(summary.relatedEventIDs)
        generatedAt = summary.generatedAt
    }

    var summary: RuntimeIncidentSummary? {
        let decoder = JSONDecoder()
        guard let steps = try? decoder.decode([IncidentSummaryStep].self, from: stepsData),
              let eventIDs = try? decoder.decode([UUID].self, from: relatedEventIDsData) else {
            return nil
        }
        return RuntimeIncidentSummary(
            id: id,
            managedServiceID: managedServiceID,
            runtimeID: runtimeID,
            title: title,
            cause: cause,
            suggestedAction: suggestedAction,
            steps: steps,
            relatedEventIDs: eventIDs,
            generatedAt: generatedAt
        )
    }
}

enum DevBerthSchemaV5: VersionedSchema {
    static var versionIdentifier = Schema.Version(5, 0, 0)
    static var models: [any PersistentModel.Type] {
        DevBerthSchemaV4.models + [
            LifecycleEventContextRecord.self,
            RuntimeIncidentSummaryRecord.self
        ]
    }
}
