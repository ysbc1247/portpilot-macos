import Darwin
import DevBerthControlContracts
import Foundation

actor DevelopmentFixtureController: PortDiscovering {
    struct FixtureDefinition: Sendable {
        let name: String
        let summary: String
    }

    final class FixtureHandle: @unchecked Sendable {
        let id: UUID
        let name: String
        let pid: Int32
        var processGroupIDs: Set<Int32>
        let ports: [UInt16]
        let startedAt: Date
        let standardOutput: FileHandle
        let standardError: FileHandle

        init(id: UUID, name: String, process: SpawnedManagedProcess, ports: [UInt16], additionalGroups: Set<Int32>) {
            self.id = id
            self.name = name
            pid = process.pid
            processGroupIDs = additionalGroups.union([process.processGroupID])
            self.ports = ports
            startedAt = Date()
            standardOutput = process.standardOutput
            standardError = process.standardError
        }
    }

    static let definitions: [FixtureDefinition] = [
        .init(name: "simple_tcp_listener", summary: "One loopback TCP listener."),
        .init(name: "simple_http_service", summary: "Loopback HTTP service with /health."),
        .init(name: "udp_listener", summary: "One loopback UDP listener."),
        .init(name: "multiple_listeners", summary: "One process with multiple TCP listeners."),
        .init(name: "delayed_readiness", summary: "HTTP listener that becomes available after a bounded delay."),
        .init(name: "failed_readiness", summary: "Process that reports deterministic readiness failure."),
        .init(name: "immediate_exit", summary: "Process that exits immediately."),
        .init(name: "sigterm_ignored", summary: "HTTP listener that ignores SIGTERM for escalation tests."),
        .init(name: "parent_supervisor_respawn", summary: "Supervisor and child in an owned process group."),
        .init(name: "detached_child", summary: "Supervisor with a separately tracked detached child."),
        .init(name: "port_conflict", summary: "Listener occupying a selected test port."),
        .init(name: "dependency_failure", summary: "Process that reports deterministic dependency failure."),
        .init(name: "docker_unavailable_simulation", summary: "State-only Docker unavailable simulation."),
        .init(name: "pid_reuse_simulation", summary: "State-only stale fingerprint simulation.")
    ]

    private let spawner: any ControlledProcessSpawning = POSIXControlledProcessSpawner()
    private let discovery = LocalPortDiscovery(runner: FoundationCommandRunner(), includeProjectInference: false)
    private var handles: [UUID: FixtureHandle] = [:]
    private var simulated: [UUID: (name: String, startedAt: Date)] = [:]

    func list() -> [JSONValue] {
        Self.definitions.map { definition in
            let active = handles.values.filter { $0.name == definition.name }.count
                + simulated.values.filter { $0.name == definition.name }.count
            return .object([
                "name": .string(definition.name), "summary": .string(definition.summary),
                "active_instances": .number(Double(active))
            ])
        }
    }

    func discover() async throws -> [ObservedListener] {
        let ownedPIDs = Set(handles.values.map(\.pid))
        guard !ownedPIDs.isEmpty else { return [] }
        return try await discovery.discover(allowedProcessIDs: ownedPIDs)
    }

    func ownedProcessIDs() -> Set<Int32> {
        Set(handles.values.map(\.pid))
    }

    func fixtureID(owningProcess pid: Int32) -> UUID? {
        handles.first { $0.value.pid == pid }.map(\.key)
    }

    func isActive(name: String) -> Bool {
        handles.values.contains { $0.name == name } || simulated.values.contains { $0.name == name }
    }

    func state() -> JSONValue {
        .object([
            "active": .array(handles.values.sorted { $0.startedAt < $1.startedAt }.map(handleValue)),
            "simulated": .array(simulated.map { id, value in .object([
                "fixture_id": .string(id.uuidString), "name": .string(value.name),
                "started_at": .string(value.startedAt.ISO8601Format()), "state": .string("simulated")
            ]) })
        ])
    }

    func start(name: String, requestedPort: UInt16?) async throws -> JSONValue {
        guard Self.definitions.contains(where: { $0.name == name }) else {
            throw ControlFailure(code: .invalidArguments, message: "Unknown development fixture \(name).")
        }
        if name == "docker_unavailable_simulation" || name == "pid_reuse_simulation" {
            let id = UUID()
            simulated[id] = (name, Date())
            return .object(["fixture_id": .string(id.uuidString), "name": .string(name), "state": .string("simulated")])
        }

        let selectedPort = requestedPort ?? 0
        let launch = try launchArguments(name: name, port: selectedPort)
        let process = try spawner.spawn(ControlledProcessLaunchRequest(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-u", launch.script.path] + launch.arguments,
            environment: ["PATH": "/usr/bin:/bin", "PYTHONUNBUFFERED": "1"],
            workingDirectory: launch.script.deletingLastPathComponent(),
            createsDedicatedProcessGroup: true
        ))
        let output = try await readInitialOutput(process.standardOutput)
        var ports = launch.expectedPorts
        var additionalGroups = Set<Int32>()
        for line in output.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let discovered = object["ports"] as? [Int] { ports = discovered.compactMap(UInt16.init(exactly:)) }
            if let port = object["port"] as? Int, let value = UInt16(exactly: port) { ports = [value] }
            if let child = object["child_pid"] as? Int, name == "detached_child" { additionalGroups.insert(Int32(child)) }
        }
        let id = UUID()
        let handle = FixtureHandle(id: id, name: name, process: process, ports: ports, additionalGroups: additionalGroups)
        handles[id] = handle

        if ["failed_readiness", "immediate_exit", "dependency_failure"].contains(name) {
            try await stop(id: id)
            return .object([
                "fixture_id": .string(id.uuidString), "name": .string(name),
                "state": .string("completed_expected"), "initial_output": .string(output.prefix(2_000).description)
            ])
        }
        guard Darwin.kill(process.pid, 0) == 0 else {
            handles.removeValue(forKey: id)
            throw ControlFailure(code: .internalError, message: "Fixture \(name) exited before readiness: \(output.prefix(2_000))")
        }
        return handleValue(handle)
    }

    func stop(id: UUID) async throws {
        if simulated.removeValue(forKey: id) != nil { return }
        guard let handle = handles.removeValue(forKey: id) else {
            throw ControlFailure(code: .entityNotFound, message: "No application-owned fixture exists with ID \(id.uuidString).")
        }
        for group in handle.processGroupIDs where group > 1 {
            if group == handle.pid {
                guard Darwin.kill(handle.pid, 0) == 0, Darwin.getpgid(handle.pid) == group else { continue }
            }
            _ = Darwin.kill(-group, SIGTERM)
        }
        await Task.detached {
            for _ in 0..<20 {
                if Darwin.kill(handle.pid, 0) != 0 { return }
                usleep(50_000)
            }
            for group in handle.processGroupIDs where group > 1 {
                if group != handle.pid || Darwin.getpgid(handle.pid) == group { _ = Darwin.kill(-group, SIGKILL) }
            }
        }.value
    }

    func stopAll() async {
        for id in Array(handles.keys) { try? await stop(id: id) }
        simulated.removeAll()
    }

    private func handleValue(_ handle: FixtureHandle) -> JSONValue {
        .object([
            "fixture_id": .string(handle.id.uuidString), "name": .string(handle.name),
            "pid": .number(Double(handle.pid)),
            "process_group_ids": .array(handle.processGroupIDs.sorted().map { .number(Double($0)) }),
            "ports": .array(handle.ports.map { .number(Double($0)) }),
            "started_at": .string(handle.startedAt.ISO8601Format()), "state": .string("running")
        ])
    }

    private func launchArguments(name: String, port: UInt16) throws -> (script: URL, arguments: [String], expectedPorts: [UInt16]) {
        switch name {
        case "simple_http_service":
            return (try script("http_fixture"), ["--port", String(port)], [port])
        case "delayed_readiness":
            return (try script("http_fixture"), ["--port", String(port), "--delay", "1.0", "--health-delay", "0.5"], [port])
        case "sigterm_ignored":
            return (try script("http_fixture"), ["--port", String(port), "--ignore-term"], [port])
        case "multiple_listeners":
            let second = nextPort(excluding: [port])
            return (try script("multi_port_fixture"), ["--ports", "\(port),\(second)"], [port, second])
        case "parent_supervisor_respawn":
            return (try script("process_tree_fixture"), ["--mode", "restart", "--marker", UUID().uuidString], [])
        case "detached_child":
            return (try script("process_tree_fixture"), ["--mode", "detach", "--marker", UUID().uuidString], [])
        case "simple_tcp_listener", "port_conflict":
            return (try script("network_fixture"), ["--mode", "tcp", "--port", String(port)], [port])
        case "udp_listener":
            return (try script("network_fixture"), ["--mode", "udp", "--port", String(port)], [port])
        case "failed_readiness":
            return (try script("network_fixture"), ["--mode", "failed-readiness"], [])
        case "immediate_exit":
            return (try script("network_fixture"), ["--mode", "immediate-exit"], [])
        case "dependency_failure":
            return (try script("network_fixture"), ["--mode", "dependency-failure"], [])
        default:
            throw ControlFailure(code: .unsupportedCapability, message: "Fixture \(name) has no launcher.")
        }
    }

    private func script(_ name: String) throws -> URL {
        guard let url = Bundle.main.url(forResource: name, withExtension: "py") else {
            throw ControlFailure(code: .internalError, message: "Bundled development fixture \(name).py is missing.")
        }
        return url
    }

    private func readInitialOutput(_ handle: FileHandle) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
                let status = Darwin.poll(&descriptor, 1, 5_000)
                guard status >= 0 else {
                    continuation.resume(throwing: ControlFailure(
                        code: .internalError,
                        message: "The fixture readiness pipe failed: \(String(cString: strerror(errno)))."
                    ))
                    return
                }
                guard status > 0 else {
                    continuation.resume(throwing: ControlFailure(
                        code: .timeout,
                        message: "The fixture did not announce readiness within five seconds."
                    ))
                    return
                }
                var buffer = [UInt8](repeating: 0, count: 8_192)
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count)
                }
                guard count >= 0 else {
                    continuation.resume(throwing: ControlFailure(
                        code: .internalError,
                        message: "The fixture readiness output could not be read: \(String(cString: strerror(errno)))."
                    ))
                    return
                }
                continuation.resume(returning: String(decoding: buffer.prefix(count), as: UTF8.self))
            }
        }
    }

    private func nextPort(excluding: Set<UInt16> = []) -> UInt16 {
        let used = Set(handles.values.flatMap(\.ports)).union(excluding)
        for port in UInt16(42_000)...UInt16(49_999) where !used.contains(port) { return port }
        return 49_999
    }
}

actor DevelopmentScopedPortDiscoverer: PortDiscovering {
    private let fixtures: DevelopmentFixtureController
    private let runtimeRegistry: ManagedRuntimeRegistry
    private let discovery = LocalPortDiscovery(runner: FoundationCommandRunner(), includeProjectInference: false)

    init(fixtures: DevelopmentFixtureController, runtimeRegistry: ManagedRuntimeRegistry) {
        self.fixtures = fixtures
        self.runtimeRegistry = runtimeRegistry
    }

    func discover() async throws -> [ObservedListener] {
        var allowedPIDs = await fixtures.ownedProcessIDs()
        for registration in await runtimeRegistry.activeRegistrations() {
            allowedPIDs.insert(registration.runtime.leaderFingerprint.pid)
            allowedPIDs.formUnion(registration.latestSnapshot.members.map { $0.fingerprint.pid })
        }
        guard !allowedPIDs.isEmpty else { return [] }
        return try await discovery.discover(allowedProcessIDs: allowedPIDs)
    }
}
