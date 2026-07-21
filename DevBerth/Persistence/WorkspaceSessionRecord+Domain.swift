import Foundation

extension WorkspaceSessionRecord {
    func session(serviceRecords: [WorkspaceSessionServiceRecord]) -> WorkspaceSession? {
        let decoder = JSONDecoder()
        guard let projectIDs = try? decoder.decode([UUID].self, from: projectIDsData) else { return nil }
        let records = serviceRecords.filter { $0.sessionID == id }
        let snapshots = records
            .compactMap(\.snapshot)
            .sorted { $0.managedServiceID.uuidString < $1.managedServiceID.uuidString }
        guard snapshots.count == records.count else { return nil }
        return WorkspaceSession(
            id: id,
            name: name,
            projectIDs: projectIDs,
            serviceSnapshots: snapshots,
            capturedAt: capturedAt,
            notes: notes
        )
    }
}

extension WorkspaceSessionServiceRecord {
    var snapshot: WorkspaceSessionServiceSnapshot? {
        let decoder = JSONDecoder()
        guard let expectedState = ExpectedServiceState(rawValue: expectedStateRawValue),
              let listeners = try? decoder.decode([ExpectedListenerConfiguration].self, from: expectedListenersData),
              let dependencies = try? decoder.decode([UUID].self, from: dependencyServiceIDsData),
              let health = RuntimeHealthState(rawValue: previousHealthStateRawValue) else {
            return nil
        }
        return WorkspaceSessionServiceSnapshot(
            managedServiceID: managedServiceID,
            expectedState: expectedState,
            expectedListeners: listeners,
            dependencyServiceIDs: dependencies,
            previousHealthState: health,
            configurationDigest: configurationDigest
        )
    }
}

extension SessionRestoreRecord {
    var result: SessionRestoreResult? {
        let decoder = JSONDecoder()
        guard let outcome = SessionRestoreOutcome(rawValue: outcomeRawValue),
              let startedIDs = try? decoder.decode([UUID].self, from: startedServiceIDsData),
              let rolledBackIDs = try? decoder.decode([UUID].self, from: rolledBackServiceIDsData),
              let errors = try? decoder.decode([String].self, from: errorsData) else {
            return nil
        }
        return SessionRestoreResult(
            id: id,
            sessionID: sessionID,
            startedAt: startedAt,
            finishedAt: finishedAt,
            outcome: outcome,
            startedServiceIDs: startedIDs,
            rolledBackServiceIDs: rolledBackIDs,
            errors: errors
        )
    }
}
