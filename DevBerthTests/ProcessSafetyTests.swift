import XCTest
@testable import DevBerth

final class ProcessSafetyTests: XCTestCase {
    func testSystemInspectorParsesCompletePSRecordAndPathsContainingSpaces() throws {
        let parsed = try XCTUnwrap(SystemProcessInspector.parsePS(
            "1 501 Mon Jan 15 12:34:56 2024 /Applications/Example Helper.app/Contents/MacOS/Example Helper --serve\n"
        ))
        XCTAssertEqual(parsed.parentPID, 1)
        XCTAssertEqual(parsed.uid, 501)
        XCTAssertEqual(
            parsed.commandLine,
            "/Applications/Example Helper.app/Contents/MacOS/Example Helper --serve"
        )

        let paths = SystemProcessInspector.parsePaths(
            "p42\nfcwd\nn/Users/developer/Example Project\nftxt\nn/Applications/Example Helper.app/Contents/MacOS/Example Helper\n"
        )
        XCTAssertEqual(paths.currentDirectory, "/Users/developer/Example Project")
        XCTAssertEqual(paths.executable, "/Applications/Example Helper.app/Contents/MacOS/Example Helper")
    }

    func testVerifierAcceptsACompleteMatchingFingerprint() async throws {
        let expected = makeFingerprint()
        let verifier = ProcessFingerprintVerifier(inspector: FixedProcessInspector(inspection: inspection(for: expected)))

        let result = try await verifier.verify(expected)
        XCTAssertEqual(result, .matched(actual: expected))
    }

    func testVerifierRejectsEverySafetyRelevantFingerprintDifference() async throws {
        let expected = makeFingerprint()
        let changed = ProcessFingerprint(
            pid: expected.pid,
            uid: 502,
            executablePath: "/opt/homebrew/bin/python3",
            executableFileIdentity: .init(deviceID: 2, inode: 99),
            startTime: expected.startTime?.addingTimeInterval(2),
            commandLineDigest: ProcessFingerprint.digest(commandLine: "python3 replacement.py"),
            parentPID: 999,
            detectedAt: expected.detectedAt.addingTimeInterval(1)
        )
        let verifier = ProcessFingerprintVerifier(inspector: FixedProcessInspector(inspection: inspection(for: changed)))

        let result = try await verifier.verify(expected)
        guard case let .mismatched(actual, differences) = result else {
            return XCTFail("Expected the reused PID to be rejected, got \(result)")
        }
        XCTAssertEqual(actual, changed)
        XCTAssertEqual(
            Set(differences),
            Set([
                .uid,
                .executablePath,
                .executableFileIdentity,
                .startTime,
                .commandLineDigest,
                .parentPID
            ])
        )
    }

    func testVerifierRejectsFingerprintMissingRequiredEvidenceWithoutInspectingPID() async throws {
        let inspector = CountingProcessInspector(inspection: nil)
        let verifier = ProcessFingerprintVerifier(inspector: inspector)
        let result = try await verifier.verify(
            .init(pid: 42, executablePath: nil, startTime: nil)
        )

        guard case let .insufficientExpectedFingerprint(missing) = result else {
            return XCTFail("Expected an insufficient fingerprint result, got \(result)")
        }
        XCTAssertEqual(Set(missing), Set([.uid, .executablePath, .startTime, .commandLineDigest, .parentPID]))
        let inspectionCalls = await inspector.calls()
        XCTAssertEqual(inspectionCalls, 0)
    }

    func testVerifierReportsProcessExit() async throws {
        let verifier = ProcessFingerprintVerifier(inspector: FixedProcessInspector(inspection: nil))
        let result = try await verifier.verify(makeFingerprint())
        XCTAssertEqual(result, .notFound)
    }

