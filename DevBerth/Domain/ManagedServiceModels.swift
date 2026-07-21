import Foundation

enum LaunchMechanism: String, Codable, CaseIterable, Sendable {
    case genericCommand
    case npmScript
    case pnpmScript
    case yarnScript
    case bunScript
    case gradleTask
    case mavenGoal
    case dockerContainer
    case dockerComposeService
    case pythonApplication
    case goCommand
    case cargoCommand
    case procfileProcess
    case processComposeService
    case executable
    case customShell

    var title: String {
        switch self {
        case .genericCommand: "Generic command"
        case .npmScript: "npm script"
        case .pnpmScript: "pnpm script"
        case .yarnScript: "Yarn script"
        case .bunScript: "Bun script"
        case .gradleTask: "Gradle task"
        case .mavenGoal: "Maven goal"
        case .dockerContainer: "Docker container"
        case .dockerComposeService: "Docker Compose service"
        case .pythonApplication: "Python application"
        case .goCommand: "Go command"
        case .cargoCommand: "Cargo command"
        case .procfileProcess: "Procfile process"
        case .processComposeService: "Process Compose service"
        case .executable: "Executable or application"
        case .customShell: "Custom shell command"
        }
    }
}

enum RestartPolicy: String, Codable, CaseIterable, Sendable {
    case never
    case onFailure
    case always
}

enum ShellSelection: Hashable, Codable, Sendable {
    case direct
    case loginShell(path: String)
    case custom(path: String)
}

struct ExpectedListenerConfiguration: Hashable, Codable, Sendable, Identifiable {
    let id: UUID
    var port: UInt16
    var protocolKind: ListenerProtocol
    var required: Bool
}

struct HealthCheckConfiguration: Hashable, Codable, Sendable {
    var url: URL
    var expectedStatus: Int
    var intervalSeconds: Double
}

struct ManagedServiceConfiguration: Hashable, Codable, Sendable, Identifiable {
    let id: UUID
    var name: String
    var projectID: UUID?
    var launchMechanism: LaunchMechanism
    var command: String
    var arguments: [String]
    var workingDirectory: String
    var shell: ShellSelection
    var environment: [String: String]
    var secretReferences: [String: UUID]
    var expectedPorts: [ExpectedListenerConfiguration]
    var startupTimeoutSeconds: Double
    var shutdownTimeoutSeconds: Double
    var restartPolicy: RestartPolicy
    var processPolicy: ManagedServiceProcessPolicy
    var healthCheck: HealthCheckConfiguration?
    var serviceChecks: [ServiceCheckConfiguration]
    var dependencyServiceIDs: [UUID]
    var logFile: String?
    var tags: [String]
    var icon: String?
    var launchesAutomatically: Bool
    var isFavorite: Bool
    var isReviewed: Bool

    init(
        id: UUID = UUID(),
        name: String,
        projectID: UUID? = nil,
        launchMechanism: LaunchMechanism = .genericCommand,
        command: String,
        arguments: [String] = [],
        workingDirectory: String,
        shell: ShellSelection = .direct,
        environment: [String: String] = [:],
        secretReferences: [String: UUID] = [:],
        expectedPorts: [ExpectedListenerConfiguration] = [],
        startupTimeoutSeconds: Double = 30,
        shutdownTimeoutSeconds: Double = 5,
        restartPolicy: RestartPolicy = .never,
        processPolicy: ManagedServiceProcessPolicy = .controlledProcessGroup,
        healthCheck: HealthCheckConfiguration? = nil,
        serviceChecks: [ServiceCheckConfiguration] = [],
        dependencyServiceIDs: [UUID] = [],
        logFile: String? = nil,
        tags: [String] = [],
        icon: String? = nil,
        launchesAutomatically: Bool = false,
        isFavorite: Bool = false,
        isReviewed: Bool = true
    ) {
        self.id = id
        self.name = name
        self.projectID = projectID
        self.launchMechanism = launchMechanism
        self.command = command
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.shell = shell
        self.environment = environment
        self.secretReferences = secretReferences
        self.expectedPorts = expectedPorts
        self.startupTimeoutSeconds = startupTimeoutSeconds
        self.shutdownTimeoutSeconds = shutdownTimeoutSeconds
        self.restartPolicy = restartPolicy
        self.processPolicy = processPolicy
        self.healthCheck = healthCheck
        self.serviceChecks = serviceChecks
        self.dependencyServiceIDs = dependencyServiceIDs
        self.logFile = logFile
        self.tags = tags
        self.icon = icon
        self.launchesAutomatically = launchesAutomatically
        self.isFavorite = isFavorite
        self.isReviewed = isReviewed
    }
}

struct ProjectConfiguration: Hashable, Codable, Sendable, Identifiable {
    let id: UUID
    var name: String
    var folderPath: String?
    var gitRemoteURL: URL?
    var profileIDs: [UUID]
}

