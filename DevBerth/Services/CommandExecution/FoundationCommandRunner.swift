import Foundation

final class FoundationCommandRunner: CommandRunning, @unchecked Sendable {
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        currentDirectory: URL?
    ) async throws -> CommandResult {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let standardOutput = Pipe()
            let standardError = Pipe()
            let outputBuffer = CommandOutputBuffer()
            let errorBuffer = CommandOutputBuffer()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment.map { ProcessInfo.processInfo.environment.merging($0) { _, new in new } }
            process.currentDirectoryURL = currentDirectory
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = standardOutput
            process.standardError = standardError
            standardOutput.fileHandleForReading.readabilityHandler = { handle in
                outputBuffer.append(handle.availableData)
            }
            standardError.fileHandleForReading.readabilityHandler = { handle in
                errorBuffer.append(handle.availableData)
            }

            do {
                try process.run()
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                standardOutput.fileHandleForReading.readabilityHandler = nil
                standardError.fileHandleForReading.readabilityHandler = nil
                throw DevBerthError.commandUnavailable(executable.path)
            } catch {
                standardOutput.fileHandleForReading.readabilityHandler = nil
                standardError.fileHandleForReading.readabilityHandler = nil
                throw DevBerthError.unexpected("Could not run \(executable.lastPathComponent): \(error.localizedDescription)")
            }

            process.waitUntilExit()
            standardOutput.fileHandleForReading.readabilityHandler = nil
            standardError.fileHandleForReading.readabilityHandler = nil
            outputBuffer.append(standardOutput.fileHandleForReading.readDataToEndOfFile())
            errorBuffer.append(standardError.fileHandleForReading.readDataToEndOfFile())
            return CommandResult(
                stdout: outputBuffer.data,
                stderr: errorBuffer.data,
                exitCode: process.terminationStatus
            )
        }.value
    }
}

private final class CommandOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
