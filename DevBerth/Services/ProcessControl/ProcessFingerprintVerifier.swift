import Foundation

enum ProcessFingerprintField: String, CaseIterable, Sendable {
    case uid = "user ID"
    case executablePath = "executable path"
    case executableFileIdentity = "executable file identity"
    case startTime = "process start time"
    case commandLineDigest = "command-line digest"
    case parentPID = "parent process"
}

enum ProcessFingerprintVerification: Equatable, Sendable {
    case matched(actual: ProcessFingerprint)
    case notFound
    case insufficientExpectedFingerprint(missing: [ProcessFingerprintField])
    case mismatched(actual: ProcessFingerprint, differences: [ProcessFingerprintField])

    var explanation: String {
        switch self {
        case .matched:
            "The current process matches the captured fingerprint."
        case .notFound:
            "The expected process exited before the action."
        case let .insufficientExpectedFingerprint(missing):
            "The observation lacks required fingerprint fields: \(missing.map(\.rawValue).joined(separator: ", "))."
        case let .mismatched(_, differences):
            "The PID now differs in: \(differences.map(\.rawValue).joined(separator: ", "))."
        }
    }
}

struct ProcessInspection: Equatable, Sendable {
    let fingerprint: ProcessFingerprint
    let commandLine: String
    let currentDirectory: String?
}

protocol ProcessInspecting: Sendable {
    func inspect(pid: Int32) async throws -> ProcessInspection?
}

protocol ExecutableFileIdentityReading: Sendable {
    func identity(atPath path: String) -> ExecutableFileIdentity?
}

struct SystemExecutableFileIdentityReader: ExecutableFileIdentityReading {
    func identity(atPath path: String) -> ExecutableFileIdentity? {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let device = attributes[.systemNumber] as? NSNumber,
            let inode = attributes[.systemFileNumber] as? NSNumber
        else { return nil }
        return ExecutableFileIdentity(deviceID: device.uint64Value, inode: inode.uint64Value)
    }
}

struct SystemProcessInspector: ProcessInspecting, Sendable {
    private let runner: any CommandRunning
    private let fileIdentityReader: any ExecutableFileIdentityReading
    private let clock: @Sendable () -> Date

    init(
        runner: any CommandRunning,
        fileIdentityReader: any ExecutableFileIdentityReading = SystemExecutableFileIdentityReader(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.runner = runner
        self.fileIdentityReader = fileIdentityReader
        self.clock = clock
    }

    func inspect(pid: Int32) async throws -> ProcessInspection? {
        async let processResult = runner.run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: [
                "-ww", "-p", String(pid), "-o", "ppid=", "-o", "uid=", "-o", "lstart=", "-o", "command="
            ],
            environment: ["LC_ALL": "C"],
            currentDirectory: nil
        )
        async let pathResult = runner.run(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-a", "-p", String(pid), "-d", "cwd,txt", "-Fnf"],
            environment: nil,
            currentDirectory: nil
        )
        let (process, paths) = try await (processResult, pathResult)
        if process.exitCode == 1 || process.stdout.isEmpty { return nil }
        guard process.exitCode == 0, let parsed = Self.parsePS(process.stdoutString) else {
            throw DevBerthError.commandFailed(
                command: "process fingerprint inspection",
                status: process.exitCode,
                details: process.stderrString
            )
        }
        guard paths.exitCode == 0 || paths.exitCode == 1 else {
            throw DevBerthError.commandFailed(command: "process path inspection", status: paths.exitCode, details: paths.stderrString)
        }
        let parsedPaths = paths.exitCode == 0
            ? Self.parsePaths(paths.stdoutString)
            : (currentDirectory: nil, executable: nil)
        let fileIdentity = parsedPaths.executable.flatMap { fileIdentityReader.identity(atPath: $0) }
        let fingerprint = ProcessFingerprint(
            pid: pid,
            uid: parsed.uid,
            executablePath: parsedPaths.executable,
            executableFileIdentity: fileIdentity,
            startTime: parsed.startTime,
            commandLineDigest: ProcessFingerprint.digest(commandLine: parsed.commandLine),
            parentPID: parsed.parentPID,
            detectedAt: clock()
        )
        return ProcessInspection(
            fingerprint: fingerprint,
            commandLine: parsed.commandLine,
            currentDirectory: parsedPaths.currentDirectory
        )
    }

    struct ParsedPS: Equatable {
        let parentPID: Int32
        let uid: UInt32
        let startTime: Date
        let commandLine: String
    }

    static func parsePS(_ output: String) -> ParsedPS? {
        guard let line = output.split(whereSeparator: \.isNewline).first else { return nil }
        let fields = line.split(omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
        guard
            fields.count >= 8,
            let parentPID = Int32(fields[0]),
            let uid = UInt32(fields[1])
        else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        guard let startTime = formatter.date(from: fields[2...6].joined(separator: " ")) else { return nil }
        return ParsedPS(
            parentPID: parentPID,
            uid: uid,
            startTime: startTime,
            commandLine: fields[7...].joined(separator: " ")
        )
    }

    static func parsePaths(_ output: String) -> (currentDirectory: String?, executable: String?) {
        var descriptor: String?
        var currentDirectory: String?
        var executable: String?
        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
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
}

struct ProcessFingerprintVerifier: ProcessFingerprintVerifying, Sendable {
    private let inspector: any ProcessInspecting

    init(runner: any CommandRunning) {
        inspector = SystemProcessInspector(runner: runner)
    }

    init(inspector: any ProcessInspecting) {
        self.inspector = inspector
    }

    func verify(_ expected: ProcessFingerprint) async throws -> ProcessFingerprintVerification {
        let missing = Self.missingRequiredFields(in: expected)
        guard missing.isEmpty else { return .insufficientExpectedFingerprint(missing: missing) }
        guard let inspection = try await inspector.inspect(pid: expected.pid) else { return .notFound }
        let actual = inspection.fingerprint
        let differences = Self.differences(expected: expected, actual: actual)
        return differences.isEmpty ? .matched(actual: actual) : .mismatched(actual: actual, differences: differences)
    }

    static func missingRequiredFields(in fingerprint: ProcessFingerprint) -> [ProcessFingerprintField] {
        var missing: [ProcessFingerprintField] = []
        if fingerprint.uid == nil { missing.append(.uid) }
        if fingerprint.executablePath == nil { missing.append(.executablePath) }
        if fingerprint.startTime == nil { missing.append(.startTime) }
        if fingerprint.commandLineDigest == nil { missing.append(.commandLineDigest) }
        if fingerprint.parentPID == nil { missing.append(.parentPID) }
        return missing
    }

    static func differences(expected: ProcessFingerprint, actual: ProcessFingerprint) -> [ProcessFingerprintField] {
        var differences: [ProcessFingerprintField] = []
        if expected.uid != actual.uid { differences.append(.uid) }
        if normalized(expected.executablePath) != normalized(actual.executablePath) { differences.append(.executablePath) }
        if let expectedFileIdentity = expected.executableFileIdentity,
           expectedFileIdentity != actual.executableFileIdentity {
            differences.append(.executableFileIdentity)
        }
        if let expectedStart = expected.startTime, let actualStart = actual.startTime {
            if abs(actualStart.timeIntervalSince(expectedStart)) >= 1 { differences.append(.startTime) }
        } else if expected.startTime != actual.startTime {
            differences.append(.startTime)
        }
        if expected.commandLineDigest != actual.commandLineDigest { differences.append(.commandLineDigest) }
        if expected.parentPID != actual.parentPID { differences.append(.parentPID) }
        return differences
    }

    private static func normalized(_ path: String?) -> String? {
        path.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    }
}
