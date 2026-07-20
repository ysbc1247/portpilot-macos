import XCTest
@testable import PortPilot

final class LaunchProfileTests: XCTestCase {
    func testValidationFindsMissingValuesAndDuplicatePorts() {
        let port = ExpectedPortConfiguration(id: UUID(), port: 3000, protocolKind: .tcp, required: true)
        let profile = LaunchProfileConfiguration(
            name: "",
            command: "",
            workingDirectory: "/definitely/missing",
            expectedPorts: [port, .init(id: UUID(), port: 3000, protocolKind: .tcp, required: true)],
            startupTimeoutSeconds: 0
        )
        let fields = Set(LaunchProfileValidator.validate(profile).map(\.field))
        XCTAssertTrue(fields.isSuperset(of: ["name", "command", "workingDirectory", "startupTimeout", "expectedPorts"]))
    }

    func testDependencyPlannerOrdersParallelLayers() throws {
        let database = LaunchProfileConfiguration(name: "Database", command: "redis-server", workingDirectory: "/tmp")
        let api = LaunchProfileConfiguration(name: "API", command: "api", workingDirectory: "/tmp", dependencyProfileIDs: [database.id])
        let web = LaunchProfileConfiguration(name: "Web", command: "web", workingDirectory: "/tmp", dependencyProfileIDs: [api.id])
        let worker = LaunchProfileConfiguration(name: "Worker", command: "worker", workingDirectory: "/tmp", dependencyProfileIDs: [database.id])
        let layers = try DependencyPlanner.orderedLayers(for: [web, worker, api, database])
        XCTAssertEqual(layers.map { Set($0.map(\.name)) }, [Set(["Database"]), Set(["API", "Worker"]), Set(["Web"])])
    }

    func testDependencyPlannerRejectsCycle() {
        let firstID = UUID()
        let secondID = UUID()
        let first = LaunchProfileConfiguration(id: firstID, name: "First", command: "a", workingDirectory: "/tmp", dependencyProfileIDs: [secondID])
        let second = LaunchProfileConfiguration(id: secondID, name: "Second", command: "b", workingDirectory: "/tmp", dependencyProfileIDs: [firstID])
        XCTAssertThrowsError(try DependencyPlanner.orderedLayers(for: [first, second])) { error in
            guard case DependencyGraphError.cycle = error else { return XCTFail("Expected cycle error") }
        }
    }

    func testPortConflictDetectionDoesNotResolveAutomatically() {
        let expected = ExpectedPortConfiguration(id: UUID(), port: 3000, protocolKind: .tcp, required: true)
        let profile = LaunchProfileConfiguration(name: "Web", command: "npm", workingDirectory: "/tmp", expectedPorts: [expected])
        let conflicts = PortConflictDetector.conflicts(for: profile, listeners: [makeListener(port: 3000)])
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts[0].listener.process.identity.pid, 42)
    }
}

