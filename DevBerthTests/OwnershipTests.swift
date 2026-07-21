import XCTest
@testable import DevBerth

final class OwnershipTests: XCTestCase {
    func testCommandSignaturesRecognizeKubernetesForwardAndSSHTunnel() {
        let kubectl = ownershipListener(
            command: "/opt/homebrew/bin/kubectl port-forward -n dev service/api 8080:80",
            executable: "/opt/homebrew/bin/kubectl"
        )
        let ssh = ownershipListener(
            command: "/usr/bin/ssh -N -L 5432:db.internal:5432 jump.example",
            executable: "/usr/bin/ssh"
        )
        let dynamicSSH = ownershipListener(
            command: "/usr/bin/ssh -D1080 jump.example",
            executable: "/usr/bin/ssh"
        )
        let loginOnlySSH = ownershipListener(
            command: "/usr/bin/ssh -l developer jump.example",
            executable: "/usr/bin/ssh"
        )

        XCTAssertEqual(classification(kubectl).category, .kubernetesPortForward)
        XCTAssertEqual(classification(kubectl).confidence, .stronglyInferred)
        XCTAssertEqual(classification(kubectl).recommendation.controllerKind, .kubernetesPortForward)
        XCTAssertEqual(classification(ssh).category, .sshTunnel)
        XCTAssertEqual(classification(ssh).recommendation.controllerKind, .sshTunnel)
        XCTAssertEqual(classification(dynamicSSH).category, .sshTunnel)
        XCTAssertEqual(classification(loginOnlySSH).category, .standaloneHostProcess)
    }

    func testLineageRulesDistinguishCodingAgentSupervisorIDETerminalAndShell() {
        let listener = ownershipListener(command: "node server.js", executable: "/opt/homebrew/bin/node")
        let cases: [([String], OwnershipCategory, LifecycleControllerKind)] = [
            (["Codex"], .codingAgentLaunchedProcess, .guardedExternalProcess),
            (["nodemon"], .supervisorManagedProcess, .unavailable),
            (["Xcode"], .ideLaunchedProcess, .guardedExternalProcess),
            (["iTerm2"], .terminalLaunchedProcess, .guardedExternalProcess),
            (["zsh"], .shellLaunchedProcess, .guardedExternalProcess)
        ]

        for (ancestors, expectedCategory, expectedController) in cases {
            let result = classification(listener, ancestorNames: ancestors)
            XCTAssertEqual(result.category, expectedCategory, "Ancestors: \(ancestors)")
            XCTAssertEqual(result.recommendation.controllerKind, expectedController, "Ancestors: \(ancestors)")
            XCTAssertEqual(result.confidence, .stronglyInferred)
        }
    }

    func testLaunchdAndHomebrewRulesExposeInferenceInsteadOfFact() {
        let homebrew = ownershipListener(
            command: "/opt/homebrew/Cellar/postgresql/17/bin/postgres",
            executable: "/opt/homebrew/Cellar/postgresql/17/bin/postgres",
            parentPID: 1
        )
        let agent = ownershipListener(
            command: "/usr/local/bin/local-agent",
            executable: "/usr/local/bin/local-agent",
            parentPID: 1
        )
        let daemon = ownershipListener(
            command: "/usr/libexec/example-daemon",
            executable: "/usr/libexec/example-daemon",
            uid: 0,
            parentPID: 1
        )

        XCTAssertEqual(classification(homebrew).category, .homebrewService)
        XCTAssertEqual(classification(homebrew).confidence, .stronglyInferred)
        XCTAssertEqual(classification(agent).category, .launchAgent)
        XCTAssertEqual(classification(daemon).category, .launchDaemon)
        XCTAssertTrue(classification(agent).recommendation.reason.contains("may trigger"))
    }

    func testStrongUnrecognizedProcessIsOnlyWeaklyInferredStandalone() {
        let result = classification(ownershipListener(
            command: "/opt/tools/custom-server",
            executable: "/opt/tools/custom-server",
            parentPID: 777
        ))

        XCTAssertEqual(result.category, .standaloneHostProcess)
        XCTAssertEqual(result.confidence, .weaklyInferred)
        XCTAssertEqual(result.recommendation.controllerKind, .guardedExternalProcess)
    }

    func testIncompleteFingerprintIsInspectOnly() {
        let weakFingerprint = ProcessFingerprint(
            pid: 42,
            executablePath: "/opt/tools/custom-server",
            startTime: nil,
            detectedAt: Date(timeIntervalSince1970: 1_740_000_000)
        )
        let result = classification(ownershipListener(
            command: "/opt/tools/custom-server",
            executable: "/opt/tools/custom-server",
            fingerprint: weakFingerprint
        ))

        XCTAssertEqual(result.category, .unknown)
        XCTAssertEqual(result.confidence, .unknown)
        XCTAssertEqual(result.recommendation.controllerKind, .unavailable)
        XCTAssertEqual(result.recommendation.supportedActions, [.inspect])
    }

