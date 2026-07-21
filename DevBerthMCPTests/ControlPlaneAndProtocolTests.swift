import Darwin
import DevBerthControlContracts
import Foundation
import SwiftData
import XCTest
@testable import DevBerth

final class CapabilityParityTests: XCTestCase {
    func testProductionRegistryIsUniqueSchemaBackedAndRoutedThroughTwoExecutionTools() throws {
        let tools = ControlCapabilityRegistry.productionTools
        XCTAssertEqual(Set(tools.map(\.name)).count, tools.count)
        XCTAssertGreaterThan(tools.count, 60)
        XCTAssertTrue(tools.allSatisfy { !$0.capability.testReference.isEmpty })
        XCTAssertTrue(tools.allSatisfy { $0.inputSchema["type"] == .string("object") })
        XCTAssertTrue(tools.allSatisfy { $0.outputSchema["type"] == .string("object") })

        let executionTools = Set(tools.filter { $0.capability.previewRequired }.map(\.name))
        XCTAssertEqual(executionTools, ["operation_execute", "change_set_execute"])
        XCTAssertTrue(tools.first { $0.name == "operation_preview" }?.annotations.readOnlyHint == true)
        XCTAssertTrue(tools.first { $0.name == "operation_execute" }?.annotations.destructiveHint == true)
        XCTAssertTrue(tools.first { $0.name == "project_delete" }?.annotations.destructiveHint == true)
        XCTAssertTrue(tools.first { $0.name == "project_create" }?.inputSchema["required"]?.arrayValue?.contains(.string("name")) == true)
    }

    func testResourcesPromptsAndStableErrorsAreCompleteAndUnique() {
        XCTAssertEqual(Set(ControlCapabilityRegistry.resources.map(\.uri)).count, ControlCapabilityRegistry.resources.count)
        XCTAssertEqual(Set(ControlCapabilityRegistry.prompts.map(\.name)).count, ControlCapabilityRegistry.prompts.count)
        XCTAssertEqual(ControlCapabilityRegistry.prompts.filter(\.developmentOnly).map(\.name), ["run_development_acceptance_suite"])
        XCTAssertTrue(ControlErrorCode.allCases.contains(.identityMismatch))
        XCTAssertTrue(ControlErrorCode.allCases.contains(.productionDataProtected))
        XCTAssertLessThanOrEqual(ControlProtocolConstants.maximumFrameBytes, 4 * 1_024 * 1_024)
    }

    func testResponseEncodingMatchesPublishedSnakeCaseEnvelope() throws {
        let response = ControlResponse(
            requestID: "request-1",
            snapshotVersion: 42,
            data: .object(["ok": .bool(true)]),
            nextCursor: "cursor-2"
        )
        let encoded = try JSONEncoder.devBerth.encode(response)
        let object = try XCTUnwrap(try JSONDecoder.devBerth.decode(JSONValue.self, from: encoded).objectValue)
        let required = try XCTUnwrap(
            ControlCapabilityRegistry.productionTools.first?.outputSchema["required"]?.arrayValue?.compactMap(\.stringValue)
        )
        XCTAssertTrue(required.allSatisfy { object[$0] != nil })
        XCTAssertEqual(object["schema_version"], .string("1"))
        XCTAssertEqual(object["request_id"], .string("request-1"))
        XCTAssertEqual(object["snapshot_version"], .number(42))
        XCTAssertEqual(object["next_cursor"], .string("cursor-2"))
        XCTAssertNil(object["schemaVersion"])
        XCTAssertNil(object["snapshotVersion"])

        let failure = ControlResponse(
            requestID: "request-2",
            snapshotVersion: 43,
            failure: .init(code: .entityChanged, message: "Changed.", recoverySuggestion: "Inspect again.")
        )
        let failureObject = try XCTUnwrap(
            try JSONDecoder.devBerth.decode(JSONValue.self, from: JSONEncoder.devBerth.encode(failure)).objectValue
        )
        XCTAssertEqual(failureObject["error"]?["code"], .string("entity_changed"))
        XCTAssertEqual(failureObject["error"]?["recovery_suggestion"], .string("Inspect again."))
        XCTAssertNotNil(ControlCapabilityRegistry.productionTools.first?.outputSchema["properties"]?["error"])
    }
}

