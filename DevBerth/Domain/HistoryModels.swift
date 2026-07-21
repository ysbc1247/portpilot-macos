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
