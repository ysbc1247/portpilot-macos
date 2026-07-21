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