final class ApplicationControlPlaneTests: XCTestCase {
    @MainActor
    func testProjectRevisionConflictAndConditionalDeletePreview() async throws {
        let harness = try makeHarness(developmentMode: false)
        let created = try successData(await call(harness.plane, "project_create", ["name": .string("API")]))
        let projectID = try XCTUnwrap(created["id"]?.stringValue)
        XCTAssertEqual(created["revision"]?.intValue, 1)

        let updated = try successData(await call(harness.plane, "project_update", [
            "project_id": .string(projectID), "revision": .number(1),
            "patch": .object(["name": .string("API v2")])
        ]))
        XCTAssertEqual(updated["revision"]?.intValue, 2)

        let stale = await call(harness.plane, "project_update", [
            "project_id": .string(projectID), "revision": .number(1),
            "patch": .object(["name": .string("stale")])
        ])
        XCTAssertEqual(stale.error?.code, .entityChanged)

        _ = try successData(await call(harness.plane, "service_create", [
            "name": .string("API service"), "project_id": .string(projectID),
            "command": .string("/usr/bin/true"), "working_directory": .string("/tmp")
        ]))
        let directDelete = await call(harness.plane, "project_delete", ["project_id": .string(projectID)])
        XCTAssertEqual(directDelete.error?.code, .operationNotApproved)

        let preview = try successData(await call(harness.plane, "operation_preview", [
            "operation_type": .string("delete_project_with_dependencies"),
            "targets": .array([.string(projectID)])
        ]))
        let operationID = try XCTUnwrap(preview["operation_id"]?.stringValue)
        XCTAssertNotNil(preview["entity_revisions"]?["project:\(projectID)"])
        _ = try successData(await call(harness.plane, "operation_execute", ["operation_id": .string(operationID)]))
        let replay = await call(harness.plane, "operation_execute", ["operation_id": .string(operationID)])
        XCTAssertEqual(replay.error?.code, .operationAlreadyUsed)
    }

    @MainActor
    func testSecretLikeEnvironmentIsRejectedAndOpaqueReferenceIsRedacted() async throws {
        let harness = try makeHarness(developmentMode: false)
        let rejected = await call(harness.plane, "service_create", [
            "name": .string("unsafe"), "command": .string("/usr/bin/true"), "working_directory": .string("/tmp"),
            "environment": .object(["API_TOKEN": .string("secret-canary-value")])
        ])
        XCTAssertEqual(rejected.error?.code, .invalidArguments)

        let reference = UUID()
        let createdResponse = await call(harness.plane, "service_create", [
            "name": .string("safe"), "command": .string("/usr/bin/true"), "working_directory": .string("/tmp"),
            "secret_references": .object(["API_TOKEN": .string(reference.uuidString)])
        ])
        let created = try successData(createdResponse)
        XCTAssertEqual(created["secret_references"]?["API_TOKEN"]?["configured"], .bool(true))
        let encoded = String(decoding: try JSONEncoder.devBerth.encode(createdResponse), as: UTF8.self)
        XCTAssertFalse(encoded.contains(reference.uuidString))
        XCTAssertFalse(encoded.contains("secret-canary-value"))
    }

    @MainActor
    func testChangeSetOrdersExecutesAndRejectsReplay() async throws {
        let harness = try makeHarness(developmentMode: false)
        let projectID = UUID()
        let preview = try successData(await call(harness.plane, "change_set_preview", [
            "changes": .array([
                .object(["tool": .string("port_reservation_create"), "arguments": .object(["name": .string("API"), "port": .number(45_611)])]),
                .object(["tool": .string("project_create"), "arguments": .object(["id": .string(projectID.uuidString), "name": .string("Coordinated")])])
            ])
        ]))
        let token = try XCTUnwrap(preview["change_set_token"]?.stringValue)
        XCTAssertEqual(preview["ordered_plan"]?.arrayValue?.first?["tool"], .string("project_create"))
        let executed = try successData(await call(harness.plane, "change_set_execute", ["change_set_token": .string(token)]))
        XCTAssertEqual(executed["status"], .string("succeeded"))
        let replay = await call(harness.plane, "change_set_execute", ["change_set_token": .string(token)])
        XCTAssertEqual(replay.error?.code, .operationAlreadyUsed)
    }

