import XCTest
@testable import DevBerth

final class RuntimePresentationTests: XCTestCase {
    func testSavedViewsSeparateObservedManagedAndExternallyReachableListeners() {
        let observed = makeListener(port: 3000, pid: 30)
        let managed = listener(port: 4000, pid: 40, managedServiceID: UUID())
        let wildcard = listener(port: 5000, pid: 50, address: "*")

        XCTAssertTrue(RuntimeSavedView.all.includes(observed, unhealthyServiceIDs: []))
        XCTAssertTrue(RuntimeSavedView.unexpected.includes(observed, unhealthyServiceIDs: []))
        XCTAssertFalse(RuntimeSavedView.unexpected.includes(managed, unhealthyServiceIDs: []))
        XCTAssertTrue(RuntimeSavedView.managed.includes(managed, unhealthyServiceIDs: []))
        XCTAssertFalse(RuntimeSavedView.externallyReachable.includes(observed, unhealthyServiceIDs: []))
        XCTAssertTrue(RuntimeSavedView.externallyReachable.includes(wildcard, unhealthyServiceIDs: []))
    }

    func testUnhealthyViewRequiresManagedRuntimeEvidence() throws {
        let serviceID = UUID()
        let managed = listener(port: 4000, pid: 40, managedServiceID: serviceID)
        let observed = makeListener(port: 3000, pid: 30)

        XCTAssertTrue(RuntimeSavedView.unhealthy.includes(managed, unhealthyServiceIDs: [serviceID]))
        XCTAssertFalse(RuntimeSavedView.unhealthy.includes(managed, unhealthyServiceIDs: []))
        XCTAssertFalse(RuntimeSavedView.unhealthy.includes(observed, unhealthyServiceIDs: [serviceID]))
    }

    func testUnresolvedOwnershipUsesHonestObservationLabels() {
        let observed = makeListener(port: 3000, pid: 30)
        let managed = listener(port: 4000, pid: 40, managedServiceID: UUID())

        XCTAssertEqual(RuntimePresentation.ownershipTitle(for: observed, resolved: nil), "Observed host process")
        XCTAssertEqual(RuntimePresentation.ownershipTitle(for: managed, resolved: nil), "DevBerth managed process")
    }

    func testManagedServiceActivitySeparatesControlledAndObservedEvidence() {
        let serviceID = UUID()
        let profile = ManagedServiceConfiguration(
            id: serviceID,
            name: "Web",
            command: "web",
            workingDirectory: "/tmp",
            expectedPorts: [
                ExpectedListenerConfiguration(id: UUID(), port: 3000, protocolKind: .tcp, required: true),
                ExpectedListenerConfiguration(id: UUID(), port: 3001, protocolKind: .tcp, required: true)
            ]
        )
        let observed = ManagedServiceActivityResolver.resolve(
            profile: profile,
            listeners: [listener(port: 3000, pid: 30)],
            runningProfileIDs: [],
            runtimeStatus: nil
        )
        XCTAssertEqual(observed.state, .observed)
        XCTAssertEqual(observed.openExpectedPortCount, 1)
        XCTAssertEqual(observed.expectedPortCount, 2)
        XCTAssertTrue(observed.isActive)
        XCTAssertFalse(observed.isControlled)

        let controlled = ManagedServiceActivityResolver.resolve(
            profile: profile,
            listeners: [],
            runningProfileIDs: [serviceID],
            runtimeStatus: nil
        )
        XCTAssertEqual(controlled.state, .controlled)
        XCTAssertTrue(controlled.isControlled)

        let stopped = ManagedServiceActivityResolver.resolve(
            profile: profile,
            listeners: [listener(port: 3999, pid: 31, address: "127.0.0.1", managedServiceID: nil)],
            runningProfileIDs: [],
            runtimeStatus: nil
        )
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertFalse(stopped.isActive)
    }

    @MainActor
    func testObservedServiceStopRequiresConfirmationAndDeduplicatesProcessTargets() async {
        let first = listener(port: 3000, pid: 30)
        let second = ObservedListener(
            protocolKind: .tcp,
            address: first.address,
            port: 3001,
            process: first.process,
            firstDetectedAt: first.firstDetectedAt,
            lastDetectedAt: first.lastDetectedAt
        )
        let router = RecordingObservedStopRouter()
        let model = AppModel(
            discoverer: FixedRuntimeDiscoverer(listeners: [first, second]),
            ownershipResolver: ObservedStopOwnershipResolver(),
            lifecycleRouter: router
        )
        model.refreshInterval = 0.01
        model.startMonitoring()
        defer { model.pauseMonitoring() }
        for _ in 0..<100 where model.listeners.count != 2 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let profile = ManagedServiceConfiguration(
            name: "Web",
            command: "web",
            workingDirectory: "/tmp",
            expectedPorts: [
                ExpectedListenerConfiguration(id: UUID(), port: 3000, protocolKind: .tcp, required: true),
                ExpectedListenerConfiguration(id: UUID(), port: 3001, protocolKind: .tcp, required: true)
            ]
        )

        XCTAssertEqual(model.observedServiceStopTargets(for: profile).count, 1)

        await model.stopProfile(profile)

        let actionsBeforeConfirmation = await router.actions()
        XCTAssertTrue(actionsBeforeConfirmation.isEmpty)
        XCTAssertEqual(model.serviceOperations[profile.id]?.phase, .failed)
        XCTAssertTrue(model.serviceOperations[profile.id]?.message.contains("Confirm") == true)

        await model.stopProfile(profile, confirmsObservedProcess: true)

        let actionsAfterConfirmation = await router.actions()
        XCTAssertEqual(actionsAfterConfirmation, [.gracefulStop])
        XCTAssertEqual(model.serviceOperations[profile.id]?.phase, .succeeded)
        XCTAssertEqual(model.serviceOperations[profile.id]?.completedTargetCount, 1)
    }

