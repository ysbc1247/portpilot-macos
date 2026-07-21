import Darwin
import Foundation

actor SafeProcessController: ProcessControlling {
    private let runner: any CommandRunning
    private let verifier: any ProcessIdentityVerifying

    init(runner: any CommandRunning, verifier: any ProcessIdentityVerifying) {
        self.runner = runner
        self.verifier = verifier
    }

    func terminate(_ process: ObservedProcess, mode: TerminationMode) async throws -> TerminationOutcome {
        let startedAt = Date()
        var state = TerminationStateMachine.reduce(state: .idle, event: .begin)
        guard state == .validatingIdentity else { throw DevBerthError.unexpected("Termination could not begin.") }

        if let reason = ProcessSafetyPolicy.terminationBlockReason(for: process) {
            state = TerminationStateMachine.reduce(state: state, event: .protectionRejected(reason))
            throw DevBerthError.protectedProcess(reason)
        }
        guard try await verifier.verify(process.identity) else {
            _ = TerminationStateMachine.reduce(state: state, event: .identityRejected)
            throw DevBerthError.processIdentityChanged
        }
        state = TerminationStateMachine.reduce(state: state, event: .identityValidated)

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
            arguments: [signal == SIGTERM ? "-TERM" : "-KILL", String(process.identity.pid)]
        )
        guard result.exitCode == 0 else {
            throw DevBerthError.commandFailed(command: "kill", status: result.exitCode, details: result.stderrString)
        }
        let deadline = Date().addingTimeInterval(timeout)
        state = TerminationStateMachine.reduce(state: state, event: .signalSent(signal: signal, deadline: deadline))

        while Date() < deadline {
            if try await !verifier.verify(process.identity) {
                state = TerminationStateMachine.reduce(state: state, event: .processExited)
                return TerminationOutcome(
                    pid: process.identity.pid,
                    mode: modeName,
                    didExit: state == .exited,
                    durationSeconds: Date().timeIntervalSince(startedAt)
                )
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        state = TerminationStateMachine.reduce(state: state, event: .deadlineReached)
        return TerminationOutcome(
            pid: process.identity.pid,
            mode: modeName,
            didExit: false,
            durationSeconds: Date().timeIntervalSince(startedAt)
        )
    }
}
