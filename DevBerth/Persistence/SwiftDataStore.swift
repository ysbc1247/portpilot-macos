import Foundation
import SwiftData

@ModelActor
actor SwiftDataStore: HistoryRecording, OwnershipRecording {
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
}
