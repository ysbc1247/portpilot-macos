import Foundation

enum LifecycleEventCategory: String, Codable, CaseIterable, Sendable {
    case requested
    case preflight
    case processSpawned
    case listenerChanged
    case starting
    case ready
    case healthChanged
    case stopping
    case exited
    case failed
    case ownershipChanged
    case sessionCapture
    case sessionRestore
    case sessionRollback
    case configurationDrift
    case safetyRefusal
    case dockerContainerStarted
    case dockerContainerStopped
    case dockerComposeChanged
}

enum LifecycleEventOutcome: String, Codable, CaseIterable, Sendable {
    case pending
    case observed
    case succeeded
    case failed
    case cancelled
}

enum LifecycleEventSeverity: String, Codable, CaseIterable, Sendable {
    case debug
    case info
    case notice
    case warning
    case error
    case critical
}

enum LifecycleEventSource: String, Codable, CaseIterable, Sendable {
    case user
    case monitor
    case launcher
    case readiness
    case health
    case processController
    case docker
    case restartPolicy
    case session
    case system
}

enum LifecycleEventTrigger: String, Codable, CaseIterable, Sendable {
    case userAction
    case automatic
    case validation
    case observation
    case dependency
    case system
}

struct LifecycleEvent: Hashable, Codable, Sendable, Identifiable {
    let id: UUID
    let timestamp: Date
    let runtimeID: UUID?
    let managedServiceID: UUID?
    let projectID: UUID?
    let sessionID: UUID?
    let category: LifecycleEventCategory
    let outcome: LifecycleEventOutcome
    let severity: LifecycleEventSeverity
    let source: LifecycleEventSource
    let trigger: LifecycleEventTrigger
    let summary: String
    let details: [String: String]
    let processFingerprint: ProcessFingerprint?
    let listenerID: String?
    let durationSeconds: Double?
    let relatedEventIDs: [UUID]

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        runtimeID: UUID? = nil,
        managedServiceID: UUID? = nil,
        projectID: UUID? = nil,
        sessionID: UUID? = nil,
        category: LifecycleEventCategory,
        outcome: LifecycleEventOutcome,
        severity: LifecycleEventSeverity = .info,
        source: LifecycleEventSource = .system,
        trigger: LifecycleEventTrigger = .system,
        summary: String,
        details: [String: String] = [:],
        processFingerprint: ProcessFingerprint? = nil,
        listenerID: String? = nil,
        durationSeconds: Double? = nil,
        relatedEventIDs: [UUID] = []
    ) {
        self.id = id
        self.timestamp = timestamp
        self.runtimeID = runtimeID
        self.managedServiceID = managedServiceID
        self.projectID = projectID
        self.sessionID = sessionID
        self.category = category
        self.outcome = outcome
        self.severity = severity
        self.source = source
        self.trigger = trigger
        self.summary = summary
        self.details = details
        self.processFingerprint = processFingerprint
        self.listenerID = listenerID
        self.durationSeconds = durationSeconds
        self.relatedEventIDs = relatedEventIDs
    }
}

struct IncidentSummaryStep: Hashable, Codable, Sendable, Identifiable {
    let id: UUID
    let timestamp: Date
    let explanation: String
    let eventID: UUID

    init(id: UUID = UUID(), timestamp: Date, explanation: String, eventID: UUID) {
        self.id = id
        self.timestamp = timestamp
        self.explanation = explanation
        self.eventID = eventID
    }
}

struct RuntimeIncidentSummary: Hashable, Codable, Sendable, Identifiable {
    let id: UUID
    let managedServiceID: UUID
    let runtimeID: UUID?
    let title: String
    let cause: String
    let suggestedAction: String
    let steps: [IncidentSummaryStep]
    let relatedEventIDs: [UUID]
    let generatedAt: Date
}

enum RuntimeLifecycleUpdate: Sendable {
    case listenerObserved(ObservedListener, change: ObservedListenerLifecycleChange)
    case launchRequested(ManagedServiceConfiguration, trigger: LifecycleEventTrigger)
    case processSpawned(ManagedRuntimeHandle, ManagedServiceConfiguration)
    case waitingForPorts(serviceID: UUID, ports: [UInt16])
    case listenersReady(serviceID: UUID, listenerIDs: Set<String>)
    case serviceReady(serviceID: UUID, description: String)
    case waitingForHealth(serviceID: UUID, description: String)
    case healthPassed(serviceID: UUID, description: String)
    case healthDegraded(serviceID: UUID, reason: String)
    case launchFailed(ManagedServiceConfiguration, reason: String)
    case stopping(serviceID: UUID, runtimeID: UUID?, reason: String)
    case stopped(serviceID: UUID, runtimeID: UUID?, reason: String)
    case exited(
        profile: ManagedServiceConfiguration,
        runtime: ManagedRuntimeHandle,
        result: RuntimeExitResult,
        intentional: Bool
    )
    case restartScheduled(serviceID: UUID, attempt: Int, delaySeconds: Double)
    case restartFailed(serviceID: UUID, reason: String)
}

enum ObservedListenerLifecycleChange: String, Codable, Sendable {
    case discovered
    case changed
    case released
}
