import Foundation
import SwiftData

@ModelActor
actor SwiftDataStore: HistoryRecording, OwnershipRecording, RestartTrustStoring {
    func record(_ event: HistoryEvent) async throws {
        modelContext.insert(ProcessHistoryEventRecord(event: event))
        try modelContext.save()
    }

    func deleteHistory(olderThan cutoff: Date) throws {
        try modelContext.delete(
            model: ProcessHistoryEventRecord.self,
            where: #Predicate { $0.timestamp < cutoff }
        )
        try modelContext.save()
    }

    func record(_ conclusion: OwnershipConclusion) async throws {
        modelContext.insert(try OwnershipEvidenceRecord(conclusion: conclusion))
        var descriptor = FetchDescriptor<OwnershipEvidenceRecord>(
            sortBy: [SortDescriptor(\.observedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1_001
        let records = try modelContext.fetch(descriptor)
        if records.count > 1_000 {
            records.dropFirst(1_000).forEach(modelContext.delete)
        }
        try modelContext.save()
    }

    func record(_ validation: ManagedServiceValidationResult) async throws {
        let serviceID = validation.managedServiceID
        let descriptor = FetchDescriptor<ManagedServiceValidationRecord>(
            predicate: #Predicate { $0.managedServiceID == serviceID }
        )
        if let existing = try modelContext.fetch(descriptor).first {
            try existing.apply(validation)
        } else {
            modelContext.insert(try ManagedServiceValidationRecord(result: validation))
        }
        try modelContext.save()
    }

    func record(_ assessment: RestartTrustAssessment) async throws {
        let serviceID = assessment.managedServiceID
        let descriptor = FetchDescriptor<ManagedServiceTrustRecord>(
            predicate: #Predicate { $0.managedServiceID == serviceID }
        )
        if let existing = try modelContext.fetch(descriptor).first {
            try existing.apply(assessment)
        } else {
            modelContext.insert(try ManagedServiceTrustRecord(assessment: assessment))
        }
        try modelContext.save()
    }

    func latestValidation(
        for managedServiceID: UUID
    ) async throws -> ManagedServiceValidationResult? {
        let descriptor = FetchDescriptor<ManagedServiceValidationRecord>(
            predicate: #Predicate { $0.managedServiceID == managedServiceID }
        )
        return try modelContext.fetch(descriptor).first?.result
    }
}
