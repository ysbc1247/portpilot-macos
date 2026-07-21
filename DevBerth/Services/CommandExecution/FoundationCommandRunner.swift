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
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment.map { ProcessInfo.processInfo.environment.merging($0) { _, new in new } }
            process.currentDirectoryURL = currentDirectory
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = standardOutput
            process.standardError = standardError

            do {
                try process.run()
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                throw DevBerthError.commandUnavailable(executable.path)
            } catch {
                throw DevBerthError.unexpected("Could not run \(executable.lastPathComponent): \(error.localizedDescription)")
            }

            let outputTask = Task.detached {
                standardOutput.fileHandleForReading.readDataToEndOfFile()
            }
            let errorTask = Task.detached {
                standardError.fileHandleForReading.readDataToEndOfFile()
            }
            process.waitUntilExit()
            let outputData = await outputTask.value
            let errorData = await errorTask.value
            return CommandResult(
                stdout: outputData,
                stderr: errorData,
                exitCode: process.terminationStatus
            )
        }.value
    }
}
