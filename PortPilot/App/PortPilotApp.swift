import SwiftData
import SwiftUI

@main
struct PortPilotApp: App {
    @StateObject private var model: AppModel
    private let container: ModelContainer

    init() {
        do {
            let schema = Schema(PortPilotSchemaV1.models)
            let configuration = ModelConfiguration("PortPilot", schema: schema)
            let createdContainer = try ModelContainer(
                for: schema,
                migrationPlan: PortPilotMigrationPlan.self,
                configurations: [configuration]
            )
            container = createdContainer
            _model = StateObject(wrappedValue: AppModel(
                historyRecorder: SwiftDataStore(modelContainer: createdContainer)
            ))
        } catch {
            fatalError("Unable to initialize PortPilot's local database: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup("PortPilot", id: "main") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 620)
                .task { model.startMonitoring() }
        }
        .defaultSize(width: 1180, height: 760)
        .commands { PortPilotCommands(model: model) }
        .modelContainer(container)

        MenuBarExtra("PortPilot", systemImage: "point.3.connected.trianglepath.dotted") {
            MenuBarView()
                .environmentObject(model)
                .modelContainer(container)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(model)
                .modelContainer(container)
        }
    }
}

struct PortPilotCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandMenu("PortPilot") {
            Button("Refresh Listeners") { model.refreshNow() }
                .keyboardShortcut("r", modifiers: .command)
            Button(model.isMonitoring ? "Pause Monitoring" : "Resume Monitoring") {
                model.isMonitoring ? model.pauseMonitoring() : model.startMonitoring()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
        }
    }
}
