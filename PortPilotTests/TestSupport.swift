import Foundation
@testable import PortPilot

final class MockCommandRunner: CommandRunning, @unchecked Sendable {
    struct Invocation: Equatable {
        let executable: String
        let arguments: [String]
    }

    private let lock = NSLock()
    private(set) var invocations: [Invocation] = []
    var handler: @Sendable (URL, [String]) throws -> CommandResult

    init(handler: @escaping @Sendable (URL, [String]) throws -> CommandResult) {
        self.handler = handler
    }

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        currentDirectory: URL?
    ) async throws -> CommandResult {
        lock.withLock { invocations.append(.init(executable: executable.path, arguments: arguments)) }
        return try handler(executable, arguments)
    }
}

func fixtureData(_ name: String, testFile: StaticString = #filePath) throws -> Data {
    let testDirectory = URL(fileURLWithPath: "\(testFile)").deletingLastPathComponent()
    let contents = try String(contentsOf: testDirectory.appendingPathComponent("Fixtures/\(name)"), encoding: .utf8)
    var data = Data()
    for line in contents.split(whereSeparator: \.isNewline) {
        data.append(contentsOf: line.utf8)
        data.append(0)
    }
    return data
}

func makeProcess(
    pid: Int32 = 42,
    executable: String = "/opt/homebrew/bin/node",
    startTime: Date = Date(timeIntervalSince1970: 1_700_000_000),
    owner: String = "developer",
    system: Bool = false
) -> ProcessMetadata {
    ProcessMetadata(
        identity: ProcessIdentity(pid: pid, executablePath: executable, startTime: startTime),
        parentPID: 1,
        name: URL(fileURLWithPath: executable).lastPathComponent,
        executablePath: executable,
        commandLine: "\(executable) server.js",
        owner: owner,
        currentDirectory: "/Users/developer/Code/example",
        parentName: "zsh",
        runtime: .node,
        project: nil,
        isSystemProcess: system,
        docker: nil,
        launchedByPortPilot: false,
        launchProfileID: nil
    )
}

func makeListener(port: UInt16 = 3000, pid: Int32 = 42) -> NetworkListener {
    NetworkListener(
        protocolKind: .tcp,
        address: "127.0.0.1",
        port: port,
        process: makeProcess(pid: pid),
        firstDetectedAt: Date(timeIntervalSince1970: 100),
        lastDetectedAt: Date(timeIntervalSince1970: 200)
    )
}

