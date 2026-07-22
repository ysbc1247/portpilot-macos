import XCTest
@testable import DevBerth

final class RuntimeAndClassificationTests: XCTestCase {
    func testClassifiesRepresentativeDevelopmentProcesses() {
        XCTAssertEqual(ProcessClassifier.classify(name: "node", executable: "/opt/node", command: "node ./node_modules/vite/bin/vite.js"), .vite)
        XCTAssertEqual(ProcessClassifier.classify(name: "java", executable: "/usr/bin/java", command: "java -jar spring-boot-api.jar"), .springBoot)
        XCTAssertEqual(ProcessClassifier.classify(name: "python", executable: "/usr/bin/python3", command: "uvicorn app.main:app --reload"), .fastAPI)
        XCTAssertEqual(ProcessClassifier.classify(name: "kubectl", executable: "/opt/kubectl", command: "kubectl port-forward service/api 8080:80"), .kubernetes)
    }

    func testRuntimeDiffIgnoresObservationTimesAndDetectsEvidenceChanges() {
        let oldA = makeListener(port: 3000, pid: 1)
        let oldB = makeListener(port: 4000, pid: 2)
        var timestampOnlyA = oldA
        timestampOnlyA.lastDetectedAt = Date(timeIntervalSince1970: 201)
        let unchangedDiff = RuntimeDiffer.diff(previous: [oldA], current: [timestampOnlyA])
        XCTAssertEqual(unchangedDiff, .empty)

        let changedProcess = ObservedProcess(
            fingerprint: oldA.process.fingerprint,
            name: oldA.process.name,
            commandLine: oldA.process.commandLine,
            owner: oldA.process.owner,
            currentDirectory: oldA.process.currentDirectory,
            parentName: oldA.process.parentName,
            runtime: .next,
            project: oldA.process.project,
            isSystemProcess: oldA.process.isSystemProcess,
            docker: oldA.process.docker,
            launchedByDevBerth: oldA.process.launchedByDevBerth,
            managedServiceID: oldA.process.managedServiceID
        )
        let changedA = ObservedListener(
            protocolKind: oldA.protocolKind,
            address: oldA.address,
            port: oldA.port,
            process: changedProcess,
            firstDetectedAt: oldA.firstDetectedAt,
            lastDetectedAt: Date(timeIntervalSince1970: 202)
        )
        let newC = makeListener(port: 5000, pid: 3)
        let diff = RuntimeDiffer.diff(previous: [oldA, oldB], current: [changedA, newC])
        XCTAssertEqual(diff.added.map(\.port), [5000])
        XCTAssertEqual(diff.updated.map(\.port), [3000])
        XCTAssertEqual(diff.removed.map(\.port), [4000])
    }

    func testAddressScopes() {
        XCTAssertEqual(makeListener().addressScope, .loopback)
        var listener = makeListener()
        listener = ObservedListener(protocolKind: .tcp, address: "::", port: listener.port, process: listener.process, firstDetectedAt: listener.firstDetectedAt, lastDetectedAt: listener.lastDetectedAt)
        XCTAssertEqual(listener.addressScope, .wildcard)
    }
}
