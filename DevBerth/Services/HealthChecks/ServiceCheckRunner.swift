import Foundation

actor ServiceCheckRunner: ServiceCheckRunning {
    private let discoverer: any PortDiscovering
    private let http: any HTTPProbing
    private let commandRunner: any CommandRunning
    private let docker: any DockerHealthInspecting
    private let dependencies: any DependencyReadinessProviding
    private let fileManager: FileManager
    private let clock: @Sendable () -> Date

    init(
        discoverer: any PortDiscovering,
        http: any HTTPProbing,
        commandRunner: any CommandRunning,
        docker: any DockerHealthInspecting,
        dependencies: any DependencyReadinessProviding,
        fileManager: FileManager = .default,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.discoverer = discoverer
        self.http = http
        self.commandRunner = commandRunner
        self.docker = docker
        self.dependencies = dependencies
        self.fileManager = fileManager
        self.clock = clock
    }

    func run(_ checks: [ServiceCheckConfiguration]) async throws -> [ServiceCheckResult] {
        var results: [ServiceCheckResult] = []
        for check in checks {
            let result = try await run(check)
            results.append(result)
            guard result.succeeded else {
                throw DevBerthError.launchValidation(result.summary)
            }
        }
        return results
    }

    private func run(_ check: ServiceCheckConfiguration) async throws -> ServiceCheckResult {
        let startedAt = clock()
        if check.initialDelaySeconds > 0 {
            try await Task.sleep(for: .seconds(check.initialDelaySeconds))
        }
        let deadline = clock().addingTimeInterval(max(0.1, check.timeoutSeconds))
        let retryLimit = max(1, check.retryLimit)
        var attempts = 0
        while attempts < retryLimit, clock() <= deadline {
            try Task.checkCancellation()
            attempts += 1
            if (try? await evaluate(check.kind, timeoutSeconds: check.timeoutSeconds)) == true {
                return ServiceCheckResult(
                    checkID: check.id,
                    succeeded: true,
                    attempts: attempts,
                    summary: successSummary(check.kind),
                    startedAt: startedAt,
                    completedAt: clock()
                )
            }
            if attempts < retryLimit, clock() < deadline {
                try await Task.sleep(for: .seconds(max(0.05, check.intervalSeconds)))
            }
        }
        return ServiceCheckResult(
            checkID: check.id,
            succeeded: false,
            attempts: attempts,
            summary: check.failureMessage,
            startedAt: startedAt,
            completedAt: clock()
        )
    }

    private func evaluate(_ kind: ServiceCheckKind, timeoutSeconds: Double) async throws -> Bool {
        switch kind {
        case let .tcpListener(host, port):
            return try await discoverer.discover().contains {
                $0.protocolKind == .tcp
                    && $0.port == port
                    && (host.isEmpty || $0.address == host)
            }
        case let .http(url, expectedStatus, responseContains):
            let response = try await http.probe(url: url, timeoutSeconds: timeoutSeconds)
            return response.statusCode == expectedStatus
                && responseContains.map { response.body.contains($0) } ?? true
        case let .executable(path, arguments, workingDirectory):
            guard path.hasPrefix("/"), fileManager.isExecutableFile(atPath: path) else { return false }
            let result = try await commandRunner.run(
                executable: URL(fileURLWithPath: path),
                arguments: arguments,
                environment: nil,
                currentDirectory: workingDirectory.map {
                    URL(fileURLWithPath: $0, isDirectory: true)
                }
            )
            return result.exitCode == 0
        case let .fileExists(path):
            return fileManager.fileExists(atPath: path)
        case let .dockerHealth(containerID):
            return try await docker.healthStatus(containerID: containerID) == "healthy"
        case let .dependencyReady(managedServiceID):
            return await dependencies.isReady(managedServiceID: managedServiceID)
        }
    }

    private func successSummary(_ kind: ServiceCheckKind) -> String {
        switch kind {
        case .tcpListener: "Expected TCP listener is open."
        case .http: "HTTP response matched the reviewed status and text criteria."
        case .executable: "Health command exited successfully."
        case .fileExists: "Required file exists."
        case .dockerHealth: "Docker reports the container healthy."
        case .dependencyReady: "Required dependency is ready."
        }
    }
}

actor URLSessionHTTPProber: HTTPProbing {
    func probe(url: URL, timeoutSeconds: Double) async throws -> HTTPProbeResponse {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeoutSeconds
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DevBerthError.malformedOutput(command: "HTTP health probe")
        }
        return HTTPProbeResponse(
            statusCode: http.statusCode,
            body: String(decoding: data, as: UTF8.self)
        )
    }
}

actor DockerCLIHealthInspector: DockerHealthInspecting {
    private let runner: any CommandRunning
    private let resolver: ExecutableResolver

    init(
        runner: any CommandRunning,
        resolver: ExecutableResolver = ExecutableResolver()
    ) {
        self.runner = runner
        self.resolver = resolver
    }

    func healthStatus(containerID: String) async throws -> String {
        guard containerID.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil else {
            throw DevBerthError.launchValidation("The Docker container identity is invalid.")
        }
        guard let executable = resolver.resolve(
            "docker",
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: FileManager.default.currentDirectoryPath
        ) else {
            throw DevBerthError.commandUnavailable("docker")
        }
        let result = try await runner.run(
            executable: executable,
            arguments: ["inspect", "--format", "{{.State.Health.Status}}", containerID],
            environment: nil,
            currentDirectory: nil
        )
        guard result.exitCode == 0 else {
            throw DevBerthError.commandFailed(
                command: "docker inspect",
                status: result.exitCode,
                details: "Docker health metadata was unavailable."
            )
        }
        return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
