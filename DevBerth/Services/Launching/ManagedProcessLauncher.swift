import Darwin
import Foundation

actor ManagedProcessLauncher: ManagedProcessLaunching {
    private struct ManagedProcess {
        let runtime: ManagedRuntimeHandle
        let profile: ManagedServiceConfiguration
        let expectedPorts: [ExpectedListenerConfiguration]
        let standardOutput: FileHandle
        let standardError: FileHandle
        var knownFingerprints: [Int32: ProcessFingerprint]
        var latestSnapshot: ProcessGroupSnapshot
        var leaderExitStatus: Int32?
        var stopRequested: Bool
    }

    private let secrets: any SecretStoring
    private let logs: ServiceLogBuffer
    private let resolver: ExecutableResolver
    private let spawner: any ControlledProcessSpawning
    private let processInspector: any ProcessInspecting
    private let fingerprintVerifier: any ProcessFingerprintVerifying
    private let groupInspector: any ProcessGroupInspecting
    private let groupOperator: any ProcessGroupOperating
    private let listenerDiscoverer: any PortDiscovering
    private let runtimeRegistry: ManagedRuntimeRegistry
    private let lifecycle: any RuntimeLifecycleObserving
    private let exitObserver: any ManagedProcessExitObserving
    private var running: [UUID: ManagedProcess] = [:]

    init(
        secrets: any SecretStoring,
        logs: ServiceLogBuffer,
        runner: any CommandRunning = FoundationCommandRunner(),
        resolver: ExecutableResolver = ExecutableResolver(),
        spawner: any ControlledProcessSpawning = POSIXControlledProcessSpawner(),
        processInspector: (any ProcessInspecting)? = nil,
        fingerprintVerifier: (any ProcessFingerprintVerifying)? = nil,
        groupInspector: (any ProcessGroupInspecting)? = nil,
        groupOperator: any ProcessGroupOperating = DarwinProcessGroupOperator(),
        listenerDiscoverer: (any PortDiscovering)? = nil,
        runtimeRegistry: ManagedRuntimeRegistry = ManagedRuntimeRegistry(),
        lifecycle: (any RuntimeLifecycleObserving)? = nil,
        exitObserver: (any ManagedProcessExitObserving)? = nil
    ) {
        let resolvedProcessInspector = processInspector ?? SystemProcessInspector(runner: runner)
        self.secrets = secrets
        self.logs = logs
        self.resolver = resolver
        self.spawner = spawner
        self.processInspector = resolvedProcessInspector
        self.fingerprintVerifier = fingerprintVerifier ?? ProcessFingerprintVerifier(inspector: resolvedProcessInspector)
        self.groupInspector = groupInspector ?? SystemProcessGroupInspector(
            runner: runner,
            processInspector: resolvedProcessInspector
        )
        self.groupOperator = groupOperator
        self.listenerDiscoverer = listenerDiscoverer ?? LocalPortDiscovery(
            runner: runner,
            includeProjectInference: false
        )
        self.runtimeRegistry = runtimeRegistry
        self.lifecycle = lifecycle ?? RuntimeLifecycleTracker()
        self.exitObserver = exitObserver ?? ManagedProcessExitHub()
    }

    func launch(_ profile: ManagedServiceConfiguration) async throws {
        guard profile.isReviewed else {
            throw DevBerthError.launchValidation("Review inferred command fields before launching this profile.")
        }
        guard running[profile.id] == nil else {
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
            guard let resolved = resolver.resolve(
                profile.command,
                environment: environment,
                workingDirectory: profile.workingDirectory
            ) else {
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

        let spawned: SpawnedManagedProcess
        do {
            spawned = try spawner.spawn(ControlledProcessLaunchRequest(
                executable: executable,
                arguments: arguments,
                environment: environment,
                workingDirectory: URL(fileURLWithPath: profile.workingDirectory, isDirectory: true),
                createsDedicatedProcessGroup: profile.processPolicy.createsDedicatedProcessGroup
            ))
        } catch {
            throw DevBerthError.unexpected("\(profile.name) could not start: \(error.localizedDescription)")
        }

        installLogReaders(for: profile.id, process: spawned)
        do {
            let fingerprint = try await captureStrongFingerprint(pid: spawned.pid)
            guard groupOperator.processGroupID(for: spawned.pid) == spawned.processGroupID else {
                throw DevBerthError.processFingerprintChanged("The new process did not remain in its assigned process group.")
            }
            let runtime = ManagedRuntimeHandle(
                id: UUID(),
                managedServiceID: profile.id,
                leaderFingerprint: fingerprint,
                processGroupID: spawned.processGroupID,
                processPolicy: profile.processPolicy,
                launchedAt: Date()
            )
            try await Task.sleep(for: .milliseconds(50))
            let snapshot = try await groupInspector.snapshot(for: runtime, listenerOwnerPIDs: [])
            var knownFingerprints = Dictionary(uniqueKeysWithValues: snapshot.controlledMembers
                .filter { $0.fingerprint.isStrong }
                .map { ($0.fingerprint.pid, $0.fingerprint) })
            knownFingerprints[fingerprint.pid] = fingerprint
            running[profile.id] = ManagedProcess(
                runtime: runtime,
                profile: profile,
                expectedPorts: profile.expectedPorts,
                standardOutput: spawned.standardOutput,
                standardError: spawned.standardError,
                knownFingerprints: knownFingerprints,
                latestSnapshot: snapshot,
                leaderExitStatus: nil,
                stopRequested: false
            )
            await runtimeRegistry.register(runtime: runtime, configuration: profile, snapshot: snapshot)
            await lifecycle.transition(.processSpawned(runtime, profile))
            startExitWatcher(profileID: profile.id, pid: spawned.pid)
            await logs.append(
                profileID: profile.id,
                stream: .internalMessage,
                data: Data(
                    "Started PID \(spawned.pid) in controlled process group \(spawned.processGroupID) with \(executable.path).".utf8
                )
            )
        } catch {
            spawned.standardOutput.readabilityHandler = nil
            spawned.standardError.readabilityHandler = nil
            try? groupOperator.send(signal: SIGKILL, toProcessGroup: spawned.processGroupID)
            Self.reap(pid: spawned.pid)
            throw error
        }
    }

    func stop(profileID: UUID, timeoutSeconds: Double) async throws {
        guard var managed = running[profileID] else { return }
        managed.stopRequested = true
        running[profileID] = managed
        await lifecycle.transition(.stopping(
            serviceID: profileID,
            runtimeID: managed.runtime.id,
            reason: "Graceful managed shutdown requested."
        ))
        let listenerOwnerPIDs = await currentListenerOwnerPIDs(for: managed)
        let snapshot = try await groupInspector.snapshot(
            for: managed.runtime,
            listenerOwnerPIDs: listenerOwnerPIDs
        )
        guard !snapshot.liveControlledMembers.isEmpty else {
            if let removed = await remove(profileID: profileID) {
                await lifecycle.transition(.stopped(
                    serviceID: profileID,
                    runtimeID: removed.runtime.id,
                    reason: "Managed process scope was already stopped."
                ))
            }
            return
        }

        try await validateOwnership(of: managed, current: snapshot)
        for member in snapshot.liveControlledMembers where member.fingerprint.isStrong {
            managed.knownFingerprints[member.fingerprint.pid] = member.fingerprint
        }
        managed.latestSnapshot = snapshot
        running[profileID] = managed
        await runtimeRegistry.update(snapshot: snapshot, forServiceID: profileID)

        switch managed.runtime.processPolicy.terminationScope {
        case .controlledProcessGroup:
            try groupOperator.send(signal: SIGTERM, toProcessGroup: managed.runtime.processGroupID)
        case .rootProcessOnly:
            try groupOperator.send(signal: SIGTERM, toProcess: managed.runtime.leaderFingerprint.pid)
        }

        let deadline = Date().addingTimeInterval(max(0.2, timeoutSeconds))
        while Date() < deadline {
            if try await managedScopeHasStopped(managed) {
                if let removed = await remove(profileID: profileID) {
                    await lifecycle.transition(.stopped(
                        serviceID: profileID,
                        runtimeID: removed.runtime.id,
                        reason: "Managed process scope stopped gracefully."
                    ))
                }
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        let forceListenerOwnerPIDs = await currentListenerOwnerPIDs(for: managed)
        let forceSnapshot = try await groupInspector.snapshot(
            for: managed.runtime,
            listenerOwnerPIDs: forceListenerOwnerPIDs
        )
        guard !forceSnapshot.liveControlledMembers.isEmpty else {
            if let removed = await remove(profileID: profileID) {
                await lifecycle.transition(.stopped(
                    serviceID: profileID,
                    runtimeID: removed.runtime.id,
                    reason: "Managed process scope stopped after its graceful timeout."
                ))
            }
            return
        }
        try await validateOwnership(of: managed, current: forceSnapshot)
        for member in forceSnapshot.liveControlledMembers where member.fingerprint.isStrong {
            managed.knownFingerprints[member.fingerprint.pid] = member.fingerprint
        }
        managed.latestSnapshot = forceSnapshot
        running[profileID] = managed
        await runtimeRegistry.update(snapshot: forceSnapshot, forServiceID: profileID)

        switch managed.runtime.processPolicy.terminationScope {
        case .controlledProcessGroup:
            try groupOperator.send(signal: SIGKILL, toProcessGroup: managed.runtime.processGroupID)
        case .rootProcessOnly:
            try groupOperator.send(signal: SIGKILL, toProcess: managed.runtime.leaderFingerprint.pid)
        }

        let forceDeadline = Date().addingTimeInterval(2)
        while Date() < forceDeadline {
            if try await managedScopeHasStopped(managed) {
                if let removed = await remove(profileID: profileID) {
                    await lifecycle.transition(.stopped(
                        serviceID: profileID,
                        runtimeID: removed.runtime.id,
                        reason: "Managed process scope required force escalation after a revalidated graceful timeout."
                    ))
                }
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw DevBerthError.unexpected(
            "The managed \(managed.runtime.processPolicy.terminationScope == .controlledProcessGroup ? "process group" : "root process") remained active after revalidated graceful and force stop attempts."
        )
    }

    func runtimeHandle(profileID: UUID) -> ManagedRuntimeHandle? {
        running[profileID]?.runtime
    }

    func processGroupSnapshot(profileID: UUID) -> ProcessGroupSnapshot? {
        running[profileID]?.latestSnapshot
    }

    private func captureStrongFingerprint(pid: Int32) async throws -> ProcessFingerprint {
        var previous: ProcessFingerprint?
        var matchingIntervals = 0
        for _ in 0..<80 {
            if let inspection = try await processInspector.inspect(pid: pid), inspection.fingerprint.isStrong {
                let current = inspection.fingerprint
                if let previous,
                   ProcessFingerprintVerifier.differences(expected: previous, actual: current).isEmpty,
                   ProcessFingerprintVerifier.differences(expected: current, actual: previous).isEmpty {
                    matchingIntervals += 1
                    if matchingIntervals >= 8 { return current }
                } else {
                    matchingIntervals = 0
                }
                previous = current
            } else {
                previous = nil
                matchingIntervals = 0
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw DevBerthError.processFingerprintChanged(
            "DevBerth could not capture a strong fingerprint that remained stable after spawning PID \(pid). The launch was stopped."
        )
    }

    private func validateOwnership(
        of managed: ManagedProcess,
        current snapshot: ProcessGroupSnapshot
    ) async throws {
        guard snapshot.processGroupID == managed.runtime.processGroupID else {
            throw DevBerthError.processFingerprintChanged("The controlled process-group identifier changed.")
        }

        if let currentLeader = snapshot.liveControlledMembers.first(where: {
            $0.fingerprint.pid == managed.runtime.leaderFingerprint.pid
        }) {
            guard currentLeader.processGroupID == managed.runtime.processGroupID else {
                throw DevBerthError.processFingerprintChanged("The managed leader left its controlled process group.")
            }
            guard groupOperator.processGroupID(for: currentLeader.fingerprint.pid) == managed.runtime.processGroupID else {
                throw DevBerthError.processFingerprintChanged("The managed leader's current process group changed.")
            }
            let verification = try await fingerprintVerifier.verify(managed.runtime.leaderFingerprint)
            guard case .matched = verification else {
                throw DevBerthError.processFingerprintChanged(verification.explanation)
            }
            return
        }

        for member in snapshot.liveControlledMembers {
            guard let known = managed.knownFingerprints[member.fingerprint.pid] else { continue }
            guard groupOperator.processGroupID(for: member.fingerprint.pid) == managed.runtime.processGroupID else { continue }
            let verification = try await fingerprintVerifier.verify(known)
            if case .matched = verification { return }
        }
        throw DevBerthError.processFingerprintChanged(
            "The managed leader exited and no previously captured descendant still anchors ownership of process group \(managed.runtime.processGroupID). DevBerth did not signal the group."
        )
    }

    private func currentListenerOwnerPIDs(for managed: ManagedProcess) async -> Set<Int32> {
        let expected = Set(managed.expectedPorts.map { "\($0.protocolKind.rawValue):\($0.port)" })
        guard let listeners = try? await listenerDiscoverer.discover() else { return [] }
        return Set(listeners.compactMap { listener in
            expected.contains("\(listener.protocolKind.rawValue):\(listener.port)")
                ? listener.process.fingerprint.pid
                : nil
        })
    }

    private func managedScopeHasStopped(_ managed: ManagedProcess) async throws -> Bool {
        switch managed.runtime.processPolicy.terminationScope {
        case .controlledProcessGroup:
            guard groupOperator.processGroupExists(managed.runtime.processGroupID) else { return true }
            let remaining = try await groupInspector.snapshot(
                for: managed.runtime,
                listenerOwnerPIDs: []
            )
            return !remaining.liveControlledMembers.contains { $0.fingerprint.isStrong }
        case .rootProcessOnly:
            let verification = try await fingerprintVerifier.verify(managed.runtime.leaderFingerprint)
            if verification == .notFound { return true }
            if case .mismatched = verification { return true }
            return false
        }
    }

    private func installLogReaders(for profileID: UUID, process: SpawnedManagedProcess) {
        process.standardOutput.readabilityHandler = { [logs] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await logs.append(profileID: profileID, stream: .standardOutput, data: data) }
        }
        process.standardError.readabilityHandler = { [logs] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await logs.append(profileID: profileID, stream: .standardError, data: data) }
        }
    }

    private func startExitWatcher(profileID: UUID, pid: Int32) {
        Task.detached(priority: .utility) { [weak self] in
            var status: Int32 = 0
            let waitedPID = Darwin.waitpid(pid, &status, 0)
            guard waitedPID == pid else { return }
            await self?.leaderDidExit(profileID: profileID, pid: pid, status: status)
        }
    }

    private func leaderDidExit(profileID: UUID, pid: Int32, status: Int32) async {
        guard var managed = running[profileID], managed.runtime.leaderFingerprint.pid == pid else { return }
        managed.leaderExitStatus = status
        running[profileID] = managed
        await logs.append(
            profileID: profileID,
            stream: .internalMessage,
            data: Data(Self.exitDescription(status: status).utf8)
        )
        if managed.runtime.processPolicy.terminationScope == .rootProcessOnly
            || !groupOperator.processGroupExists(managed.runtime.processGroupID) {
            await completeExit(profileID: profileID, expectedRuntimeID: managed.runtime.id)
        } else {
            startGroupExitWatcher(profileID: profileID, runtimeID: managed.runtime.id)
        }
    }

    private func startGroupExitWatcher(profileID: UUID, runtimeID: UUID) {
        Task { [weak self] in
            guard let self else { return }
            for _ in 0..<3_600 {
                guard await self.isCurrentRuntime(profileID: profileID, runtimeID: runtimeID) else { return }
                guard await self.processGroupStillExists(profileID: profileID, runtimeID: runtimeID) else {
                    await self.completeExit(profileID: profileID, expectedRuntimeID: runtimeID)
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func isCurrentRuntime(profileID: UUID, runtimeID: UUID) -> Bool {
        running[profileID]?.runtime.id == runtimeID
    }

    private func processGroupStillExists(profileID: UUID, runtimeID: UUID) -> Bool {
        guard let managed = running[profileID], managed.runtime.id == runtimeID else { return false }
        return groupOperator.processGroupExists(managed.runtime.processGroupID)
    }

    private func completeExit(profileID: UUID, expectedRuntimeID: UUID) async {
        guard let managed = running[profileID], managed.runtime.id == expectedRuntimeID else { return }
        let result = Self.exitResult(status: managed.leaderExitStatus, at: Date())
        guard let removed = await remove(profileID: profileID) else { return }
        await lifecycle.transition(.exited(
            profile: removed.profile,
            runtime: removed.runtime,
            result: result,
            intentional: removed.stopRequested
        ))
        await exitObserver.managedProcessDidExit(ManagedProcessExitNotice(
            profile: removed.profile,
            runtime: removed.runtime,
            result: result,
            intentional: removed.stopRequested
        ))
    }

    @discardableResult
    private func remove(profileID: UUID) async -> ManagedProcess? {
        if let managed = running.removeValue(forKey: profileID) {
            managed.standardOutput.readabilityHandler = nil
            managed.standardError.readabilityHandler = nil
            await logs.finalize(profileID: profileID)
            await runtimeRegistry.remove(serviceID: profileID, runtimeID: managed.runtime.id)
            return managed
        }
        return nil
    }

    private static func reap(pid: Int32) {
        var status: Int32 = 0
        while Darwin.waitpid(pid, &status, 0) == -1 && errno == EINTR {}
    }

    private static func exitDescription(status: Int32) -> String {
        let signal = status & 0x7f
        if signal == 0 {
            return "Managed leader exited with status \((status >> 8) & 0xff)."
        }
        return "Managed leader exited after signal \(signal)."
    }

    private static func exitResult(status: Int32?, at date: Date) -> RuntimeExitResult {
        guard let status else {
            return RuntimeExitResult(
                exitedAt: date,
                exitCode: nil,
                signal: nil,
                reason: "The managed process scope ended."
            )
        }
        let signal = status & 0x7f
        if signal == 0 {
            let code = (status >> 8) & 0xff
            return RuntimeExitResult(
                exitedAt: date,
                exitCode: code,
                signal: nil,
                reason: "The managed leader exited with status \(code)."
            )
        }
        return RuntimeExitResult(
            exitedAt: date,
            exitCode: nil,
            signal: signal,
            reason: "The managed leader exited after signal \(signal)."
        )
    }
}
