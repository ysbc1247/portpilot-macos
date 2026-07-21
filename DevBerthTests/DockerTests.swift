import XCTest
@testable import DevBerth

final class DockerTests: XCTestCase {
    func testFoundationCommandRunnerDrainsOutputLargerThanPipeCapacity() async throws {
        let payload = (0..<8_192)
            .map { String(format: "%08d\n", $0) }
            .joined()

        let result = try await FoundationCommandRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%s", payload]
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdoutString, payload)
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testExecutableResolverUsesAdditionalGUISearchDirectories() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevBerthExecutableResolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("docker")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let resolved = ExecutableResolver().resolve(
            "docker",
            environment: ["PATH": "/usr/bin:/bin"],
            workingDirectory: "/",
            additionalSearchDirectories: [directory.path]
        )

        XCTAssertEqual(resolved?.path, executable.path)
    }

    func testParsesIPv4IPv6PublishedPortsAndSkipsUnpublishedPorts() {
        let value = "127.0.0.1:5432->5432/tcp, [::]:8080->80/tcp, 6379/tcp, 0.0.0.0:5353->5353/udp"
        let mappings = DockerPortParser.parse(value)
        XCTAssertEqual(mappings.count, 3)
        XCTAssertEqual(mappings.map(\.hostAddress), ["127.0.0.1", "::", "0.0.0.0"])
        XCTAssertEqual(mappings.map(\.hostPort), [5432, 8080, 5353])
        XCTAssertEqual(mappings.map(\.containerPort), [5432, 80, 5353])
        XCTAssertEqual(mappings.map(\.protocolKind), [.tcp, .tcp, .udp])
    }

    func testParsesDockerJSONAndComposeLabels() throws {
        let line = #"{"ID":"abc123","Image":"postgres:17","Names":"db","Ports":"127.0.0.1:5432->5432/tcp","Status":"Up 2 minutes","Labels":"com.docker.compose.project=demo,com.docker.compose.service=db"}"#
        let container = try XCTUnwrap(DockerCLIClient.parseContainerLine(line))
        XCTAssertEqual(container.name, "db")
        XCTAssertEqual(container.composeProject, "demo")
        XCTAssertEqual(container.composeService, "db")
        XCTAssertEqual(container.ports.first?.hostPort, 5432)
    }

    func testUnavailableDockerDoesNotInvokeRunner() async {
        let runner = MockCommandRunner { _, _ in XCTFail("Docker should not be invoked"); return .init(stdout: Data(), stderr: Data(), exitCode: 0) }
        let client = DockerCLIClient(runner: runner, executable: nil)
        let value = await client.availability()
        XCTAssertEqual(value, .notInstalled)
    }

    func testBatchInspectionSurfacesEngineAndVerifiedComposeContext() async throws {
        let fixture = try ComposeFixture()
        let runner = MockCommandRunner { _, arguments in
            try fixture.result(for: arguments)
        }
        let client = DockerCLIClient(runner: runner, executable: URL(fileURLWithPath: "/usr/local/bin/docker"))

        let first = try await client.runningContainers()
        let second = try await client.runningContainers()
        let container = try XCTUnwrap(first.first)

        XCTAssertEqual(first, second)
        XCTAssertEqual(container.id, fixture.containerID)
        XCTAssertEqual(container.name, "demo-api-1")
        XCTAssertEqual(container.image, "demo/api:latest")
        XCTAssertEqual(container.state, "running")
        XCTAssertEqual(container.healthStatus, "healthy")
        XCTAssertEqual(container.restartPolicy, "unless-stopped")
        XCTAssertEqual(container.ports, [
            .init(hostAddress: "127.0.0.1", hostPort: 8080, containerPort: 3000, protocolKind: .tcp),
            .init(hostAddress: "::", hostPort: 8443, containerPort: 3000, protocolKind: .tcp)
        ])
        let context = try XCTUnwrap(container.composeContext, container.composeContextIssue ?? "Missing Compose context")
        XCTAssertEqual(context.projectName, "demo")
        XCTAssertEqual(context.serviceName, "api")
        XCTAssertEqual(context.workingDirectory.path, fixture.directory.path)
        XCTAssertEqual(context.configurationFilePaths, [fixture.composeFile.path])
        XCTAssertEqual(context.environmentFilePaths, [fixture.environmentFile.path])
        XCTAssertNil(container.composeContextIssue)

        XCTAssertEqual(runner.invocations.filter { $0.arguments.first == "inspect" }.count, 2)
        XCTAssertEqual(runner.invocations.filter { $0.arguments.contains("config") }.count, 1)
        XCTAssertEqual(runner.invocations.filter { $0.arguments.contains("ps") && $0.arguments.first == "compose" }.count, 1)
    }

    func testComposeContextAcceptsCaseOnlyPathSpellingOnCaseInsensitiveVolume() async throws {
        let fixture = try ComposeFixture()
        let caseVariant = fixture.directory.deletingLastPathComponent()
            .appendingPathComponent(fixture.directory.lastPathComponent.lowercased(), isDirectory: true)
        guard FileManager.default.fileExists(atPath: caseVariant.path),
              caseVariant.path != fixture.directory.path else {
            throw XCTSkip("This test requires a case-insensitive volume and a case-varying fixture name.")
        }
        fixture.useLabelRoot(caseVariant)
        let runner = MockCommandRunner { _, arguments in try fixture.result(for: arguments) }
        let client = DockerCLIClient(runner: runner, executable: URL(fileURLWithPath: "/usr/local/bin/docker"))

        let containers = try await client.runningContainers()
        let container = try XCTUnwrap(containers.first)
        let context = try XCTUnwrap(container.composeContext)

        XCTAssertEqual(context.workingDirectory.path, caseVariant.path)
        XCTAssertNil(container.composeContextIssue)
    }

    func testComposeContextRejectsRealSymlinkComponent() async throws {
        let fixture = try ComposeFixture()
        let link = fixture.directory.deletingLastPathComponent()
            .appendingPathComponent("DevBerthDockerLink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.directory)
        defer { try? FileManager.default.removeItem(at: link) }
        fixture.useLabelRoot(link)
        let runner = MockCommandRunner { _, arguments in try fixture.result(for: arguments) }
        let client = DockerCLIClient(runner: runner, executable: URL(fileURLWithPath: "/usr/local/bin/docker"))

        let containers = try await client.runningContainers()
        let container = try XCTUnwrap(containers.first)

        XCTAssertNil(container.composeContext)
        XCTAssertTrue(try XCTUnwrap(container.composeContextIssue).contains("symbolic links"))
    }

    func testPassiveInspectionSkipsComposeControlVerification() async throws {
        let fixture = try ComposeFixture()
        let runner = MockCommandRunner { _, arguments in
            try fixture.result(for: arguments)
        }
        let client = DockerCLIClient(runner: runner, executable: URL(fileURLWithPath: "/usr/local/bin/docker"))

        let containers = try await client.observedRunningContainers()
        let container = try XCTUnwrap(containers.first)

        XCTAssertEqual(container.composeProject, "demo")
        XCTAssertEqual(container.composeService, "api")
        XCTAssertNil(container.composeContext)
        XCTAssertEqual(container.composeContextIssue, "Compose control scope is not verified during passive inspection.")
        XCTAssertFalse(runner.invocations.contains { $0.arguments.contains("config") })
        XCTAssertFalse(runner.invocations.contains { $0.arguments.contains("--format") && $0.arguments.contains("json") })
    }

    func testComposeHashMismatchLeavesContainerInspectionOnly() async throws {
        let fixture = try ComposeFixture(configurationHashOutput: "api different-hash\n")
        let runner = MockCommandRunner { _, arguments in try fixture.result(for: arguments) }
        let client = DockerCLIClient(runner: runner, executable: URL(fileURLWithPath: "/usr/local/bin/docker"))

        let containers = try await client.runningContainers()
        let container = try XCTUnwrap(containers.first)

        XCTAssertNil(container.composeContext)
        XCTAssertTrue(try XCTUnwrap(container.composeContextIssue).contains("hash differs"))
        XCTAssertFalse(runner.invocations.contains { $0.arguments.contains("--format") && $0.arguments.contains("json") })
    }

    func testOneOffComposeContainerNeverReceivesServiceScope() async throws {
        let fixture = try ComposeFixture(oneOff: true)
        let runner = MockCommandRunner { _, arguments in try fixture.result(for: arguments) }
        let client = DockerCLIClient(runner: runner, executable: URL(fileURLWithPath: "/usr/local/bin/docker"))

        let containers = try await client.runningContainers()
        let container = try XCTUnwrap(containers.first)

        XCTAssertNil(container.composeContext)
        XCTAssertTrue(try XCTUnwrap(container.composeContextIssue).contains("One-off"))
        XCTAssertFalse(runner.invocations.contains { $0.arguments.first == "compose" })
    }

    func testVerifiedComposeRestartUsesAllExactScopeArgumentsAndNoDependencies() async throws {
        let fixture = try ComposeFixture()
        let runner = MockCommandRunner { _, arguments in try fixture.result(for: arguments) }
        let client = DockerCLIClient(runner: runner, executable: URL(fileURLWithPath: "/usr/local/bin/docker"))
        let containers = try await client.runningContainers()
        let context = try XCTUnwrap(containers.first?.composeContext)

        try await client.restartComposeService(context: context)

        let expected = [
            "compose",
            "--project-name", "demo",
            "--project-directory", fixture.directory.path,
            "--file", fixture.composeFile.path,
            "--env-file", fixture.environmentFile.path,
            "restart", "--no-deps", "api"
        ]
        XCTAssertEqual(runner.invocations.last?.arguments, expected)
    }

    func testComposeMutationRefusesContextFileReplacementBeforeDockerAction() async throws {
        let fixture = try ComposeFixture()
        let runner = MockCommandRunner { _, arguments in try fixture.result(for: arguments) }
        let client = DockerCLIClient(runner: runner, executable: URL(fileURLWithPath: "/usr/local/bin/docker"))
        let containers = try await client.runningContainers()
        let context = try XCTUnwrap(containers.first?.composeContext)
        try Data("services:\n  api:\n    image: changed-and-longer\n".utf8).write(to: fixture.composeFile)
        let invocationCount = runner.invocations.count

        do {
            try await client.stopComposeService(context: context)
            XCTFail("Expected stale Compose path evidence to be refused")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("changed identity or contents"))
        }
        XCTAssertEqual(runner.invocations.count, invocationCount)
    }

    func testConfigurationHashParserRejectsAmbiguousOutput() {
        XCTAssertEqual(DockerCLIClient.parseConfigurationHash("api abc123\n", serviceName: "api"), "abc123")
        XCTAssertEqual(DockerCLIClient.parseConfigurationHash("abc123\n", serviceName: "api"), "abc123")
        XCTAssertNil(DockerCLIClient.parseConfigurationHash("worker abc123\n", serviceName: "api"))
        XCTAssertNil(DockerCLIClient.parseConfigurationHash("api one\napi two\n", serviceName: "api"))
    }

    func testAssociationMonitoringRecordsContainerAndComposeTransitionsAfterBaseline() async {
        let container = DockerContainer(
            id: String(repeating: "b", count: 64),
            name: "demo-api-1",
            image: "demo/api:latest",
            state: "running",
            status: "running",
            ports: [],
            composeProject: "demo",
            composeService: "api"
        )
        let docker = SequencedDockerService(snapshots: [[container], []])
        let recorder = DockerLifecycleRecorder()
        let provider = DockerAssociationProvider(
            client: docker,
            lifecycleRecorder: recorder,
            refreshInterval: 0
        )

        _ = await provider.correlate([])
        _ = await provider.correlate([])
        let events = await recorder.events()

        XCTAssertEqual(events.map(\.category), [.dockerContainerStopped, .dockerComposeChanged])
        XCTAssertTrue(events.allSatisfy { $0.outcome == .observed && $0.trigger == .observation })
    }

    func testAssociationRefreshUsesExponentialBackoffAndManualInvalidation() async {
        let docker = FailingDockerService()
        let clock = MutableDateClock(date: Date(timeIntervalSince1970: 100))
        let provider = DockerAssociationProvider(
            client: docker,
            refreshInterval: 10,
            clock: { clock.now() }
        )

        _ = await provider.correlate([])
        var observationCalls = await docker.observationCalls()
        let availabilityCalls = await docker.availabilityCalls()
        XCTAssertEqual(observationCalls, 1)
        XCTAssertEqual(availabilityCalls, 0)

        clock.advance(by: 9)
        _ = await provider.correlate([])
        observationCalls = await docker.observationCalls()
        XCTAssertEqual(observationCalls, 1)

        clock.advance(by: 1)
        _ = await provider.correlate([])
        observationCalls = await docker.observationCalls()
        XCTAssertEqual(observationCalls, 2)

        clock.advance(by: 19)
        _ = await provider.correlate([])
        observationCalls = await docker.observationCalls()
        XCTAssertEqual(observationCalls, 2)

        clock.advance(by: 1)
        _ = await provider.correlate([])
        observationCalls = await docker.observationCalls()
        XCTAssertEqual(observationCalls, 3)

        await provider.invalidate()
        _ = await provider.correlate([])
        observationCalls = await docker.observationCalls()
        XCTAssertEqual(observationCalls, 4)
    }
}

