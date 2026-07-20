import Foundation

actor DockerCLIClient: DockerServing {
    private let runner: any CommandRunning
    private let executable: URL?

    init(runner: any CommandRunning, resolver: ExecutableResolver = ExecutableResolver()) {
        self.runner = runner
        self.executable = resolver.resolve(
            "docker",
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: NSHomeDirectory()
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
        let executable = try dockerExecutable()
        let result = try await runner.run(
            executable: executable,
            arguments: ["ps", "--format", "{{json .}}"]
        )
        guard result.exitCode == 0 else {
            throw PortPilotError.dockerUnavailable(Self.concise(result.stderrString))
        }
        return result.stdoutString.split(whereSeparator: \.isNewline).compactMap { Self.parseContainerLine(String($0)) }
    }

    func stop(containerID: String) async throws {
        try await runAction(["stop", containerID], description: "stop container")
    }

    func restart(containerID: String) async throws {
        try await runAction(["restart", containerID], description: "restart container")
    }

    func recentLogs(containerID: String, lines: Int) async throws -> String {
        let executable = try dockerExecutable()
        let result = try await runner.run(
            executable: executable,
            arguments: ["logs", "--tail", String(min(max(lines, 1), 2_000)), containerID]
        )
        guard result.exitCode == 0 else {
            throw PortPilotError.commandFailed(command: "docker logs", status: result.exitCode, details: Self.concise(result.stderrString))
        }
        return result.stdoutString + result.stderrString
    }

    private func runAction(_ arguments: [String], description: String) async throws {
        let result = try await runner.run(executable: try dockerExecutable(), arguments: arguments)
        guard result.exitCode == 0 else {
            throw PortPilotError.commandFailed(command: "docker \(description)", status: result.exitCode, details: Self.concise(result.stderrString))
        }
    }

    private func dockerExecutable() throws -> URL {
        guard let executable else { throw PortPilotError.dockerUnavailable("The Docker CLI is not installed or is not on PATH.") }
        return executable
    }

    static func parseContainerLine(_ line: String) -> DockerContainer? {
        guard let data = line.data(using: .utf8), let value = try? JSONDecoder().decode(DockerPSLine.self, from: data) else { return nil }
        let labels = parseLabels(value.labels)
        return DockerContainer(
            id: value.id,
            name: value.names,
            image: value.image,
            status: value.status,
            ports: DockerPortParser.parse(value.ports),
            composeProject: labels["com.docker.compose.project"],
            composeService: labels["com.docker.compose.service"]
        )
    }

    private static func parseLabels(_ text: String) -> [String: String] {
        Dictionary(uniqueKeysWithValues: text.split(separator: ",").compactMap { item in
            guard let equal = item.firstIndex(of: "=") else { return nil }
            return (String(item[..<equal]), String(item[item.index(after: equal)...]))
        })
    }

    private static func concise(_ text: String) -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Docker did not provide additional details." : String(value.prefix(500))
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
