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
            "-ww", "-p", String(pid), "-o", "ppid=", "-o", "user=", "-o", "lstart=", "-o", "command="
        ]
        async let resultTask = try? runner.run(
            executable: URL(fileURLWithPath: "/bin/ps"), arguments: arguments,
            environment: ["LC_ALL": "C"], currentDirectory: nil
        )
        async let pathsTask = processPaths(pid: pid)
        let (result, paths) = await (resultTask, pathsTask)
        let parsed = result.flatMap { Self.parsePS($0.stdoutString) }
        let cwd = paths.currentDirectory
        let executable = paths.executable
        let name = executable.map { URL(fileURLWithPath: $0).lastPathComponent } ?? fallbackName
        let owner = parsed?.owner ?? fallbackOwner
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

    private func processPaths(pid: Int32) async -> (currentDirectory: String?, executable: String?) {
        let result = try? await runner.run(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-a", "-p", String(pid), "-d", "cwd,txt", "-Fnf"]
        )
        guard result?.exitCode == 0 else { return (nil, nil) }
        var descriptor: String?
        var currentDirectory: String?
        var executable: String?
        for line in result?.stdoutString.split(whereSeparator: \.isNewline).map(String.init) ?? [] {
            if line.hasPrefix("f") {
                descriptor = String(line.dropFirst())
            } else if line.hasPrefix("n") {
                let path = String(line.dropFirst())
                if descriptor == "cwd" { currentDirectory = path }
                if descriptor == "txt", executable == nil { executable = path }
            }
        }
        return (currentDirectory, executable)
    }

    struct ParsedPS: Equatable {
        let parentPID: Int32?
        let owner: String
        let startTime: Date?
        let command: String
    }

    static func parsePS(_ output: String) -> ParsedPS? {
        guard let line = output.split(whereSeparator: \.isNewline).first else { return nil }
        let fields = line.split(omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
        guard fields.count >= 8 else { return nil }
        let parentPID = Int32(fields[0])
        let owner = String(fields[1])
        let dateText = fields[2...6].joined(separator: " ")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        let startTime = formatter.date(from: dateText)
        let command = fields[7...].joined(separator: " ")
        return ParsedPS(parentPID: parentPID, owner: owner, startTime: startTime, command: command)
    }
}