    @MainActor
    func testOperationRejectsRawPIDAndIsolationModeMismatch() async throws {
        let harness = try makeHarness(developmentMode: false)
        let rawPID = await call(harness.plane, "operation_preview", [
            "operation_type": .string("stop_runtime"), "targets": .array([.string("listener")]), "pid": .number(42)
        ])
        XCTAssertEqual(rawPID.error?.code, .invalidArguments)

        let mismatched = ControlRequest(
            handshake: ControlHandshake(client: .init(name: "test", version: "1", developmentMode: true)),
            toolName: "runtime_snapshot"
        )
        let protected = await harness.plane.handle(mismatched)
        XCTAssertEqual(protected.error?.code, .productionDataProtected)

        let debugOnProduction = await call(harness.plane, "dev_test_store_reset", ["confirm": .bool(true)])
        XCTAssertEqual(debugOnProduction.error?.code, .developmentModeRequired)
    }

    @MainActor
    func testProjectsServicesSessionsPortsDockerHistoryAndSettingsUseOnePlane() async throws {
        let harness = try makeHarness(developmentMode: false)
        let snapshot = try successData(await call(harness.plane, "runtime_snapshot"))
        XCTAssertEqual(snapshot["counts"]?["active_listeners"], .number(0))

        let project = try successData(await call(harness.plane, "project_create", ["name": .string("Coverage")]))
        let projectID = try XCTUnwrap(project["id"]?.stringValue)
        let first = try successData(await call(harness.plane, "service_create", [
            "name": .string("backend"), "project_id": .string(projectID),
            "command": .string("/usr/bin/true"), "working_directory": .string("/tmp"),
            "expected_ports": .array([])
        ]))
        let firstID = try XCTUnwrap(first["id"]?.stringValue)
        let second = try successData(await call(harness.plane, "service_create", [
            "name": .string("worker"), "project_id": .string(projectID),
            "command": .string("/usr/bin/true"), "working_directory": .string("/tmp")
        ]))
        let secondID = try XCTUnwrap(second["id"]?.stringValue)
        let dependency = try successData(await call(harness.plane, "dependency_update", [
            "service_id": .string(secondID), "dependency_service_id": .string(firstID),
            "action": .string("add"), "revision": second["revision"] ?? .number(1)
        ]))
        XCTAssertEqual(dependency["revision"]?.intValue, 2)
        let validation = try successData(await call(harness.plane, "dependency_validate"))
        XCTAssertEqual(validation["valid"], .bool(true))

        let session = try successData(await call(harness.plane, "session_create", [
            "name": .string("default"), "project_ids": .array([.string(projectID)]),
            "services": .array([.object(["service_id": .string(firstID), "expected_state": .string("stopped")])])
        ]))
        let sessionID = try XCTUnwrap(session["id"]?.stringValue)
        let diff = try successData(await call(harness.plane, "session_diff", ["session_id": .string(sessionID)]))
        XCTAssertEqual(diff["session_id"], .string(sessionID))

        let watch = try successData(await call(harness.plane, "port_watch_create", ["name": .string("API watch"), "port": .number(45_612)]))
        let watchID = try XCTUnwrap(watch["id"]?.stringValue)
        let updatedWatch = try successData(await call(harness.plane, "port_watch_update", [
            "port_id": .string(watchID), "revision": .number(1), "patch": .object(["name": .string("API watch 2")])
        ]))
        XCTAssertEqual(updatedWatch["revision"]?.intValue, 2)
        let ports = try successData(await call(harness.plane, "ports_list"))
        XCTAssertEqual(ports["watched"]?.arrayValue?.count, 1)

        let docker = try successData(await call(harness.plane, "docker_status"))
        XCTAssertNotNil(docker["status"])
        let settings = try successData(await call(harness.plane, "settings_get"))
        XCTAssertEqual(settings["mcp"]?["enabled"], .bool(true))
        let history = try successData(await call(harness.plane, "history_query", ["limit": .number(10)]))
        XCTAssertNotNil(history["events"])
        let diagnosis = try successData(await call(harness.plane, "diagnostics_analyze"))
        XCTAssertEqual(diagnosis["analysis_method"], .string("deterministic_lifecycle_evidence"))
    }

