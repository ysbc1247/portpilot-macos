import SwiftData
import SwiftUI

@main
struct DevBerthApp: App {
    @StateObject private var model: AppModel
    private let container: ModelContainer

    init() {
        do {
            let schema = Schema(DevBerthSchemaV6.models)
            let isUITesting = ProcessInfo.processInfo.environment["DEVBERTH_UI_TESTING"] == "1"
            let configuration: ModelConfiguration
            if isUITesting {
                configuration = ModelConfiguration("DevBerthUITests", schema: schema, isStoredInMemoryOnly: true)
            } else {
                let migration = try ProductDataMigrator().migrateForCurrentUser()
                configuration = ModelConfiguration("DevBerth", schema: schema, url: migration.storeURL)
            }
            let createdContainer = try ModelContainer(
                for: schema,
                migrationPlan: DevBerthMigrationPlan.self,
                configurations: [configuration]
            )
            container = createdContainer
            let store = SwiftDataStore(modelContainer: createdContainer)
            let discoverer: (any PortDiscovering)? = isUITesting ? UITestPortDiscoverer() : nil
            let resourceReader: (any ProcessResourceUsageReading)? = isUITesting ? UITestResourceReader() : nil
            _model = StateObject(wrappedValue: AppModel(
                discoverer: discoverer,
                historyRecorder: store,
                ownershipRecorder: store,
                restartTrustStore: store,
                workspaceSessionRecorder: store,
                processResourceReader: resourceReader
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

private struct UITestPortDiscoverer: PortDiscovering {
    func discover() async throws -> [ObservedListener] {
        let observedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let command = "/usr/bin/python3 -m http.server 45123"
        let process = ObservedProcess(
            fingerprint: ProcessFingerprint(
                pid: 42_424,
                uid: 501,
                executablePath: "/usr/bin/python3",
                startTime: observedAt,
                commandLineDigest: ProcessFingerprint.digest(commandLine: command),
                parentPID: 1,
                detectedAt: observedAt
            ),
            name: "devberth-ui-fixture",
            commandLine: command,
            owner: "ui-test",
            currentDirectory: "/tmp/devberth-ui-fixture",
            parentName: "xctest",
            runtime: .python,
            project: nil,
            isSystemProcess: false,
            docker: nil,
            launchedByDevBerth: false,
            managedServiceID: nil
        )
        return [ObservedListener(
            protocolKind: .tcp,
            address: "127.0.0.1",
            port: 45_123,
            process: process,
            firstDetectedAt: observedAt,
            lastDetectedAt: observedAt
        )]
    }
}

private struct UITestResourceReader: ProcessResourceUsageReading {
    func read(pids: Set<Int32>) async throws -> [Int32: ProcessResourceUsage] {
        Dictionary(uniqueKeysWithValues: pids.map {
            ($0, ProcessResourceUsage(cpuPercent: 1.5, residentMemoryBytes: 12_582_912, capturedAt: Date()))
        })
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
