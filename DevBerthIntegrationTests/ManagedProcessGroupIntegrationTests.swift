import Darwin
import Foundation
import XCTest
@testable import DevBerth

final class ManagedProcessGroupIntegrationTests: XCTestCase {
    func testPOSIXSpawnerCreatesDedicatedGroupAndPreservesArgumentsAndWorkingDirectory() async throws {
        let spawner = POSIXControlledProcessSpawner()
        let marker = "argument with spaces ; $(not-executed)"
        let spawned = try spawner.spawn(ControlledProcessLaunchRequest(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", "import json,os,sys; print(json.dumps([os.getcwd(), sys.argv[1]]))", marker],
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true),
            createsDedicatedProcessGroup: true
        ))
        defer { forceCleanup(groupID: spawned.processGroupID, marker: marker) }

        XCTAssertEqual(Darwin.getpgid(spawned.pid), spawned.pid)
        let outputTask = Task.detached { spawned.standardOutput.readDataToEndOfFile() }
        let errorTask = Task.detached { spawned.standardError.readDataToEndOfFile() }
        var status: Int32 = 0
        XCTAssertEqual(Darwin.waitpid(spawned.pid, &status, 0), spawned.pid)
        let output = await outputTask.value
        let error = await errorTask.value
        XCTAssertEqual(status, 0, String(decoding: error, as: UTF8.self))
        let decoded = try JSONDecoder().decode([String].self, from: output)
        XCTAssertEqual(decoded, ["/private/tmp", marker])
    }

    func testManagedGroupStopsSpawnedChildWithMultipleListeners() async throws {
        let context = try await makeContext(mode: "spawn-multiple")
        defer { forceCleanup(groupID: context.groupID, marker: context.marker) }
        let listeners = try await waitForListeners(marker: context.marker, count: 2)
        XCTAssertEqual(Set(listeners.map { $0.process.fingerprint.pid }).count, 1)
        XCTAssertEqual(Darwin.getpgid(listeners[0].process.fingerprint.pid), context.groupID)

        try await context.launcher.stop(profileID: context.profileID, timeoutSeconds: 2)

        try await waitForProcessGroupExit(context.groupID)
        XCTAssertFalse(processGroupExists(context.groupID))
        let remainingListeners = try await currentListeners(marker: context.marker)
        XCTAssertTrue(remainingListeners.isEmpty)
    }

    func testManagedGroupTracksExecReplacementUnderSameStrongLeader() async throws {
        let context = try await makeContext(mode: "replace")
        defer { forceCleanup(groupID: context.groupID, marker: context.marker) }
        let listeners = try await waitForListeners(marker: context.marker, count: 1)
        let listener = try XCTUnwrap(listeners.first)
        let capturedHandle = await context.launcher.runtimeHandle(profileID: context.profileID)
        let handle = try XCTUnwrap(capturedHandle)
        XCTAssertEqual(listener.process.fingerprint.pid, handle.leaderFingerprint.pid)
        XCTAssertEqual(listener.process.fingerprint.commandLineDigest, handle.leaderFingerprint.commandLineDigest)

        try await context.launcher.stop(profileID: context.profileID, timeoutSeconds: 2)
        try await waitForProcessGroupExit(context.groupID)
        XCTAssertFalse(processGroupExists(context.groupID))
    }

    func testManagedGroupStopsSupervisorAfterItRestartsChild() async throws {
        let context = try await makeContext(mode: "restart")
        defer { forceCleanup(groupID: context.groupID, marker: context.marker) }
        let initialListeners = try await waitForListeners(marker: context.marker, count: 1)
        let first = try XCTUnwrap(initialListeners.first)
        XCTAssertEqual(Darwin.getpgid(first.process.fingerprint.pid), context.groupID)

        XCTAssertEqual(Darwin.kill(first.process.fingerprint.pid, SIGTERM), 0)
        let replacement = try await waitForReplacementListener(
            marker: context.marker,
            excludingPID: first.process.fingerprint.pid,
            processGroupID: context.groupID
        )
        XCTAssertNotEqual(replacement.process.fingerprint.pid, first.process.fingerprint.pid)
        XCTAssertEqual(Darwin.getpgid(replacement.process.fingerprint.pid), context.groupID)

        try await context.launcher.stop(profileID: context.profileID, timeoutSeconds: 2)
        try await waitForProcessGroupExit(context.groupID)
        XCTAssertFalse(processGroupExists(context.groupID))
    }

    func testManagedGroupLeavesDetachedDescendantAlone() async throws {
        let context = try await makeContext(mode: "detach")
        var detachedPID: Int32?
        defer {
            if let detachedPID { forceCleanup(pid: detachedPID, marker: context.marker) }
            forceCleanup(groupID: context.groupID, marker: context.marker)
        }
        let detachedListeners = try await waitForListeners(marker: context.marker, count: 1)
        let listener = try XCTUnwrap(detachedListeners.first)
        detachedPID = listener.process.fingerprint.pid
        XCTAssertNotEqual(Darwin.getpgid(listener.process.fingerprint.pid), context.groupID)

        try await context.launcher.stop(profileID: context.profileID, timeoutSeconds: 2)

        try await waitForProcessGroupExit(context.groupID)
        XCTAssertFalse(processGroupExists(context.groupID))
        XCTAssertTrue(processExists(listener.process.fingerprint.pid))
        let remainingListeners = try await currentListeners(marker: context.marker)
        XCTAssertFalse(remainingListeners.isEmpty)
        let detachedWasSignaled = forceCleanup(pid: listener.process.fingerprint.pid, marker: context.marker)
        XCTAssertTrue(detachedWasSignaled)
        if detachedWasSignaled { detachedPID = nil }
        try await waitForProcessExit(listener.process.fingerprint.pid)
    }

    func testManagedGroupReportsTimeoutWhenLeaderIgnoresSIGTERM() async throws {
        let context = try await makeContext(mode: "ignore-term")
        defer { forceCleanup(groupID: context.groupID, marker: context.marker) }
        _ = try await waitForListeners(marker: context.marker, count: 1)

        do {
            try await context.launcher.stop(profileID: context.profileID, timeoutSeconds: 0.25)
            XCTFail("Expected the ignored graceful signal to time out")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("did not stop"))
        }
        XCTAssertTrue(processGroupExists(context.groupID))
    }

    private struct ManagedContext {
        let launcher: ManagedProcessLauncher
        let profileID: UUID
        let marker: String
        let groupID: Int32
    }

    private func makeContext(mode: String) async throws -> ManagedContext {
        let script = try XCTUnwrap(
            Bundle(for: ManagedProcessGroupIntegrationTests.self)
                .url(forResource: "process_tree_fixture", withExtension: "py")
        )
        let runner = FoundationCommandRunner()
        let launcher = ManagedProcessLauncher(
            secrets: IntegrationEmptySecretStore(),
            logs: ServiceLogBuffer(persistsToDisk: false),
            runner: runner
        )
        let profileID = UUID()
        let marker = "devberth-\(UUID().uuidString)"
        let profile = ManagedServiceConfiguration(
            id: profileID,
            name: "Process tree \(mode)",
            command: "/usr/bin/python3",
            arguments: ["-u", script.path, "--mode", mode, "--marker", marker],
            workingDirectory: "/tmp",
            shutdownTimeoutSeconds: 2
        )

        try await launcher.launch(profile)
        guard let handle = await launcher.runtimeHandle(profileID: profileID) else {
            throw DevBerthError.unexpected("Managed fixture launched without a runtime handle.")
        }
        return ManagedContext(
            launcher: launcher,
            profileID: profileID,
            marker: marker,
            groupID: handle.processGroupID
        )
    }

    private func waitForListeners(marker: String, count: Int) async throws -> [ObservedListener] {
        let discovery = LocalPortDiscovery(
            runner: FoundationCommandRunner(),
            includeProjectInference: false
        )
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            let listeners = try await discovery.discover().filter { $0.process.commandLine.contains(marker) }
            if listeners.count >= count { return listeners }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw DevBerthError.unexpected("The process-tree fixture did not expose \(count) listeners.")
    }

    private func waitForReplacementListener(
        marker: String,
        excludingPID: Int32,
        processGroupID: Int32
    ) async throws -> ObservedListener {
        let discovery = LocalPortDiscovery(
            runner: FoundationCommandRunner(),
            includeProjectInference: false
        )
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            if let listener = try await discovery.discover().first(where: {
                $0.process.fingerprint.pid != excludingPID
                    && Darwin.getpgid($0.process.fingerprint.pid) == processGroupID
            }) {
                return listener
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let diagnostic = try await FoundationCommandRunner().run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-axww", "-o", "pid=", "-o", "ppid=", "-o", "pgid=", "-o", "command="],
            environment: ["LC_ALL": "C"],
            currentDirectory: nil
        )
        let matchingProcesses = diagnostic.stdoutString
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { $0.contains(marker) }
            .joined(separator: " | ")
        throw DevBerthError.unexpected(
            "The supervisor did not expose a replacement child listener. Matching processes: \(matchingProcesses)"
        )
    }

    private func currentListeners(marker: String) async throws -> [ObservedListener] {
        try await LocalPortDiscovery(
            runner: FoundationCommandRunner(),
            includeProjectInference: false
        ).discover().filter { $0.process.commandLine.contains(marker) }
    }

    private func waitForProcessExit(_ pid: Int32) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if !processExists(pid) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Fixture PID \(pid) did not exit after cleanup")
    }

    private func waitForProcessGroupExit(_ groupID: Int32) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if !processGroupExists(groupID) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw DevBerthError.unexpected("Fixture process group \(groupID) was not reaped after stopping.")
    }

    private func processExists(_ pid: Int32) -> Bool {
        errno = 0
        return Darwin.kill(pid, 0) == 0 || errno == EPERM
    }

    private func processGroupExists(_ groupID: Int32) -> Bool {
        errno = 0
        return Darwin.kill(-groupID, 0) == 0 || errno == EPERM
    }

    @discardableResult
    private func forceCleanup(pid: Int32, marker: String) -> Bool {
        guard processRows().contains(where: { $0.pid == pid && $0.command.contains(marker) }) else { return false }
        return Darwin.kill(pid, SIGKILL) == 0
    }

    private func forceCleanup(groupID: Int32, marker: String) {
        guard groupID > 1 else { return }
        guard processRows().contains(where: {
            $0.processGroupID == groupID && $0.command.contains(marker)
        }) else { return }
        Darwin.kill(-groupID, SIGKILL)
    }

    private func processRows() -> [(pid: Int32, processGroupID: Int32, command: String)] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axww", "-o", "pid=", "-o", "pgid=", "-o", "command="]
        process.environment = ["LC_ALL": "C"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard fields.count == 3, let pid = Int32(fields[0]), let groupID = Int32(fields[1]) else { return nil }
            return (pid: pid, processGroupID: groupID, command: String(fields[2]))
        }
    }
}

private struct IntegrationEmptySecretStore: SecretStoring {
    func save(value: String, reference: UUID) async throws {}
    func value(for reference: UUID) async throws -> String? { nil }
    func delete(reference: UUID) async throws {}
}
