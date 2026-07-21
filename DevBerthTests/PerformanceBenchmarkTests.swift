import XCTest
@testable import DevBerth

final class PerformanceBenchmarkTests: XCTestCase {
    func testRuntimeSemanticDiffBenchmark() {
        let previous = (0..<500).map { makeListener(port: UInt16(40_000 + $0), pid: Int32(10_000 + $0)) }
        let current = previous.map { listener in
            var value = listener
            value.lastDetectedAt = Date()
            return value
        }
        let options = XCTMeasureOptions()
        options.iterationCount = 5

        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()], options: options) {
            for _ in 0..<100 {
                let diff = RuntimeDiffer.diff(previous: previous, current: current)
                XCTAssertEqual(diff, .empty)
            }
        }
    }

    func testTaggedListenerParserBenchmark() throws {
        let tcp = try fixtureData("lsof_tcp.fields")
        let options = XCTMeasureOptions()
        options.iterationCount = 5

        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()], options: options) {
            for _ in 0..<1_000 {
                XCTAssertEqual(LsofFieldParser.parse(tcp, defaultProtocol: .tcp).count, 3)
            }
        }
    }
}
