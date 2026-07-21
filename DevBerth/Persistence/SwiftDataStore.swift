import Foundation
import SwiftData

@ModelActor
actor SwiftDataStore: HistoryRecording, OwnershipRecording, RestartTrustStoring, RuntimeLifecycleRecording, WorkspaceSessionRecording {
    private var lifecycleWriteCount = 0
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

    func record(_ runtime: RuntimeInstance) async throws {
        let runtimeID = runtime.id
        let descriptor = FetchDescriptor<RuntimeInstanceRecord>(
            predicate: #Predicate { $0.id == runtimeID }
        )
        if let existing = try modelContext.fetch(descriptor).first {
            try existing.apply(runtime)
        } else {
            modelContext.insert(try RuntimeInstanceRecord(runtime: runtime))
        }
        try modelContext.save()
    }

    func record(_ event: LifecycleEvent) async throws {
        modelContext.insert(try LifecycleEventRecord(event: event))
        modelContext.insert(try LifecycleEventContextRecord(event: event))
        lifecycleWriteCount += 1
        if lifecycleWriteCount.isMultiple(of: 100) {
            try pruneLifecycleEvents(retaining: 5_000)
        }
        try modelContext.save()
    }

    func record(_ incident: RuntimeIncidentSummary) async throws {
        modelContext.insert(try RuntimeIncidentSummaryRecord(summary: incident))
        var descriptor = FetchDescriptor<RuntimeIncidentSummaryRecord>(
            sortBy: [SortDescriptor(\.generatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 251
        let records = try modelContext.fetch(descriptor)
        records.dropFirst(250).forEach(modelContext.delete)
        try modelContext.save()
    }

    func record(_ session: WorkspaceSession) async throws {
        modelContext.insert(try WorkspaceSessionRecord(session: session))
        for snapshot in session.serviceSnapshots {
            modelContext.insert(try WorkspaceSessionServiceRecord(
                sessionID: session.id,
                snapshot: snapshot
            ))
        }
        try modelContext.save()
    }

    func record(_ result: SessionRestoreResult) async throws {
        modelContext.insert(try SessionRestoreRecord(result: result))
        try modelContext.save()
    }

    func pruneLifecycleHistory(retaining limit: Int) async throws {
        try pruneLifecycleEvents(retaining: max(0, limit))
        try modelContext.save()
    }

    private func pruneLifecycleEvents(retaining limit: Int) throws {
        var descriptor = FetchDescriptor<LifecycleEventRecord>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = limit + 100
        let events = try modelContext.fetch(descriptor)
        let removedIDs = Set(events.dropFirst(limit).map(\.id))
        guard !removedIDs.isEmpty else { return }
        events.filter { removedIDs.contains($0.id) }.forEach(modelContext.delete)
        let contexts = try modelContext.fetch(FetchDescriptor<LifecycleEventContextRecord>())
        contexts.filter { removedIDs.contains($0.lifecycleEventID) }.forEach(modelContext.delete)
    }
}
