import Darwin
import Foundation

struct ControlledProcessLaunchRequest: Sendable {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
    let workingDirectory: URL
    let createsDedicatedProcessGroup: Bool
}

struct SpawnedManagedProcess: @unchecked Sendable {
    let pid: Int32
    let processGroupID: Int32
    let standardOutput: FileHandle
    let standardError: FileHandle
}

protocol ControlledProcessSpawning: Sendable {
    func spawn(_ request: ControlledProcessLaunchRequest) throws -> SpawnedManagedProcess
}

struct POSIXControlledProcessSpawner: ControlledProcessSpawning, Sendable {
    func spawn(_ request: ControlledProcessLaunchRequest) throws -> SpawnedManagedProcess {
        try validate(request)
        let outputPipe = try Self.makePipe()
        let errorPipe: (read: Int32, write: Int32)
        do {
            errorPipe = try Self.makePipe()
        } catch {
            Darwin.close(outputPipe.read)
            Darwin.close(outputPipe.write)
            throw error
        }

        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        var fileActionsInitialized = false
        var attributesInitialized = false
        var parentOwnsDescriptors = true
        defer {
            if fileActionsInitialized { posix_spawn_file_actions_destroy(&fileActions) }
            if attributesInitialized { posix_spawnattr_destroy(&attributes) }
            if parentOwnsDescriptors {
                Darwin.close(outputPipe.read)
                Darwin.close(outputPipe.write)
                Darwin.close(errorPipe.read)
                Darwin.close(errorPipe.write)
            }
        }

        try Self.check(posix_spawn_file_actions_init(&fileActions), operation: "initialize launch file actions")
        fileActionsInitialized = true
        try Self.check(posix_spawnattr_init(&attributes), operation: "initialize launch attributes")
        attributesInitialized = true

        try Self.check(
            posix_spawn_file_actions_adddup2(&fileActions, outputPipe.write, STDOUT_FILENO),
            operation: "connect managed stdout"
        )
        try Self.check(
            posix_spawn_file_actions_adddup2(&fileActions, errorPipe.write, STDERR_FILENO),
            operation: "connect managed stderr"
        )
        for descriptor in [outputPipe.read, outputPipe.write, errorPipe.read, errorPipe.write] {
            try Self.check(
                posix_spawn_file_actions_addclose(&fileActions, descriptor),
                operation: "close inherited launch descriptor"
            )
        }
        try Self.addWorkingDirectory(request.workingDirectory.path, to: &fileActions)

        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        for signal in [SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGPIPE, SIGCHLD, SIGALRM, SIGUSR1, SIGUSR2] {
            sigaddset(&defaultSignals, signal)
        }
        try Self.check(
            posix_spawnattr_setsigdefault(&attributes, &defaultSignals),
            operation: "restore managed signal defaults"
        )
        var emptySignalMask = sigset_t()
        sigemptyset(&emptySignalMask)
        try Self.check(
            posix_spawnattr_setsigmask(&attributes, &emptySignalMask),
            operation: "clear managed signal mask"
        )
        var spawnFlags = POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        if request.createsDedicatedProcessGroup {
            spawnFlags |= POSIX_SPAWN_SETPGROUP
            try Self.check(
                posix_spawnattr_setpgroup(&attributes, 0),
                operation: "create managed process group"
            )
        }
        try Self.check(
            posix_spawnattr_setflags(&attributes, Int16(spawnFlags)),
            operation: "enable managed launch attributes"
        )

        let argumentValues = [request.executable.path] + request.arguments
        let environmentValues = request.environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let spawnStatus = Self.withCStringArray(argumentValues) { arguments in
            Self.withCStringArray(environmentValues) { environment in
                request.executable.path.withCString { executable in
                    posix_spawn(&pid, executable, &fileActions, &attributes, arguments, environment)
                }
            }
        }
        try Self.check(spawnStatus, operation: "launch \(request.executable.lastPathComponent)")

        Darwin.close(outputPipe.write)
        Darwin.close(errorPipe.write)
        parentOwnsDescriptors = false
        let processGroupID = request.createsDedicatedProcessGroup ? pid : Darwin.getpgid(pid)
        guard processGroupID > 1 else {
            Darwin.kill(pid, SIGKILL)
            Darwin.close(outputPipe.read)
            Darwin.close(errorPipe.read)
            throw DevBerthError.unexpected("The managed process started without a safe process group.")
        }
        return SpawnedManagedProcess(
            pid: pid,
            processGroupID: processGroupID,
            standardOutput: FileHandle(fileDescriptor: outputPipe.read, closeOnDealloc: true),
            standardError: FileHandle(fileDescriptor: errorPipe.read, closeOnDealloc: true)
        )
    }

    private func validate(_ request: ControlledProcessLaunchRequest) throws {
        let values = [request.executable.path, request.workingDirectory.path]
            + request.arguments
            + request.environment.flatMap { [$0.key, $0.value] }
        guard !values.contains(where: { $0.utf8.contains(0) }) else {
            throw DevBerthError.launchValidation("Launch values cannot contain NUL bytes.")
        }
        guard request.executable.isFileURL, request.workingDirectory.isFileURL else {
            throw DevBerthError.launchValidation("Executable and working-directory values must be local file URLs.")
        }
    }

    private static func makePipe() throws -> (read: Int32, write: Int32) {
        var descriptors: [Int32] = [0, 0]
        guard Darwin.pipe(&descriptors) == 0 else {
            throw DevBerthError.commandFailed(
                command: "create managed log pipe",
                status: Int32(errno),
                details: String(cString: strerror(errno))
            )
        }
        for index in descriptors.indices where descriptors[index] <= STDERR_FILENO {
            let duplicated = Darwin.fcntl(descriptors[index], F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
            guard duplicated >= 0 else {
                let failure = errno
                descriptors.forEach { Darwin.close($0) }
                throw DevBerthError.commandFailed(
                    command: "protect managed log descriptor",
                    status: Int32(failure),
                    details: String(cString: strerror(failure))
                )
            }
            Darwin.close(descriptors[index])
            descriptors[index] = duplicated
        }
        return (read: descriptors[0], write: descriptors[1])
    }

    private static func addWorkingDirectory(
        _ path: String,
        to fileActions: inout posix_spawn_file_actions_t?
    ) throws {
        typealias AddChdir = @convention(c) (
            UnsafeMutablePointer<posix_spawn_file_actions_t?>?,
            UnsafePointer<CChar>?
        ) -> Int32
        guard let symbol = dlsym(
            UnsafeMutableRawPointer(bitPattern: -2),
            "posix_spawn_file_actions_addchdir_np"
        ) else {
            throw DevBerthError.unexpected("This macOS version cannot set a managed process working directory.")
        }
        let function = unsafeBitCast(symbol, to: AddChdir.self)
        let status = path.withCString { function(&fileActions, $0) }
        try check(status, operation: "set managed process working directory")
    }

    private static func withCStringArray<Result>(
        _ values: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
    ) -> Result {
        let storage: [UnsafeMutablePointer<CChar>] = values.map { strdup($0)! }
        defer { storage.forEach { free($0) } }
        var pointers: [UnsafeMutablePointer<CChar>?] = storage.map { Optional($0) }
        pointers.append(nil)
        return pointers.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }

    private static func check(_ status: Int32, operation: String) throws {
        guard status == 0 else {
            throw DevBerthError.commandFailed(
                command: operation,
                status: status,
                details: String(cString: strerror(status))
            )
        }
    }
}
