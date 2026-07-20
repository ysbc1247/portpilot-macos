import XCTest
@testable import PortPilot

final class ProcessSafetyTests: XCTestCase {
    func testIdentityParserAndVerifierMatchExecutableAndStartTime() async throws {
        let output = "Mon Jan 15 12:34:56 2024 /opt/homebrew/bin/node\n"
        let start = try XCTUnwrap(ProcessIdentityVerifier.parse(output)?.startTime)
        let runner = MockCommandRunner { _, _ in
            CommandResult(stdout: Data(output.utf8), stderr: Data(), exitCode: 0)
        }
        let verifier = ProcessIdentityVerifier(runner: runner)
        let matches = try await verifier.verify(.init(pid: 42, executablePath: "/opt/homebrew/bin/node", startTime: start))
        let mismatches = try await verifier.verify(.init(pid: 42, executablePath: "/opt/homebrew/bin/python", startTime: start))
        XCTAssertTrue(matches)
        XCTAssertFalse(mismatches)
    }

    func testWeakIdentityIsNeverAccepted() async throws {
        let runner = MockCommandRunner { _, _ in XCTFail("Weak identity should not run ps"); return .init(stdout: Data(), stderr: Data(), exitCode: 0) }
        let verifier = ProcessIdentityVerifier(runner: runner)
        let matches = try await verifier.verify(.init(pid: 42, executablePath: nil, startTime: nil))
        XCTAssertFalse(matches)
    }

    func testSafetyPolicyProtectsRootAndSystemProcesses() {
        XCTAssertNotNil(ProcessSafetyPolicy.terminationBlockReason(for: makeProcess(owner: "root")))
        XCTAssertNotNil(ProcessSafetyPolicy.terminationBlockReason(for: makeProcess(system: true)))
        XCTAssertNil(ProcessSafetyPolicy.terminationBlockReason(for: makeProcess()))
    }

    func testTerminationStateMachineGracefulTimeoutAndExit() {
        let deadline = Date().addingTimeInterval(1)
        var state = TerminationStateMachine.reduce(state: .idle, event: .begin)
        state = TerminationStateMachine.reduce(state: state, event: .identityValidated)
        state = TerminationStateMachine.reduce(state: state, event: .signalSent(signal: 15, deadline: deadline))
        XCTAssertEqual(TerminationStateMachine.reduce(state: state, event: .processExited), .exited)
        XCTAssertEqual(TerminationStateMachine.reduce(state: state, event: .deadlineReached), .timedOut)
    }

    func testForceStopWithoutConfirmationIsRejected() async {
        let runner = MockCommandRunner { _, _ in .init(stdout: Data(), stderr: Data(), exitCode: 0) }
        let controller = SafeProcessController(runner: runner, verifier: AlwaysValidVerifier())
        do {
            _ = try await controller.terminate(makeProcess(), mode: .force(confirmed: false))
            XCTFail("Expected confirmation error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("confirmation"))
        }
    }
}

private struct AlwaysValidVerifier: ProcessIdentityVerifying {
    func verify(_ expected: ProcessIdentity) async throws -> Bool { true }
}
