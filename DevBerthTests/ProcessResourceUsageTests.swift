import XCTest
@testable import DevBerth

final class ProcessResourceUsageTests: XCTestCase {
    func testParserReturnsCPUAndResidentMemoryForValidRows() throws {
        let capturedAt = Date(timeIntervalSince1970: 123)
        let values = SystemProcessResourceUsageReader.parse(
            "  42  12.5  2048\n  99   0.0   512\n",
            capturedAt: capturedAt
        )

        XCTAssertEqual(values[42]?.cpuPercent, 12.5)
        XCTAssertEqual(values[42]?.residentMemoryBytes, 2_097_152)
        XCTAssertEqual(values[42]?.capturedAt, capturedAt)
        XCTAssertEqual(values[99]?.residentMemoryBytes, 524_288)
    }

    func testParserSkipsMalformedNegativeAndOverflowRows() {
        let values = SystemProcessResourceUsageReader.parse(
            "bad row\n-1 1.0 25\n42 nope 200\n99 1.0 18446744073709551615",
            capturedAt: Date()
        )

        XCTAssertTrue(values.isEmpty)
    }

    func testReaderBatchesAReadOnlyPSInvocation() async throws {
        let runner = MockCommandRunner { executable, arguments in
            XCTAssertEqual(executable.path, "/bin/ps")
            XCTAssertEqual(arguments, ["-p", "42,99", "-o", "pid=", "-o", "%cpu=", "-o", "rss="])
            return CommandResult(stdout: Data("42 2.5 1024\n99 0.1 2048\n".utf8), stderr: Data(), exitCode: 0)
        }
        let reader = SystemProcessResourceUsageReader(
            runner: runner,
            clock: { Date(timeIntervalSince1970: 500) }
        )

        let values = try await reader.read(pids: [99, 42])

        XCTAssertEqual(values.keys.sorted(), [42, 99])
        XCTAssertEqual(runner.invocations.count, 1)
    }
}