    @MainActor
    func testOperationAndChangeSetExpirationAndStaleSnapshot() async throws {
        let harness = try makeHarness(developmentMode: false)
        let project = try successData(await call(harness.plane, "project_create", ["name": .string("Expiring")]))
        let projectID = try XCTUnwrap(project["id"]?.stringValue)
        let preview = try successData(await call(harness.plane, "operation_preview", [
            "operation_type": .string("delete_project_with_dependencies"), "targets": .array([.string(projectID)])
        ]))
        let operationID = try XCTUnwrap(preview["operation_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
        let lease = try XCTUnwrap(harness.plane.operationLeases[operationID])
        harness.plane.operationLeases[operationID] = .init(
            id: lease.id, type: lease.type, targets: lease.targets, options: lease.options,
            fingerprints: lease.fingerprints, revisions: lease.revisions, ownershipRoutes: lease.ownershipRoutes,
            targetEvidence: lease.targetEvidence, createdAt: lease.createdAt,
            expiresAt: Date().addingTimeInterval(-1), stateVersion: lease.stateVersion, used: false
        )
        let expired = await call(harness.plane, "operation_execute", ["operation_id": .string(operationID.uuidString)])
        XCTAssertEqual(expired.error?.code, .operationExpired)

        let freshPreview = try successData(await call(harness.plane, "operation_preview", [
            "operation_type": .string("delete_project_with_dependencies"), "targets": .array([.string(projectID)])
        ]))
        _ = try successData(await call(harness.plane, "project_create", ["name": .string("Concurrent GUI edit")]))
        let stale = await call(harness.plane, "operation_execute", ["operation_id": freshPreview["operation_id"] ?? .null])
        XCTAssertEqual(stale.error?.code, .staleSnapshot)

        let changePreview = try successData(await call(harness.plane, "change_set_preview", [
            "changes": .array([.object(["tool": .string("project_create"), "arguments": .object(["name": .string("Lease")])])])
        ]))
        let token = try XCTUnwrap(changePreview["change_set_token"]?.stringValue.flatMap(UUID.init(uuidString:)))
        let changeLease = try XCTUnwrap(harness.plane.changeSetLeases[token])
        harness.plane.changeSetLeases[token] = .init(
            id: changeLease.id, changes: changeLease.changes, stateVersion: changeLease.stateVersion,
            revisions: changeLease.revisions, compensation: changeLease.compensation,
            createdAt: changeLease.createdAt, expiresAt: Date().addingTimeInterval(-1), used: false
        )
        let expiredChange = await call(harness.plane, "change_set_execute", ["change_set_token": .string(token.uuidString)])
        XCTAssertEqual(expiredChange.error?.code, .changeSetExpired)
    }

    @MainActor
    func testDevelopmentFixtureLifecycleParityAndDisposableReset() async throws {
        let harness = try makeHarness(developmentMode: true)
        let parity = try successData(await call(harness.plane, "dev_capability_parity_validate"))
        XCTAssertEqual(parity["valid"], .bool(true))
        let fixture = try successData(await call(harness.plane, "dev_fixture_start", ["name": .string("pid_reuse_simulation")]))
        let fixtureID = try XCTUnwrap(fixture["fixture_id"]?.stringValue)
        let state = try successData(await call(harness.plane, "dev_internal_state"))
        XCTAssertEqual(state["fixtures"]?["simulated"]?.arrayValue?.count, 1)
        _ = try successData(await call(harness.plane, "dev_fixture_stop", ["fixture_id": .string(fixtureID)]))
        _ = try successData(await call(harness.plane, "project_create", ["name": .string("Disposable")]))
        let reset = try successData(await call(harness.plane, "dev_test_store_reset", ["confirm": .bool(true)]))
        XCTAssertEqual(reset["production_data_touched"], .bool(false))
        let projects = try successData(await call(harness.plane, "projects_list"))
        XCTAssertTrue(projects["projects"]?.arrayValue?.isEmpty == true)
    }

    @MainActor
    func testDevelopmentAcceptanceSuiteExecutesAllIsolatedScenarios() async throws {
        let harness = try makeHarness(developmentMode: true)
        let result = try successData(await call(harness.plane, "dev_acceptance_suite_run"))
        let scenarios = try XCTUnwrap(result["scenarios"]?.arrayValue)
        if result["passed"] != .bool(true) {
            XCTFail("Development acceptance failed: \(scenarios)")
        }
        XCTAssertEqual(scenarios.count, 9)
        XCTAssertTrue(scenarios.allSatisfy { $0["passed"] == .bool(true) })
        XCTAssertEqual(result["production_data_touched"], .bool(false))
        XCTAssertTrue(try harness.plane.store.projects().isEmpty)
        XCTContext.runActivity(named: "DEVBERTH_MCP_ACCEPTANCE \(result)") { _ in }
    }

    @MainActor
    func testDevelopmentPerformanceCoversRequiredControlPlanePathsWithoutPersistentProbes() async throws {
        let harness = try makeHarness(developmentMode: true)
        let result = try successData(await call(harness.plane, "dev_performance_measure", ["iterations": .number(50)]))
        for key in [
            "runtime_snapshot_latency_ms", "project_inspection_ms", "project_create_ms", "project_update_ms",
            "session_capture_ms", "session_diff_ms", "change_set_preview_ms", "operation_preview_ms",
            "log_retrieval_ms", "memory_delta_bytes", "concurrent_clients", "host_reconnect"
        ] {
            XCTAssertNotNil(result[key], "Missing performance field \(key)")
        }
        XCTAssertTrue(try harness.plane.store.projects().isEmpty)
        XCTAssertTrue(try harness.plane.store.services().isEmpty)
        XCTAssertTrue(try harness.plane.store.sessions().isEmpty)
        XCTContext.runActivity(named: "DEVBERTH_MCP_PERFORMANCE \(result)") { _ in }
    }
}

final class UnixControlSocketTests: XCTestCase {
    func testSocketPermissionsRequestRoundTripAndLiveSocketProtection() async throws {
        let directory = URL(fileURLWithPath: "/tmp/db-sock-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketURL = directory.appendingPathComponent("control.sock")
        let server = UnixControlServer(socketURL: socketURL)
        try server.start { request in
            ControlResponse(requestID: request.requestID, snapshotVersion: 7, data: .object(["tool": .string(request.toolName)]))
        }
        defer { server.stop() }

        var directoryInfo = stat()
        var socketInfo = stat()
        XCTAssertEqual(lstat(directory.path, &directoryInfo), 0)
        XCTAssertEqual(lstat(socketURL.path, &socketInfo), 0)
        XCTAssertEqual(directoryInfo.st_mode & 0o777, 0o700)
        XCTAssertEqual(socketInfo.st_mode & 0o777, 0o600)

        let second = UnixControlServer(socketURL: socketURL)
        XCTAssertThrowsError(try second.start { _ in
            ControlResponse(requestID: "unexpected", snapshotVersion: 0, data: .null)
        }) { error in
            guard case ControlSocketError.hostAlreadyRunning = error else {
                return XCTFail("Expected hostAlreadyRunning, got \(error)")
            }
        }

        let request = ControlRequest(
            handshake: ControlHandshake(client: .init(name: "socket-tests", version: "1", developmentMode: false)),
            toolName: "runtime_snapshot"
        )
        let response = try await UnixControlClient(socketURL: socketURL).send(request)
        XCTAssertEqual(response.snapshotVersion, 7)
        XCTAssertEqual(response.data?["tool"], .string("runtime_snapshot"))
    }

    func testConcurrentClientsAndFrameLimit() async throws {
        let directory = URL(fileURLWithPath: "/tmp/db-many-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketURL = directory.appendingPathComponent("control.sock")
        let server = UnixControlServer(socketURL: socketURL)
        try server.start { request in
            ControlResponse(requestID: request.requestID, snapshotVersion: 9, data: .string(request.correlationID))
        }
        defer { server.stop() }

        let values = try await withThrowingTaskGroup(of: UInt64.self) { group in
            for index in 0..<8 {
                group.addTask {
                    let request = ControlRequest(
                        handshake: ControlHandshake(client: .init(name: "client-\(index)", version: "1", developmentMode: false)),
                        toolName: "runtime_snapshot"
                    )
                    return try await UnixControlClient(socketURL: socketURL).send(request).snapshotVersion
                }
            }
            var results: [UInt64] = []
            for try await value in group { results.append(value) }
            return results
        }
        XCTAssertEqual(values, Array(repeating: 9, count: 8))

        let oversized = ControlRequest(
            handshake: ControlHandshake(client: .init(name: "large", version: "1", developmentMode: false)),
            toolName: "runtime_search",
            arguments: .object(["query": .string(String(repeating: "x", count: ControlProtocolConstants.maximumFrameBytes))])
        )
        do {
            _ = try await UnixControlClient(socketURL: socketURL).send(oversized)
            XCTFail("Expected the oversized frame to be rejected.")
        } catch ControlSocketError.frameTooLarge {
            // Expected before any oversized allocation is sent to the host.
        }
    }
}

final class MCPIntegrationConfigurationTests: XCTestCase {
    func testTOMLEditorPreservesUnrelatedConfigurationAndReplacesOneTable() throws {
        let source = """
        model = "gpt-5.6"

        [mcp_servers.other]
        command = "/tmp/other"

        [mcp_servers.devberth]
        command = "/old/helper"
        args = ["old"]

        [features]
        multi_agent = true
        """
        let replacement = """
        [mcp_servers.devberth]
        command = "/new/helper"
        args = ["serve", "--stdio"]
        """
        let result = try CodexTOMLEditor.replacingDevBerthSection(in: source, with: replacement)
        XCTAssertTrue(result.contains("model = \"gpt-5.6\""))
        XCTAssertTrue(result.contains("[mcp_servers.other]"))
        XCTAssertTrue(result.contains("[features]"))
        XCTAssertTrue(result.contains("/new/helper"))
        XCTAssertFalse(result.contains("/old/helper"))
    }

    func testTOMLEditorRejectsDuplicateDevBerthTables() {
        let source = "[mcp_servers.devberth]\ncommand = \"a\"\n[mcp_servers.devberth]\ncommand = \"b\"\n"
        XCTAssertThrowsError(try CodexTOMLEditor.replacingDevBerthSection(in: source, with: "[mcp_servers.devberth]"))
    }
}

final class ControlPlaneMigrationTests: XCTestCase {
    @MainActor
    func testV6FixtureMigratesToV7AndPreservesExistingData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("devberth-v7-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("fixture.store")
        let projectID = UUID()
        try createV6Fixture(at: storeURL, projectID: projectID)

        let schema = Schema(DevBerthSchemaV7.models)
        let configuration = ModelConfiguration("V7Migration", schema: schema, url: storeURL)
        let container = try ModelContainer(for: schema, migrationPlan: DevBerthMigrationPlan.self, configurations: [configuration])
        let context = ModelContext(container)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ProjectRecord>()).map(\.id), [projectID])
        XCTAssertTrue(try context.fetch(FetchDescriptor<EntityRevisionRecord>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<MCPAuditEventRecord>()).isEmpty)
    }

    @MainActor
    private func createV6Fixture(at url: URL, projectID: UUID) throws {
        let schema = Schema(DevBerthSchemaV6.models)
        let configuration = ModelConfiguration("V6Fixture", schema: schema, url: url)
        let container = try ModelContainer(for: schema, migrationPlan: V6OnlyMigrationPlan.self, configurations: [configuration])
        let context = ModelContext(container)
        context.insert(ProjectRecord(id: projectID, name: "V6 project"))
        try context.save()
    }
}

final class MCPStdioProtocolTests: XCTestCase {
    func testProductionAndDevelopmentDiscoveryAreProtocolClean() throws {
        let production = try runTranscript(
            arguments: ["serve", "--stdio"],
            additionalMessages: [
                #"{"jsonrpc":"2.0","id":5,"method":"resources/templates/list","params":{}}"#,
                #"{"jsonrpc":"2.0","id":6,"method":"resources/read","params":{"uri":"app://capabilities"}}"#,
                #"{"jsonrpc":"2.0","id":7,"method":"prompts/get","params":{"name":"inspect_local_runtime","arguments":{}}}"#
            ],
            expectedOutputLines: 7
        )
        let productionTools = try toolNames(from: production)
        XCTAssertTrue(productionTools.contains("runtime_snapshot"))
        XCTAssertFalse(productionTools.contains { $0.hasPrefix("dev_") })
        XCTAssertGreaterThan(try resultArray(named: "resources", id: 3, messages: production).count, 5)
        XCTAssertGreaterThan(try resultArray(named: "prompts", id: 4, messages: production).count, 5)
        let initialization = try result(id: 1, messages: production)
        XCTAssertEqual(initialization["protocolVersion"] as? String, "2025-11-25")
        let toolObjects = try resultArray(named: "tools", id: 2, messages: production)
        XCTAssertTrue(toolObjects.allSatisfy { $0["inputSchema"] != nil && $0["outputSchema"] != nil && $0["annotations"] != nil })
        XCTAssertGreaterThan(try resultArray(named: "resourceTemplates", id: 5, messages: production).count, 0)
        XCTAssertGreaterThan(try resultArray(named: "contents", id: 6, messages: production).count, 0)
        XCTAssertGreaterThan(try resultArray(named: "messages", id: 7, messages: production).count, 0)

        let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let development = try runTranscript(arguments: ["serve", "--stdio", "--development", "--workspace", repositoryRoot.path])
        let developmentTools = try toolNames(from: development)
        XCTAssertTrue(developmentTools.contains("runtime_snapshot"))
        XCTAssertTrue(developmentTools.contains("dev_acceptance_suite_run"))
    }

    func testStructuredToolResultAndProgressUseTheStubControlHost() throws {
        let directory = URL(fileURLWithPath: "/tmp/db-mcp-progress-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketURL = directory.appendingPathComponent("control.sock")
        let host = UnixControlServer(socketURL: socketURL)
        try host.start { request in
            ControlResponse(
                requestID: request.requestID,
                snapshotVersion: 42,
                data: .object(["stubbed": .bool(true), "tool": .string(request.toolName)])
            )
        }
        defer { host.stop() }

        let call = #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"_meta":{"progressToken":"progress-5"},"name":"runtime_snapshot","arguments":{}}}"#
        let cancellation = #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":999,"reason":"unknown request is advisory"}}"#
        let messages = try runTranscript(
            arguments: ["serve", "--stdio"],
            additionalMessages: [call, cancellation],
            expectedOutputLines: 7,
            controlSocketURL: socketURL
        )
        let progress = messages.filter { $0["method"] as? String == "notifications/progress" }
        XCTAssertEqual(progress.count, 2)
        XCTAssertEqual((progress.first?["params"] as? [String: Any])?["progressToken"] as? String, "progress-5")
        XCTAssertEqual((progress.last?["params"] as? [String: Any])?["progress"] as? NSNumber, 1)
        let callResult = try result(id: 5, messages: messages)
        let structured = try XCTUnwrap(callResult["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["snapshot_version"] as? NSNumber, 42)
        XCTAssertEqual(((structured["data"] as? [String: Any])?["stubbed"] as? NSNumber)?.boolValue, true)
    }

    private func runTranscript(
        arguments: [String],
        additionalMessages: [String] = [],
        expectedOutputLines: Int = 4,
        controlSocketURL: URL? = nil
    ) throws -> [[String: Any]] {
        let testBundle = Bundle(for: MCPStdioProtocolTests.self).bundleURL
        let appBundle = testBundle.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = appBundle.appendingPathComponent("Contents/Resources/devberth-mcp")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path), "Missing helper at \(executable.path)")
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let input = Pipe()
        let output = Pipe()
        let diagnostics = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = diagnostics
        if let controlSocketURL {
            var environment = ProcessInfo.processInfo.environment
            environment["DEVBERTH_CONTROL_SOCKET_PATH"] = controlSocketURL.path
            process.environment = environment
        }
        let terminated = expectation(description: "MCP helper exits on EOF")
        let responsesReady = expectation(description: "MCP helper returns protocol responses")
        let outputLock = NSLock()
        var outputData = Data()
        var didFulfillResponses = false
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            outputLock.lock()
            outputData.append(data)
            let lineCount = outputData.filter { $0 == UInt8(ascii: "\n") }.count
            if lineCount >= expectedOutputLines, !didFulfillResponses {
                didFulfillResponses = true
                responsesReady.fulfill()
            }
            outputLock.unlock()
        }
        process.terminationHandler = { _ in terminated.fulfill() }
        try process.run()
        let messages = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"DevBerthTests","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"resources/list","params":{}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"prompts/list","params":{}}"#
        ] + additionalMessages
        let transcript = messages.joined(separator: "\n") + "\n"
        input.fileHandleForWriting.write(Data(transcript.utf8))
        wait(for: [responsesReady], timeout: 10)
        try input.fileHandleForWriting.close()
        wait(for: [terminated], timeout: 10)
        output.fileHandleForReading.readabilityHandler = nil
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: diagnostics.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        outputLock.lock()
        outputData.append(output.fileHandleForReading.readDataToEndOfFile())
        let stdout = String(decoding: outputData, as: UTF8.self)
        outputLock.unlock()
        return try stdout.split(whereSeparator: \.isNewline).map { line in
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
            return try XCTUnwrap(object as? [String: Any], "Non-JSON stdout line: \(line)")
        }
    }

    private func toolNames(from messages: [[String: Any]]) throws -> [String] {
        let response = try XCTUnwrap(messages.first { ($0["id"] as? NSNumber)?.intValue == 2 }, "No tools/list response in \(messages)")
        let result = try XCTUnwrap(response["result"] as? [String: Any], "tools/list failed: \(response)")
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        return tools.compactMap { $0["name"] as? String }
    }

    private func resultArray(named key: String, id: Int, messages: [[String: Any]]) throws -> [[String: Any]] {
        let result = try result(id: id, messages: messages)
        return try XCTUnwrap(result[key] as? [[String: Any]])
    }

    private func result(id: Int, messages: [[String: Any]]) throws -> [String: Any] {
        let response = try XCTUnwrap(messages.first { ($0["id"] as? NSNumber)?.intValue == id })
        return try XCTUnwrap(response["result"] as? [String: Any], "Request \(id) failed: \(response)")
    }
}

private struct ControlPlaneHarness {
    let plane: ApplicationControlPlane
    let container: ModelContainer
    let model: AppModel
}

@MainActor
private func makeHarness(developmentMode: Bool) throws -> ControlPlaneHarness {
    let schema = Schema(DevBerthSchemaV7.models)
    let configuration = ModelConfiguration("ControlPlaneTests-\(UUID().uuidString)", schema: schema, isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, migrationPlan: DevBerthMigrationPlan.self, configurations: [configuration])
    let fixtures = DevelopmentFixtureController()
    let runtimeRegistry = ManagedRuntimeRegistry()
    let persistence = SwiftDataStore(modelContainer: container)
    let discoverer: any PortDiscovering = developmentMode
        ? DevelopmentScopedPortDiscoverer(fixtures: fixtures, runtimeRegistry: runtimeRegistry)
        : EmptyControlPlaneDiscoverer()
    let model = AppModel(
        discoverer: discoverer,
        historyRecorder: persistence,
        ownershipRecorder: persistence,
        restartTrustStore: persistence,
        workspaceSessionRecorder: persistence,
        processResourceReader: EmptyControlPlaneResourceReader(),
        runtimeRegistry: runtimeRegistry
    )
    model.pauseMonitoring()
    return ControlPlaneHarness(
        plane: ApplicationControlPlane(
            model: model, container: container, developmentMode: developmentMode,
            fixtureController: fixtures
        ),
        container: container,
        model: model
    )
}

@MainActor
private func call(
    _ plane: ApplicationControlPlane,
    _ tool: String,
    _ arguments: [String: JSONValue] = [:]
) async -> ControlResponse {
    await plane.handle(ControlRequest(
        handshake: ControlHandshake(client: .init(name: "DevBerthMCPTests", version: "1", developmentMode: plane.developmentMode)),
        toolName: tool,
        arguments: .object(arguments)
    ))
}

private func successData(_ response: ControlResponse, file: StaticString = #filePath, line: UInt = #line) throws -> JSONValue {
    if let error = response.error {
        XCTFail("Unexpected \(error.code.rawValue): \(error.message)", file: file, line: line)
    }
    return try XCTUnwrap(response.data, file: file, line: line)
}

private struct EmptyControlPlaneDiscoverer: PortDiscovering {
    func discover() async throws -> [ObservedListener] { [] }
}

private struct EmptyControlPlaneResourceReader: ProcessResourceUsageReading {
    func read(pids: Set<Int32>) async throws -> [Int32: ProcessResourceUsage] { [:] }
}

private enum V6OnlyMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [DevBerthSchemaV6.self] }
    static var stages: [MigrationStage] { [] }
}
