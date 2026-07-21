import Darwin
import Foundation

actor SafeProcessController: ProcessControlling {
    private let runner: any CommandRunning
    private let verifier: any ProcessFingerprintVerifying
    private let listenerOwnershipVerifier: any ListenerOwnershipVerifying

    init(
        runner: any CommandRunning,
        verifier: any ProcessFingerprintVerifying,
        listenerOwnershipVerifier: (any ListenerOwnershipVerifying)? = nil
    ) {
        self.runner = runner
        self.verifier = verifier
        self.listenerOwnershipVerifier = listenerOwnershipVerifier ?? LsofListenerOwnershipVerifier(runner: runner)
    }

    func terminate(_ target: ProcessActionTarget, mode: TerminationMode) async throws -> TerminationOutcome {
        let startedAt = Date()
        var state = TerminationStateMachine.reduce(state: .idle, event: .begin)
        guard state == .validatingFingerprint else { throw DevBerthError.unexpected("Termination could not begin.") }

        if let reason = ProcessSafetyPolicy.terminationBlockReason(for: target.process) {
            state = TerminationStateMachine.reduce(state: state, event: .protectionRejected(reason))
            throw DevBerthError.protectedProcess(reason)
        }

        let verifiedFingerprint = try await revalidate(target)
        state = TerminationStateMachine.reduce(state: state, event: .fingerprintValidated)

        let signal: Int32
        let timeout: Double
        let modeName: String
        switch mode {
        case let .graceful(timeoutSeconds):
            signal = SIGTERM
            timeout = max(0.2, timeoutSeconds)
            modeName = "graceful"
        case let .force(confirmed):
            guard confirmed else {
                throw DevBerthError.unexpected("Force stop requires explicit confirmation.")
            }
            signal = SIGKILL
            timeout = 2
            modeName = "force"
        }

        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/kill"),
            arguments: [signal == SIGTERM ? "-TERM" : "-KILL", String(verifiedFingerprint.pid)]
        )
        guard result.exitCode == 0 else {
            throw DevBerthError.commandFailed(command: "kill", status: result.exitCode, details: result.stderrString)
        }
        let deadline = Date().addingTimeInterval(timeout)
        state = TerminationStateMachine.reduce(state: state, event: .signalSent(signal: signal, deadline: deadline))

        while Date() < deadline {
            switch try await verifier.verify(verifiedFingerprint) {
            case .notFound:
                state = TerminationStateMachine.reduce(state: state, event: .processExited)
                return TerminationOutcome(
                    pid: verifiedFingerprint.pid,
                    mode: modeName,
                    completion: .exited,
                    durationSeconds: Date().timeIntervalSince(startedAt)
                )
            case .mismatched:
                state = TerminationStateMachine.reduce(state: state, event: .processExited)
                return TerminationOutcome(
                    pid: verifiedFingerprint.pid,
                    mode: modeName,
                    completion: .fingerprintChangedAfterSignal,
                    durationSeconds: Date().timeIntervalSince(startedAt)
                )
            case .matched:
                try await Task.sleep(for: .milliseconds(150))
            case let .insufficientExpectedFingerprint(missing):
                throw DevBerthError.processFingerprintChanged(
                    "Required fields disappeared: \(missing.map(\.rawValue).joined(separator: ", "))."
                )
            }
        }
        state = TerminationStateMachine.reduce(state: state, event: .deadlineReached)
        return TerminationOutcome(
            pid: verifiedFingerprint.pid,
            mode: modeName,
            completion: .timedOut,
            durationSeconds: Date().timeIntervalSince(startedAt)
        )
    }

    private func revalidate(_ target: ProcessActionTarget) async throws -> ProcessFingerprint {
        let verification = try await verifier.verify(target.process.fingerprint)
        guard case let .matched(actual) = verification else {
            throw DevBerthError.processFingerprintChanged(verification.explanation)
        }
        guard try await listenerOwnershipVerifier.verify(target.expectedListener, isOwnedBy: actual) else {
            throw DevBerthError.listenerOwnershipChanged(target.expectedListener.port)
        }
        return actual
    }
}
