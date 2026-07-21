import Foundation

enum HistoryEventType: String, Codable, CaseIterable, Sendable {
    case portDetected
    case portReleased
    case processStarted
    case processStopped
    case processDisappeared
    case gracefulStopRequested
    case forceStopRequested
    case restartRequested
    case launchSucceeded
    case launchFailed
    case healthCheckPassed
    case healthCheckFailed
    case portConflictDetected
    case dockerContainerStarted
    case dockerContainerStopped
    case profileCreated
    case profileModified
}

enum HistoryResult: String, Codable, Sendable {
    case succeeded
    case failed
    case cancelled
    case observed
}

struct HistoryEvent: Hashable, Codable, Sendable, Identifiable {
    let id: UUID
    let timestamp: Date
    let port: UInt16?
    let processFingerprint: ProcessFingerprint?
    let processName: String?
    let projectID: UUID?
    let profileID: UUID?
    let type: HistoryEventType
    let result: HistoryResult
    let errorDetails: String?
    let durationSeconds: Double?
}

struct LifecycleHistoryEventSnapshot: Hashable, Sendable, Identifiable {
    let id: UUID
    let timestamp: Date
    let managedServiceID: UUID?
    let categoryRawValue: String
    let outcomeRawValue: String
    let summary: String
}

struct LifecycleHistoryContextSnapshot: Hashable, Sendable {
    let lifecycleEventID: UUID
    let severityRawValue: String
    let sourceRawValue: String
}

struct LifecycleHistoryRow: Hashable, Sendable, Identifiable {
    let id: UUID
    let timestamp: Date
    let managedServiceID: UUID?
    let categoryRawValue: String
    let outcomeRawValue: String
    let summary: String
    let severityRawValue: String
    let sourceRawValue: String
}

enum LifecycleHistoryPresentation {
    static func rows(
        events: [LifecycleHistoryEventSnapshot],
        contexts: [LifecycleHistoryContextSnapshot],
        severity: LifecycleEventSeverity?,
        cutoff: Date?,
        searchText: String
    ) -> [LifecycleHistoryRow] {
        var contextsByEventID: [UUID: LifecycleHistoryContextSnapshot] = [:]
        contextsByEventID.reserveCapacity(contexts.count)
        for context in contexts {
            contextsByEventID[context.lifecycleEventID] = context
        }

        return events.compactMap { event in
            let context = contextsByEventID[event.id]
            let matchesSeverity = severity == nil || context?.severityRawValue == severity?.rawValue
            let matchesDate = cutoff.map { event.timestamp >= $0 } ?? true
            let haystack = [
                event.categoryRawValue,
                event.outcomeRawValue,
                event.summary,
                context?.sourceRawValue ?? "",
                context?.severityRawValue ?? ""
            ].joined(separator: " ")
            guard matchesSeverity,
                  matchesDate,
                  searchText.isEmpty || haystack.localizedCaseInsensitiveContains(searchText)
            else { return nil }
            return LifecycleHistoryRow(
                id: event.id,
                timestamp: event.timestamp,
                managedServiceID: event.managedServiceID,
                categoryRawValue: event.categoryRawValue,
                outcomeRawValue: event.outcomeRawValue,
                summary: event.summary,
                severityRawValue: context?.severityRawValue ?? LifecycleEventSeverity.info.rawValue,
                sourceRawValue: context?.sourceRawValue ?? LifecycleEventSource.system.rawValue
            )
        }
    }
}

struct PortConflict: Hashable, Sendable, Identifiable {
    var id: String { listener.id }
    let expectedPort: ExpectedListenerConfiguration
    let listener: ObservedListener
    let owningProjectID: UUID?
}

struct PendingLaunchConflict: Identifiable, Sendable {
    let id = UUID()
    let profile: ManagedServiceConfiguration
    let conflict: PortConflict
}

enum PortConflictDetector {
    static func conflicts(
        for profile: ManagedServiceConfiguration,
        listeners: [ObservedListener]
    ) -> [PortConflict] {
        profile.expectedPorts.compactMap { expected in
            guard let match = listeners.first(where: {
                $0.port == expected.port && $0.protocolKind == expected.protocolKind
            }) else { return nil }
            return PortConflict(expectedPort: expected, listener: match, owningProjectID: nil)
        }
    }
}
