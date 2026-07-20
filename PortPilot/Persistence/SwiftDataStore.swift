import Foundation
import SwiftData

@ModelActor
actor SwiftDataStore: HistoryRecording {
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
}

