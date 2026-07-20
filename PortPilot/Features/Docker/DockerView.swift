import SwiftUI

@MainActor
final class DockerViewModel: ObservableObject {
    @Published private(set) var availability: DockerAvailability = .checking
    @Published private(set) var containers: [DockerContainer] = []
    @Published var error: PortPilotError?
    @Published var logs = ""
    @Published var logsContainerName = ""
    private let client: any DockerServing

    init(client: (any DockerServing)? = nil) {
        self.client = client ?? DockerCLIClient(runner: FoundationCommandRunner())
    }

    func refresh() async {
        availability = await client.availability()
        guard case .available = availability else { containers = []; return }
        do { containers = try await client.runningContainers() }
        catch let value as PortPilotError { error = value }
        catch { self.error = .unexpected(error.localizedDescription) }
    }

    func stop(_ container: DockerContainer) async {
        do { try await client.stop(containerID: container.id); await refresh() }
        catch { self.error = .unexpected(error.localizedDescription) }
    }

    func restart(_ container: DockerContainer) async {
        do { try await client.restart(containerID: container.id); await refresh() }
        catch { self.error = .unexpected(error.localizedDescription) }
    }

    func openLogs(_ container: DockerContainer) async {
        do {
            logs = try await client.recentLogs(containerID: container.id, lines: 300)
            logsContainerName = container.name
        } catch { self.error = .unexpected(error.localizedDescription) }
    }
}

struct DockerView: View {
    @StateObject private var model = DockerViewModel()
    @State private var pendingStop: DockerContainer?

    var body: some View {
        Group {
            switch model.availability {
            case .checking:
                ProgressView("Checking Docker…")
            case .notInstalled:
                EmptyStateView(
                    symbol: "shippingbox",
                    title: "Docker is not installed",
                    message: "Port monitoring remains fully available. Install a Docker-compatible runtime to enable container controls.",
                    actionTitle: "Check Again",
                    action: { Task { await model.refresh() } }
                )
            case let .daemonUnavailable(details):
                EmptyStateView(
                    symbol: "shippingbox.and.arrow.backward",
                    title: "Docker daemon is unavailable",
                    message: LocalizedStringKey(details),
                    actionTitle: "Retry",
                    action: { Task { await model.refresh() } }
                )
            case let .available(version):
                if model.containers.isEmpty {
                    EmptyStateView(
                        symbol: "shippingbox",
                        title: "No running containers",
                        message: "Docker \(version) is available. Published ports will appear here when containers are running.",
                        actionTitle: "Refresh",
                        action: { Task { await model.refresh() } }
                    )
                } else {
                    Table(model.containers) {
                        TableColumn("Container", value: \.name)
                        TableColumn("Image", value: \.image)
                        TableColumn("Published Ports") { container in
                            Text(container.ports.map { "\($0.hostPort) → \($0.containerPort)/\($0.protocolKind.rawValue.lowercased())" }.joined(separator: ", "))
                                .font(.system(.body, design: .monospaced))
                        }
                        TableColumn("Compose") { container in
                            Text([container.composeProject, container.composeService].compactMap { $0 }.joined(separator: " / ").nilIfEmpty ?? "—")
                        }
                        TableColumn("Status", value: \.status)
                        TableColumn("Actions") { container in
                            HStack {
                                Button("Logs") { Task { await model.openLogs(container) } }
                                Button("Restart") { Task { await model.restart(container) } }
                                Button("Stop", role: .destructive) { pendingStop = container }
                            }
                        }
                        .width(min: 150, ideal: 180)
                    }
                }
            }
        }
        .navigationTitle("Docker")
        .toolbar { Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } } }
        .task { await model.refresh() }
        .confirmationDialog("Stop \(pendingStop?.name ?? "container")?", isPresented: Binding(
            get: { pendingStop != nil }, set: { if !$0 { pendingStop = nil } }
        )) {
            if let pendingStop {
                Button("Stop Container", role: .destructive) { Task { await model.stop(pendingStop) }; self.pendingStop = nil }
            }
            Button("Cancel", role: .cancel) { pendingStop = nil }
        } message: { Text("Docker will request a graceful container stop using its configured timeout.") }
        .sheet(isPresented: Binding(get: { !model.logsContainerName.isEmpty }, set: { if !$0 { model.logsContainerName = "" } })) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Recent logs — \(model.logsContainerName)").font(.headline).padding()
                Divider()
                ScrollView([.horizontal, .vertical]) {
                    Text(model.logs).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding()
                }
            }
            .frame(width: 760, height: 480)
        }
        .alert(item: $model.error) { value in Alert(title: Text("Docker action failed"), message: Text(value.localizedDescription)) }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
