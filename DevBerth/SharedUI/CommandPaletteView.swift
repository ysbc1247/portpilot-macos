import SwiftData
import SwiftUI

struct CommandPaletteView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var isPresented: Bool
    @State private var query = ""
    @Query(sort: \LaunchProfileRecord.name) private var profiles: [LaunchProfileRecord]
    @Query private var dependencies: [ProfileDependencyRecord]
    @Query private var expectedPorts: [ExpectedPortRecord]
    @Query private var processPolicies: [ManagedServiceProcessPolicyRecord]

    private struct Action: Identifiable {
        let id = UUID()
        let title: String
        let symbol: String
        let keywords: String
        let perform: () -> Void
    }

    private var actions: [Action] {
        [
            Action(title: "Open Active Ports", symbol: "point.3.connected.trianglepath.dotted", keywords: "listeners search port") { model.navigate(to: .activePorts); isPresented = false },
            Action(title: "Open Projects", symbol: "folder", keywords: "services groups") { model.navigate(to: .projects); isPresented = false },
            Action(title: "Open Launch Profiles", symbol: "play.square.stack", keywords: "start run") { model.navigate(to: .launchProfiles); isPresented = false },
            Action(title: "Open History", symbol: "clock.arrow.circlepath", keywords: "events audit") { model.navigate(to: .history); isPresented = false },
            Action(title: "Open Docker", symbol: "shippingbox", keywords: "containers compose") { model.navigate(to: .docker); isPresented = false },
            Action(title: "Open Settings", symbol: "gearshape", keywords: "preferences") { model.navigate(to: .settings); isPresented = false },
            Action(title: "Refresh listeners", symbol: "arrow.clockwise", keywords: "ports reload") { model.refreshNow(); isPresented = false },
            Action(title: model.isMonitoring ? "Pause monitoring" : "Resume monitoring", symbol: model.isMonitoring ? "pause" : "play", keywords: "toggle") {
                model.isMonitoring ? model.pauseMonitoring() : model.startMonitoring(); isPresented = false
            }
        ] + profiles.compactMap { record in
            guard let profile = record.configuration(
                dependencies: dependencies,
                expectedPorts: expectedPorts,
                processPolicies: processPolicies
            ) else { return nil }
            return Action(title: "Start \(profile.name)", symbol: "play", keywords: "profile \(profile.tags.joined(separator: " "))") {
                Task { await model.launchProfile(profile) }
                isPresented = false
            }
        }
    }

    private var filtered: [Action] {
        guard !query.isEmpty else { return actions }
        return actions.filter { "\($0.title) \($0.keywords)".localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Type a command or port", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding()
            Divider()
            List(filtered) { action in
                Button(action: action.perform) {
                    Label(action.title, systemImage: action.symbol)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 5)
            }
        }
        .frame(width: 520, height: 310)
        .onSubmit {
            if let port = UInt16(query) {
                model.searchText = String(port)
                model.navigate(to: .activePorts)
                isPresented = false
            } else if filtered.count == 1 {
                filtered[0].perform()
            }
        }
    }
}
