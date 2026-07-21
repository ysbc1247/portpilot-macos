import Darwin
import Foundation

actor DockerCLIClient: DockerServing {
    private struct CachedComposeVerification {
        let candidate: DockerComposeCandidate
        let result: DockerComposeVerification
        let checkedAt: Date
    }

    private let runner: any CommandRunning
    private let executable: URL?
    private var composeCache: [String: CachedComposeVerification] = [:]
    private let composeCacheDuration: TimeInterval = 15

    init(runner: any CommandRunning, resolver: ExecutableResolver = ExecutableResolver()) {
        self.runner = runner
        let environment = ProcessInfo.processInfo.environment
        let homeDirectory = environment["HOME"] ?? NSHomeDirectory()
        self.executable = resolver.resolve(
            "docker",
            environment: environment,
            workingDirectory: homeDirectory,
            additionalSearchDirectories: [
                "\(homeDirectory)/.docker/bin",
                "\(homeDirectory)/.orbstack/bin",
                "\(homeDirectory)/.rd/bin",
                "/Applications/Docker.app/Contents/Resources/bin",
                "\(homeDirectory)/Applications/Docker.app/Contents/Resources/bin",
                "/Applications/OrbStack.app/Contents/MacOS/xbin"
            ]
        )
    }

    init(runner: any CommandRunning, executable: URL?) {
        self.runner = runner
        self.executable = executable
    }

    func availability() async -> DockerAvailability {
        guard let executable else { return .notInstalled }
        do {
            let result = try await runner.run(
                executable: executable,
                arguments: ["version", "--format", "{{.Server.Version}}"]
            )
            guard result.exitCode == 0 else {
                return .daemonUnavailable(Self.concise(result.stderrString))
            }
            return .available(version: result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return .daemonUnavailable(error.localizedDescription)
        }
    }

    func runningContainers() async throws -> [DockerContainer] {
        try await runningContainers(verifyComposeContexts: true)
    }

    func observedRunningContainers() async throws -> [DockerContainer] {
        try await runningContainers(verifyComposeContexts: false)
    }

    private func runningContainers(verifyComposeContexts: Bool) async throws -> [DockerContainer] {
        let executable = try dockerExecutable()
        let identifiers = try await runningContainerIDs(executable: executable)
        guard !identifiers.isEmpty else {
            composeCache = [:]
            return []
        }
        let result = try await runner.run(
            executable: executable,
            arguments: ["inspect"] + identifiers
        )
        guard result.exitCode == 0 else {
            throw DevBerthError.commandFailed(
                command: "docker inspect",
                status: result.exitCode,
                details: Self.concise(result.stderrString)
            )
        }
        let inspected: [DockerInspectContainer]
        do {
            inspected = try JSONDecoder().decode([DockerInspectContainer].self, from: result.stdout)
        } catch {
            throw DevBerthError.malformedOutput(command: "docker inspect")
        }

        var containers: [DockerContainer] = []
        for item in inspected {
            let compose: DockerComposeVerification
            if verifyComposeContexts {
                compose = await verifiedComposeContext(for: item, executable: executable)
            } else if item.hasComposeLabels {
                compose = .unverified("Compose control scope is not verified during passive inspection.")
            } else {
                compose = .notCompose
            }
            containers.append(item.container(compose: compose))
        }
        let activeIDs = Set(inspected.map(\.id))
        composeCache = composeCache.filter { activeIDs.contains($0.key) }
        return containers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func stop(containerID: String) async throws {
        try await runAction(["stop", containerID], description: "stop container")
    }

    func restart(containerID: String) async throws {
        try await runAction(["restart", containerID], description: "restart container")
    }

    func remove(containerID: String) async throws {
        try await runAction(["rm", "--force", containerID], description: "remove container")
    }

    func stopComposeService(context: DockerComposeContext) async throws {
        try await runComposeAction(context: context, command: ["stop"], description: "stop Compose service")
    }

    func restartComposeService(context: DockerComposeContext) async throws {
        try await runComposeAction(
            context: context,
            command: ["restart", "--no-deps"],
            description: "restart Compose service"
        )
    }

    func removeComposeService(context: DockerComposeContext) async throws {
        try await runComposeAction(
            context: context,
            command: ["rm", "--force", "--stop"],
            description: "remove Compose service"
        )
    }

    func recentLogs(containerID: String, lines: Int) async throws -> String {
        let executable = try dockerExecutable()
        let result = try await runner.run(
            executable: executable,
            arguments: ["logs", "--tail", String(min(max(lines, 1), 2_000)), containerID]
        )
        guard result.exitCode == 0 else {
            throw DevBerthError.commandFailed(
                command: "docker logs",
                status: result.exitCode,
                details: Self.concise(result.stderrString)
            )
        }
        return result.stdoutString + result.stderrString
    }

    private func runningContainerIDs(executable: URL) async throws -> [String] {
        let result = try await runner.run(executable: executable, arguments: ["ps", "--quiet", "--no-trunc"])
        guard result.exitCode == 0 else {
            throw DevBerthError.dockerUnavailable(Self.concise(result.stderrString))
        }
        return result.stdoutString
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter(Self.isPlausibleContainerID)
    }

    private func verifiedComposeContext(
        for item: DockerInspectContainer,
        executable: URL
    ) async -> DockerComposeVerification {
        guard item.hasComposeLabels else { return .notCompose }
        let candidate: DockerComposeCandidate
        do {
            candidate = try DockerComposeCandidate(item: item)
        } catch {
            return .unverified(error.localizedDescription)
        }
        if let cached = composeCache[item.id],
           cached.candidate == candidate,
           Date().timeIntervalSince(cached.checkedAt) < composeCacheDuration {
            return cached.result
        }
        let result = await verify(candidate: candidate, executable: executable)
        composeCache[item.id] = .init(candidate: candidate, result: result, checkedAt: Date())
        return result
    }

    private func verify(
        candidate: DockerComposeCandidate,
        executable: URL
    ) async -> DockerComposeVerification {
        do {
            let hash = try await currentConfigurationHash(candidate: candidate, executable: executable)
            guard hash == candidate.configurationHash else {
                return .unverified("The current Compose configuration hash differs from the container label. Refresh or recreate the service before controlling it.")
            }
            guard try await composeScopeContains(candidate: candidate, executable: executable) else {
                return .unverified("The labeled Compose scope did not resolve to this exact container. No service action is available.")
            }
            return .verified(candidate.context(verifiedAt: Date()))
        } catch {
            return .unverified("Compose context verification failed: \(error.localizedDescription)")
        }
    }

    private func runComposeAction(
        context: DockerComposeContext,
        command: [String],
        description: String
    ) async throws {
        let executable = try dockerExecutable()
        let candidate = try DockerComposeCandidate(context: context)
        let verification = await verify(candidate: candidate, executable: executable)
        guard case let .verified(current) = verification else {
            let issue = verification.issue ?? "The Compose context is no longer verified."
            throw DevBerthError.ownerActionUnavailable(
                owner: "\(context.projectName)/\(context.serviceName)",
                reason: "\(issue) No Docker mutation was sent."
            )
        }
        let result = try await runner.run(
            executable: executable,
            arguments: Self.composeScopeArguments(current) + command + [current.serviceName]
        )
        guard result.exitCode == 0 else {
            throw DevBerthError.commandFailed(
                command: "docker \(description)",
                status: result.exitCode,
                details: Self.concise(result.stderrString)
            )
        }
        composeCache.removeValue(forKey: context.containerID)
    }

    private func currentConfigurationHash(
        candidate: DockerComposeCandidate,
        executable: URL
    ) async throws -> String {
        let result = try await runner.run(
            executable: executable,
            arguments: Self.composeScopeArguments(candidate) + ["config", "--hash", candidate.serviceName]
        )
        guard result.exitCode == 0 else {
            throw DevBerthError.commandFailed(
                command: "docker compose config --hash",
                status: result.exitCode,
                details: Self.concise(result.stderrString)
            )
        }
        guard let hash = Self.parseConfigurationHash(result.stdoutString, serviceName: candidate.serviceName) else {
            throw DevBerthError.malformedOutput(command: "docker compose config --hash")
        }
        return hash
    }

    private func composeScopeContains(
        candidate: DockerComposeCandidate,
        executable: URL
    ) async throws -> Bool {
        let result = try await runner.run(
            executable: executable,
            arguments: Self.composeScopeArguments(candidate)
                + ["ps", "--all", "--no-trunc", "--format", "json", candidate.serviceName]
        )
        guard result.exitCode == 0 else {
            throw DevBerthError.commandFailed(
                command: "docker compose ps",
                status: result.exitCode,
                details: Self.concise(result.stderrString)
            )
        }
        let rows = try Self.parseComposeRows(result.stdout)
        return rows.contains {
            $0.id == candidate.containerID
                && $0.project == candidate.projectName
                && $0.service == candidate.serviceName
        }
    }

    private func runAction(_ arguments: [String], description: String) async throws {
        let result = try await runner.run(executable: try dockerExecutable(), arguments: arguments)
        guard result.exitCode == 0 else {
            throw DevBerthError.commandFailed(
                command: "docker \(description)",
                status: result.exitCode,
                details: Self.concise(result.stderrString)
            )
        }
    }

    private func dockerExecutable() throws -> URL {
        guard let executable else {
            throw DevBerthError.dockerUnavailable("The Docker CLI is not installed or is not on PATH.")
        }
        return executable
    }

    static func composeScopeArguments(_ context: DockerComposeContext) -> [String] {
        composeScopeArguments(
            projectName: context.projectName,
            serviceName: context.serviceName,
            workingDirectory: context.workingDirectory.path,
            configurationFiles: context.configurationFilePaths,
            environmentFiles: context.environmentFilePaths
        )
    }

    fileprivate static func composeScopeArguments(_ candidate: DockerComposeCandidate) -> [String] {
        composeScopeArguments(
            projectName: candidate.projectName,
            serviceName: candidate.serviceName,
            workingDirectory: candidate.workingDirectory.path,
            configurationFiles: candidate.configurationFiles.map(\.path),
            environmentFiles: candidate.environmentFiles.map(\.path)
        )
    }

    private static func composeScopeArguments(
        projectName: String,
        serviceName: String,
        workingDirectory: String,
        configurationFiles: [String],
        environmentFiles: [String]
    ) -> [String] {
        var arguments = [
            "compose",
            "--project-name", projectName,
            "--project-directory", workingDirectory
        ]
        for path in configurationFiles {
            arguments += ["--file", path]
        }
        for path in environmentFiles {
            arguments += ["--env-file", path]
        }
        return arguments
    }

    static func parseConfigurationHash(_ output: String, serviceName: String) -> String? {
        let lines = output.split(whereSeparator: \.isNewline)
        guard lines.count == 1 else { return nil }
        let components = lines[0].split(whereSeparator: \.isWhitespace).map(String.init)
        if components.count == 1 { return components[0].nilIfEmpty }
        guard components.count == 2, components[0] == serviceName else { return nil }
        return components[1].nilIfEmpty
    }

    static func parseContainerLine(_ line: String) -> DockerContainer? {
        guard let data = line.data(using: .utf8),
              let value = try? JSONDecoder().decode(DockerPSLine.self, from: data) else { return nil }
        let labels = parseLabels(value.labels)
        return DockerContainer(
            id: value.id,
            name: value.names,
            image: value.image,
            state: "running",
            status: value.status,
            ports: DockerPortParser.parse(value.ports),
            composeProject: labels[DockerComposeLabel.project],
            composeService: labels[DockerComposeLabel.service]
        )
    }

    private static func parseComposeRows(_ data: Data) throws -> [DockerComposePSRow] {
        if data.isEmpty { return [] }
        if let rows = try? JSONDecoder().decode([DockerComposePSRow].self, from: data) {
            return rows
        }
        let text = String(decoding: data, as: UTF8.self)
        let rows = text.split(whereSeparator: \.isNewline).compactMap { line in
            try? JSONDecoder().decode(DockerComposePSRow.self, from: Data(line.utf8))
        }
        guard !rows.isEmpty else { throw DevBerthError.malformedOutput(command: "docker compose ps") }
        return rows
    }

    private static func parseLabels(_ text: String) -> [String: String] {
        Dictionary(uniqueKeysWithValues: text.split(separator: ",").compactMap { item in
            guard let equal = item.firstIndex(of: "=") else { return nil }
            return (String(item[..<equal]), String(item[item.index(after: equal)...]))
        })
    }

    private static func isPlausibleContainerID(_ value: String) -> Bool {
        value.count >= 12 && value.allSatisfy { $0.isHexDigit }
    }

    private static func concise(_ text: String) -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Docker did not provide additional details." : String(value.prefix(500))
    }
}

private enum DockerComposeLabel {
    static let project = "com.docker.compose.project"
    static let service = "com.docker.compose.service"
    static let configurationHash = "com.docker.compose.config-hash"
    static let workingDirectory = "com.docker.compose.project.working_dir"
    static let configurationFiles = "com.docker.compose.project.config_files"
    static let environmentFiles = "com.docker.compose.project.environment_file"
    static let oneOff = "com.docker.compose.oneoff"
}

private enum DockerComposeVerification: Hashable {
    case notCompose
    case verified(DockerComposeContext)
    case unverified(String)

    var issue: String? {
        if case let .unverified(value) = self { return value }
        return nil
    }
}

private struct DockerComposeCandidate: Hashable {
    let containerID: String
    let projectName: String
    let serviceName: String
    let workingDirectory: DockerContextPath
    let configurationFiles: [DockerContextPath]
    let environmentFiles: [DockerContextPath]
    let configurationHash: String

    init(item: DockerInspectContainer) throws {
        let labels = item.labels
        guard labels[DockerComposeLabel.oneOff]?.lowercased() != "true" else {
            throw DevBerthError.ownerActionUnavailable(
                owner: item.displayName,
                reason: "One-off Compose containers cannot safely receive service-wide actions."
            )
        }
        guard let projectName = labels[DockerComposeLabel.project]?.strictDockerMetadata,
              let serviceName = labels[DockerComposeLabel.service]?.strictDockerMetadata,
              let configurationHash = labels[DockerComposeLabel.configurationHash]?.strictDockerMetadata,
              let workingDirectoryPath = labels[DockerComposeLabel.workingDirectory]?.strictDockerPath,
              let configurationFileValue = labels[DockerComposeLabel.configurationFiles]?.strictDockerMetadata else {
            throw DevBerthError.ownerActionUnavailable(
                owner: item.displayName,
                reason: "Required canonical Compose labels are missing or malformed."
            )
        }
        let configurationPaths = Self.pathList(configurationFileValue)
        guard !configurationPaths.isEmpty else {
            throw DevBerthError.ownerActionUnavailable(
                owner: item.displayName,
                reason: "The Compose configuration-file label is empty."
            )
        }
        let environmentPaths = Self.pathList(labels[DockerComposeLabel.environmentFiles] ?? "")
        self.containerID = item.id
        self.projectName = projectName
        self.serviceName = serviceName
        self.workingDirectory = try DockerContextPath.capture(workingDirectoryPath, expectsDirectory: true)
        self.configurationFiles = try configurationPaths.map { try DockerContextPath.capture($0, expectsDirectory: false) }
        self.environmentFiles = try environmentPaths.map { try DockerContextPath.capture($0, expectsDirectory: false) }
        self.configurationHash = configurationHash
    }

    init(context: DockerComposeContext) throws {
        let currentWorkingDirectory = try DockerContextPath.capture(context.workingDirectory.path, expectsDirectory: true)
        let currentConfigurationFiles = try context.configurationFiles.map {
            try DockerContextPath.capture($0.path, expectsDirectory: false)
        }
        let currentEnvironmentFiles = try context.environmentFiles.map {
            try DockerContextPath.capture($0.path, expectsDirectory: false)
        }
        guard currentWorkingDirectory == context.workingDirectory,
              currentConfigurationFiles == context.configurationFiles,
              currentEnvironmentFiles == context.environmentFiles else {
            throw DevBerthError.ownerActionUnavailable(
                owner: "\(context.projectName)/\(context.serviceName)",
                reason: "A verified Compose path changed identity or contents before the action."
            )
        }
        containerID = context.containerID
        projectName = context.projectName
        serviceName = context.serviceName
        workingDirectory = currentWorkingDirectory
        configurationFiles = currentConfigurationFiles
        environmentFiles = currentEnvironmentFiles
        configurationHash = context.configurationHash
    }

    func context(verifiedAt: Date) -> DockerComposeContext {
        DockerComposeContext(
            containerID: containerID,
            projectName: projectName,
            serviceName: serviceName,
            workingDirectory: workingDirectory,
            configurationFiles: configurationFiles,
            environmentFiles: environmentFiles,
            configurationHash: configurationHash,
            verifiedAt: verifiedAt
        )
    }

    private static func pathList(_ value: String) -> [String] {
        value.split(separator: ",", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private extension DockerContextPath {
    static func capture(_ path: String, expectsDirectory: Bool) throws -> DockerContextPath {
        guard let safePath = path.strictDockerPath else {
            throw DevBerthError.ownerActionUnavailable(owner: path, reason: "The Compose path is not a safe absolute path.")
        }
        let url = URL(fileURLWithPath: safePath)
        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        guard canonicalURL.path == url.standardizedFileURL.path else {
            throw DevBerthError.ownerActionUnavailable(owner: safePath, reason: "Compose context paths containing symbolic links are not trusted for mutation.")
        }
        var metadata = stat()
        guard Darwin.lstat(safePath, &metadata) == 0 else {
            throw DevBerthError.ownerActionUnavailable(
                owner: safePath,
                reason: expectsDirectory ? "The Compose working directory is unavailable." : "A Compose context file is unavailable or not a regular file."
            )
        }
        let fileType = metadata.st_mode & mode_t(S_IFMT)
        guard fileType != mode_t(S_IFLNK),
              expectsDirectory ? fileType == mode_t(S_IFDIR) : fileType == mode_t(S_IFREG) else {
            throw DevBerthError.ownerActionUnavailable(
                owner: safePath,
                reason: expectsDirectory ? "The Compose working directory is unavailable." : "A Compose context file is unavailable or not a regular file."
            )
        }
        let modificationDate = expectsDirectory ? nil : Date(
            timeIntervalSince1970: TimeInterval(metadata.st_mtimespec.tv_sec)
                + TimeInterval(metadata.st_mtimespec.tv_nsec) / 1_000_000_000
        )
        return DockerContextPath(
            path: safePath,
            fileIdentity: .init(deviceID: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino)),
            size: expectsDirectory ? 0 : UInt64(max(metadata.st_size, 0)),
            modificationDate: modificationDate
        )
    }
}

private struct DockerInspectContainer: Decodable {
    struct Configuration: Decodable {
        let image: String
        let labels: [String: String]?

        enum CodingKeys: String, CodingKey {
            case image = "Image"
            case labels = "Labels"
        }
    }

    struct Health: Decodable { let status: String
        enum CodingKeys: String, CodingKey { case status = "Status" }
    }

    struct State: Decodable {
        let status: String
        let health: Health?

        enum CodingKeys: String, CodingKey {
            case status = "Status"
            case health = "Health"
        }
    }

    struct RestartPolicy: Decodable { let name: String
        enum CodingKeys: String, CodingKey { case name = "Name" }
    }

    struct HostConfiguration: Decodable {
        let restartPolicy: RestartPolicy
        enum CodingKeys: String, CodingKey { case restartPolicy = "RestartPolicy" }
    }

    struct PortBinding: Decodable {
        let hostIP: String
        let hostPort: String

        enum CodingKeys: String, CodingKey {
            case hostIP = "HostIp"
            case hostPort = "HostPort"
        }
    }

    struct NetworkSettings: Decodable {
        let ports: [String: [PortBinding]?]?
        enum CodingKeys: String, CodingKey { case ports = "Ports" }
    }

    let id: String
    let name: String
    let configuration: Configuration
    let state: State
    let hostConfiguration: HostConfiguration
    let networkSettings: NetworkSettings

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case configuration = "Config"
        case state = "State"
        case hostConfiguration = "HostConfig"
        case networkSettings = "NetworkSettings"
    }

    var labels: [String: String] { configuration.labels ?? [:] }
    var displayName: String { name.hasPrefix("/") ? String(name.dropFirst()) : name }
    var hasComposeLabels: Bool { labels[DockerComposeLabel.project] != nil || labels[DockerComposeLabel.service] != nil }

    func container(compose: DockerComposeVerification) -> DockerContainer {
        let context: DockerComposeContext?
        let issue: String?
        switch compose {
        case .notCompose:
            context = nil
            issue = nil
        case let .verified(value):
            context = value
            issue = nil
        case let .unverified(value):
            context = nil
            issue = value
        }
        return DockerContainer(
            id: id,
            name: displayName,
            image: configuration.image,
            state: state.status,
            status: state.status,
            healthStatus: state.health?.status,
            restartPolicy: hostConfiguration.restartPolicy.name,
            ports: publishedPorts,
            composeProject: labels[DockerComposeLabel.project],
            composeService: labels[DockerComposeLabel.service],
            composeContext: context,
            composeContextIssue: issue
        )
    }

    private var publishedPorts: [DockerPortMapping] {
        guard let ports = networkSettings.ports else { return [] }
        return ports.flatMap { key, optionalBindings -> [DockerPortMapping] in
            guard let slash = key.lastIndex(of: "/"),
                  let containerPort = UInt16(key[..<slash]),
                  let protocolKind = ListenerProtocol(rawValue: key[key.index(after: slash)...].uppercased()),
                  let bindings = optionalBindings else { return [] }
            return bindings.compactMap { binding in
                guard let hostPort = UInt16(binding.hostPort) else { return nil }
                return DockerPortMapping(
                    hostAddress: binding.hostIP.isEmpty ? "*" : binding.hostIP,
                    hostPort: hostPort,
                    containerPort: containerPort,
                    protocolKind: protocolKind
                )
            }
        }.sorted {
            ($0.hostPort, $0.containerPort, $0.protocolKind.rawValue)
                < ($1.hostPort, $1.containerPort, $1.protocolKind.rawValue)
        }
    }
}

private struct DockerComposePSRow: Decodable {
    let id: String
    let project: String
    let service: String

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case project = "Project"
        case service = "Service"
    }
}

private struct DockerPSLine: Decodable {
    let id: String
    let image: String
    let names: String
    let ports: String
    let status: String
    let labels: String

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case image = "Image"
        case names = "Names"
        case ports = "Ports"
        case status = "Status"
        case labels = "Labels"
    }
}

private extension String {
    var strictDockerMetadata: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.count <= 4_096,
              !value.contains("\0"),
              !value.contains("\n"),
              !value.contains("\r") else { return nil }
        return value
    }

    var strictDockerPath: String? {
        guard let value = strictDockerMetadata,
              value.hasPrefix("/"),
              URL(fileURLWithPath: value).standardizedFileURL.path == value else { return nil }
        return value
    }

    var nilIfEmpty: String? { isEmpty ? nil : self }
}
