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
