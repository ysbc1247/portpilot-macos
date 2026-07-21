import XCTest
@testable import DevBerth

final class LsofFieldParserTests: XCTestCase {
    func testParsesTCPIPv4IPv6AndMultiplePortsPerPID() throws {
        let listeners = LsofFieldParser.parse(try fixtureData("lsof_tcp.fields"), defaultProtocol: .tcp)
        XCTAssertEqual(listeners.count, 3)
        XCTAssertEqual(listeners.filter { $0.pid == 411 }.map(\.port), [5173, 5174])
        XCTAssertEqual(listeners[0].address, "127.0.0.1")
        XCTAssertEqual(listeners[1].address, "::1")
        XCTAssertEqual(listeners[2].address, "*")
        XCTAssertTrue(listeners.allSatisfy { $0.protocolKind == .tcp })
    }

    func testParsesUDPAndWildcardAddresses() throws {
        let listeners = LsofFieldParser.parse(try fixtureData("lsof_udp.fields"), defaultProtocol: .udp)
        XCTAssertEqual(listeners.map(\.port), [5353, 45678])
        XCTAssertEqual(listeners.map(\.protocolKind), [.udp, .udp])
        XCTAssertEqual(listeners.map(\.address), ["*", "::1"])
    }

    func testSkipsMalformedAndNonListeningRecords() {
        let fields = ["p12", "cbad", "f3", "PTCP", "nnot-an-endpoint", "TST=CLOSED"]
        let data = Data(fields.joined(separator: "\0").utf8) + Data([0])
        XCTAssertTrue(LsofFieldParser.parse(data, defaultProtocol: .tcp).isEmpty)
    }

    func testEndpointParserHandlesConnectionSuffix() {
        let value = LsofFieldParser.parseEndpoint("[::1]:8080-> [::1]:51234")
        XCTAssertEqual(value?.address, "::1")
        XCTAssertEqual(value?.port, 8080)
    }
}