    func testControllerAbortsWhenFingerprintChangedBeforeSignal() async throws {
        let expected = makeFingerprint()
        let changed = ProcessFingerprint(
            pid: expected.pid,
            uid: expected.uid,
            executablePath: expected.executablePath,
            executableFileIdentity: expected.executableFileIdentity,
            startTime: expected.startTime,
            commandLineDigest: ProcessFingerprint.digest(commandLine: "node replacement.js"),
            parentPID: expected.parentPID,
            detectedAt: expected.detectedAt
        )
        let runner = successfulRunner()
        let verifier = SequencedFingerprintVerifier(results: [
            .mismatched(actual: changed, differences: [.commandLineDigest])
        ])
        let controller = SafeProcessController(
            runner: runner,
            verifier: verifier,
            listenerOwnershipVerifier: FixedListenerOwnershipVerifier(ownedPorts: [3000])
        )

        await XCTAssertThrowsErrorAsync(
            try await controller.terminate(makeTarget(fingerprint: expected), mode: .graceful(timeoutSeconds: 1))
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("command-line digest"))
        }
        XCTAssertFalse(runner.invocations.contains { $0.executable == "/bin/kill" })
    }

    func testControllerAbortsWhenListenerOwnershipChangedBeforeSignal() async throws {
        let fingerprint = makeFingerprint()
        let runner = successfulRunner()
        let controller = SafeProcessController(
            runner: runner,
            verifier: SequencedFingerprintVerifier(results: [.matched(actual: fingerprint)]),
            listenerOwnershipVerifier: FixedListenerOwnershipVerifier(ownedPorts: [])
        )

        await XCTAssertThrowsErrorAsync(
            try await controller.terminate(makeTarget(fingerprint: fingerprint), mode: .graceful(timeoutSeconds: 1))
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("3000"))
        }
        XCTAssertFalse(runner.invocations.contains { $0.executable == "/bin/kill" })
    }

    func testControllerTreatsProcessExitAfterSignalAsSuccess() async throws {
        let fingerprint = makeFingerprint()
        let runner = successfulRunner()
        let controller = SafeProcessController(
            runner: runner,
            verifier: SequencedFingerprintVerifier(results: [.matched(actual: fingerprint), .notFound]),
            listenerOwnershipVerifier: FixedListenerOwnershipVerifier(ownedPorts: [3000])
        )

        let outcome = try await controller.terminate(
            makeTarget(fingerprint: fingerprint),
            mode: .graceful(timeoutSeconds: 1)
        )

        XCTAssertEqual(outcome.completion, .exited)
        XCTAssertEqual(runner.invocations.filter { $0.executable == "/bin/kill" }.count, 1)
    }

    func testControllerDoesNotSignalReusedPIDAfterOriginalTargetExits() async throws {
        let fingerprint = makeFingerprint()
        let replacement = makeFingerprint(commandLine: "node replacement.js", detectedAt: fingerprint.detectedAt.addingTimeInterval(1))
        let runner = successfulRunner()
        let controller = SafeProcessController(
            runner: runner,
            verifier: SequencedFingerprintVerifier(results: [
                .matched(actual: fingerprint),
                .mismatched(actual: replacement, differences: [.commandLineDigest])
            ]),
            listenerOwnershipVerifier: FixedListenerOwnershipVerifier(ownedPorts: [3000])
        )

        let outcome = try await controller.terminate(
            makeTarget(fingerprint: fingerprint),
            mode: .graceful(timeoutSeconds: 1)
        )

        XCTAssertEqual(outcome.completion, .fingerprintChangedAfterSignal)
        XCTAssertEqual(runner.invocations.filter { $0.executable == "/bin/kill" }.count, 1)
    }

    func testForceStopRequiresConfirmationBeforeSendingSignal() async throws {
        let fingerprint = makeFingerprint()
        let runner = successfulRunner()
        let controller = SafeProcessController(
            runner: runner,
            verifier: SequencedFingerprintVerifier(results: [.matched(actual: fingerprint)]),
            listenerOwnershipVerifier: FixedListenerOwnershipVerifier(ownedPorts: [3000])
        )

        await XCTAssertThrowsErrorAsync(
            try await controller.terminate(makeTarget(fingerprint: fingerprint), mode: .force(confirmed: false))
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("confirmation"))
        }
        XCTAssertFalse(runner.invocations.contains { $0.executable == "/bin/kill" })
    }

    func testForceEscalationPerformsFreshFingerprintAndListenerValidation() async throws {
        let fingerprint = makeFingerprint()
        let runner = successfulRunner()
        let verifier = SequencedFingerprintVerifier(results: [
            .matched(actual: fingerprint),
            .matched(actual: fingerprint),
            .matched(actual: fingerprint),
            .matched(actual: fingerprint),
            .notFound
        ])
        let listenerVerifier = FixedListenerOwnershipVerifier(ownedPorts: [3000])
        let controller = SafeProcessController(
            runner: runner,
            verifier: verifier,
            listenerOwnershipVerifier: listenerVerifier
        )
        let target = makeTarget(fingerprint: fingerprint)

        let graceful = try await controller.terminate(target, mode: .graceful(timeoutSeconds: 0.2))
        let forced = try await controller.terminate(target, mode: .force(confirmed: true))

        XCTAssertEqual(graceful.completion, .timedOut)
        XCTAssertEqual(forced.completion, .exited)
        let fingerprintValidationCalls = await verifier.calls()
        let listenerValidationCalls = await listenerVerifier.calls()
        XCTAssertGreaterThanOrEqual(fingerprintValidationCalls, 5)
        XCTAssertEqual(listenerValidationCalls, 2)
        let killCalls = runner.invocations.filter { $0.executable == "/bin/kill" }
        XCTAssertEqual(killCalls.map(\.arguments), [["-TERM", "42"], ["-KILL", "42"]])
    }

    func testListenerExpectationDistinguishesMultipleListenersOwnedBySameProcess() async throws {
        let fingerprint = makeFingerprint()
        let acceptedRunner = successfulRunner()
        let acceptedController = SafeProcessController(
            runner: acceptedRunner,
            verifier: SequencedFingerprintVerifier(results: [.matched(actual: fingerprint), .notFound]),
            listenerOwnershipVerifier: FixedListenerOwnershipVerifier(ownedPorts: [3000])
        )
        _ = try await acceptedController.terminate(
            makeTarget(fingerprint: fingerprint, port: 3000),
            mode: .graceful(timeoutSeconds: 1)
        )

        let rejectedRunner = successfulRunner()
        let rejectedController = SafeProcessController(
            runner: rejectedRunner,
            verifier: SequencedFingerprintVerifier(results: [.matched(actual: fingerprint)]),
            listenerOwnershipVerifier: FixedListenerOwnershipVerifier(ownedPorts: [3000])
        )
        await XCTAssertThrowsErrorAsync(
            try await rejectedController.terminate(
                makeTarget(fingerprint: fingerprint, port: 4000),
                mode: .graceful(timeoutSeconds: 1)
            )
        )
        XCTAssertFalse(rejectedRunner.invocations.contains { $0.executable == "/bin/kill" })
    }

    func testSafetyPolicyProtectsRootAndSystemProcesses() {
        XCTAssertNotNil(ProcessSafetyPolicy.terminationBlockReason(for: makeProcess(owner: "root")))
        XCTAssertNotNil(ProcessSafetyPolicy.terminationBlockReason(for: makeProcess(system: true)))
        XCTAssertNil(ProcessSafetyPolicy.terminationBlockReason(for: makeProcess()))
    }

    func testTerminationStateMachineGracefulTimeoutAndExit() {
        let deadline = Date().addingTimeInterval(1)
        var state = TerminationStateMachine.reduce(state: .idle, event: .begin)
        state = TerminationStateMachine.reduce(state: state, event: .fingerprintValidated)
        state = TerminationStateMachine.reduce(state: state, event: .signalSent(signal: 15, deadline: deadline))
        XCTAssertEqual(TerminationStateMachine.reduce(state: state, event: .processExited), .exited)
        XCTAssertEqual(TerminationStateMachine.reduce(state: state, event: .deadlineReached), .timedOut)
    }
}

