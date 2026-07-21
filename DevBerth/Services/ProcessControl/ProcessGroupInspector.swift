import Darwin
import Foundation

protocol ProcessGroupInspecting: Sendable {
    func snapshot(
        for runtime: ManagedRuntimeHandle,
        listenerOwnerPIDs: Set<Int32>
    ) async throws -> ProcessGroupSnapshot
}

protocol ProcessGroupOperating: Sendable {
    func processGroupID(for pid: Int32) -> Int32?
    func processGroupExists(_ processGroupID: Int32) -> Bool
    func send(signal: Int32, toProcessGroup processGroupID: Int32) throws
    func send(signal: Int32, toProcess pid: Int32) throws
}

struct DarwinProcessGroupOperator: ProcessGroupOperating, Sendable {
    func processGroupID(for pid: Int32) -> Int32? {
        let groupID = Darwin.getpgid(pid)
        return groupID >= 0 ? groupID : nil
    }

    func processGroupExists(_ processGroupID: Int32) -> Bool {
        errno = 0
        if Darwin.kill(-processGroupID, 0) == 0 { return true }
        return errno == EPERM
    }

    func send(signal: Int32, toProcessGroup processGroupID: Int32) throws {
        guard processGroupID > 1 else {
            throw DevBerthError.unexpected("Refused to signal invalid process group \(processGroupID).")
        }
        errno = 0
        guard Darwin.kill(-processGroupID, signal) == 0 else {
            if errno == ESRCH { return }
            throw DevBerthError.commandFailed(
                command: "signal managed process group",
                status: Int32(errno),
                details: String(cString: strerror(errno))
            )
        }
    }

    func send(signal: Int32, toProcess pid: Int32) throws {
        guard pid > 1 else { throw DevBerthError.unexpected("Refused to signal invalid PID \(pid).") }
        errno = 0
        guard Darwin.kill(pid, signal) == 0 else {
            if errno == ESRCH { return }
            throw DevBerthError.commandFailed(
                command: "signal managed process",
                status: Int32(errno),
                details: String(cString: strerror(errno))
            )
        }
    }
}

struct SystemProcessGroupInspector: ProcessGroupInspecting, Sendable {
    private let runner: any CommandRunning
    private let processInspector: any ProcessInspecting
    private let clock: @Sendable () -> Date

    init(
        runner: any CommandRunning,
        processInspector: (any ProcessInspecting)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.runner = runner
        self.processInspector = processInspector ?? SystemProcessInspector(runner: runner)
        self.clock = clock
    }

    func snapshot(
        for runtime: ManagedRuntimeHandle,
        listenerOwnerPIDs: Set<Int32> = []
    ) async throws -> ProcessGroupSnapshot {
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-axww", "-o", "pid=", "-o", "pgid=", "-o", "ppid=", "-o", "state="],
            environment: ["LC_ALL": "C"],
            currentDirectory: nil
        )
        guard result.exitCode == 0 else {
            throw DevBerthError.commandFailed(
                command: "process group inspection",
                status: result.exitCode,
                details: result.stderrString
            )
        }

        let topology = Self.parseTopology(result.stdoutString)
        let descendants = Self.descendantPIDs(of: runtime.leaderFingerprint.pid, in: topology)
        let relevant = topology.filter {
            $0.processGroupID == runtime.processGroupID
                || descendants.contains($0.pid)
                || $0.pid == runtime.leaderFingerprint.pid
        }
        guard relevant.count <= 256 else {
            throw DevBerthError.unexpected(
                "Process group \(runtime.processGroupID) contains more than 256 relevant processes. DevBerth refused to inspect or signal an unbounded group."
            )
        }
        let inspections = await inspect(relevant.map(\.pid))
        let capturedAt = clock()
        let members = relevant.map { entry in
            let fingerprint = inspections[entry.pid]?.fingerprint ?? ProcessFingerprint(
                pid: entry.pid,
                executablePath: nil,
                startTime: nil,
                parentPID: entry.parentPID,
                detectedAt: capturedAt
            )
            let isInControlledGroup = entry.processGroupID == runtime.processGroupID
            let role: ProcessGroupMemberRole
            if entry.pid == runtime.leaderFingerprint.pid {
                role = .leader
            } else if listenerOwnerPIDs.contains(entry.pid) {
                role = .listenerOwner
            } else if descendants.contains(entry.pid) {
                role = isInControlledGroup ? .descendant : .escapedDescendant
            } else {
                role = .groupMember
            }
            return ProcessGroupMemberSnapshot(
                fingerprint: fingerprint,
                processGroupID: entry.processGroupID,
                role: role,
                isInControlledGroup: isInControlledGroup,
                isZombie: entry.state == "Z"
            )
        }

        return ProcessGroupSnapshot(
            runtimeID: runtime.id,
            managedServiceID: runtime.managedServiceID,
            processGroupID: runtime.processGroupID,
            leaderFingerprint: runtime.leaderFingerprint,
            members: members,
            capturedAt: capturedAt
        )
    }

    struct TopologyEntry: Equatable, Sendable {
        let pid: Int32
        let processGroupID: Int32
        let parentPID: Int32
        let state: String
    }

    static func parseTopology(_ output: String) -> [TopologyEntry] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard
                fields.count == 4,
                let pid = Int32(fields[0]),
                let processGroupID = Int32(fields[1]),
                let parentPID = Int32(fields[2])
            else { return nil }
            return TopologyEntry(
                pid: pid,
                processGroupID: processGroupID,
                parentPID: parentPID,
                state: String(fields[3].prefix(1))
            )
        }
    }

    static func descendantPIDs(of rootPID: Int32, in topology: [TopologyEntry]) -> Set<Int32> {
        let children = Dictionary(grouping: topology, by: \.parentPID)
        var descendants = Set<Int32>()
        var pending = [rootPID]
        while let parent = pending.popLast() {
            for child in children[parent] ?? [] where descendants.insert(child.pid).inserted {
                pending.append(child.pid)
            }
        }
        return descendants
    }

    private func inspect(_ pids: [Int32]) async -> [Int32: ProcessInspection] {
        await withTaskGroup(of: (Int32, ProcessInspection?).self) { group in
            for pid in pids {
                group.addTask {
                    (pid, try? await processInspector.inspect(pid: pid))
                }
            }
            var byPID: [Int32: ProcessInspection] = [:]
            for await (pid, inspection) in group {
                if let inspection { byPID[pid] = inspection }
            }
            return byPID
        }
    }
}