    func testLifecycleHistoryPresentationIndexesLargeContextSetAndFilters() {
        let selectedID = UUID()
        var events: [LifecycleHistoryEventSnapshot] = []
        events.reserveCapacity(5_000)
        for index in 0..<5_000 {
            let isSelected = index == 4_999
            let event = LifecycleHistoryEventSnapshot(
                id: isSelected ? selectedID : UUID(),
                timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                managedServiceID: nil,
                categoryRawValue: isSelected ? "healthChanged" : "ready",
                outcomeRawValue: "succeeded",
                summary: isSelected ? "Selected degraded service" : "Ready"
            )
            events.append(event)
        }
        let contexts = events.map {
            LifecycleHistoryContextSnapshot(
                lifecycleEventID: $0.id,
                severityRawValue: $0.id == selectedID ? LifecycleEventSeverity.warning.rawValue : LifecycleEventSeverity.info.rawValue,
                sourceRawValue: LifecycleEventSource.health.rawValue
            )
        }

        let rows = LifecycleHistoryPresentation.rows(
            events: events,
            contexts: contexts,
            severity: .warning,
            cutoff: nil,
            searchText: "degraded"
        )

        XCTAssertEqual(rows.map { $0.id }, [selectedID])
        XCTAssertEqual(rows.first?.severityRawValue, LifecycleEventSeverity.warning.rawValue)
        XCTAssertEqual(rows.first?.sourceRawValue, LifecycleEventSource.health.rawValue)

        let unfilteredRows = LifecycleHistoryPresentation.rows(
            events: events,
            contexts: contexts,
            severity: nil,
            cutoff: nil,
            searchText: "   \n"
        )
        XCTAssertEqual(unfilteredRows.count, events.count)
    }

    private func listener(
        port: UInt16,
        pid: Int32,
        address: String = "127.0.0.1",
        managedServiceID: UUID? = nil
    ) -> ObservedListener {
        let base = makeProcess(pid: pid)
        let process = ObservedProcess(
            fingerprint: base.fingerprint,
            name: base.name,
            commandLine: base.commandLine,
            owner: base.owner,
            currentDirectory: base.currentDirectory,
            parentName: base.parentName,
            runtime: base.runtime,
            project: base.project,
            isSystemProcess: base.isSystemProcess,
            docker: base.docker,
            launchedByDevBerth: managedServiceID != nil,
            managedServiceID: managedServiceID
        )
        return ObservedListener(
            protocolKind: .tcp,
            address: address,
            port: port,
            process: process,
            firstDetectedAt: Date(timeIntervalSince1970: 100),
            lastDetectedAt: Date(timeIntervalSince1970: 200)
        )
    }
}

private actor FixedRuntimeDiscoverer: PortDiscovering {
    let listeners: [ObservedListener]
    init(listeners: [ObservedListener]) { self.listeners = listeners }
    func discover() async throws -> [ObservedListener] { listeners }
}

private struct ObservedStopOwnershipResolver: RuntimeOwnershipResolving {
    func resolve(listener: ObservedListener) async -> RuntimeOwnershipGraph {
        RuntimeOwnershipGraph(
            listenerID: listener.id,
            listener: listener,
            processGroupID: nil,
            processLineage: [],
            primaryConclusion: OwnershipConclusion(
                subject: .listener(id: listener.id),
                category: .standaloneHostProcess,
                value: listener.process.name,
                confidence: .verified,
                evidence: [],
                detectionMethod: .commandSignature
            ),
            additionalConclusions: [],
            managedRuntimeID: nil,
            managedServiceID: nil,
            managedConfigurationDigest: nil,
            projectID: nil,
            workspaceSessionIDs: [],
            recommendation: OwnershipActionRecommendation(
                controllerKind: .guardedExternalProcess,
                title: "Stop exact process",
                reason: "Test fixture",
                supportedActions: [.inspect, .gracefulStop]
            ),
            resolvedAt: Date()
        )
    }
}

private actor RecordingObservedStopRouter: OwnerAwareLifecycleRouting {
    private var recordedActions: [LifecycleActionKind] = []

    func perform(
        _ action: LifecycleActionKind,
        on graph: RuntimeOwnershipGraph,
        forceConfirmed: Bool
    ) async throws -> OwnerAwareLifecycleResult {
        recordedActions.append(action)
        return OwnerAwareLifecycleResult(
            controllerKind: graph.recommendation.controllerKind,
            action: action,
            didStop: true,
            summary: "Stopped fixture",
            durationSeconds: 0
        )
    }

    func actions() -> [LifecycleActionKind] { recordedActions }
}
