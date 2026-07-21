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

struct DockerContextPath: Hashable, Codable, Sendable, Identifiable {
    var id: String { path }
    let path: String
    let fileIdentity: ExecutableFileIdentity
    let size: UInt64
    let modificationDate: Date?
}

struct DockerComposeContext: Hashable, Codable, Sendable {
    let containerID: String
    let projectName: String
    let serviceName: String
    let workingDirectory: DockerContextPath
    let configurationFiles: [DockerContextPath]
    let environmentFiles: [DockerContextPath]
    let configurationHash: String
    let verifiedAt: Date

    var configurationFilePaths: [String] { configurationFiles.map(\.path) }
    var environmentFilePaths: [String] { environmentFiles.map(\.path) }
}

struct DockerContainer: Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let image: String
    let state: String
    let status: String
    let healthStatus: String?
    let restartPolicy: String
    let ports: [DockerPortMapping]
    let composeProject: String?
    let composeService: String?
    let composeContext: DockerComposeContext?
    let composeContextIssue: String?

    init(
        id: String,
        name: String,
        image: String,
        state: String = "unknown",
        status: String,
        healthStatus: String? = nil,
        restartPolicy: String = "no",
        ports: [DockerPortMapping],
        composeProject: String?,
        composeService: String?,
        composeContext: DockerComposeContext? = nil,
        composeContextIssue: String? = nil
    ) {
        self.id = id
        self.name = name
        self.image = image
        self.state = state
        self.status = status
        self.healthStatus = healthStatus
        self.restartPolicy = restartPolicy
        self.ports = ports
        self.composeProject = composeProject
        self.composeService = composeService
        self.composeContext = composeContext
        self.composeContextIssue = composeContextIssue
    }
}

protocol DockerServing: Sendable {
    func availability() async -> DockerAvailability
    func runningContainers() async throws -> [DockerContainer]
    func observedRunningContainers() async throws -> [DockerContainer]
    func stop(containerID: String) async throws
    func restart(containerID: String) async throws
    func remove(containerID: String) async throws
    func stopComposeService(context: DockerComposeContext) async throws
    func restartComposeService(context: DockerComposeContext) async throws
    func removeComposeService(context: DockerComposeContext) async throws
    func recentLogs(containerID: String, lines: Int) async throws -> String
}

extension DockerServing {
    func observedRunningContainers() async throws -> [DockerContainer] {
        try await runningContainers()
    }

    func remove(containerID: String) async throws {
        throw DevBerthError.ownerActionUnavailable(
            owner: containerID,
            reason: "This Docker controller does not support removal."
        )
    }

    func stopComposeService(context: DockerComposeContext) async throws {
        throw DevBerthError.ownerActionUnavailable(
            owner: "\(context.projectName)/\(context.serviceName)",
            reason: "This Docker controller does not support verified Compose actions."
        )
    }

    func restartComposeService(context: DockerComposeContext) async throws {
        throw DevBerthError.ownerActionUnavailable(
            owner: "\(context.projectName)/\(context.serviceName)",
            reason: "This Docker controller does not support verified Compose actions."
        )
    }

    func removeComposeService(context: DockerComposeContext) async throws {
        throw DevBerthError.ownerActionUnavailable(
            owner: "\(context.projectName)/\(context.serviceName)",
            reason: "This Docker controller does not support verified Compose actions."
        )
    }
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
