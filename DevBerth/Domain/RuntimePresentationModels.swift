import Foundation

enum RuntimePresentationMode: String, CaseIterable, Identifiable {
    case table
    case groupedByProject

    var id: Self { self }
    var title: String { self == .table ? "Table" : "Projects" }
    var symbol: String { self == .table ? "tablecells" : "folder" }
}

enum RuntimeSavedView: String, CaseIterable, Identifiable {
    case all
    case managed
    case unexpected
    case unhealthy
    case docker
    case externallyReachable

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All Runtime"
        case .managed: "Managed"
        case .unexpected: "Unexpected"
        case .unhealthy: "Unhealthy"
        case .docker: "Docker"
        case .externallyReachable: "Externally Reachable"
        }
    }

    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .managed: "checkmark.shield"
        case .unexpected: "questionmark.diamond"
        case .unhealthy: "waveform.path.ecg.rectangle"
        case .docker: "shippingbox"
        case .externallyReachable: "network"
        }
    }

    func includes(_ listener: ObservedListener, unhealthyServiceIDs: Set<UUID>) -> Bool {
        switch self {
        case .all:
            true
        case .managed:
            listener.process.managedServiceID != nil
        case .unexpected:
            listener.process.managedServiceID == nil
        case .unhealthy:
            listener.process.managedServiceID.map(unhealthyServiceIDs.contains) ?? false
        case .docker:
            listener.process.docker != nil
        case .externallyReachable:
            listener.addressScope != .loopback
        }
    }
}

enum RuntimePresentation {
    static func ownershipTitle(
        for listener: ObservedListener,
        resolved: RuntimeOwnershipGraph?
    ) -> String {
        if let resolved { return resolved.primaryConclusion.category.title }
        if listener.process.managedServiceID != nil { return "DevBerth managed process" }
        if listener.process.docker?.composeService != nil { return "Docker Compose service" }
        if listener.process.docker != nil { return "Docker container" }
        if listener.process.isSystemProcess { return "Protected system process" }
        return "Observed host process"
    }
}

enum ManagedServiceActivityState: Hashable, Sendable {
    case controlled
    case observed
    case stopped
}

struct ManagedServiceActivityEvidence: Hashable, Sendable {
    let state: ManagedServiceActivityState
    let matchingListenerIDs: Set<String>
    let openExpectedPortCount: Int
    let expectedPortCount: Int

    var isActive: Bool { state != .stopped }
    var isControlled: Bool { state == .controlled }
}

enum ManagedServiceActivityResolver {
    static func resolve(
        profile: ManagedServiceConfiguration,
        listeners: [ObservedListener],
        runningProfileIDs: Set<UUID>,
        runtimeStatus: ManagedServiceRuntimeStatus?
    ) -> ManagedServiceActivityEvidence {
        if runningProfileIDs.contains(profile.id) || runtimeStatus?.processRunning == true {
            return ManagedServiceActivityEvidence(
                state: .controlled,
                matchingListenerIDs: runtimeStatus?.openListenerIDs ?? [],
                openExpectedPortCount: profile.expectedPorts.count,
                expectedPortCount: profile.expectedPorts.count
            )
        }

        let matchingListeners = listeners.filter { listener in
            profile.expectedPorts.contains {
                $0.port == listener.port && $0.protocolKind == listener.protocolKind
            }
        }
        guard !matchingListeners.isEmpty else {
            return ManagedServiceActivityEvidence(
                state: .stopped,
                matchingListenerIDs: [],
                openExpectedPortCount: 0,
                expectedPortCount: profile.expectedPorts.count
            )
        }
        let openExpectedPortCount = profile.expectedPorts.filter { expected in
            matchingListeners.contains {
                $0.port == expected.port && $0.protocolKind == expected.protocolKind
            }
        }.count
        return ManagedServiceActivityEvidence(
            state: .observed,
            matchingListenerIDs: Set(matchingListeners.map(\.id)),
            openExpectedPortCount: openExpectedPortCount,
            expectedPortCount: profile.expectedPorts.count
        )
    }
}
