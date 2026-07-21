import Foundation

enum DockerAvailability: Equatable, Sendable {
    case checking
    case available(version: String)
    case notInstalled
    case daemonUnavailable(String)
}

struct DockerPortMapping: Hashable, Sendable, Identifiable {
    var id: String { "\(hostAddress):\(hostPort):\(containerPort):\(protocolKind)" }
    let hostAddress: String
    let hostPort: UInt16
    let containerPort: UInt16
    let protocolKind: ListenerProtocol
}

struct DockerContainer: Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let image: String
    let status: String
    let ports: [DockerPortMapping]
    let composeProject: String?
    let composeService: String?
}

protocol DockerServing: Sendable {
    func availability() async -> DockerAvailability
    func runningContainers() async throws -> [DockerContainer]
    func stop(containerID: String) async throws
    func restart(containerID: String) async throws
    func recentLogs(containerID: String, lines: Int) async throws -> String
}

enum DockerPortParser {
    static func parse(_ text: String) -> [DockerPortMapping] {
        text.split(separator: ",").compactMap { component in
            let mapping = component.trimmingCharacters(in: .whitespaces)
            guard let arrow = mapping.range(of: "->") else { return nil }
            let host = String(mapping[..<arrow.lowerBound])
            let container = String(mapping[arrow.upperBound...])
            guard
                let hostColon = host.lastIndex(of: ":"),
                let hostPort = UInt16(host[host.index(after: hostColon)...]),
                let slash = container.lastIndex(of: "/"),
                let containerPort = UInt16(container[..<slash])
            else { return nil }
            var address = String(host[..<hostColon])
            if address.hasPrefix("[") && address.hasSuffix("]") {
                address.removeFirst(); address.removeLast()
            }
            let protocolText = container[container.index(after: slash)...].uppercased()
            guard let protocolKind = ListenerProtocol(rawValue: protocolText) else { return nil }
            return DockerPortMapping(
                hostAddress: address.isEmpty ? "*" : address,
                hostPort: hostPort,
                containerPort: containerPort,
                protocolKind: protocolKind
            )
        }
    }
}