private struct FixedProcessInspector: ProcessInspecting {
    let inspection: ProcessInspection?

    func inspect(pid: Int32) async throws -> ProcessInspection? { inspection }
}

private actor CountingProcessInspector: ProcessInspecting {
    private let inspection: ProcessInspection?
    private var callCount = 0

    init(inspection: ProcessInspection?) {
        self.inspection = inspection
    }

    func inspect(pid: Int32) async throws -> ProcessInspection? {
        callCount += 1
        return inspection
    }

    func calls() -> Int { callCount }
}

private actor SequencedFingerprintVerifier: ProcessFingerprintVerifying {
    private let results: [ProcessFingerprintVerification]
    private var callCount = 0

    init(results: [ProcessFingerprintVerification]) {
        precondition(!results.isEmpty)
        self.results = results
    }

    func verify(_ expected: ProcessFingerprint) async throws -> ProcessFingerprintVerification {
        defer { callCount += 1 }
        return results[min(callCount, results.count - 1)]
    }

    func calls() -> Int { callCount }
}

private actor FixedListenerOwnershipVerifier: ListenerOwnershipVerifying {
    private let ownedPorts: Set<UInt16>
    private var callCount = 0

    init(ownedPorts: Set<UInt16>) {
        self.ownedPorts = ownedPorts
    }

    func verify(
        _ expectation: ListenerOwnershipExpectation,
        isOwnedBy fingerprint: ProcessFingerprint
    ) async throws -> Bool {
        callCount += 1
        return ownedPorts.contains(expectation.port)
    }

    func calls() -> Int { callCount }
}