private actor FailingDockerService: DockerServing {
    private var observations = 0
    private var availabilityChecks = 0

    func availability() async -> DockerAvailability {
        availabilityChecks += 1
        return .daemonUnavailable("test")
    }

    func runningContainers() async throws -> [DockerContainer] {
        observations += 1
        throw DevBerthError.dockerUnavailable("test")
    }

    func observationCalls() -> Int { observations }
    func availabilityCalls() -> Int { availabilityChecks }
    func stop(containerID: String) async throws {}
    func restart(containerID: String) async throws {}
    func recentLogs(containerID: String, lines: Int) async throws -> String { "" }
}

private final class MutableDateClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(date: Date) { self.date = date }
    func now() -> Date { lock.withLock { date } }
    func advance(by seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
}

private actor SequencedDockerService: DockerServing {
    private var snapshots: [[DockerContainer]]

    init(snapshots: [[DockerContainer]]) { self.snapshots = snapshots }
    func availability() async -> DockerAvailability { .available(version: "test") }
    func runningContainers() async throws -> [DockerContainer] {
        snapshots.isEmpty ? [] : snapshots.removeFirst()
    }
    func stop(containerID: String) async throws {}
    func restart(containerID: String) async throws {}
    func recentLogs(containerID: String, lines: Int) async throws -> String { "" }
}

