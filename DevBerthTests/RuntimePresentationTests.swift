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

