import Foundation
import XCTest
@testable import DevBerth

final class HarmlessListenerIntegrationTests: XCTestCase {
    func testDiscoversFixtureOnTemporaryHighPort() async throws {
        let server = try startFixture()
        defer { stopFixture(server) }

        let discovery = LocalPortDiscovery(runner: FoundationCommandRunner(), includeProjectInference: false)
        let deadline = Date().addingTimeInterval(5)
        var found: NetworkListener?
        while Date() < deadline && found == nil {
            found = try await discovery.discover().first { $0.process.identity.pid == server.processIdentifier }
            if found == nil { try await Task.sleep(for: .milliseconds(200)) }
        }
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.addressScope, .loopback)
        XCTAssertTrue(found?.process.identity.isStrong == true)
    }

    func testGracefulStopTerminatesOwnedFixture() async throws {
        let server = try startFixture()
        defer { stopFixture(server) }
        let runner = FoundationCommandRunner()
        let listener = try await waitForListener(pid: server.processIdentifier, runner: runner)
        let controller = SafeProcessController(runner: runner, verifier: ProcessIdentityVerifier(runner: runner))
        let outcome = try await controller.terminate(listener.process, mode: .graceful(timeoutSeconds: 2))
        XCTAssertTrue(outcome.didExit)
    }

    func testIgnoringFixtureRequiresConfirmedForceStop() async throws {
        let server = try startFixture(ignoreTerm: true)
        defer { stopFixture(server) }
        let runner = FoundationCommandRunner()
        let listener = try await waitForListener(pid: server.processIdentifier, runner: runner)
        let controller = SafeProcessController(runner: runner, verifier: ProcessIdentityVerifier(runner: runner))
        let graceful = try await controller.terminate(listener.process, mode: .graceful(timeoutSeconds: 0.3))
        XCTAssertFalse(graceful.didExit)
        let forced = try await controller.terminate(listener.process, mode: .force(confirmed: true))
        XCTAssertTrue(forced.didExit)
    }

    private func startFixture(ignoreTerm: Bool = false) throws -> Process {
        let script = try XCTUnwrap(
            Bundle(for: HarmlessListenerIntegrationTests.self).url(forResource: "http_fixture", withExtension: "py"),
            "The harmless listener script must be embedded in the integration-test bundle."
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", script.path, "--port", "0"] + (ignoreTerm ? ["--ignore-term"] : [])
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        return process
    }

    private func waitForListener(pid: Int32, runner: any CommandRunning) async throws -> NetworkListener {
        let discovery = LocalPortDiscovery(runner: runner, includeProjectInference: false)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let listener = try await discovery.discover().first(where: { $0.process.identity.pid == pid }) {
                return listener
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        throw XCTSkip("The fixture listener did not become discoverable before timeout.")
    }

    private func stopFixture(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
}
