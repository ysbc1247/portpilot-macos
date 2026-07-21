import XCTest
@testable import DevBerth

final class ServiceCheckRunnerTests: XCTestCase {
    func testEveryReviewedCheckKindUsesStructuredInputsAndPasses() async throws {
        let commandRunner = MockCommandRunner { executable, arguments in
            XCTAssertEqual(executable.path, "/usr/bin/true")
            XCTAssertEqual(arguments, ["--mode", "health"])
            return CommandResult(stdout: Data(), stderr: Data(), exitCode: 0)
        }
        let dependencyID = UUID()
        let runner = ServiceCheckRunner(
            discoverer: ServiceCheckDiscovery(listeners: [makeListener(port: 49_901)]),
            http: FixedHTTPProbe(response: .init(statusCode: 204, body: "ready=true")),
            commandRunner: commandRunner,
            docker: FixedDockerHealth(status: "healthy"),
            dependencies: FixedDependencyReadiness(readyIDs: [dependencyID])
        )
        let checks = [
            ServiceCheckConfiguration(
                kind: .tcpListener(host: "127.0.0.1", port: 49_901),
                retryLimit: 1,
                failureMessage: "TCP listener missing."
            ),
            ServiceCheckConfiguration(
                kind: .http(
                    url: try XCTUnwrap(URL(string: "http://127.0.0.1:49901/ready")),
                    expectedStatus: 204,
                    responseContains: "ready=true"
                ),
                retryLimit: 1,
                failureMessage: "HTTP readiness failed."
            ),
            ServiceCheckConfiguration(
                kind: .executable(
                    path: "/usr/bin/true",
                    arguments: ["--mode", "health"],
                    workingDirectory: "/tmp"
                ),
                retryLimit: 1,
                failureMessage: "Command failed."
            ),
            ServiceCheckConfiguration(
                kind: .fileExists(path: "/tmp"),
                retryLimit: 1,
                failureMessage: "File missing."
            ),
            ServiceCheckConfiguration(
                kind: .dockerHealth(containerID: "api-1"),
                retryLimit: 1,
                failureMessage: "Container unhealthy."
            ),
            ServiceCheckConfiguration(
                kind: .dependencyReady(managedServiceID: dependencyID),
                retryLimit: 1,
                failureMessage: "Dependency unavailable."
            )
        ]

        let results = try await runner.run(checks)

        XCTAssertEqual(results.count, checks.count)
        XCTAssertTrue(results.allSatisfy(\.succeeded))
        XCTAssertEqual(commandRunner.invocations.count, 1)
    }

    func testRetryIntervalAllowsListenerToBecomeReady() async throws {
        let discovery = SequencedServiceCheckDiscovery(snapshots: [[], [makeListener(port: 49_902)]])
        let runner = makeRunner(discoverer: discovery)
        let check = ServiceCheckConfiguration(
            kind: .tcpListener(host: "127.0.0.1", port: 49_902),
            timeoutSeconds: 1,
            intervalSeconds: 0.01,
            retryLimit: 3,
            failureMessage: "Listener did not open."
        )

        let results = try await runner.run([check])
        let result = try XCTUnwrap(results.first)

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.attempts, 2)
    }

    func testFailedHTTPCheckReportsOnlyReviewedFailureMessage() async throws {
        let privateResponse = "token=private-value-that-must-not-escape"
        let runner = ServiceCheckRunner(
            discoverer: ServiceCheckDiscovery(listeners: []),
            http: FixedHTTPProbe(response: .init(statusCode: 503, body: privateResponse)),
            commandRunner: MockCommandRunner { _, _ in
                CommandResult(stdout: Data(), stderr: Data(), exitCode: 0)
            },
            docker: FixedDockerHealth(status: "unhealthy"),
            dependencies: FixedDependencyReadiness(readyIDs: [])
        )
        let check = ServiceCheckConfiguration(
            kind: .http(
                url: try XCTUnwrap(URL(string: "http://127.0.0.1:49903/health")),
                expectedStatus: 200,
                responseContains: "ready"
            ),
            timeoutSeconds: 1,
            retryLimit: 1,
            failureMessage: "The reviewed HTTP readiness criteria did not pass."
        )

        do {
            _ = try await runner.run([check])
            XCTFail("Expected the check to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(check.failureMessage))
            XCTAssertFalse(error.localizedDescription.contains(privateResponse))
            XCTAssertFalse(error.localizedDescription.contains("private-value"))
        }
    }

    private func makeRunner(discoverer: any PortDiscovering) -> ServiceCheckRunner {
        ServiceCheckRunner(
            discoverer: discoverer,
            http: FixedHTTPProbe(response: .init(statusCode: 200, body: "ready")),
            commandRunner: MockCommandRunner { _, _ in
                CommandResult(stdout: Data(), stderr: Data(), exitCode: 0)
            },
            docker: FixedDockerHealth(status: "healthy"),
            dependencies: FixedDependencyReadiness(readyIDs: [])
        )
    }
}

private struct ServiceCheckDiscovery: PortDiscovering {
    let listeners: [ObservedListener]
    func discover() async throws -> [ObservedListener] { listeners }
}

private actor SequencedServiceCheckDiscovery: PortDiscovering {
    private var snapshots: [[ObservedListener]]

    init(snapshots: [[ObservedListener]]) {
        self.snapshots = snapshots
    }

    func discover() async throws -> [ObservedListener] {
        guard snapshots.count > 1 else { return snapshots.first ?? [] }
        return snapshots.removeFirst()
    }
}

private actor FixedHTTPProbe: HTTPProbing {
    let response: HTTPProbeResponse
    init(response: HTTPProbeResponse) { self.response = response }
    func probe(url: URL, timeoutSeconds: Double) async throws -> HTTPProbeResponse { response }
}

private actor FixedDockerHealth: DockerHealthInspecting {
    let status: String
    init(status: String) { self.status = status }
    func healthStatus(containerID: String) async throws -> String { status }
}

private actor FixedDependencyReadiness: DependencyReadinessProviding {
    let readyIDs: Set<UUID>
    init(readyIDs: Set<UUID>) { self.readyIDs = readyIDs }
    func isReady(managedServiceID: UUID) async -> Bool { readyIDs.contains(managedServiceID) }
}
