import XCTest
@testable import DevBerth

final class DockerTests: XCTestCase {
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
}

