import XCTest
@testable import PortPilot

final class ProjectInfererTests: XCTestCase {
    func testInfersNearestProjectRootWithoutRecursiveScan() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let nested = root.appendingPathComponent("Sources/Feature")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{\"name\":\"fixture-project\"}".utf8).write(to: root.appendingPathComponent("package.json"))
        let inferred = ProjectInferer().infer(from: nested.path)
        XCTAssertEqual(inferred?.rootPath, root.path)
        XCTAssertEqual(inferred?.name, "fixture-project")
        XCTAssertEqual(inferred?.evidence, "package.json")
    }
}

