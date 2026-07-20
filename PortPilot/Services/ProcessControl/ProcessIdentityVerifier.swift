import Foundation

struct ProcessIdentityVerifier: ProcessIdentityVerifying, Sendable {
    private let runner: any CommandRunning

    init(runner: any CommandRunning) {
        self.runner = runner
    }

    func verify(_ expected: ProcessIdentity) async throws -> Bool {
        guard expected.isStrong else { return false }
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-ww", "-p", String(expected.pid), "-o", "lstart=", "-o", "comm="],
            environment: ["LC_ALL": "C"],
            currentDirectory: nil
        )
        if result.exitCode == 1 || result.stdout.isEmpty { return false }
        guard result.exitCode == 0, let actual = Self.parse(result.stdoutString) else {
            throw PortPilotError.commandFailed(command: "ps identity verification", status: result.exitCode, details: result.stderrString)
        }
        guard
            let expectedPath = expected.executablePath,
            URL(fileURLWithPath: actual.executable).standardizedFileURL.path == URL(fileURLWithPath: expectedPath).standardizedFileURL.path,
            let expectedStart = expected.startTime
        else { return false }
        return abs(actual.startTime.timeIntervalSince(expectedStart)) < 1
    }

    static func parse(_ output: String) -> (startTime: Date, executable: String)? {
        guard let line = output.split(whereSeparator: \.isNewline).first else { return nil }
        let fields = line.split(omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
        guard fields.count >= 6 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        guard let date = formatter.date(from: fields[0...4].joined(separator: " ")) else { return nil }
        return (date, String(fields[5]))
    }
}