    func testResolverPrefersVerifiedManagedRuntimeRegistration() async {
        let registry = ManagedRuntimeRegistry()
        let serviceID = UUID()
        let projectID = UUID()
        let leader = ownershipFingerprint(pid: 100, parentPID: 1, command: "/usr/bin/python3 supervisor.py")
        let child = ownershipFingerprint(pid: 101, parentPID: 100, command: "/usr/bin/python3 api.py")
        let runtime = ManagedRuntimeHandle(
            id: UUID(),
            managedServiceID: serviceID,
            leaderFingerprint: leader,
            processGroupID: 100,
            processPolicy: .controlledProcessGroup,
            launchedAt: leader.detectedAt
        )
        let snapshot = ProcessGroupSnapshot(
            runtimeID: runtime.id,
            managedServiceID: serviceID,
            processGroupID: 100,
            leaderFingerprint: leader,
            members: [
                .init(fingerprint: leader, processGroupID: 100, role: .leader, isInControlledGroup: true),
                .init(fingerprint: child, processGroupID: 100, role: .listenerOwner, isInControlledGroup: true)
            ]
        )
        let configuration = ManagedServiceConfiguration(
            id: serviceID,
            name: "Managed API",
            projectID: projectID,
            command: "/usr/bin/python3",
            workingDirectory: "/tmp"
        )
        await registry.register(runtime: runtime, configuration: configuration, snapshot: snapshot)
        let listener = ownershipListener(
            command: "/usr/bin/python3 api.py",
            executable: "/usr/bin/python3",
            pid: 101,
            parentPID: 100,
            fingerprint: child
        )
        let resolver = RuntimeOwnershipResolver(
            runtimeRegistry: registry,
            lineageProvider: FixedLineageProvider(nodes: ownershipLineage(listener: listener, ancestorNames: ["python3"])),
            groupOperator: FixedOwnershipGroupOperator(groupIDs: [101: 100]),
            clock: { Date(timeIntervalSince1970: 1_740_000_100) }
        )

        let graph = await resolver.resolve(listener: listener)

        XCTAssertEqual(graph.primaryConclusion.category, .applicationManagedProcess)
        XCTAssertEqual(graph.primaryConclusion.confidence, .verified)
        XCTAssertEqual(graph.primaryConclusion.value, "Managed API")
        XCTAssertEqual(graph.managedRuntimeID, runtime.id)
        XCTAssertEqual(graph.managedServiceID, serviceID)
        XCTAssertEqual(graph.projectID, projectID)
        XCTAssertEqual(graph.recommendation.controllerKind, .managedProcess)
        XCTAssertTrue(graph.primaryConclusion.evidence.contains { $0.field == "listener owner" && $0.isVerified })
    }

    func testResolverRoutesComposeAssociationAboveHostPID() async {
        let base = ownershipListener(command: "com.docker.backend", executable: "/Applications/Docker.app/backend")
        let process = ObservedProcess(
            fingerprint: base.process.fingerprint,
            name: base.process.name,
            commandLine: base.process.commandLine,
            owner: base.process.owner,
            currentDirectory: base.process.currentDirectory,
            parentName: base.process.parentName,
            runtime: .docker,
            project: nil,
            isSystemProcess: false,
            docker: .init(
                containerID: "abc123",
                containerName: "demo-api-1",
                image: "demo/api:latest",
                composeProject: "demo",
                composeService: "api",
                containerPort: 8080
            ),
            launchedByDevBerth: false,
            managedServiceID: nil
        )
        let listener = ObservedListener(
            protocolKind: base.protocolKind,
            address: base.address,
            port: base.port,
            process: process,
            firstDetectedAt: base.firstDetectedAt,
            lastDetectedAt: base.lastDetectedAt
        )
        let resolver = RuntimeOwnershipResolver(
            runtimeRegistry: ManagedRuntimeRegistry(),
            lineageProvider: FixedLineageProvider(nodes: ownershipLineage(listener: listener, ancestorNames: [])),
            groupOperator: FixedOwnershipGroupOperator(groupIDs: [process.fingerprint.pid: 88])
        )

        let graph = await resolver.resolve(listener: listener)

        XCTAssertEqual(graph.primaryConclusion.category, .dockerComposeService)
        XCTAssertEqual(graph.primaryConclusion.value, "demo/api")
        XCTAssertEqual(graph.primaryConclusion.detectionMethod, .composeMetadata)
        XCTAssertEqual(graph.recommendation.controllerKind, .dockerComposeService)
        XCTAssertEqual(graph.recommendation.supportedActions, [.inspect])
        XCTAssertTrue(graph.recommendation.reason.contains("host-side process"))
    }

