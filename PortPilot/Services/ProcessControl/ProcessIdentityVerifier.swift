import Foundation

struct ProcessIdentityVerifier: ProcessIdentityVerifying, Sendable {
    private let runner: any CommandRunning

    init(runner: any CommandRunning) {
        self.runner = runner
    }

    func verify(_ expected: ProcessIdentity) async throws -> Bool {
        guard expected.isStrong else { return false }
        async let startResult = runner.run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-ww", "-p", String(expected.pid), "-o", "lstart="],
            environment: ["LC_ALL": "C"],
            currentDirectory: nil
        )
        async let executableResult = runner.run(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-a", "-p", String(expected.pid), "-d", "txt", "-Fn"],
            environment: nil,
            currentDirectory: nil
        )
        let (start, executable) = try await (startResult, executableResult)
        if start.exitCode == 1 || start.stdout.isEmpty { return false }
        guard start.exitCode == 0, executable.exitCode == 0,
              let actualStart = Self.parseStartTime(start.stdoutString),
              let actualExecutable = Self.parseExecutable(executable.stdoutString) else {
            throw PortPilotError.commandFailed(command: "process identity verification", status: max(start.exitCode, executable.exitCode), details: start.stderrString + executable.stderrString)
        }
        guard
            let expectedPath = expected.executablePath,
            URL(fileURLWithPath: actualExecutable).standardizedFileURL.path == URL(fileURLWithPath: expectedPath).standardizedFileURL.path,
            let expectedStart = expected.startTime
        else { return false }
        return abs(actualStart.timeIntervalSince(expectedStart)) < 1
    }

    static func parseStartTime(_ output: String) -> Date? {
        guard let line = output.split(whereSeparator: \.isNewline).first else { return nil }
        let fields = line.split(omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
        guard fields.count >= 5 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.date(from: fields[0...4].joined(separator: " "))
    }

    static func parseExecutable(_ output: String) -> String? {
        output.split(whereSeparator: \.isNewline).map(String.init).first { $0.hasPrefix("n/") }.map { String($0.dropFirst()) }
    }
}
