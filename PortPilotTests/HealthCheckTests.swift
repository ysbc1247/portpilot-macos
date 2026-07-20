import Foundation
import XCTest
@testable import PortPilot

final class HealthCheckTests: XCTestCase {
    func testHealthCheckAcceptsExpectedStatus() async throws {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 204, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let checker = HTTPHealthChecker(session: URLSession(configuration: configuration))
        try await checker.waitUntilHealthy(
            configuration: .init(url: URL(string: "https://portpilot.invalid/health")!, expectedStatus: 204, intervalSeconds: 0.01),
            timeoutSeconds: 0.5
        )
    }

    func testHealthCheckTimesOutOnWrongStatus() async {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let checker = HTTPHealthChecker(session: URLSession(configuration: configuration))
        do {
            try await checker.waitUntilHealthy(
                configuration: .init(url: URL(string: "https://portpilot.invalid/health")!, expectedStatus: 200, intervalSeconds: 0.01),
                timeoutSeconds: 0.05
            )
            XCTFail("Expected timeout")
        } catch let error as PortPilotError {
            guard case .healthCheckTimedOut = error else { return XCTFail("Unexpected error: \(error)") }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