    func testLineageProviderBoundsCyclesAndPreservesObservedRoot() async {
        let listener = ownershipListener(command: "node server.js", executable: "/usr/bin/node", pid: 10, parentPID: 20)
        let parent = ownershipFingerprint(pid: 20, parentPID: 30, command: "/bin/zsh")
        let grandparent = ownershipFingerprint(pid: 30, parentPID: 20, command: "/Applications/Terminal.app/Terminal")
        let provider = SystemProcessLineageProvider(
            inspector: OwnershipMappedInspector(values: [
                20: .init(fingerprint: parent, commandLine: "/bin/zsh", currentDirectory: "/tmp"),
                30: .init(fingerprint: grandparent, commandLine: "/Applications/Terminal.app/Terminal", currentDirectory: nil)
            ]),
            maximumDepth: 12
        )

        let nodes = await provider.lineage(for: listener.process)

        XCTAssertEqual(nodes.map { $0.fingerprint.pid }, [10, 20, 30])
        XCTAssertEqual(nodes[0].commandLine, "node server.js")
    }
}

private struct FixedLineageProvider: ProcessLineageProviding {
    let nodes: [ProcessLineageNode]
    func lineage(for process: ObservedProcess) async -> [ProcessLineageNode] { nodes }
}

private struct OwnershipMappedInspector: ProcessInspecting {
    let values: [Int32: ProcessInspection]
    func inspect(pid: Int32) async throws -> ProcessInspection? { values[pid] }
}

private struct FixedOwnershipGroupOperator: ProcessGroupOperating {
    let groupIDs: [Int32: Int32]
    func processGroupID(for pid: Int32) -> Int32? { groupIDs[pid] }
    func processGroupExists(_ processGroupID: Int32) -> Bool { true }
    func send(signal: Int32, toProcessGroup processGroupID: Int32) throws {}
    func send(signal: Int32, toProcess pid: Int32) throws {}
}

private func classification(
    _ listener: ObservedListener,
    ancestorNames: [String] = []
) -> OwnershipClassification {
    OwnershipRuleEngine.classify(
        listener: listener,
        lineage: ownershipLineage(listener: listener, ancestorNames: ancestorNames)
    )
}

private func ownershipLineage(
    listener: ObservedListener,
    ancestorNames: [String]
) -> [ProcessLineageNode] {
    var nodes = [ProcessLineageNode(
        fingerprint: listener.process.fingerprint,
        name: listener.process.name,
        commandLine: listener.process.commandLine,
        currentDirectory: listener.process.currentDirectory
    )]
    var childPID = listener.process.fingerprint.pid
    for (offset, name) in ancestorNames.enumerated() {
        let pid = Int32(900 + offset)
        let fingerprint = ownershipFingerprint(pid: pid, parentPID: childPID, command: name)
        nodes.append(.init(
            fingerprint: fingerprint,
            name: name,
            commandLine: "/Applications/\(name).app/Contents/MacOS/\(name)",
            currentDirectory: nil
        ))
        childPID = pid
    }
    return nodes
}

private func ownershipListener(
    command: String,
    executable: String,
    uid: UInt32 = 501,
    pid: Int32 = 42,
    parentPID: Int32 = 77,
    fingerprint: ProcessFingerprint? = nil
) -> ObservedListener {
    let resolvedFingerprint = fingerprint ?? ownershipFingerprint(
        pid: pid,
        uid: uid,
        parentPID: parentPID,
        command: command,
        executable: executable
    )
    let process = ObservedProcess(
        fingerprint: resolvedFingerprint,
        name: URL(fileURLWithPath: executable).lastPathComponent,
        commandLine: command,
        owner: uid == 0 ? "root" : "developer",
        currentDirectory: "/tmp/example",
        parentName: nil,
        runtime: .unknown,
        project: nil,
        isSystemProcess: false,
        docker: nil,
        launchedByDevBerth: false,
        managedServiceID: nil
    )
    return ObservedListener(
        protocolKind: .tcp,
        address: "127.0.0.1",
        port: 8080,
        process: process,
        firstDetectedAt: resolvedFingerprint.detectedAt,
        lastDetectedAt: resolvedFingerprint.detectedAt
    )
}

private func ownershipFingerprint(
    pid: Int32,
    uid: UInt32 = 501,
    parentPID: Int32,
    command: String,
    executable: String = "/usr/bin/python3"
) -> ProcessFingerprint {
    let detectedAt = Date(timeIntervalSince1970: 1_740_000_000)
    return ProcessFingerprint(
        pid: pid,
        uid: uid,
        executablePath: executable,
        executableFileIdentity: .init(deviceID: 1, inode: UInt64(pid)),
        startTime: detectedAt.addingTimeInterval(-10),
        commandLineDigest: ProcessFingerprint.digest(commandLine: command),
        parentPID: parentPID,
        detectedAt: detectedAt
    )
}
