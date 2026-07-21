import Combine
import DevBerthControlContracts
import Foundation
import SwiftData

@MainActor
final class ControlHostStatusModel: ObservableObject {
    @Published private(set) var state = "Starting"
    @Published private(set) var socketPath: String
    @Published private(set) var lastError: String?
    @Published private(set) var lastConnectionTest: String?
    let developmentMode: Bool

    init(socketURL: URL, developmentMode: Bool) {
        socketPath = socketURL.path
        self.developmentMode = developmentMode
    }

    func markRunning() { state = developmentMode ? "Running (isolated development)" : "Running"; lastError = nil }
    func markDisabled(_ reason: String) { state = "Disabled"; lastError = reason }
    func markFailed(_ error: Error) { state = "Failed"; lastError = error.localizedDescription }

    func testConnection() async {
        let request = ControlRequest(
            handshake: ControlHandshake(client: ControlClientIdentity(
                name: "DevBerth Settings", version: "1", developmentMode: developmentMode
            )),
            toolName: "runtime_snapshot", timeoutSeconds: 5, source: .gui
        )
        do {
            let response = try await UnixControlClient(socketURL: URL(fileURLWithPath: socketPath)).send(request)
            if let error = response.error { lastConnectionTest = "Failed: \(error.message)" }
            else { lastConnectionTest = "Connected · snapshot \(response.snapshotVersion)" }
        } catch {
            lastConnectionTest = "Failed: \(error.localizedDescription)"
        }
    }
}

@MainActor
final class DevBerthControlHost {
    private let server: UnixControlServer
    private let plane: ApplicationControlPlane
    private let status: ControlHostStatusModel
    private var started = false

    init(
        model: AppModel,
        container: ModelContainer,
        developmentMode: Bool,
        status: ControlHostStatusModel,
        fixtureController: DevelopmentFixtureController = DevelopmentFixtureController()
    ) {
        server = UnixControlServer(socketURL: ControlSocketPath.socketURL(developmentMode: developmentMode))
        plane = ApplicationControlPlane(
            model: model,
            container: container,
            developmentMode: developmentMode,
            fixtureController: fixtureController
        )
        self.status = status
    }

    func start() {
        guard !started else { return }
        do {
            try server.start { [plane] request in await plane.handle(request) }
            started = true
            status.markRunning()
        } catch {
            status.markFailed(error)
        }
    }

    func stop() {
        guard started else { return }
        server.stop()
        started = false
    }
}