private actor DockerLifecycleRecorder: RuntimeLifecycleRecording {
    private var values: [LifecycleEvent] = []
    func record(_ runtime: RuntimeInstance) async throws {}
    func record(_ event: LifecycleEvent) async throws { values.append(event) }
    func record(_ incident: RuntimeIncidentSummary) async throws {}
    func events() -> [LifecycleEvent] { values }
}

private final class ComposeFixture: @unchecked Sendable {
    let directory: URL
    let composeFile: URL
    let environmentFile: URL
    let containerID = String(repeating: "a", count: 64)
    let configurationHashOutput: String
    let oneOff: Bool
    private var labelRoot: URL?

    init(configurationHashOutput: String = "api compose-hash-123\n", oneOff: Bool = false) throws {
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DevBerthDockerTests-\(UUID().uuidString)", isDirectory: true)
        composeFile = directory.appendingPathComponent("compose.yaml")
        environmentFile = directory.appendingPathComponent(".env")
        self.configurationHashOutput = configurationHashOutput
        self.oneOff = oneOff
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("services:\n  api:\n    image: demo/api:latest\n".utf8).write(to: composeFile)
        try Data("PORT=3000\n".utf8).write(to: environmentFile)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func useLabelRoot(_ root: URL) {
        labelRoot = root
    }

    func result(for arguments: [String]) throws -> CommandResult {
        if arguments == ["ps", "--quiet", "--no-trunc"] {
            return success("\(containerID)\n")
        }
        if arguments == ["inspect", containerID] {
            return .init(stdout: try inspectData(), stderr: Data(), exitCode: 0)
        }
        if arguments.contains("config") {
            return success(configurationHashOutput)
        }
        if arguments.contains("--format") && arguments.contains("json") {
            let data = try JSONSerialization.data(withJSONObject: [[
                "ID": containerID,
                "Name": "demo-api-1",
                "Project": "demo",
                "Service": "api",
                "State": "running",
                "Health": "healthy",
                "Publishers": []
            ]])
            return .init(stdout: data, stderr: Data(), exitCode: 0)
        }
        if arguments.contains("restart") || arguments.contains("stop") || arguments.contains("rm") {
            return success("")
        }
        throw DevBerthError.unexpected("Unexpected Docker test invocation: \(arguments)")
    }

    private func inspectData() throws -> Data {
        let labeledDirectory = labelRoot ?? directory
        var labels = [
            "com.docker.compose.project": "demo",
            "com.docker.compose.service": "api",
            "com.docker.compose.config-hash": "compose-hash-123",
            "com.docker.compose.project.working_dir": labeledDirectory.path,
            "com.docker.compose.project.config_files": labeledDirectory.appendingPathComponent(composeFile.lastPathComponent).path,
            "com.docker.compose.project.environment_file": labeledDirectory.appendingPathComponent(environmentFile.lastPathComponent).path
        ]
        if oneOff { labels["com.docker.compose.oneoff"] = "True" }
        return try JSONSerialization.data(withJSONObject: [[
            "Id": containerID,
            "Name": "/demo-api-1",
            "Config": ["Image": "demo/api:latest", "Labels": labels],
            "State": ["Status": "running", "Health": ["Status": "healthy"]],
            "HostConfig": ["RestartPolicy": ["Name": "unless-stopped"]],
            "NetworkSettings": ["Ports": [
                "3000/tcp": [
                    ["HostIp": "127.0.0.1", "HostPort": "8080"],
                    ["HostIp": "::", "HostPort": "8443"]
                ],
                "5353/udp": NSNull()
            ]]
        ]])
    }

    private func success(_ output: String) -> CommandResult {
        .init(stdout: Data(output.utf8), stderr: Data(), exitCode: 0)
    }
}