private func makeFingerprint(
    pid: Int32 = 42,
    uid: UInt32 = 501,
    executable: String = "/opt/homebrew/bin/node",
    commandLine: String = "/opt/homebrew/bin/node server.js",
    parentPID: Int32 = 1,
    detectedAt: Date = Date(timeIntervalSince1970: 1_700_000_010)
) -> ProcessFingerprint {
    ProcessFingerprint(
        pid: pid,
        uid: uid,
        executablePath: executable,
        executableFileIdentity: .init(deviceID: 1, inode: 42),
        startTime: Date(timeIntervalSince1970: 1_700_000_000),
        commandLineDigest: ProcessFingerprint.digest(commandLine: commandLine),
        parentPID: parentPID,
        detectedAt: detectedAt
    )
}

private func inspection(for fingerprint: ProcessFingerprint) -> ProcessInspection {
    ProcessInspection(
        fingerprint: fingerprint,
        commandLine: "/opt/homebrew/bin/node server.js",
        currentDirectory: "/Users/developer/Code/example"
    )
}

private func makeTarget(fingerprint: ProcessFingerprint, port: UInt16 = 3000) -> ProcessActionTarget {
    let process = ObservedProcess(
        fingerprint: fingerprint,
        name: "node",
        commandLine: "/opt/homebrew/bin/node server.js",
        owner: "developer",
        currentDirectory: "/Users/developer/Code/example",
        parentName: "zsh",
        runtime: .node,
        project: nil,
        isSystemProcess: false,
        docker: nil,
        launchedByDevBerth: false,
        managedServiceID: nil
    )
    return ProcessActionTarget(listener: ObservedListener(
        protocolKind: .tcp,
        address: "127.0.0.1",
        port: port,
        process: process,
        firstDetectedAt: fingerprint.detectedAt,
        lastDetectedAt: fingerprint.detectedAt
    ))
}

private func successfulRunner() -> MockCommandRunner {
    MockCommandRunner { _, _ in
        .init(stdout: Data(), stderr: Data(), exitCode: 0)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        errorHandler(error)
    }
}
