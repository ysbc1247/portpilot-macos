import Foundation
@testable import DevBerth

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

func fixtureData(_ name: String) throws -> Data {
    guard let fixtureURL = Bundle(for: MockCommandRunner.self).url(forResource: name, withExtension: nil) else {
        throw DevBerthError.unexpected("The test fixture \(name) is missing from the unit-test bundle.")
    }
    let contents = try String(contentsOf: fixtureURL, encoding: .utf8)
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
) -> ObservedProcess {
    ObservedProcess(
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
        launchedByDevBerth: false,
        managedServiceID: nil
    )
}

func makeListener(port: UInt16 = 3000, pid: Int32 = 42) -> ObservedListener {
    ObservedListener(
        protocolKind: .tcp,
        address: "127.0.0.1",
        port: port,
        process: makeProcess(pid: pid),
        firstDetectedAt: Date(timeIntervalSince1970: 100),
        lastDetectedAt: Date(timeIntervalSince1970: 200)
    )
}
