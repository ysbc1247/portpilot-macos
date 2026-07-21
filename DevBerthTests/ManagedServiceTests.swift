import XCTest
@testable import DevBerth

final class ManagedServiceTests: XCTestCase {
    func testValidationFindsMissingValuesAndDuplicatePorts() {
        let port = ExpectedListenerConfiguration(id: UUID(), port: 3000, protocolKind: .tcp, required: true)
        let service = ManagedServiceConfiguration(
            name: "",
            command: "",
            workingDirectory: "/definitely/missing",
            expectedPorts: [port, .init(id: UUID(), port: 3000, protocolKind: .tcp, required: true)],
            startupTimeoutSeconds: 0
        )
        let fields = Set(ManagedServiceValidator.validate(service).map(\.field))
        XCTAssertTrue(fields.isSuperset(of: ["name", "command", "workingDirectory", "startupTimeout", "expectedPorts"]))
    }

    func testDependencyPlannerOrdersParallelLayers() throws {
        let database = ManagedServiceConfiguration(name: "Database", command: "redis-server", workingDirectory: "/tmp")
        let api = ManagedServiceConfiguration(name: "API", command: "api", workingDirectory: "/tmp", dependencyServiceIDs: [database.id])
        let web = ManagedServiceConfiguration(name: "Web", command: "web", workingDirectory: "/tmp", dependencyServiceIDs: [api.id])
        let worker = ManagedServiceConfiguration(name: "Worker", command: "worker", workingDirectory: "/tmp", dependencyServiceIDs: [database.id])
        let layers = try DependencyPlanner.orderedLayers(for: [web, worker, api, database])
        XCTAssertEqual(layers.map { Set($0.map(\.name)) }, [Set(["Database"]), Set(["API", "Worker"]), Set(["Web"])])
    }

    func testDependencyPlannerRejectsCycle() {
        let firstID = UUID()
        let secondID = UUID()
        let first = ManagedServiceConfiguration(id: firstID, name: "First", command: "a", workingDirectory: "/tmp", dependencyServiceIDs: [secondID])
        let second = ManagedServiceConfiguration(id: secondID, name: "Second", command: "b", workingDirectory: "/tmp", dependencyServiceIDs: [firstID])
        XCTAssertThrowsError(try DependencyPlanner.orderedLayers(for: [first, second])) { error in
            guard case DependencyGraphError.cycle = error else { return XCTFail("Expected cycle error") }
        }
    }

    func testPortConflictDetectionDoesNotResolveAutomatically() {
        let expected = ExpectedListenerConfiguration(id: UUID(), port: 3000, protocolKind: .tcp, required: true)
        let service = ManagedServiceConfiguration(name: "Web", command: "npm", workingDirectory: "/tmp", expectedPorts: [expected])
        let conflicts = PortConflictDetector.conflicts(for: service, listeners: [makeListener(port: 3000)])
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts[0].listener.process.identity.pid, 42)
    }
}
