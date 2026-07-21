import SwiftData
import SwiftUI

@main
struct DevBerthApp: App {
    @StateObject private var model: AppModel
    private let container: ModelContainer

    init() {
        do {
            let migration = try ProductDataMigrator().migrateForCurrentUser()
            let schema = Schema(DevBerthSchemaV2.models)
            let configuration = ModelConfiguration("DevBerth", schema: schema, url: migration.storeURL)
            let createdContainer = try ModelContainer(
                for: schema,
                migrationPlan: DevBerthMigrationPlan.self,
                configurations: [configuration]
            )
            container = createdContainer
            _model = StateObject(wrappedValue: AppModel(
                historyRecorder: SwiftDataStore(modelContainer: createdContainer)
            ))
        } catch {
            fatalError("Unable to initialize DevBerth's local database: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup("DevBerth", id: "main") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 620)
                .task { model.startMonitoring() }
        }
        .defaultSize(width: 1180, height: 760)
        .commands { DevBerthCommands(model: model) }
        .modelContainer(container)

        MenuBarExtra("DevBerth", systemImage: "point.3.connected.trianglepath.dotted") {
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

struct DevBerthCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandMenu("DevBerth") {
            Button("Refresh Listeners") { model.refreshNow() }
                .keyboardShortcut("r", modifiers: .command)
            Button(model.isMonitoring ? "Pause Monitoring" : "Resume Monitoring") {
                model.isMonitoring ? model.pauseMonitoring() : model.startMonitoring()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
        }
    }
}
