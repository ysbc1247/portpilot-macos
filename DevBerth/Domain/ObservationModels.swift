import Foundation

enum ListenerProtocol: String, Codable, CaseIterable, Sendable {
    case tcp = "TCP"
    case udp = "UDP"
}

enum ListenerAddressScope: String, Codable, Sendable {
    case loopback
    case localNetwork
    case wildcard
    case unknown
}

struct ProcessIdentity: Hashable, Codable, Sendable {
    let pid: Int32
    let executablePath: String?
    let startTime: Date?

    var isStrong: Bool { executablePath != nil && startTime != nil }
}

enum ProcessRuntime: String, Codable, CaseIterable, Sendable {
    case node = "Node.js"
    case vite = "Vite"
    case next = "Next.js"
    case angular = "Angular"
    case java = "Java"
    case springBoot = "Spring Boot"
    case gradle = "Gradle"
    case maven = "Maven"
    case python = "Python"
    case django = "Django"
    case flask = "Flask"
    case fastAPI = "FastAPI"
    case go = "Go"
    case rust = "Rust"
    case rails = "Ruby on Rails"
    case php = "PHP"
    case postgreSQL = "PostgreSQL"
    case mysql = "MySQL"
    case redis = "Redis"
    case mongoDB = "MongoDB"
    case elasticsearch = "Elasticsearch"
    case docker = "Docker"
    case kubernetes = "Kubernetes"
    case sshTunnel = "SSH tunnel"
    case unknown = "Process"

    var symbolName: String {
        switch self {
        case .node, .vite, .next, .angular: "shippingbox"
        case .java, .springBoot, .gradle, .maven: "cup.and.saucer"
        case .python, .django, .flask, .fastAPI: "chevron.left.forwardslash.chevron.right"
        case .go, .rust: "gearshape.2"
        case .postgreSQL, .mysql, .redis, .mongoDB, .elasticsearch: "cylinder"
        case .docker: "shippingbox.fill"
        case .kubernetes: "circle.hexagongrid"
        case .sshTunnel: "lock.shield"
        default: "terminal"
        }
    }
}

struct ProjectInference: Hashable, Codable, Sendable {
    let name: String
    let rootPath: String
    let evidence: String
}

struct DockerAssociation: Hashable, Codable, Sendable {
    let containerID: String
    let containerName: String
    let image: String
    let composeProject: String?
    let composeService: String?
    let containerPort: UInt16?
}

struct ObservedProcess: Hashable, Codable, Sendable, Identifiable {
    var id: ProcessIdentity { identity }
    let identity: ProcessIdentity
    let parentPID: Int32?
    let name: String
    let executablePath: String?
    let commandLine: String
    let owner: String
    let currentDirectory: String?
    let parentName: String?
    let runtime: ProcessRuntime
    let project: ProjectInference?
    let isSystemProcess: Bool
    let docker: DockerAssociation?
    let launchedByDevBerth: Bool
    let managedServiceID: UUID?
}

struct ObservedListener: Hashable, Codable, Sendable, Identifiable {
    let protocolKind: ListenerProtocol
    let address: String
    let port: UInt16
    let process: ObservedProcess
    var firstDetectedAt: Date
    var lastDetectedAt: Date

    var id: String {
        "\(process.identity.pid):\(protocolKind.rawValue):\(address):\(port)"
    }

    var addressScope: ListenerAddressScope {
        let normalized = address.lowercased()
        if normalized == "*" || normalized == "0.0.0.0" || normalized == "::" || normalized == "[::]" {
            return .wildcard
        }
        if normalized == "localhost" || normalized == "::1" || normalized == "[::1]" || normalized.hasPrefix("127.") {
            return .loopback
        }
        if normalized.isEmpty { return .unknown }
        return .localNetwork
    }
}

struct RuntimeSnapshot: Equatable, Sendable {
    let listeners: [ObservedListener]
    let capturedAt: Date
}

struct RuntimeDiff: Equatable, Sendable {
    let added: [ObservedListener]
    let updated: [ObservedListener]
    let removed: [ObservedListener]

    static let empty = RuntimeDiff(added: [], updated: [], removed: [])
}

enum RuntimeDiffer {
    static func diff(previous: [ObservedListener], current: [ObservedListener]) -> RuntimeDiff {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        let added = current.filter { previousByID[$0.id] == nil }
        let updated = current.filter { listener in
            guard let old = previousByID[listener.id] else { return false }
            return old != listener
        }
        let removed = previous.filter { currentByID[$0.id] == nil }
        return RuntimeDiff(added: added, updated: updated, removed: removed)
    }
}

