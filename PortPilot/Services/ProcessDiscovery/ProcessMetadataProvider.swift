import Foundation

struct ProcessMetadataProvider: Sendable {
    private let runner: any CommandRunning
    private let inferer: ProjectInferer

    init(runner: any CommandRunning, inferer: ProjectInferer = ProjectInferer()) {
        self.runner = runner
        self.inferer = inferer
    }

    func metadata(pid: Int32, fallbackName: String, fallbackOwner: String) async -> ProcessMetadata {
        let arguments = [
            "-ww", "-p", String(pid), "-o", "ppid=", "-o", "user=", "-o", "lstart=", "-o", "comm=", "-o", "command="
        ]
        let result = try? await runner.run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: arguments,
            environment: ["LC_ALL": "C"],
            currentDirectory: nil
        )
        let parsed = result.flatMap { Self.parsePS($0.stdoutString) }
        let cwd = await currentDirectory(pid: pid)
        let name = parsed?.executable.map { URL(fileURLWithPath: $0).lastPathComponent } ?? fallbackName
        let owner = parsed?.owner ?? fallbackOwner
        let executable = parsed?.executable
        let command = parsed?.command ?? fallbackName
        let identity = ProcessIdentity(pid: pid, executablePath: executable, startTime: parsed?.startTime)
        return ProcessMetadata(
            identity: identity,
            parentPID: parsed?.parentPID,
            name: name,
            executablePath: executable,
            commandLine: command,
            owner: owner,
            currentDirectory: cwd,
            parentName: nil,
            runtime: ProcessClassifier.classify(name: name, executable: executable, command: command),
            project: inferer.infer(from: cwd),
            isSystemProcess: SystemProcessClassifier.isSystemProcess(name: name, executable: executable, owner: owner, currentDirectory: cwd),
            docker: nil,
            launchedByPortPilot: false,
            launchProfileID: nil
        )
    }

    private func currentDirectory(pid: Int32) async -> String? {
        let result = try? await runner.run(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-a", "-p", String(pid), "-d", "cwd", "-Fn"]
        )
        guard result?.exitCode == 0 else { return nil }
        return result?.stdoutString
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { $0.hasPrefix("n/") })
            .map { String($0.dropFirst()) }
    }

    struct ParsedPS: Equatable {
        let parentPID: Int32?
        let owner: String
        let startTime: Date?
        let executable: String?
        let command: String
    }

    static func parsePS(_ output: String) -> ParsedPS? {
        guard let line = output.split(whereSeparator: \.isNewline).first else { return nil }
        let fields = line.split(omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
        guard fields.count >= 9 else { return nil }
        let parentPID = Int32(fields[0])
        let owner = String(fields[1])
        let dateText = fields[2...6].joined(separator: " ")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        let startTime = formatter.date(from: dateText)
        let executable = String(fields[7])
        let command = fields[8...].joined(separator: " ")
        return ParsedPS(parentPID: parentPID, owner: owner, startTime: startTime, executable: executable, command: command)
    }
}
