import Foundation

struct LsofListenerOwnershipVerifier: ListenerOwnershipVerifying, Sendable {
    private let runner: any CommandRunning

    init(runner: any CommandRunning) {
        self.runner = runner
    }

    func verify(
        _ expectation: ListenerOwnershipExpectation,
        isOwnedBy fingerprint: ProcessFingerprint
    ) async throws -> Bool {
        let selector: String
        let arguments: [String]
        switch expectation.protocolKind {
        case .tcp:
            selector = "TCP"
            arguments = [
                "-nP", "-a", "-p", String(fingerprint.pid),
                "-iTCP:\(expectation.port)", "-sTCP:LISTEN", "-F0pcLftPnT", "+c", "0"
            ]
        case .udp:
            selector = "UDP"
            arguments = [
                "-nP", "-a", "-p", String(fingerprint.pid),
                "-iUDP:\(expectation.port)", "-F0pcLftPnT", "+c", "0"
            ]
        }
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: arguments
        )
        if result.exitCode == 1 { return false }
        guard result.exitCode == 0 else {
            throw DevBerthError.commandFailed(
                command: "listener ownership verification (\(selector))",
                status: result.exitCode,
                details: result.stderrString
            )
        }
        return LsofFieldParser.parse(result.stdout, defaultProtocol: expectation.protocolKind).contains {
            $0.pid == fingerprint.pid
                && $0.protocolKind == expectation.protocolKind
                && $0.address == expectation.address
                && $0.port == expectation.port
        }
    }
}
