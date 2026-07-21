import Foundation
import SwiftData

@ModelActor
actor SwiftDataStore: HistoryRecording, OwnershipRecording, RestartTrustStoring, RuntimeLifecycleRecording, WorkspaceSessionRecording {
    private var lifecycleWritesUntilPrune = 100
    private var processHistoryWritesUntilPrune = 100
    func record(_ event: HistoryEvent) async throws {
        modelContext.insert(ProcessHistoryEventRecord(event: event))
        try reserveProcessHistoryCapacity(for: 1)
        try save()
    }

    func record(_ events: [HistoryEvent]) async throws {
        guard !events.isEmpty else { return }
        for event in events { modelContext.insert(ProcessHistoryEventRecord(event: event)) }
        try reserveProcessHistoryCapacity(for: events.count)
        try save()
    }

    func deleteHistory(olderThan cutoff: Date) throws {
        try modelContext.delete(
            model: ProcessHistoryEventRecord.self,
            where: #Predicate { $0.timestamp < cutoff }
        )
        try save()
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
        try save()
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
        try save()
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
        try save()
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
        try save()
    }

    func record(_ event: LifecycleEvent) async throws {
        modelContext.insert(try LifecycleEventRecord(event: event))
        modelContext.insert(try LifecycleEventContextRecord(event: event))
        lifecycleWritesUntilPrune -= 1
        if lifecycleWritesUntilPrune <= 0 {
            try pruneLifecycleEvents(retaining: 4_900)
            lifecycleWritesUntilPrune = 100
        }
        try save()
    }

    func record(_ events: [LifecycleEvent]) async throws {
        guard !events.isEmpty else { return }
        for event in events {
            modelContext.insert(try LifecycleEventRecord(event: event))
            modelContext.insert(try LifecycleEventContextRecord(event: event))
        }
        lifecycleWritesUntilPrune -= events.count
        if lifecycleWritesUntilPrune <= 0 {
            try pruneLifecycleEvents(retaining: max(0, 5_000 - max(100, events.count)))
            lifecycleWritesUntilPrune = 100
        }
        try save()
    }

    func record(_ incident: RuntimeIncidentSummary) async throws {
        modelContext.insert(try RuntimeIncidentSummaryRecord(summary: incident))
        var descriptor = FetchDescriptor<RuntimeIncidentSummaryRecord>(
            sortBy: [SortDescriptor(\.generatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 251
        let records = try modelContext.fetch(descriptor)
        records.dropFirst(250).forEach(modelContext.delete)
        try save()
    }

    func record(_ session: WorkspaceSession) async throws {
        modelContext.insert(try WorkspaceSessionRecord(session: session))
        for snapshot in session.serviceSnapshots {
            modelContext.insert(try WorkspaceSessionServiceRecord(
                sessionID: session.id,
                snapshot: snapshot
            ))
        }
        try save()
    }

    func record(_ result: SessionRestoreResult) async throws {
        modelContext.insert(try SessionRestoreRecord(result: result))
        try save()
    }

    func pruneLifecycleHistory(retaining limit: Int) async throws {
        try pruneLifecycleEvents(retaining: max(0, limit))
        try save()
    }

    func pruneProcessHistory(retaining limit: Int) async throws {
        try pruneProcessHistoryRecords(retaining: max(0, limit))
        try save()
    }

    private func reserveProcessHistoryCapacity(for insertedCount: Int) throws {
        processHistoryWritesUntilPrune -= insertedCount
        guard processHistoryWritesUntilPrune <= 0 else { return }
        try pruneProcessHistoryRecords(retaining: max(0, 5_000 - max(100, insertedCount)))
        processHistoryWritesUntilPrune = 100
    }

    private func pruneProcessHistoryRecords(retaining limit: Int) throws {
        let count = try modelContext.fetchCount(FetchDescriptor<ProcessHistoryEventRecord>())
        guard count > limit else { return }
        var descriptor = FetchDescriptor<ProcessHistoryEventRecord>(
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        descriptor.fetchLimit = count - limit
        try modelContext.fetch(descriptor).forEach(modelContext.delete)
    }

    private func pruneLifecycleEvents(retaining limit: Int) throws {
        let descriptor = FetchDescriptor<LifecycleEventRecord>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        let events = try modelContext.fetch(descriptor)
        let removedIDs = Set(events.dropFirst(limit).map(\.id))
        guard !removedIDs.isEmpty else { return }
        events.filter { removedIDs.contains($0.id) }.forEach(modelContext.delete)
        let contexts = try modelContext.fetch(FetchDescriptor<LifecycleEventContextRecord>())
        contexts.filter { removedIDs.contains($0.lifecycleEventID) }.forEach(modelContext.delete)
    }

    private func save() throws {
        let interval = DevBerthPerformance.begin(.swiftDataWrite)
        defer { DevBerthPerformance.end(interval) }
        try modelContext.save()
    }
}
