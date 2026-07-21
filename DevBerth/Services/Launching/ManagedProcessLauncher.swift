import Darwin
import Foundation

actor ManagedProcessLauncher: ManagedProcessLaunching {
    private struct ManagedProcess {
        let process: Process
        let stdout: Pipe
        let stderr: Pipe
    }

    private let secrets: any SecretStoring
    private let logs: ServiceLogBuffer
    private let resolver: ExecutableResolver
    private var running: [UUID: ManagedProcess] = [:]

    init(
        secrets: any SecretStoring,
        logs: ServiceLogBuffer,
        resolver: ExecutableResolver = ExecutableResolver()
    ) {
        self.secrets = secrets
        self.logs = logs
        self.resolver = resolver
    }

    func launch(_ profile: ManagedServiceConfiguration) async throws {
        guard profile.isReviewed else {
            throw DevBerthError.launchValidation("Review inferred command fields before launching this profile.")
        }
        guard running[profile.id]?.process.isRunning != true else {
            throw DevBerthError.launchValidation("\(profile.name) is already running under DevBerth.")
        }
        let issues = ManagedServiceValidator.validate(profile).filter { $0.severity == .error }
        guard issues.isEmpty else {
            throw DevBerthError.launchValidation(issues.map(\.message).joined(separator: " "))
        }

        var environment = ProcessInfo.processInfo.environment.merging(profile.environment) { _, profileValue in profileValue }
        var secretValues: [String] = []
        for (name, reference) in profile.secretReferences {
            guard let value = try await secrets.value(for: reference) else { throw DevBerthError.missingSecret(name) }
            environment[name] = value
            secretValues.append(value)
        }
        await logs.setSecrets(secretValues, for: profile.id)

        let executable: URL
        let arguments: [String]
        switch profile.shell {
        case .direct:
            guard let resolved = resolver.resolve(profile.command, environment: environment, workingDirectory: profile.workingDirectory) else {
                throw DevBerthError.commandUnavailable(profile.command)
            }
            executable = resolved
            arguments = profile.arguments
        case let .loginShell(path), let .custom(path):
            guard FileManager.default.isExecutableFile(atPath: path) else {
                throw DevBerthError.commandUnavailable(path)
            }
            executable = URL(fileURLWithPath: path)
            let authoredCommand: String
            if profile.launchMechanism == .customShell {
                authoredCommand = ([profile.command] + profile.arguments).joined(separator: " ")
            } else {
                authoredCommand = ShellEscaper.command(executable: profile.command, arguments: profile.arguments)
            }
            arguments = ["-lc", authoredCommand]
        }

        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: profile.workingDirectory, isDirectory: true)
        process.environment = environment
        process.standardOutput = standardOutput
        process.standardError = standardError

        standardOutput.fileHandleForReading.readabilityHandler = { [logs] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await logs.append(profileID: profile.id, stream: .standardOutput, data: data) }
        }
        standardError.fileHandleForReading.readabilityHandler = { [logs] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await logs.append(profileID: profile.id, stream: .standardError, data: data) }
        }
        process.terminationHandler = { [weak self, logs] process in
            let status = process.terminationStatus
            Task {
                await logs.append(
                    profileID: profile.id,
                    stream: .internalMessage,
                    data: Data("Process exited with status \(status).".utf8)
                )
                await self?.remove(profileID: profile.id)
            }
        }

        do {
            try process.run()
        } catch {
            standardOutput.fileHandleForReading.readabilityHandler = nil
            standardError.fileHandleForReading.readabilityHandler = nil
            throw DevBerthError.unexpected("\(profile.name) could not start: \(error.localizedDescription)")
        }
        running[profile.id] = ManagedProcess(process: process, stdout: standardOutput, stderr: standardError)
        await logs.append(
            profileID: profile.id,
            stream: .internalMessage,
            data: Data("Started PID \(process.processIdentifier) with \(executable.path).".utf8)
        )
    }

    func stop(profileID: UUID, timeoutSeconds: Double) async throws {
        guard let managed = running[profileID], managed.process.isRunning else { return }
        managed.process.terminate()
        let deadline = Date().addingTimeInterval(max(0.2, timeoutSeconds))
        while managed.process.isRunning && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard !managed.process.isRunning else {
            throw DevBerthError.unexpected("The service did not stop before its graceful shutdown timeout. Force stop its verified process from Active Ports if needed.")
        }
        remove(profileID: profileID)
    }

    private func remove(profileID: UUID) {
        if let managed = running.removeValue(forKey: profileID) {
            managed.stdout.fileHandleForReading.readabilityHandler = nil
            managed.stderr.fileHandleForReading.readabilityHandler = nil
        }
    }
}
