import CryptoKit
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

struct ExecutableFileIdentity: Hashable, Codable, Sendable {
    let deviceID: UInt64
    let inode: UInt64
}

struct ProcessFingerprint: Hashable, Codable, Sendable {
    let pid: Int32
    let uid: UInt32?
    let executablePath: String?
    let executableFileIdentity: ExecutableFileIdentity?
    let startTime: Date?
    let commandLineDigest: String?
    let parentPID: Int32?
    let detectedAt: Date

    init(
        pid: Int32,
        uid: UInt32? = nil,
        executablePath: String?,
        executableFileIdentity: ExecutableFileIdentity? = nil,
        startTime: Date?,
        commandLineDigest: String? = nil,
        parentPID: Int32? = nil,
        detectedAt: Date = Date()
    ) {
        self.pid = pid
        self.uid = uid
        self.executablePath = executablePath
        self.executableFileIdentity = executableFileIdentity
        self.startTime = startTime
        self.commandLineDigest = commandLineDigest
        self.parentPID = parentPID
        self.detectedAt = detectedAt
    }

    var isStrong: Bool {
        uid != nil
            && executablePath != nil
            && startTime != nil
            && commandLineDigest != nil
            && parentPID != nil
    }

    static func digest(commandLine: String) -> String {
        SHA256.hash(data: Data(commandLine.utf8)).map { String(format: "%02x", $0) }.joined()
    }
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
    let state: String?
    let healthStatus: String?
    let restartPolicy: String?
    let composeContext: DockerComposeContext?
    let composeContextIssue: String?

    init(
        containerID: String,
        containerName: String,
        image: String,
        composeProject: String?,
        composeService: String?,
        containerPort: UInt16?,
        state: String? = nil,
        healthStatus: String? = nil,
        restartPolicy: String? = nil,
        composeContext: DockerComposeContext? = nil,
        composeContextIssue: String? = nil
    ) {
        self.containerID = containerID
        self.containerName = containerName
        self.image = image
        self.composeProject = composeProject
        self.composeService = composeService
        self.containerPort = containerPort
        self.state = state
        self.healthStatus = healthStatus
        self.restartPolicy = restartPolicy
        self.composeContext = composeContext
        self.composeContextIssue = composeContextIssue
    }
}

struct ObservedProcess: Hashable, Codable, Sendable, Identifiable {
    var id: ProcessFingerprint { fingerprint }
    let fingerprint: ProcessFingerprint
    let name: String
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

    var parentPID: Int32? { fingerprint.parentPID }
    var executablePath: String? { fingerprint.executablePath }
}

struct ObservedListener: Hashable, Codable, Sendable, Identifiable {
    let protocolKind: ListenerProtocol
    let address: String
    let port: UInt16
    let process: ObservedProcess
    var firstDetectedAt: Date
    var lastDetectedAt: Date

    var id: String {
        "\(process.fingerprint.pid):\(protocolKind.rawValue):\(address):\(port)"
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

struct ListenerOwnershipExpectation: Hashable, Codable, Sendable {
    let listenerID: String
    let protocolKind: ListenerProtocol
    let address: String
    let port: UInt16

    init(listener: ObservedListener) {
        listenerID = listener.id
        protocolKind = listener.protocolKind
        address = listener.address
        port = listener.port
    }
}

struct ProcessActionTarget: Hashable, Codable, Sendable {
    let process: ObservedProcess
    let expectedListener: ListenerOwnershipExpectation

    init(listener: ObservedListener) {
        process = listener.process
        expectedListener = ListenerOwnershipExpectation(listener: listener)
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

    var hasCadenceRelevantChanges: Bool {
        (added + updated + removed).contains(where: \.isCadenceRelevant)
    }
}

enum RuntimeDiffer {
    static func diff(previous: [ObservedListener], current: [ObservedListener]) -> RuntimeDiff {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        let added = current.filter { previousByID[$0.id] == nil }
        let updated = current.filter { listener in
            guard let old = previousByID[listener.id] else { return false }
            return !old.hasSameRuntimeEvidence(as: listener)
        }
        let removed = previous.filter { currentByID[$0.id] == nil }
        return RuntimeDiff(added: added, updated: updated, removed: removed)
    }
}

private extension ObservedListener {
    var isCadenceRelevant: Bool {
        protocolKind == .tcp || port < 49_152 || addressScope != .localNetwork
    }

    func hasSameRuntimeEvidence(as other: ObservedListener) -> Bool {
        protocolKind == other.protocolKind
            && address == other.address
            && port == other.port
            && process.hasSameRuntimeEvidence(as: other.process)
    }
}

private extension ObservedProcess {
    func hasSameRuntimeEvidence(as other: ObservedProcess) -> Bool {
        fingerprint.hasSameRuntimeEvidence(as: other.fingerprint)
            && name == other.name
            && commandLine == other.commandLine
            && owner == other.owner
            && currentDirectory == other.currentDirectory
            && parentName == other.parentName
            && runtime == other.runtime
            && project == other.project
            && isSystemProcess == other.isSystemProcess
            && docker == other.docker
            && launchedByDevBerth == other.launchedByDevBerth
            && managedServiceID == other.managedServiceID
    }
}

private extension ProcessFingerprint {
    func hasSameRuntimeEvidence(as other: ProcessFingerprint) -> Bool {
        pid == other.pid
            && uid == other.uid
            && executablePath == other.executablePath
            && executableFileIdentity == other.executableFileIdentity
            && startTime == other.startTime
            && commandLineDigest == other.commandLineDigest
            && parentPID == other.parentPID
    }
}
