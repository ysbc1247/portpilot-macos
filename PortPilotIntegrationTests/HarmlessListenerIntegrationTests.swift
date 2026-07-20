import Foundation
import XCTest
@testable import PortPilot

final class HarmlessListenerIntegrationTests: XCTestCase {
    func testDiscoversFixtureOnTemporaryHighPort() async throws {
        let server = try startFixture()
        defer { stopFixture(server) }
        let readiness = server.standardOutput as? Pipe
        _ = readiness?.fileHandleForReading.availableData

        let discovery = LocalPortDiscovery(runner: FoundationCommandRunner())
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

    private func startFixture() throws -> Process {
        let port = Int.random(in: 49_152...60_000)
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/http_fixture.py")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, "--port", String(port)]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        return process
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