struct ManagedServiceValidationIssue: Hashable, Sendable, Identifiable {
    enum Severity: Sendable { case warning, error }
    let id = UUID()
    let field: String
    let message: String
    let severity: Severity
}

struct ManagedEnvironmentParseResult: Sendable, Equatable {
    let values: [String: String]
    let sensitiveNames: [String]
    let invalidLines: [String]
    let duplicateNames: [String]

    var isValid: Bool {
        sensitiveNames.isEmpty && invalidLines.isEmpty && duplicateNames.isEmpty
    }
}

enum ManagedEnvironmentParser {
    static func parse(_ text: String) -> ManagedEnvironmentParseResult {
        var values: [String: String] = [:]
        var sensitiveNames = Set<String>()
        var invalidLines: [String] = []
        var duplicateNames = Set<String>()

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard let equal = line.firstIndex(of: "=") else {
                invalidLines.append(line)
                continue
            }
            let name = String(line[..<equal]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: equal)...])
            guard isValidVariableName(name) else {
                invalidLines.append(line)
                continue
            }
            if values[name] != nil {
                duplicateNames.insert(name)
                continue
            }
            if SensitiveEnvironmentKeyPolicy.isSensitive(name) {
                sensitiveNames.insert(name)
                continue
            }
            values[name] = value
        }
        return ManagedEnvironmentParseResult(
            values: values,
            sensitiveNames: sensitiveNames.sorted(),
            invalidLines: invalidLines,
            duplicateNames: duplicateNames.sorted()
        )
    }

    static func isValidVariableName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first,
              CharacterSet.letters.union(CharacterSet(charactersIn: "_")).contains(first) else {
            return false
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        return name.unicodeScalars.dropFirst().allSatisfy(allowed.contains)
    }
}

enum ManagedServiceValidator {
    static func validate(_ profile: ManagedServiceConfiguration, fileManager: FileManager = .default) -> [ManagedServiceValidationIssue] {
        var issues: [ManagedServiceValidationIssue] = []
        if profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(field: "name", message: "A profile name is required.", severity: .error))
        }
        if profile.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(field: "command", message: "A launch command is required.", severity: .error))
        }
        var isDirectory: ObjCBool = false
        if !fileManager.fileExists(atPath: profile.workingDirectory, isDirectory: &isDirectory) || !isDirectory.boolValue {
            issues.append(.init(field: "workingDirectory", message: "The working directory does not exist.", severity: .error))
        }
        if !(1...300).contains(profile.startupTimeoutSeconds) {
            issues.append(.init(field: "startupTimeout", message: "Startup timeout must be between 1 and 300 seconds.", severity: .error))
        }
        if !(1...60).contains(profile.shutdownTimeoutSeconds) {
            issues.append(.init(field: "shutdownTimeout", message: "Shutdown timeout must be between 1 and 60 seconds.", severity: .error))
        }
        if !profile.processPolicy.createsDedicatedProcessGroup {
            issues.append(.init(
                field: "processPolicy",
                message: "Application-managed services must launch in a dedicated process group.",
                severity: .error
            ))
        }
        let duplicatedPorts = Dictionary(grouping: profile.expectedPorts, by: { "\($0.protocolKind.rawValue):\($0.port)" })
            .filter { $0.value.count > 1 }
        if !duplicatedPorts.isEmpty {
            issues.append(.init(field: "expectedPorts", message: "Expected ports must be unique within a profile.", severity: .error))
        }
        return issues
    }
}

enum DependencyGraphError: LocalizedError, Equatable {
    case missingProfile(UUID)
    case cycle([UUID])

    var errorDescription: String? {
        switch self {
        case let .missingProfile(id): "A dependency profile (\(id.uuidString)) no longer exists."
        case let .cycle(ids): "The dependency graph contains a cycle: \(ids.map(\.uuidString).joined(separator: " → "))."
        }
    }
}

enum DependencyPlanner {
    static func orderedLayers(for profiles: [ManagedServiceConfiguration]) throws -> [[ManagedServiceConfiguration]] {
        let byID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        for profile in profiles {
            if let missing = profile.dependencyServiceIDs.first(where: { byID[$0] == nil }) {
                throw DependencyGraphError.missingProfile(missing)
            }
        }

        var remaining = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, Set($0.dependencyServiceIDs)) })
        var layers: [[ManagedServiceConfiguration]] = []
        var completed = Set<UUID>()

        while !remaining.isEmpty {
            let readyIDs = remaining.compactMap { id, dependencies in
                dependencies.isSubset(of: completed) ? id : nil
            }.sorted { lhs, rhs in
                (byID[lhs]?.name ?? "") < (byID[rhs]?.name ?? "")
            }
            guard !readyIDs.isEmpty else {
                throw DependencyGraphError.cycle(Array(remaining.keys).sorted { $0.uuidString < $1.uuidString })
            }
            layers.append(readyIDs.compactMap { byID[$0] })
            readyIDs.forEach {
                completed.insert($0)
                remaining.removeValue(forKey: $0)
            }
        }
        return layers
    }
}
