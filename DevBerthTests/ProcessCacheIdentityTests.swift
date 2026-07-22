import Foundation
import XCTest
@testable import DevBerth

final class ProcessCacheIdentityTests: XCTestCase {
    func testNativeReaderCapturesFullIdentityForCurrentProcess() throws {
        let pid = Int32(ProcessInfo.processInfo.processIdentifier)
        let identity = try XCTUnwrap(SystemProcessCacheIdentityReader().identity(pid: pid))

        XCTAssertEqual(identity.pid, pid)
        XCTAssertFalse(identity.executablePath.isEmpty)
        XCTAssertFalse(identity.commandLineDigest.isEmpty)
        XCTAssertFalse(identity.currentDirectory.isEmpty)
    }

    func testParsesNativeProcessArgumentsWithoutEnvironmentValues() {
        var argumentCount: Int32 = 2
        var data = withUnsafeBytes(of: &argumentCount) { Data($0) }
        data.append(contentsOf: "/usr/bin/node".utf8)
        data.append(contentsOf: [0, 0])
        data.append(contentsOf: "/usr/bin/node".utf8)
        data.append(0)
        data.append(contentsOf: "server.js".utf8)
        data.append(0)
        data.append(contentsOf: "SECRET=excluded".utf8)
        data.append(0)

        XCTAssertEqual(
            SystemProcessCacheIdentityReader.parseCommandLine(data),
            "/usr/bin/node\0server.js"
        )
    }

    func testMetadataCacheInvalidatesForPIDReuseAndDirectoryChange() async throws {
        let listenerFields = [
            "p42", "cnode", "Ldeveloper", "f12", "tIPv4", "PTCP",
            "n127.0.0.1:3000", "TST=LISTEN"
        ]
        let listenerData = Data(listenerFields.joined(separator: "\0").utf8) + Data([0])
        let runner = MockCommandRunner { executable, arguments in
            if executable.path == "/usr/sbin/lsof", arguments.contains("-iTCP") {
                return CommandResult(stdout: listenerData, stderr: Data(), exitCode: 0)
            }
            if executable.path == "/usr/sbin/lsof", arguments.contains("-iUDP") {
                return CommandResult(stdout: Data(), stderr: Data(), exitCode: 1)
            }
            if executable.path == "/bin/ps" {
                return CommandResult(
                    stdout: Data("1 501 Tue Jul 22 08:00:00 2026 /opt/homebrew/bin/node server.js\n".utf8),
                    stderr: Data(),
                    exitCode: 0
                )
            }
            return CommandResult(
                stdout: Data("fcwd\nn/Users/developer/one\nftxt\nn/opt/homebrew/bin/node\n".utf8),
                stderr: Data(),
                exitCode: 0
            )
        }
        let initial = cacheIdentity(startTime: 100, directory: "/Users/developer/one")
        let identityReader = MutableProcessCacheIdentityReader(identity: initial)
        let discoverer = LocalPortDiscovery(
            runner: runner,
            includeProjectInference: false,
            identityReader: identityReader,
            metadataCacheLifetime: 3_600
        )

        _ = try await discoverer.discover()
        _ = try await discoverer.discover()
        XCTAssertEqual(metadataInspectionCount(runner), 1)

        identityReader.setIdentity(cacheIdentity(startTime: 101, directory: "/Users/developer/one"))
        _ = try await discoverer.discover()
        XCTAssertEqual(metadataInspectionCount(runner), 2)

        identityReader.setIdentity(cacheIdentity(startTime: 101, directory: "/Users/developer/two"))
        _ = try await discoverer.discover()
        XCTAssertEqual(metadataInspectionCount(runner), 3)
    }

    private func metadataInspectionCount(_ runner: MockCommandRunner) -> Int {
        runner.invocations.filter { $0.executable == "/bin/ps" }.count
    }

    private func cacheIdentity(startTime: TimeInterval, directory: String) -> ProcessCacheIdentity {
        ProcessCacheIdentity(
            pid: 42,
            uid: 501,
            executablePath: "/opt/homebrew/bin/node",
            executableFileIdentity: ExecutableFileIdentity(deviceID: 1, inode: 2),
            startTime: Date(timeIntervalSince1970: startTime),
            commandLineDigest: ProcessFingerprint.digest(commandLine: "/opt/homebrew/bin/node\0server.js"),
            parentPID: 1,
            currentDirectory: directory
        )
    }
}

private final class MutableProcessCacheIdentityReader: ProcessCacheIdentityReading, @unchecked Sendable {
    private let lock = NSLock()
    private var value: ProcessCacheIdentity?

    init(identity: ProcessCacheIdentity?) {
        value = identity
    }

    func identity(pid: Int32) -> ProcessCacheIdentity? {
        lock.withLock { value }
    }

    func setIdentity(_ identity: ProcessCacheIdentity?) {
        lock.withLock { value = identity }
    }
}
